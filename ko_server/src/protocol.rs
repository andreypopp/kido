use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::num::{NonZeroU16, NonZeroU64, NonZeroUsize};

use ko_config::runtime::{PathMap, RuntimePi};
use ko_config::values::{AbsPath, RuntimeColor, RuntimeName, env_valid};
use ko_pane_wire::frame::{
    self, CellPx, Dim, History, KeyAction, KeyCode, MouseAction, MouseButton,
};
use ko_pane_wire::ring;
use ko_sys::pid::Exit;
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::de::{self, DeserializeOwned};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::api::WaitMs;
use crate::config::BUILD;
use crate::http::Status;
use crate::ids::{ClientId, Instance, MessageId, Name, PaneId, SessionId, VarName, WindowId};
use crate::pane_proc::{self, Death};
use crate::route::{Body, Invalid};
use crate::vars::{Loose, Vars};

const PROTOCOL: &str = "1.0";
const PROTOCOL_MAJOR: &str = "1";
const VT: &str = env!("KO_VT");

pub(crate) const PROTOCOL_HEADER: &str = "ko-protocol";
pub(crate) const VT_HEADER: &str = "ko-vt";

pub(crate) fn version_headers() -> [(&'static str, String); 2] {
    [
        (PROTOCOL_HEADER, PROTOCOL.to_owned()),
        (VT_HEADER, VT.to_owned()),
    ]
}

pub fn decode<T: Serialize + DeserializeOwned>(text: &[u8]) -> serde_json::Result<T> {
    let value: T = serde_json::from_slice(text)?;
    if text.contains(&b'[')
        && !records_are_objects(
            &serde_json::from_slice(text)?,
            &serde_json::to_value(&value)?,
        )
    {
        return Err(de::Error::custom("a record must be a JSON object"));
    }
    Ok(value)
}

fn records_are_objects(input: &Value, output: &Value) -> bool {
    match (input, output) {
        (Value::Array(_), Value::Object(_)) => false,
        (Value::Object(input), Value::Object(output)) => output.iter().all(|(key, output)| {
            input
                .get(key)
                .is_none_or(|input| records_are_objects(input, output))
        }),
        (Value::Array(input), Value::Array(output)) => input
            .iter()
            .zip(output)
            .all(|(input, output)| records_are_objects(input, output)),
        _ => true,
    }
}

pub fn json(value: &impl Serialize) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Version {
    pub protocol: String,
    pub vt: String,
    pub build: String,
}

pub fn version() -> Version {
    Version {
        protocol: PROTOCOL.to_owned(),
        vt: VT.to_owned(),
        build: BUILD.to_owned(),
    }
}

/// The reply of a running server: its version, and the instance that changes at each start.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ServerVersion {
    #[serde(flatten)]
    pub version: Version,
    pub instance: Instance,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ErrorKind {
    Invalid,
    Refused,
    Gone,
    Io,
    PreconditionFailed,
    #[serde(rename = "not_found")]
    Missing,
    ProtocolMismatch(Version),
    VtMismatch(Version),
}

impl ErrorKind {
    pub(crate) fn status(&self) -> Status {
        match self {
            ErrorKind::Invalid => Status::BadRequest,
            ErrorKind::Refused | ErrorKind::VtMismatch(_) => Status::Conflict,
            ErrorKind::Gone => Status::Gone,
            ErrorKind::Io => Status::Internal,
            ErrorKind::Missing => Status::NotFound,
            ErrorKind::PreconditionFailed => Status::PreconditionFailed,
            ErrorKind::ProtocolMismatch(_) => Status::UpgradeRequired,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Error {
    #[serde(flatten)]
    pub kind: ErrorKind,
    pub message: String,
}

impl Error {
    pub(crate) fn new(kind: ErrorKind, message: impl Into<String>) -> Error {
        Error {
            kind,
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Empty {}

pub fn check_version(protocol: Option<&str>, vt: Option<&str>) -> Result<(), Error> {
    let compatible = protocol
        .and_then(|protocol| protocol.split_once('.'))
        .is_some_and(|(major, minor)| {
            major == PROTOCOL_MAJOR
                && !minor.is_empty()
                && minor.bytes().all(|byte| byte.is_ascii_digit())
        });
    if !compatible {
        Err(Error {
            kind: ErrorKind::ProtocolMismatch(version()),
            message: "protocol major mismatch".to_owned(),
        })
    } else if vt != Some(VT) {
        Err(Error {
            kind: ErrorKind::VtMismatch(version()),
            message: "terminal revision mismatch".to_owned(),
        })
    } else {
        Ok(())
    }
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "CellPixels")]
struct RawCellPx {
    #[schemars(range(min = 1))]
    width: u16,
    #[schemars(range(min = 1))]
    height: u16,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "Size")]
struct RawSize {
    #[schemars(range(min = 1, max = 4096))]
    cols: u16,
    #[schemars(range(min = 1, max = 4096))]
    rows: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cell_px: Option<CellPixels>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(try_from = "RawSize", into = "RawSize")]
#[schemars(with = "RawSize")]
pub struct Size(pub frame::Size);

impl TryFrom<RawSize> for Size {
    type Error = &'static str;

    fn try_from(raw: RawSize) -> Result<Size, &'static str> {
        Ok(Size(frame::Size {
            cols: Dim::new(raw.cols).ok_or("invalid size")?,
            rows: Dim::new(raw.rows).ok_or("invalid size")?,
            cell_px: raw.cell_px.map(|cell| cell.0),
        }))
    }
}

impl From<Size> for RawSize {
    fn from(Size(size): Size) -> RawSize {
        RawSize {
            cols: size.cols.get(),
            rows: size.rows.get(),
            cell_px: size.cell_px.map(CellPixels),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Cause {
    Exited { code: i32 },
    Signaled { signal: i32 },
    Failed { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Dead {
    pub at: u64,
    pub cause: Cause,
}

impl From<Exit> for Cause {
    fn from(exit: Exit) -> Cause {
        match exit {
            Exit::Exited(code) => Cause::Exited { code },
            Exit::Signaled(signal) => Cause::Signaled { signal },
        }
    }
}

impl From<&Death> for Dead {
    fn from(death: &Death) -> Dead {
        Dead {
            at: death.at.nanos(),
            cause: match &death.cause {
                pane_proc::Cause::Exit(exit) => Cause::from(*exit),
                pane_proc::Cause::StartFailed(message) | pane_proc::Cause::Failed(message) => {
                    Cause::Failed {
                        message: message.clone(),
                    }
                }
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ProgramKind {
    Permission,
    Question,
    Auth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ProgramState {
    Idle,
    Working {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        progress: Option<u8>,
    },
    Done,
    Blocked {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kind: Option<ProgramKind>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        progress: Option<u8>,
    },
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ProgramRecord {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    /// The server's monotonic start time in nanoseconds for a child record; absent on the root.
    pub started: Option<u64>,
    #[serde(flatten)]
    pub state: ProgramState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ProgramStatus {
    pub serial: u64,
    pub records: Vec<ProgramRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum OutcomeResult {
    Success,
    Failure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Outcome {
    pub serial: u64,
    pub result: OutcomeResult,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentState {
    Running {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        progress: Option<u8>,
    },
    Waiting {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kind: Option<ProgramKind>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        progress: Option<u8>,
    },
    Idle {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        outcome: Option<Outcome>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Agent {
    pub since: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
    pub state: AgentState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct CommandExit {
    pub code: i32,
    pub command: String,
    pub started_at: u64,
    pub ended_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Origin {
    Unknown,
    Command { command: String, started_at: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Phase {
    Unknown,
    Pending {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        last: Option<CommandExit>,
    },
    Idle {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        last: Option<CommandExit>,
    },
    Running {
        origin: Origin,
        fullscreen: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Shell {
    pub phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report: Option<Agent>,
}

impl Shell {
    pub fn running_command(&self) -> Option<&str> {
        match self {
            Shell {
                report: None,
                phase:
                    Phase::Running {
                        origin: Origin::Command { command, .. },
                        fullscreen: false,
                    },
            } if !command.is_empty() => Some(command),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Remote {
    Terminal { interactive: bool, status: Shell },
    Agent { name: String, status: Agent },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Local {
    Terminal(Shell),
    SomeAgent { name: String, status: Agent },
    PiAgent { session: String, status: Agent },
}

impl Local {
    fn shell(&self) -> Option<&Shell> {
        match self {
            Self::Terminal(shell) => Some(shell),
            Self::SomeAgent { .. } | Self::PiAgent { .. } => None,
        }
    }

    fn agent(&self) -> Option<&Agent> {
        match self {
            Self::SomeAgent { status, .. } | Self::PiAgent { status, .. } => Some(status),
            Self::Terminal(_) => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Live {
    Host { pane: Local },
    Runtime { pane: Local },
    Ssh { destination: String, pane: Remote },
}

impl Live {
    pub fn shell(&self) -> Option<&Shell> {
        match self {
            Live::Host { pane } | Live::Runtime { pane } => pane.shell(),
            Live::Ssh {
                pane: Remote::Terminal { status: shell, .. },
                ..
            } => Some(shell),
            Live::Ssh { .. } => None,
        }
    }

    pub fn agent(&self) -> Option<&Agent> {
        match self {
            Live::Host { pane } | Live::Runtime { pane } => pane.agent(),
            Live::Ssh {
                pane: Remote::Agent { status, .. },
                ..
            } => Some(status),
            Live::Ssh { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PaneStatus {
    pub kind: Live,
    pub program_status: ProgramStatus,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    pub since: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Foreground {
    pub pid: u32,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ProgressState {
    Set,
    Error,
    Indeterminate,
    Pause,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Progress {
    pub state: ProgressState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Row {
    pub id: PaneId,
    /// The pane's creation time in server monotonic nanoseconds.
    pub started: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<i32>,
    pub command: Vec<String>,
    pub cwd: String,
    pub title: String,
    #[schemars(extend("x-always-sent" = true))]
    pub dead: Option<Dead>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<Foreground>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<PaneStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<Progress>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<PaneId>,
    #[serde(default, skip_serializing_if = "Close::is_exit")]
    pub close: Close,
    /// True while the pane has its message stream open.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub inbox: bool,
    /// The runtime that runs the pane's program now. The host has none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeName>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Listing {
    #[serde(flatten)]
    pub row: Row,
    #[serde(default)]
    #[schemars(extend("x-always-sent" = true))]
    pub vars: Vars,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PasteResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub pasted: bool,
    #[serde(rename = "unsafe")]
    pub unsafe_paste: bool,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(remote = "KeyAction", rename_all = "lowercase")]
#[schemars(rename = "KeyAction")]
enum KeyActionDef {
    Release,
    Press,
    Repeat,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[schemars(rename = "Key")]
struct RawKey {
    #[serde(with = "KeyActionDef")]
    #[schemars(with = "KeyActionDef")]
    action: KeyAction,
    #[schemars(range(max = 175))]
    key: u16,
    mods: u16,
    #[schemars(range(max = 1_114_111))]
    #[schemars(description = "A Unicode scalar value: no surrogate, 0xD800 to 0xDFFF.")]
    unshifted_codepoint: u32,
    text: String,
    composing: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(try_from = "RawKey", into = "RawKey")]
#[schemars(with = "RawKey")]
pub struct Key(pub frame::Key);

impl TryFrom<RawKey> for Key {
    type Error = &'static str;

    fn try_from(raw: RawKey) -> Result<Key, &'static str> {
        Ok(Key(frame::Key {
            action: raw.action,
            key: KeyCode::new(raw.key).ok_or("invalid key")?,
            mods: raw.mods,
            unshifted: char::from_u32(raw.unshifted_codepoint).ok_or("invalid codepoint")?,
            text: raw.text,
            composing: raw.composing,
        }))
    }
}

impl From<Key> for RawKey {
    fn from(Key(key): Key) -> RawKey {
        RawKey {
            action: key.action,
            key: key.key.get(),
            mods: key.mods,
            unshifted_codepoint: u32::from(key.unshifted),
            text: key.text,
            composing: key.composing,
        }
    }
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(remote = "MouseAction", rename_all = "lowercase")]
#[schemars(rename = "MouseAction")]
enum MouseActionDef {
    Press,
    Release,
    Motion,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(remote = "MouseButton", rename_all = "lowercase")]
#[schemars(rename = "MouseButton")]
enum MouseButtonDef {
    Unknown,
    Left,
    Right,
    Middle,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,
    Ten,
    Eleven,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(remote = "frame::Mouse")]
#[schemars(rename = "Mouse")]
struct MouseDef {
    #[serde(with = "MouseActionDef")]
    #[schemars(with = "MouseActionDef")]
    action: MouseAction,
    #[serde(with = "MouseButtonDef")]
    #[schemars(with = "MouseButtonDef")]
    button: MouseButton,
    col: u16,
    row: u16,
    mods: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[schemars(with = "MouseDef")]
pub struct Mouse(#[serde(with = "MouseDef")] pub frame::Mouse);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Paste {
    pub text: String,
    pub check_safe: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(try_from = "String", into = "String")]
#[schemars(with = "Base64")]
pub struct Text(pub Vec<u8>);

struct Base64;

impl JsonSchema for Base64 {
    fn schema_name() -> Cow<'static, str> {
        "Base64".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "string", "contentEncoding": "base64"})
    }
}

impl TryFrom<String> for Text {
    type Error = &'static str;

    fn try_from(text: String) -> Result<Text, &'static str> {
        ko_pane_wire::base64::decode(&text)
            .map(Text)
            .ok_or("invalid base64")
    }
}

impl From<Text> for String {
    fn from(Text(bytes): Text) -> String {
        ko_pane_wire::base64::encode(&bytes)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Input {
    Key(Key),
    Mouse(Mouse),
    Paste(Paste),
    Text { data: Text },
}

impl<'a> From<&'a Input> for pane_proc::Input<'a> {
    fn from(input: &'a Input) -> pane_proc::Input<'a> {
        match input {
            Input::Key(key) => pane_proc::Input::Key(&key.0),
            Input::Mouse(mouse) => pane_proc::Input::Mouse(mouse.0),
            Input::Paste(paste) => pane_proc::Input::Paste {
                text: &paste.text,
                check_safe: paste.check_safe,
            },
            Input::Text { data } => pane_proc::Input::Text(&data.0),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    Argv { argv: Vec<String> },
    Shell { command: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Variable {
    pub name: String,
    pub value: String,
}

/// What the sweep does with a dead pane: exit removes it at once unless its program failed to start,
/// keep retains it, and on_exit removes it after the linger grace.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Close {
    #[default]
    Exit,
    Keep,
    OnExit,
}

impl Close {
    fn is_exit(&self) -> bool {
        *self == Close::Exit
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PanePatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close: Option<Close>,
}

/// Where a new pane starts: an absolute path of the host, or the directory of another pane. The
/// pane form needs a pane that the caller may read. The server maps the pane's directory into the
/// new pane's runtime, or to the host, through the runtimes' `paths`. When the pane's directory is
/// unknown or does not map, the new pane starts in the default directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum Cwd {
    Path(AbsPath),
    Pane { pane: PaneId },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct CreatePane {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<Cwd>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Command>,
    #[serde(default)]
    pub env: Vec<Variable>,
    #[serde(default, skip_serializing_if = "Loose::is_empty")]
    pub vars: Loose,
    /// The pane that this pane belongs to, for the pane's life. It must be a pane that is not
    /// dead. The sweep removes the pane when the parent is gone or dead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<PaneId>,
    #[serde(default, skip_serializing_if = "Close::is_exit")]
    pub close: Close,
    /// The runtime that runs the pane's program, for the pane's life. A caller on a runtime's
    /// socket creates panes in its own runtime only. Otherwise the host runs the pane.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<RuntimeName>,
}

/// A window of one pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct NewWindow {
    /// Defaults to the session of the parent, else of the calling pane, else a new session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<Name>,
    #[serde(flatten)]
    pub pane: CreatePane,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Placement {
    pub session: SessionId,
    pub window: WindowId,
    pub pane: PaneId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct StopPane {
    /// Milliseconds to wait for the pane to end by itself before ko removes it.
    #[serde(default = "WaitMs::none")]
    pub wait_ms: WaitMs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u16", into = "u16")]
pub struct Cells(Dim);

impl JsonSchema for Cells {
    fn schema_name() -> Cow<'static, str> {
        "Cells".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": Dim::MIN.get(), "maximum": Dim::MAX.get()})
    }
}

impl Cells {
    pub fn new(count: u16) -> Option<Cells> {
        Dim::new(count).map(Cells)
    }

    pub(crate) fn clamped(count: usize) -> Cells {
        let count = u16::try_from(count).unwrap_or(u16::MAX);
        Cells(Dim::new(count).unwrap_or(if count == 0 { Dim::MIN } else { Dim::MAX }))
    }

    pub fn get(self) -> u16 {
        self.0.get()
    }
}

impl From<Dim> for Cells {
    fn from(dim: Dim) -> Cells {
        Cells(dim)
    }
}

impl From<Cells> for Dim {
    fn from(cells: Cells) -> Dim {
        cells.0
    }
}

impl TryFrom<u16> for Cells {
    type Error = &'static str;

    fn try_from(count: u16) -> Result<Cells, &'static str> {
        Cells::new(count).ok_or("invalid size")
    }
}

impl From<Cells> for u16 {
    fn from(cells: Cells) -> u16 {
        cells.get()
    }
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(transparent)]
pub struct Revision(u64);

impl Revision {
    pub const FIRST: Revision = Revision(0);

    pub fn get(self) -> u64 {
        self.0
    }

    pub(crate) fn next(self) -> Revision {
        Revision(self.0.saturating_add(1))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(try_from = "RawCellPx", into = "RawCellPx")]
#[schemars(with = "RawCellPx")]
pub struct CellPixels(pub CellPx);

impl TryFrom<RawCellPx> for CellPixels {
    type Error = &'static str;

    fn try_from(raw: RawCellPx) -> Result<CellPixels, &'static str> {
        Ok(CellPixels(CellPx {
            width: NonZeroU16::new(raw.width).ok_or("invalid size")?,
            height: NonZeroU16::new(raw.height).ok_or("invalid size")?,
        }))
    }
}

impl From<CellPixels> for RawCellPx {
    fn from(CellPixels(cell): CellPixels) -> RawCellPx {
        RawCellPx {
            width: cell.width.get(),
            height: cell.height.get(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub enum Axis {
    #[serde(rename = "h")]
    Horizontal,
    #[serde(rename = "v")]
    Vertical,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
#[schemars(rename = "{L}Node")]
pub enum Node<L> {
    Split { split: Axis, children: Vec<Node<L>> },
    Leaf(L),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Leaf {
    pub pane: PaneId,
    pub cols: Cells,
    pub rows: Cells,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Float {
    pub pane: PaneId,
    pub x: u16,
    pub y: u16,
    pub cols: Cells,
    pub rows: Cells,
    pub z: u32,
    pub border: bool,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Window {
    pub id: WindowId,
    pub name: Name,
    pub vars: Vars,
    pub cols: Cells,
    pub rows: Cells,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell_px: Option<CellPixels>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zoom: Option<PaneId>,
    pub focus: PaneId,
    pub tree: Node<Leaf>,
    pub floats: Vec<Float>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Session {
    pub id: SessionId,
    pub name: Name,
    pub vars: Vars,
    pub windows: Vec<Window>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Layout {
    pub sessions: Vec<Session>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Snapshot {
    pub revision: Revision,
    pub layout: Layout,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct LayoutPanes {
    #[serde(flatten)]
    pub snapshot: Snapshot,
    pub panes: Vec<Listing>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum PaneRef {
    Existing(PaneId),
    New { new: CreatePane },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DraftLeaf {
    pub pane: PaneRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<Cells>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<Cells>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DraftFloat {
    pub pane: PaneRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<Cells>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<Cells>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub z: Option<u32>,
    #[serde(default)]
    pub border: bool,
    #[serde(default)]
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DraftWindow {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<WindowId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<Name>,
    #[serde(default)]
    pub vars: Loose,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<Cells>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<Cells>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell_px: Option<CellPixels>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zoom: Option<PaneId>,
    pub tree: Node<DraftLeaf>,
    #[serde(default)]
    pub floats: Vec<DraftFloat>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DraftSession {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<SessionId>,
    pub name: Name,
    #[serde(default)]
    pub vars: Loose,
    pub windows: Vec<DraftWindow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DraftLayout {
    pub sessions: Vec<DraftSession>,
}

impl DraftLayout {
    // The session and window indices of the window that holds the pane.
    pub fn locate(&self, pane: PaneId) -> Option<(usize, usize)> {
        self.sessions.iter().enumerate().find_map(|(s, session)| {
            session
                .windows
                .iter()
                .position(|window| window.holds(pane))
                .map(|w| (s, w))
        })
    }

    pub fn window_mut(&mut self, id: WindowId) -> Option<&mut DraftWindow> {
        self.sessions
            .iter_mut()
            .flat_map(|session| session.windows.iter_mut())
            .find(|window| window.id == Some(id))
    }

    pub fn session_mut(&mut self, id: SessionId) -> Option<&mut DraftSession> {
        self.sessions
            .iter_mut()
            .find(|session| session.id == Some(id))
    }
}

impl DraftWindow {
    pub fn holds(&self, pane: PaneId) -> bool {
        self.tree.contains(pane)
            || self
                .floats
                .iter()
                .any(|float| float.pane == PaneRef::Existing(pane))
    }

    pub fn single(request: &CreatePane) -> DraftWindow {
        Self::leaf(DraftLeaf {
            pane: PaneRef::New {
                new: request.clone(),
            },
            cols: None,
            rows: None,
        })
    }

    pub fn leaf(leaf: DraftLeaf) -> DraftWindow {
        DraftWindow {
            id: None,
            name: None,
            vars: Loose::new(),
            cols: None,
            rows: None,
            cell_px: None,
            zoom: None,
            tree: Node::Leaf(leaf),
            floats: Vec::new(),
        }
    }
}

impl DraftSession {
    pub fn single(name: Name, request: &CreatePane) -> DraftSession {
        DraftSession {
            id: None,
            name: name.clone(),
            vars: Loose::new(),
            windows: vec![DraftWindow::single(request)],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PutLayout {
    pub revision: Revision,
    pub layout: DraftLayout,
}

impl Node<Leaf> {
    pub fn leaves<'a>(&'a self, out: &mut Vec<&'a Leaf>) {
        match self {
            Node::Leaf(leaf) => out.push(leaf),
            Node::Split { children, .. } => {
                children.iter().for_each(|child| child.leaves(out));
            }
        }
    }
}

pub fn pick<T>(axis: Axis, cols: T, rows: T) -> T {
    match axis {
        Axis::Horizontal => cols,
        Axis::Vertical => rows,
    }
}

// A leaf of a layout tree: its pane once it has one, and its size on an axis once known.
pub trait Tile {
    fn pane_id(&self) -> Option<PaneId>;
    fn extent(&self, axis: Axis) -> Option<usize>;
}

impl Tile for Leaf {
    fn pane_id(&self) -> Option<PaneId> {
        Some(self.pane)
    }

    fn extent(&self, axis: Axis) -> Option<usize> {
        Some(usize::from(pick(axis, self.cols, self.rows).get()))
    }
}

impl Tile for DraftLeaf {
    fn pane_id(&self) -> Option<PaneId> {
        match self.pane {
            PaneRef::Existing(id) => Some(id),
            PaneRef::New { .. } => None,
        }
    }

    fn extent(&self, axis: Axis) -> Option<usize> {
        pick(axis, self.cols, self.rows).map(|size| usize::from(size.get()))
    }
}

impl<L> Node<L> {
    // The fewest cells that the node needs on the axis: one for each leaf and each divider.
    pub fn minimum(&self, axis: Axis) -> usize {
        match self {
            Node::Leaf(_) => 1,
            Node::Split { split, children } => {
                let mins = children.iter().map(|child| child.minimum(axis));
                if *split == axis {
                    mins.sum::<usize>() + children.len().saturating_sub(1)
                } else {
                    mins.max().unwrap_or(1)
                }
            }
        }
    }
}

impl<L: Tile> Node<L> {
    pub fn contains(&self, pane: PaneId) -> bool {
        match self {
            Node::Leaf(leaf) => leaf.pane_id() == Some(pane),
            Node::Split { children, .. } => children.iter().any(|child| child.contains(pane)),
        }
    }

    // The node's size on the axis from the sizes of the leaves that have one.
    pub fn known(&self, axis: Axis) -> Option<usize> {
        match self {
            Node::Leaf(leaf) => leaf.extent(axis),
            Node::Split { split, children } => {
                let sizes: Vec<usize> = children
                    .iter()
                    .filter_map(|child| child.known(axis))
                    .collect();
                if *split == axis {
                    (!sizes.is_empty()).then(|| sizes.iter().sum::<usize>() + sizes.len() - 1)
                } else {
                    sizes.into_iter().max()
                }
            }
        }
    }
}

impl Window {
    pub fn panes(&self) -> Vec<PaneId> {
        let mut leaves = Vec::new();
        self.tree.leaves(&mut leaves);
        leaves
            .into_iter()
            .map(|leaf| leaf.pane)
            .chain(self.floats.iter().map(|float| float.pane))
            .collect()
    }

    pub(crate) fn has(&self, pane: PaneId) -> bool {
        self.tree.contains(pane) || self.floats.iter().any(|float| float.pane == pane)
    }

    pub fn pane_sizes(&self) -> Vec<(PaneId, frame::Size)> {
        let mut leaves = Vec::new();
        self.tree.leaves(&mut leaves);
        let cell_px = self.cell_px.map(|cell| cell.0);
        leaves
            .into_iter()
            .map(|leaf| (leaf.pane, leaf.cols, leaf.rows))
            .chain(
                self.floats
                    .iter()
                    .map(|float| (float.pane, float.cols, float.rows)),
            )
            .map(|(pane, cols, rows)| {
                let (cols, rows) = if self.zoom == Some(pane) {
                    (self.cols, self.rows)
                } else {
                    (cols, rows)
                };
                (
                    pane,
                    frame::Size {
                        cols: cols.into(),
                        rows: rows.into(),
                        cell_px,
                    },
                )
            })
            .collect()
    }
}

impl Layout {
    pub fn windows(&self) -> impl Iterator<Item = (&Session, &Window)> {
        self.sessions
            .iter()
            .flat_map(|session| session.windows.iter().map(move |window| (session, window)))
    }

    pub fn session(&self, id: SessionId) -> Option<&Session> {
        self.sessions.iter().find(|session| session.id == id)
    }

    pub fn window(&self, id: WindowId) -> Option<(&Session, &Window)> {
        self.windows().find(|(_, window)| window.id == id)
    }

    pub fn locate(&self, pane: PaneId) -> Option<(&Session, &Window)> {
        self.windows().find(|(_, window)| window.has(pane))
    }

    pub fn pane_sizes(&self) -> Vec<(PaneId, frame::Size)> {
        self.windows()
            .flat_map(|(_, window)| window.pane_sizes())
            .collect()
    }

    pub fn panes(&self) -> BTreeSet<PaneId> {
        self.windows()
            .flat_map(|(_, window)| window.panes())
            .collect()
    }
}

impl From<&Node<Leaf>> for Node<DraftLeaf> {
    fn from(node: &Node<Leaf>) -> Node<DraftLeaf> {
        match node {
            Node::Leaf(leaf) => Node::Leaf(DraftLeaf {
                pane: PaneRef::Existing(leaf.pane),
                cols: Some(leaf.cols),
                rows: Some(leaf.rows),
            }),
            Node::Split { split, children } => Node::Split {
                split: *split,
                children: children.iter().map(Node::from).collect(),
            },
        }
    }
}

impl From<&Float> for DraftFloat {
    fn from(float: &Float) -> DraftFloat {
        DraftFloat {
            pane: PaneRef::Existing(float.pane),
            x: Some(float.x),
            y: Some(float.y),
            cols: Some(float.cols),
            rows: Some(float.rows),
            z: Some(float.z),
            border: float.border,
            title: float.title.clone(),
        }
    }
}

impl From<&Window> for DraftWindow {
    fn from(window: &Window) -> DraftWindow {
        DraftWindow {
            id: Some(window.id),
            name: Some(window.name.clone()),
            vars: window.vars.loose(),
            cols: Some(window.cols),
            rows: Some(window.rows),
            cell_px: window.cell_px,
            zoom: window.zoom,
            tree: Node::from(&window.tree),
            floats: window.floats.iter().map(DraftFloat::from).collect(),
        }
    }
}

impl From<&Session> for DraftSession {
    fn from(session: &Session) -> DraftSession {
        DraftSession {
            id: Some(session.id),
            name: session.name.clone(),
            vars: session.vars.loose(),
            windows: session.windows.iter().map(DraftWindow::from).collect(),
        }
    }
}

impl From<&Layout> for DraftLayout {
    fn from(layout: &Layout) -> DraftLayout {
        DraftLayout {
            sessions: layout.sessions.iter().map(DraftSession::from).collect(),
        }
    }
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(remote = "History", rename_all = "lowercase")]
#[schemars(rename = "History")]
pub(crate) enum HistoryDef {
    None,
    All,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Images {
    #[default]
    None,
}

fn no_history() -> History {
    History::None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ViewOptions {
    #[serde(with = "HistoryDef", default = "no_history")]
    #[schemars(with = "HistoryDef")]
    pub history: History,
    #[serde(default)]
    pub images: Images,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Marker {
    Resize(Size),
    Dead { at: u64 },
}

impl From<ring::Marker> for Marker {
    fn from(marker: ring::Marker) -> Marker {
        match marker {
            ring::Marker::Resize(size) => Marker::Resize(Size(size)),
            ring::Marker::Dead(dead) => Marker::Dead {
                at: dead.at.nanos(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Hello {
    pub name: String,
    #[serde(flatten)]
    pub selection: Selection,
    pub focused: bool,
    pub sizing: Sizing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Sizing {
    Disabled,
    Windows {
        viewport: Size,
        windows: WindowSizes,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct WindowSize {
    pub window: WindowId,
    pub size: Size,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "Vec<WindowSize>", into = "Vec<WindowSize>")]
pub struct WindowSizes(Vec<WindowSize>);

impl JsonSchema for WindowSizes {
    fn schema_name() -> Cow<'static, str> {
        "WindowSizes".into()
    }
    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "array", "items": generator.subschema_for::<WindowSize>(), "uniqueItems": true,
            "description": "Window ids must be unique, including entries with different sizes."})
    }
}

impl From<Option<WindowSize>> for WindowSizes {
    fn from(window: Option<WindowSize>) -> Self {
        Self(window.into_iter().collect())
    }
}

impl TryFrom<Vec<WindowSize>> for WindowSizes {
    type Error = &'static str;

    fn try_from(windows: Vec<WindowSize>) -> Result<Self, Self::Error> {
        let mut ids = std::collections::BTreeSet::new();
        if windows.iter().any(|entry| !ids.insert(entry.window)) {
            return Err("duplicate window size");
        }
        Ok(Self(windows))
    }
}

impl From<WindowSizes> for Vec<WindowSize> {
    fn from(windows: WindowSizes) -> Self {
        windows.0
    }
}

impl WindowSizes {
    pub(crate) fn iter(&self) -> impl Iterator<Item = &WindowSize> {
        self.0.iter()
    }
}

impl Sizing {
    pub(crate) fn size(&self, window: WindowId) -> Option<frame::Size> {
        match self {
            Self::Disabled => None,
            Self::Windows { windows, .. } => windows
                .iter()
                .find(|entry| entry.window == window)
                .map(|entry| entry.size.0),
        }
    }

    pub(crate) fn retain(&mut self, keep: impl FnMut(&WindowSize) -> bool) {
        if let Self::Windows { windows, .. } = self {
            windows.0.retain(keep);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct NavigationId(NonZeroU64);

impl NavigationId {
    pub fn next(previous: Option<Self>) -> Option<Self> {
        previous.map_or(Some(Self(NonZeroU64::MIN)), |id| {
            id.0.checked_add(1).map(Self)
        })
    }
}

impl TryFrom<u64> for NavigationId {
    type Error = &'static str;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        NonZeroU64::new(value)
            .map(Self)
            .ok_or("navigation id must be nonzero")
    }
}

impl From<NavigationId> for u64 {
    fn from(id: NavigationId) -> Self {
        id.0.get()
    }
}

impl JsonSchema for NavigationId {
    fn schema_name() -> Cow<'static, str> {
        "NavigationId".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": 1, "maximum": u64::MAX, "description": "The client's id of a select or switch, which its selected answer echoes."})
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Selection {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<WindowId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<PaneId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Over {
    Session,
    Window,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Next,
    Previous,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Switch {
    pub over: Over,
    pub direction: Direction,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientRequest {
    Hello(Hello),
    Select {
        request: NavigationId,
        #[serde(flatten)]
        selection: Selection,
    },
    Switch {
        request: NavigationId,
        #[serde(flatten)]
        switch: Switch,
    },
    Size {
        sizing: Sizing,
    },
    Focused {
        focused: bool,
    },
    ClipboardAnswer {
        id: u64,
        #[serde(flatten)]
        served: Option<ClipboardServed>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ViewRequest {
    Resync(ViewOptions),
    Input { input: Input },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct Bounds {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_bytes: Option<NonZeroUsize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_lines: Option<NonZeroUsize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum Scrollback {
    Disabled,
    Scrollback(Bounds),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Terminal {
    pub(crate) scrollback: Scrollback,
    pub(crate) apc_max_bytes: usize,
    pub(crate) kitty_images_max_bytes: u64,
    pub(crate) continuation_max_bytes: usize,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(remote = "frame::Medium", rename_all = "snake_case")]
#[schemars(rename = "Medium")]
enum MediumDef {
    File,
    TempFile,
    SharedMem,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[schemars(with = "MediumDef")]
pub(crate) struct Medium(#[serde(with = "MediumDef")] pub(crate) frame::Medium);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Limits {
    pub terminal: Terminal,
    pub(crate) media: Vec<Medium>,
}

impl Limits {
    pub fn of(limits: frame::Limits, media: &[frame::Medium]) -> Limits {
        Limits {
            terminal: Terminal {
                scrollback: match limits.scrollback {
                    frame::Scrollback::Disabled => Scrollback::Disabled,
                    frame::Scrollback::Bounded {
                        max_bytes,
                        max_lines,
                    } => Scrollback::Scrollback(Bounds {
                        max_bytes,
                        max_lines,
                    }),
                },
                apc_max_bytes: limits.apc_max_bytes,
                kitty_images_max_bytes: limits.kitty_images_max_bytes,
                continuation_max_bytes: limits.continuation_max_bytes,
            },
            media: media.iter().copied().map(Medium).collect(),
        }
    }
}

impl Terminal {
    pub fn limits(&self) -> frame::Limits {
        frame::Limits {
            scrollback: match self.scrollback {
                Scrollback::Disabled => frame::Scrollback::Disabled,
                Scrollback::Scrollback(bounds) => frame::Scrollback::Bounded {
                    max_bytes: bounds.max_bytes,
                    max_lines: bounds.max_lines,
                },
            },
            apc_max_bytes: self.apc_max_bytes,
            kitty_images_max_bytes: self.kitty_images_max_bytes,
            continuation_max_bytes: self.continuation_max_bytes,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Welcome {
    pub client: ClientId,
    pub limits: Limits,
    pub instance: Instance,
    pub now: u64,
    /// Runtimes with their link states, configured first by name, then by session.
    pub runtimes: Vec<ClientRuntime>,
    /// The latest runtime configuration error; absent after a successful read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtimes_error: Option<String>,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RuntimeSource {
    /// An entry of the configuration file. Its name is global.
    Config,
    /// A definition that a pane of the session registered; it goes with the session.
    Session { id: SessionId },
}

/// What a client needs of a runtime to mark its panes and offer it for a new pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ClientRuntime {
    pub name: RuntimeName,
    pub source: RuntimeSource,
    pub kind: RuntimeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<RuntimeColor>,
    pub state: LinkState,
}

impl ClientRuntime {
    pub fn is(&self, name: &RuntimeName, source: RuntimeSource) -> bool {
        self.name == *name && self.source == source
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Title {
    pub pane: PaneId,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Pwd {
    pub pane: PaneId,
    pub pwd: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PaneDead {
    pub pane: PaneId,
    pub dead: Dead,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct StatusChange {
    pub pane: PaneId,
    pub status: PaneStatus,
    pub now: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    Refused {
        message: String,
    },
    Welcome(Welcome),
    Layout(LayoutPanes),
    Focus {
        window: WindowId,
        pane: PaneId,
    },
    Selected {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        request: Option<NavigationId>,
        #[serde(flatten)]
        selection: Selection,
    },
    Title(Title),
    Pwd(Pwd),
    Pid {
        pane: PaneId,
        pid: i32,
    },
    Foreground {
        pane: PaneId,
        foreground: Foreground,
    },
    Dead(PaneDead),
    Status(StatusChange),
    Var {
        pane: PaneId,
        name: VarName,
        value: Value,
    },
    VarDeleted {
        pane: PaneId,
        name: VarName,
    },
    Bell {
        pane: PaneId,
    },
    ClipboardWrite {
        pane: PaneId,
        location: ClipboardLocation,
        contents: Vec<ClipboardContent>,
    },
    ClipboardRead {
        pane: PaneId,
        id: u64,
        location: ClipboardLocation,
        mimes: Vec<String>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        list: bool,
    },
    Notify {
        pane: PaneId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        body: String,
    },
    Progress {
        pane: PaneId,
        #[schemars(extend("x-always-sent" = true))]
        progress: Option<Progress>,
    },
    Inbox {
        pane: PaneId,
        inbox: bool,
    },
    PaneRuntime {
        pane: PaneId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        runtime: Option<RuntimeName>,
    },
    /// A runtime was added to the list, or its kind, colour or link state changed.
    Runtime(ClientRuntime),
    /// The runtime configuration error changed. An absent message clears the error.
    RuntimesError {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// A runtime left the configuration and has no live link.
    RuntimeDeleted {
        name: RuntimeName,
        source: RuntimeSource,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardLocation {
    Standard,
    Selection,
    Primary,
}

impl From<frame::ClipboardLocation> for ClipboardLocation {
    fn from(location: frame::ClipboardLocation) -> ClipboardLocation {
        match location {
            frame::ClipboardLocation::Standard => ClipboardLocation::Standard,
            frame::ClipboardLocation::Selection => ClipboardLocation::Selection,
            frame::ClipboardLocation::Primary => ClipboardLocation::Primary,
        }
    }
}

impl From<ClipboardLocation> for frame::ClipboardLocation {
    fn from(location: ClipboardLocation) -> frame::ClipboardLocation {
        match location {
            ClipboardLocation::Standard => frame::ClipboardLocation::Standard,
            ClipboardLocation::Selection => frame::ClipboardLocation::Selection,
            ClipboardLocation::Primary => frame::ClipboardLocation::Primary,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ClipboardServed {
    pub contents: Vec<ClipboardContent>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub available: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ClipboardContent {
    pub mime: String,
    pub data: Text,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PixelFormat {
    Rgb,
    Rgba,
    GrayAlpha,
    Gray,
}

impl PixelFormat {
    pub fn header(self) -> &'static str {
        match self {
            PixelFormat::Rgb => "rgb",
            PixelFormat::Rgba => "rgba",
            PixelFormat::GrayAlpha => "gray_alpha",
            PixelFormat::Gray => "gray",
        }
    }

    pub fn from_header(text: &str) -> Option<PixelFormat> {
        [
            PixelFormat::Rgb,
            PixelFormat::Rgba,
            PixelFormat::GrayAlpha,
            PixelFormat::Gray,
        ]
        .into_iter()
        .find(|format| format.header() == text)
    }
}

impl From<frame::PixelFormat> for PixelFormat {
    fn from(format: frame::PixelFormat) -> PixelFormat {
        match format {
            frame::PixelFormat::Rgb => PixelFormat::Rgb,
            frame::PixelFormat::Rgba => PixelFormat::Rgba,
            frame::PixelFormat::GrayAlpha => PixelFormat::GrayAlpha,
            frame::PixelFormat::Gray => PixelFormat::Gray,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ImageShm {
    pub name: String,
    pub length: u64,
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    pub generation: u64,
    pub gap_ms: u32,
    pub frames: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SearchMatch {
    pub row: u32,
    pub col: u16,
    pub end_row: u32,
    pub end_col: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SearchEvent {
    Matches { matches: Vec<SearchMatch> },
    Done,
}

pub const IMAGE_FORMAT_HEADER: &str = "ko-image-format";
pub const IMAGE_WIDTH_HEADER: &str = "ko-image-width";
pub const IMAGE_HEIGHT_HEADER: &str = "ko-image-height";
pub const IMAGE_GENERATION_HEADER: &str = "ko-image-generation";
pub const IMAGE_GAP_HEADER: &str = "ko-image-gap-ms";
pub const IMAGE_FRAMES_HEADER: &str = "ko-image-frames";
pub const ACCEPT_SHM_HEADER: &str = "ko-accept-shm";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub enum SessionRef {
    Id(SessionId),
    Name(Name),
}

impl JsonSchema for SessionRef {
    fn schema_name() -> Cow<'static, str> {
        "SessionRef".into()
    }

    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "anyOf": [generator.subschema_for::<SessionId>(), generator.subschema_for::<Name>()],
            "description": "A session id, or the name of a session."
        })
    }
}

impl TryFrom<String> for SessionRef {
    type Error = &'static str;

    fn try_from(text: String) -> Result<SessionRef, &'static str> {
        match text.parse() {
            Ok(id) => Ok(SessionRef::Id(id)),
            Err(_) => Name::try_from(text).map(SessionRef::Name),
        }
    }
}

impl From<SessionRef> for String {
    fn from(session: SessionRef) -> String {
        match session {
            SessionRef::Id(id) => id.to_string(),
            SessionRef::Name(name) => name.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct VarCondition {
    pub name: VarName,
    pub value: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DeleteVars {
    pub names: Vec<VarName>,
    #[serde(default, rename = "if", skip_serializing_if = "Option::is_none")]
    pub condition: Option<VarCondition>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Candidate {
    pub pane: PaneId,
    pub session: SessionId,
    pub window: WindowId,
    pub title: String,
    /// True while the pane has its message stream open, so a prompt goes through its queue.
    pub inbox: bool,
}

/// A prompt for the agent in a pane. The scope is the window of `from`, else its session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SendPrompt {
    /// The pane that the prompt comes from. A pane identity may name only itself.
    pub from: PaneId,
    /// The id of the message when the prompt goes through the agent's message stream.
    pub id: MessageId,
    pub target: PaneId,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Via {
    Paste,
    Message(Posted),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Sent {
    pub via: Via,
}

impl From<Posted> for Sent {
    fn from(posted: Posted) -> Sent {
        Sent {
            via: Via::Message(posted),
        }
    }
}

/// What a message is to the sender's knowledge: queued is in the pane's queue and not written,
/// delivered is written to the stream and not acked, acked is received.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MessageState {
    Queued,
    Delivered,
    Acked,
}

/// The state of a sent message. The seq counts the messages of the pane in arrival order. A
/// repeat of an id that the pane has seen is a duplicate and gets the state of the original.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Posted {
    pub state: MessageState,
    pub seq: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub duplicate: bool,
}

/// Any JSON value of at most 4096 bytes when encoded.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "Value", into = "Value")]
pub struct Data(Value, usize);

const MAX_DATA: usize = 4096;

impl TryFrom<Value> for Data {
    type Error = &'static str;

    fn try_from(value: Value) -> Result<Data, &'static str> {
        let length = json(&value).len();
        if length <= MAX_DATA {
            Ok(Data(value, length))
        } else {
            Err("data exceeds 4 KiB")
        }
    }
}

impl From<Data> for Value {
    fn from(Data(value, _): Data) -> Value {
        value
    }
}

impl Data {
    pub(crate) fn len(&self) -> usize {
        self.1
    }
}

impl JsonSchema for Data {
    fn schema_name() -> Cow<'static, str> {
        "Data".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"description": "Any JSON value of at most 4096 bytes when encoded."})
    }
}

/// What the sender of a message is to its receiver, from the `parent` edges of the panes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Relation {
    Parent,
    Child,
    Sibling,
    Descendant,
    SiblingDescendant,
}

/// The kinds that a sender may give. The server reads none of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SendKind {
    Message,
    Steer,
    Interrupt,
    Stop,
    Notice,
}

/// A message to the pane in the path. The server stamps the sender.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SendMessage {
    pub id: MessageId,
    pub kind: SendKind,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Data>,
}

/// The sender of a message, as the server knows it. The session and the name are those of a
/// pane that has a pi root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Sender {
    Pane {
        pane: PaneId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    User,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Payload {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Data>,
}

/// How a pane that has a parent ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum End {
    Dead(Dead),
    Gone,
}

/// The kinds of a received message: those of the senders, user for a prompt of `ko prompt`, and
/// ended, which the server makes when a pane with a parent dies or leaves the layout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Content {
    Message(Payload),
    Steer(Payload),
    Interrupt(Payload),
    Stop(Payload),
    Notice(Payload),
    User(Payload),
    Ended { end: End },
}

impl Content {
    pub(crate) fn sent(kind: SendKind, payload: Payload) -> Content {
        match kind {
            SendKind::Message => Content::Message(payload),
            SendKind::Steer => Content::Steer(payload),
            SendKind::Interrupt => Content::Interrupt(payload),
            SendKind::Stop => Content::Stop(payload),
            SendKind::Notice => Content::Notice(payload),
        }
    }
}

/// A message on the message stream of a pane. The id is the sender's, so the receiver can drop a
/// repeat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Message {
    pub seq: u64,
    pub id: MessageId,
    pub from: Sender,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relation: Option<Relation>,
    #[serde(flatten)]
    pub content: Content,
}

/// What the receiver says about a message of its stream. A message that is neither acked nor
/// refused is written again to the next stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamRequest {
    Ack { id: MessageId },
    Refuse { id: MessageId },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Marked {
    pub offset: u64,
    pub marker: Marker,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Skipped {
    pub offset: u64,
    pub from: u64,
    pub to: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ViewEvent {
    Marked(Marked),
    Skipped(Skipped),
    Pasted(PasteResult),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub(crate) enum InputResult {
    Pasted(PasteResult),
    Sent(Empty),
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(transparent)]
pub(crate) struct VarValue(pub(crate) Value);

impl Body for VarValue {
    const OVERSIZED: &'static str = "variable too large";

    fn decode(payload: Option<&[u8]>) -> Result<VarValue, Invalid> {
        let bytes = payload.ok_or_else(|| Invalid::message(Self::OVERSIZED))?;
        serde_json::from_slice(bytes).map_err(|error| Invalid::message(error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use serde::de::DeserializeOwned;

    #[test]
    fn window_size_reports_are_complete_and_reject_duplicate_windows() {
        same::<ClientRequest>(
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":120,"rows":40},"windows":[{"window":"window_1","size":{"cols":35,"rows":12}},{"window":"window_2","size":{"cols":60,"rows":20}}]}}"#,
        );
        same::<ClientRequest>(r#"{"type":"size","sizing":{"type":"disabled"}}"#);
        for invalid in [
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":120,"rows":40},"windows":[{"window":"window_1","size":{"cols":35,"rows":12}},{"window":"window_1","size":{"cols":60,"rows":20}}]}}"#,
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":120,"rows":40},"windows":[{"window":"bad","size":{"cols":35,"rows":12}}]}}"#,
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":120,"rows":40},"windows":[{"window":"window_1","size":{"cols":4097,"rows":12}}]}}"#,
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":120,"rows":40},"windows":[["window_1",{"cols":35,"rows":12}]]}}"#,
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":120,"rows":40},"windows":[{"window":"window_1","size":[35,12]}]}}"#,
        ] {
            assert!(
                decode::<ClientRequest>(invalid.as_bytes()).is_err(),
                "{invalid}"
            );
        }
    }

    #[test]
    fn every_wire_type_round_trips_its_json() {
        same::<Version>(
            r#"{"protocol":"1.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty"}"#,
        );
        for json in [
            r#"{"kind":"invalid","message":"m"}"#,
            r#"{"kind":"refused","message":"m"}"#,
            r#"{"kind":"gone","message":"m"}"#,
            r#"{"kind":"io","message":"m"}"#,
            r#"{"kind":"not_found","message":"m"}"#,
            r#"{"kind":"precondition_failed","message":"m"}"#,
            r#"{"kind":"protocol_mismatch","protocol":"1.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty","message":"m"}"#,
            r#"{"kind":"vt_mismatch","protocol":"1.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty","message":"m"}"#,
        ] {
            same::<Error>(json);
        }
        for json in [
            r#"{"names":["pi.session","pi.name"]}"#,
            r#"{"names":["pi.session"],"if":{"name":"pi.session","value":"abc"}}"#,
        ] {
            same::<DeleteVars>(json);
        }
        for json in [
            r#"{"id":"pane_3","started":0,"pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":null}"#,
            r#"{"id":"pane_3","started":0,"pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"exited","code":7}}}"#,
            r#"{"id":"pane_3","started":0,"pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"signaled","signal":9}}}"#,
            r#"{"id":"pane_3","started":0,"pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"failed","message":"boom"}}}"#,
        ] {
            same::<Row>(json);
        }
        same::<Row>(
            r#"{"id":"pane_4","started":0,"pid":1,"command":["/bin/sh"],"cwd":"/","title":"","dead":null,"foreground":{"pid":77,"name":"sleep"},"status":{"kind":{"type":"host","pane":{"type":"terminal","phase":{"type":"running","origin":{"type":"command","command":"sleep 2","started_at":5},"fullscreen":false},"report":{"since":4,"msg":"m","state":{"type":"waiting","kind":"question","progress":42}}}},"program_status":{"serial":3,"records":[{"id":"","state":"blocked","kind":"question","progress":42,"app":"pi","title":"t","msg":"m"},{"id":"a/b","state":"working"},{"id":"c","state":"done"}]},"title":"sleep 2","message":"m","progress":42,"since":6},"progress":{"state":"set","progress":50}}"#,
        );
        for json in [
            r#"{"type":"host","pane":{"type":"some_agent","name":"claude-code","status":{"since":1,"state":{"type":"idle","outcome":{"serial":2,"result":"success"}}}}}"#,
            r#"{"type":"host","pane":{"type":"pi_agent","session":"s","status":{"since":1,"state":{"type":"running"}}}}"#,
            r#"{"type":"ssh","destination":"deploy@h","pane":{"type":"terminal","interactive":true,"status":{"phase":{"type":"idle","last":{"code":1,"command":"false","started_at":1,"ended_at":2}}}}}"#,
            r#"{"type":"ssh","destination":"h","pane":{"type":"agent","name":"pi","status":{"since":0,"state":{"type":"idle"}}}}"#,
            r#"{"type":"host","pane":{"type":"terminal","phase":{"type":"running","origin":{"type":"unknown"},"fullscreen":true}}}"#,
            r#"{"type":"host","pane":{"type":"terminal","phase":{"type":"unknown"}}}"#,
        ] {
            same::<Live>(json);
        }
        same::<Listing>(
            r#"{"id":"pane_4","started":0,"pid":1,"command":["/bin/sh"],"cwd":"/","title":"","dead":null,"vars":{"n":[1,{"a":null}],"pi.name":"Worker"}}"#,
        );
        for json in [
            r#"{"pasted":true,"unsafe":false}"#,
            r#"{"id":41,"pasted":false,"unsafe":true}"#,
        ] {
            same::<PasteResult>(json);
        }
        for json in [
            r#"{"type":"hello","name":"test","focused":true,"sizing":{"type":"windows","viewport":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"windows":[]}}"#,
            r#"{"type":"hello","name":"app","pane":"pane_3","focused":false,"sizing":{"type":"disabled"}}"#,
            r#"{"type":"hello","name":"app","session":"session_1","window":"window_2","pane":"pane_3","focused":false,"sizing":{"type":"windows","viewport":{"cols":80,"rows":24},"windows":[]}}"#,
            r#"{"type":"select","request":1,"pane":"pane_3"}"#,
            r#"{"type":"select","request":1,"session":"session_1"}"#,
            r#"{"type":"switch","request":1,"over":"window","direction":"previous"}"#,
            r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"windows":[]}}"#,
            r#"{"type":"focused","focused":true}"#,
        ] {
            same::<ClientRequest>(json);
        }
        same::<SendPrompt>(
            r#"{"from":"pane_1","id":"abcdefgh","target":"pane_2","text":"hi\nthere"}"#,
        );
        same::<Sent>(r#"{"via":{"type":"paste"}}"#);
        same::<Sent>(r#"{"via":{"type":"message","state":"acked","seq":3,"duplicate":true}}"#);
        same::<SendMessage>(
            r#"{"id":"abcdefgh","kind":"notice","text":"x","data":{"list":[1,2],"report":true}}"#,
        );
        same::<Message>(
            r#"{"seq":1,"id":"abcdefgh","from":{"type":"pane","pane":"pane_3","name":"w"},"relation":"sibling_descendant","kind":"steer","text":"x"}"#,
        );
        same::<Message>(
            r#"{"seq":2,"id":"abcdefgh","from":{"type":"user"},"kind":"user","text":"x"}"#,
        );
        same::<Message>(
            r#"{"seq":3,"id":"ended-pane_3","from":{"type":"pane","pane":"pane_3"},"relation":"child","kind":"ended","end":{"type":"dead","at":5,"cause":{"type":"exited","code":0}}}"#,
        );
        same::<Message>(
            r#"{"seq":4,"id":"ended-pane_3","from":{"type":"pane","pane":"pane_3"},"kind":"ended","end":{"type":"gone"}}"#,
        );
        same::<StreamRequest>(r#"{"type":"ack","id":"abcdefgh"}"#);
        same::<StreamRequest>(r#"{"type":"refuse","id":"abcdefgh"}"#);
        same::<ClientEvent>(r#"{"type":"inbox","pane":"pane_3","inbox":true}"#);
        same::<ClientEvent>(
            r#"{"type":"runtime","name":"gpu-1","source":{"type":"config"},"kind":"ssh","state":{"type":"failed","message":"refused"}}"#,
        );
        same::<ClientEvent>(
            r#"{"type":"runtime_deleted","name":"gpu-1","source":{"type":"session","id":"session_3"}}"#,
        );
        same::<ClientEvent>(
            r##"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"disabled"},"apc_max_bytes":1,"kitty_images_max_bytes":1,"continuation_max_bytes":1},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":1,"runtimes":[{"name":"buildbox","source":{"type":"config"},"kind":"ssh","color":"#d08a2a","state":{"type":"up"}},{"name":"e2e","source":{"type":"session","id":"session_3"},"kind":"command","state":{"type":"starting"}}]}"##,
        );
        for bad in [
            r#"{"id":"abcdefg","kind":"message","text":"x"}"#,
            r#"{"id":"abcdefgh","kind":"user","text":"x"}"#,
            r#"{"id":"abcdefgh","kind":"ended","text":"x"}"#,
            r#"{"id":"abcdefgh","kind":"message"}"#,
        ] {
            assert!(decode::<SendMessage>(bad.as_bytes()).is_err(), "{bad}");
        }
        let big = format!(
            r#"{{"id":"abcdefgh","kind":"message","text":"x","data":"{}"}}"#,
            "d".repeat(4095)
        );
        assert!(decode::<SendMessage>(big.as_bytes()).is_err());
        let fits = format!(
            r#"{{"id":"abcdefgh","kind":"message","text":"x","data":"{}"}}"#,
            "d".repeat(4094)
        );
        assert!(decode::<SendMessage>(fits.as_bytes()).is_ok());
        for bad in [
            r#"{"type":"ack"}"#,
            r#"{"type":"ack","id":"short"}"#,
            r#"{"type":"nack","id":"abcdefgh"}"#,
            r#"["ack","abcdefgh"]"#,
        ] {
            assert!(decode::<StreamRequest>(bad.as_bytes()).is_err(), "{bad}");
        }
        same::<Candidate>(
            r#"{"pane":"pane_2","session":"session_1","window":"window_3","title":"Worker","inbox":true}"#,
        );
        for json in [
            r#"{"env":[]}"#,
            r#"{"cwd":"/tmp","command":{"type":"argv","argv":["/bin/sh","-c","x"]},"env":[{"name":"X","value":"y"}]}"#,
            r#"{"command":{"type":"shell","command":"exec cat"},"env":[]}"#,
            r#"{"env":[],"vars":{"n":[1,{"a":null}],"pi.name":"Worker"}}"#,
        ] {
            same::<CreatePane>(json);
        }
        for json in [
            r#"{"type":"resync","history":"all","images":"none"}"#,
            r#"{"type":"resync","history":"none","images":"none"}"#,
            r#"{"type":"input","input":{"type":"key","action":"press","key":20,"mods":2,"unshifted_codepoint":97,"text":"a","composing":false}}"#,
            r#"{"type":"input","input":{"type":"key","action":"release","key":58,"mods":0,"unshifted_codepoint":0,"text":"","composing":true}}"#,
            r#"{"type":"input","input":{"type":"key","action":"repeat","key":1,"mods":0,"unshifted_codepoint":0,"text":"","composing":false}}"#,
            r#"{"type":"input","input":{"type":"mouse","action":"press","button":"left","col":3,"row":4,"mods":1}}"#,
            r#"{"type":"input","input":{"type":"mouse","action":"motion","button":"eleven","col":0,"row":0,"mods":0}}"#,
            r#"{"type":"input","input":{"type":"mouse","action":"release","button":"unknown","col":0,"row":0,"mods":0}}"#,
            r#"{"type":"input","input":{"type":"paste","text":"hello\n","check_safe":false,"id":23}}"#,
            r#"{"type":"input","input":{"type":"paste","text":"x","check_safe":true}}"#,
            r#"{"type":"input","input":{"type":"text","data":"aGk="}}"#,
        ] {
            same::<ViewRequest>(json);
        }
        for json in [
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback","max_bytes":50000000},"apc_max_bytes":68157440,"kitty_images_max_bytes":320000000,"continuation_max_bytes":68157440},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":123456789,"runtimes":[]}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"disabled"},"apc_max_bytes":68157440,"kitty_images_max_bytes":320000000,"continuation_max_bytes":68157440},"media":["file","temp_file","shared_mem"]},"instance":"0123456789abcdef0123456789abcdef","now":123456789,"runtimes":[]}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback","max_bytes":83886080,"max_lines":5000},"apc_max_bytes":68157440,"kitty_images_max_bytes":320000000,"continuation_max_bytes":68157440},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":123456789,"runtimes":[]}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback"},"apc_max_bytes":68157440,"kitty_images_max_bytes":320000000,"continuation_max_bytes":68157440},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":123456789,"runtimes":[]}"#,
            r#"{"type":"layout","revision":3,"layout":{"sessions":[{"id":"session_1","name":"s","vars":{"a":1},"windows":[{"id":"window_1","name":"w","vars":{},"cols":80,"rows":24,"cell_px":{"width":8,"height":16},"zoom":"pane_1","focus":"pane_2","tree":{"split":"h","children":[{"pane":"pane_1","cols":40,"rows":24},{"pane":"pane_2","cols":39,"rows":24}]},"floats":[{"pane":"pane_3","x":6,"y":4,"cols":28,"rows":8,"z":0,"border":false,"title":""}]}]}]},"panes":[{"id":"pane_3","started":0,"pid":7,"command":["/bin/sh"],"cwd":"/tmp","title":"t","dead":null,"foreground":{"pid":7,"name":"sh"},"vars":{}}]}"#,
            r#"{"type":"layout","revision":0,"layout":{"sessions":[]},"panes":[]}"#,
            r#"{"type":"foreground","pane":"pane_3","foreground":{"pid":7,"name":"sh"}}"#,
            r#"{"type":"selected","session":"session_1","window":"window_1","pane":"pane_2"}"#,
            r#"{"type":"selected"}"#,
            r#"{"type":"title","pane":"pane_3","title":"x"}"#,
            r#"{"type":"pwd","pane":"pane_3","pwd":"file://h/tmp"}"#,
            r#"{"type":"dead","pane":"pane_3","dead":{"at":123456789012345,"cause":{"type":"signaled","signal":15}}}"#,
            r#"{"type":"status","pane":"pane_3","status":{"kind":{"type":"host","pane":{"type":"terminal","phase":{"type":"idle"}}},"program_status":{"serial":0,"records":[]},"title":"zsh","since":9},"now":99}"#,
            r#"{"type":"var","pane":"pane_3","name":"ssh.args","value":["-l","x"]}"#,
            r#"{"type":"var_deleted","pane":"pane_3","name":"ssh.args"}"#,
            r#"{"type":"bell","pane":"pane_3"}"#,
            r#"{"type":"notify","pane":"pane_3","body":"done"}"#,
            r#"{"type":"notify","pane":"pane_3","title":"build","body":"done"}"#,
            r#"{"type":"progress","pane":"pane_3","progress":null}"#,
            r#"{"type":"progress","pane":"pane_3","progress":{"state":"indeterminate"}}"#,
            r#"{"type":"focus","window":"window_2","pane":"pane_3"}"#,
        ] {
            same::<ClientEvent>(json);
        }
        for json in [
            r#"{"type":"marked","offset":99,"marker":{"type":"resize","cols":80,"rows":24,"cell_px":{"width":8,"height":16}}}"#,
            r#"{"type":"marked","offset":5,"marker":{"type":"resize","cols":4096,"rows":1}}"#,
            r#"{"type":"marked","offset":7,"marker":{"type":"dead","at":123456789012345}}"#,
            r#"{"type":"skipped","offset":100000,"from":10,"to":100000}"#,
            r#"{"type":"pasted","id":77,"pasted":true,"unsafe":false}"#,
        ] {
            same::<ViewEvent>(json);
        }
    }

    fn same<T: Serialize + DeserializeOwned>(json: &str) {
        assert_eq!(decoded::<T>(json), Ok(json.to_owned()), "{json}");
    }

    fn decoded<T: Serialize + DeserializeOwned>(json: &str) -> Result<String, String> {
        decode::<T>(json.as_bytes())
            .map(|value| super::json(&value))
            .map_err(|error| error.to_string())
    }

    #[test]
    fn decoders_take_defaults_and_nulls_and_refuse_bad_shapes() {
        let hello = r#"{"type":"hello","name":"x","focused":true,"sizing":{"type":"windows","viewport":{"cols":1,"rows":1},"windows":[]}}"#;
        assert_eq!(
            decoded::<ClientRequest>(
                r#"{"type":"hello","name":"x","focused":true,"extra":1,"sizing":{"type":"windows","viewport":{"cols":1,"rows":1},"windows":[]}}"#
            ),
            Ok(hello.to_owned())
        );
        assert_eq!(
            decoded::<ClientRequest>(
                r#"{"type":"hello","name":"x","focused":true,"pane":null,"sizing":{"type":"windows","viewport":{"cols":1,"rows":1,"cell_px":null},"windows":[]}}"#
            ),
            Ok(hello.to_owned())
        );
        for refused in [
            r#"["select","pane_1"]"#,
            r#"{"type":"switch","request":1,"over":"pane","direction":"next"}"#,
            r#"{"type":"switch","request":1,"over":"window"}"#,
            r#"{"type":"focused","focused":1}"#,
            r#"{"type":"focused"}"#,
            r#""focused""#,
            r#"{"type":"nope"}"#,
            r#"{"focused":true}"#,
        ] {
            assert!(decoded::<ClientRequest>(refused).is_err(), "{refused}");
        }
        assert_eq!(
            decoded::<CreatePane>(r#"{"cwd":null,"command":null}"#),
            Ok(r#"{"env":[]}"#.to_owned())
        );
        for refused in [
            r#"{"cwd":{"pane":"x"}}"#,
            r#"{"cwd":{}}"#,
            r#"{"cwd":["pane_1"]}"#,
        ] {
            assert!(decoded::<CreatePane>(refused).is_err(), "{refused}");
        }
        assert_eq!(
            decoded::<ViewRequest>(r#"{"type":"resync"}"#),
            Ok(r#"{"type":"resync","history":"none","images":"none"}"#.to_owned())
        );
        assert_eq!(
            decoded::<ViewRequest>(
                r#"{"type":"input","input":{"type":"paste","text":"x","check_safe":true,"id":null}}"#
            ),
            Ok(
                r#"{"type":"input","input":{"type":"paste","text":"x","check_safe":true}}"#
                    .to_owned()
            )
        );
    }

    #[test]
    fn input_is_checked_where_it_is_decoded() {
        let key = |key: i64, codepoint: i64| {
            format!(
                r#"{{"type":"key","action":"press","key":{key},"mods":0,"unshifted_codepoint":{codepoint},"text":"","composing":false}}"#
            )
        };
        let refused: Vec<bool> = [
            key(-1, 0),
            key(176, 0),
            key(175, 0x10ffff),
            key(1, 0x110000),
            key(1, 0xd800),
            r#"{"type":"mouse","action":"press","button":"left","col":70000,"row":0,"mods":0}"#
                .to_owned(),
            r#"{"type":"text","data":"aGk"}"#.to_owned(),
            r#"{"type":"text","data":"a=Gk"}"#.to_owned(),
        ]
        .iter()
        .map(|json| decoded::<Input>(json).is_err())
        .collect();
        assert_eq!(refused, [true, true, false, true, true, true, true, true]);
        for (text, bytes) in [("", ""), ("aGk=", "hi"), ("aGk/", "hi?"), ("aA==", "h")] {
            let json = format!(r#"{{"type":"text","data":"{text}"}}"#);
            assert_eq!(
                serde_json::from_str::<Input>(&json).unwrap(),
                Input::Text {
                    data: Text(bytes.as_bytes().to_vec())
                }
            );
            assert_eq!(decoded::<Input>(&json), Ok(json));
        }
    }

    #[test]
    fn a_grid_is_limited_to_the_panes_dimension_and_a_cell_to_65535_pixels() {
        let ok = |cols: u32, rows: u32, px: u32| {
            let json = format!(
                r#"{{"cols":{cols},"rows":{rows},"cell_px":{{"width":{px},"height":{px}}}}}"#
            );
            serde_json::from_str::<Size>(&json).is_ok()
        };
        assert_eq!(
            [
                ok(4096, 4096, 65535),
                ok(4097, 24, 8),
                ok(80, 4097, 8),
                ok(80, 24, 65536),
                ok(0, 24, 8)
            ],
            [true, false, false, false, false]
        );
    }

    #[test]
    fn the_version_check_takes_a_higher_minor_and_refuses_another_major_or_terminal() {
        let checked: Vec<String> = [
            (Some("1.3"), Some(VT)),
            (Some("1.7"), Some(VT)),
            (Some("2.0"), Some(VT)),
            (Some("1."), Some(VT)),
            (None, Some(VT)),
            (Some("1.3"), Some("wrong")),
            (Some("1.3"), None),
        ]
        .into_iter()
        .map(|(protocol, vt)| match check_version(protocol, vt) {
            Ok(()) => "ok".to_owned(),
            Err(error) => format!("{:?} {}", error.kind.status(), error.message),
        })
        .collect();
        assert_eq!(
            checked,
            [
                "ok",
                "ok",
                "UpgradeRequired protocol major mismatch",
                "UpgradeRequired protocol major mismatch",
                "UpgradeRequired protocol major mismatch",
                "Conflict terminal revision mismatch",
                "Conflict terminal revision mismatch",
            ]
        );
    }

    fn json_text() -> impl Strategy<Value = String> {
        let leaf = prop_oneof![
            Just("null".to_owned()),
            any::<bool>().prop_map(|b| b.to_string()),
            prop_oneof![Just(-1i64), 0i64..70000, Just(i64::MAX), Just(i64::MIN)]
                .prop_map(|n| n.to_string()),
            prop::sample::select(vec![
                "\"terminal\"",
                "\"press\"",
                "\"left\"",
                "\"all\"",
                "\"none\"",
                "\"pane_1\"",
                "\"/tmp\"",
                "\"aGk=\"",
                "\"!!\"",
                "\"argv\"",
                "\"shell\"",
                "\"hello\"",
                "\"input\"",
                "\"key\"",
                "\"text\"",
                "\"resync\"",
                "\"\"",
                "0.5",
                "1e300",
            ])
            .prop_map(str::to_owned),
        ];
        let keys = prop::sample::select(vec![
            "kind",
            "name",
            "pane",
            "focused",
            "size",
            "cols",
            "rows",
            "cell_px",
            "width",
            "height",
            "sizing",
            "viewport",
            "windows",
            "cwd",
            "command",
            "env",
            "value",
            "action",
            "key",
            "mods",
            "unshifted_codepoint",
            "text",
            "composing",
            "button",
            "col",
            "row",
            "history",
            "images",
            "check_safe",
            "id",
        ]);
        leaf.prop_recursive(3, 24, 5, move |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..4)
                    .prop_map(|items| format!("[{}]", items.join(","))),
                prop::collection::vec((keys.clone(), inner), 0..5).prop_map(|fields| {
                    let fields: Vec<String> = fields
                        .into_iter()
                        .map(|(key, value)| format!("\"{key}\":{value}"))
                        .collect();
                    format!("{{{}}}", fields.join(","))
                }),
            ]
        })
    }

    #[test]
    fn a_record_is_an_object_at_every_level_and_inside_a_tagged_enum() {
        for (accepted, json) in [
            (
                decoded::<CreatePane>(
                    r#"{"command":{"type":"argv","argv":["/bin/sh"]},"env":[{"name":"A","value":"b"}]}"#,
                ),
                r#"{"command":{"type":"argv","argv":["/bin/sh"]},"env":[{"name":"A","value":"b"}]}"#,
            ),
            (
                decoded::<ClientRequest>(
                    r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"windows":[]}}"#,
                ),
                r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"windows":[]}}"#,
            ),
            (
                decoded::<ViewRequest>(
                    r#"{"type":"input","input":{"type":"mouse","action":"press","button":"left","col":1,"row":2,"mods":0}}"#,
                ),
                r#"{"type":"input","input":{"type":"mouse","action":"press","button":"left","col":1,"row":2,"mods":0}}"#,
            ),
            (
                decoded::<ClientEvent>(r#"{"type":"selected","pane":null}"#),
                r#"{"type":"selected"}"#,
            ),
        ] {
            assert_eq!(accepted, Ok(json.to_owned()), "{json}");
        }
        let refused = [
            decoded::<CreatePane>(r#"[]"#),
            decoded::<CreatePane>(r#"["/tmp"]"#),
            decoded::<CreatePane>(r#"{"env":[["A","b"]]}"#),
            decoded::<CreatePane>(r#"{"command":["argv",["/bin/sh"]]}"#),
            decoded::<ClientRequest>(r#"["size",{"cols":80,"rows":24}]"#),
            decoded::<ClientRequest>(r#"["focused",true]"#),
            decoded::<ClientRequest>(
                r#"{"type":"size","sizing":{"type":"windows","viewport":{"cols":80,"rows":24,"cell_px":[8,16]},"windows":[]}}"#,
            ),
            decoded::<ClientRequest>(
                r#"{"type":"hello","name":"t","focused":true,"sizing":{"type":"windows","viewport":[80,24],"windows":[]}}"#,
            ),
            decoded::<ViewRequest>(r#"{"type":"resync","history":"all","images":["x"]}"#),
            decoded::<ViewRequest>(r#"{"type":"input","input":["paste",["x",true]]}"#),
            decoded::<ViewRequest>(
                r#"{"type":"input","input":{"type":"paste","text":"x","check_safe":["true"]}}"#,
            ),
            decoded::<ViewEvent>(
                r#"{"type":"marked","offset":1,"marker":{"type":"dead","at":[1]}}"#,
            ),
            decoded::<ViewEvent>(r#"{"type":"marked","offset":1,"marker":["resize",80,24]}"#),
            decoded::<ClientEvent>(r#"{"type":"layout","revision":1,"layout":[["s"]]}"#),
            decoded::<ClientEvent>(r#"{"type":"welcome","client":"client_1","limits":[]}"#),
            decoded::<ClientEvent>(
                r#"{"type":"welcome","client":"client_1","limits":{"terminal":{"scrollback":{"type":"disabled"},"apc_max_bytes":1,"kitty_images_max_bytes":1,"continuation_max_bytes":1},"media":[]},"instance":"0123456789ABCDEF0123456789abcdef"}"#,
            ),
            decoded::<Error>(r#"{"kind":["invalid"],"message":"m"}"#),
            decoded::<ClientRequest>(r#"{"type":"focused","focused":true,"focused":false}"#),
            decoded::<ClientRequest>(r#"{"type":"focused","type":"focused","focused":true}"#),
        ];
        for result in refused {
            assert!(result.is_err(), "{result:?}");
        }
    }

    proptest! {
        #[test]
        fn decoders_return_a_value_or_a_decode_error(text in json_text(), cut in 0usize..200) {
            let text = text.get(..cut.min(text.len())).unwrap_or(&text).to_owned();
            for decoded in [
                decoded::<ClientRequest>(&text),
                decoded::<ViewRequest>(&text),
                decoded::<Input>(&text),
                decoded::<CreatePane>(&text),
            ]
            .into_iter()
            .flatten()
            {
                prop_assert!(serde_json::from_str::<serde_json::Value>(&decoded).is_ok());
            }
        }
    }

    #[test]
    fn a_pixel_format_header_is_its_json_name_and_parses_back() {
        for format in [
            PixelFormat::Rgb,
            PixelFormat::Rgba,
            PixelFormat::GrayAlpha,
            PixelFormat::Gray,
        ] {
            assert_eq!(format!("\"{}\"", format.header()), json(&format));
            assert_eq!(PixelFormat::from_header(format.header()), Some(format));
        }
        assert_eq!(PixelFormat::from_header("RGB"), None);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    Ssh,
    Command,
    Container,
    Podman,
}

/// The state of a runtime's link. The first pane of a runtime starts it, and the idle rule or a
/// request takes it down.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LinkState {
    Down,
    Starting,
    Up,
    Failed { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RuntimeInfo {
    #[serde(flatten)]
    pub runtime: ClientRuntime,
    /// The panes of the document that the runtime runs, dead ones included.
    pub panes: u32,
    /// The path of the runtime's listener on the host, bound while the link is up.
    pub socket: String,
    /// The effective host-to-runtime prefix list that maps a host cwd.
    pub paths: Vec<PathMap>,
    /// The configured directory inside the runtime for a pane whose cwd does not map.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
    pub pi: RuntimePi,
}

/// The state of a runtime when its wait ends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct RuntimeWait {
    pub state: LinkState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DownRuntime {
    /// Remove the live panes of the runtime first, as a stop does. Without force, live panes
    /// refuse the request.
    #[serde(default)]
    pub force: bool,
}

/// Enters the runtime in the caller's pane until the visit connection closes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct VisitRequest {
    /// The host directory, mapped through the runtime's paths.
    pub cwd: AbsPath,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    /// The command to run without a shell. Without a command, starts the runtime's shell.
    pub command: Option<Vec<String>>,
    #[serde(default)]
    /// Variables applied after the runtime's variables.
    pub env: Vec<Variable>,
}

/// The first message must be visit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum VisitClient {
    /// Starts the visit with the caller's host directory and command.
    Visit(VisitRequest),
}

/// The runtime's visit updates. Failed and ended are followed by a normal WebSocket close.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum VisitServer {
    /// The runtime's link is starting.
    Starting {},
    /// The token is ready. Runs the transport on the pane's terminal.
    Up {
        /// The transport command, without the runtime-exec wrapper.
        argv: Vec<String>,
    },
    /// The visit could not start.
    Failed {
        /// The reason that the visit failed.
        message: String,
    },
    /// The server ended the visit.
    Ended {
        /// The reason that the visit ended.
        message: String,
    },
}

pub const EXEC_CHUNK: usize = 64 << 10;

/// The signals that a client can send to the command of an exec session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum KillSignal {
    Term,
    Kill,
    Int,
}

/// Runs argv inside the runtime without a shell. The cwd is a path of the runtime. The env
/// applies after the env of the runtime. Without stdin the command reads an empty input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct ExecRequest {
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<AbsPath>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub stdin: bool,
}

fn invalid_argv(argv: &[String]) -> Option<&'static str> {
    if argv.first().is_none_or(String::is_empty) {
        Some("argv needs a program")
    } else if argv.iter().any(|arg| arg.contains('\0')) {
        Some("invalid argv or env")
    } else {
        None
    }
}

impl VisitRequest {
    pub(crate) fn invalid(&self) -> Option<&'static str> {
        self.command.as_deref().and_then(invalid_argv).or_else(|| {
            self.env
                .iter()
                .any(|variable| !env_valid(&variable.name, &variable.value))
                .then_some("invalid argv or env")
        })
    }
}

impl ExecRequest {
    pub(crate) fn invalid(&self) -> Option<&'static str> {
        invalid_argv(&self.argv).or_else(|| {
            self.env
                .iter()
                .any(|(name, value)| !env_valid(name, value))
                .then_some("invalid argv or env")
        })
    }
}

/// A message of the client of an exec session. The first one must be exec. The data of stdin is
/// at most 64 KiB before its encoding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ExecClient {
    Exec(ExecRequest),
    Stdin {
        data: Text,
    },
    /// Closes the input of the command.
    Eof {},
    Signal {
        signal: KillSignal,
    },
}

/// The signals by which a command can end. Other is any signal that this list does not name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "UPPERCASE")]
pub enum ExitSignal {
    Hup,
    Int,
    Quit,
    Ill,
    Trap,
    Abrt,
    Bus,
    Fpe,
    Kill,
    Usr1,
    Segv,
    Usr2,
    Pipe,
    Alrm,
    Term,
    Other,
}

impl From<i32> for ExitSignal {
    fn from(number: i32) -> ExitSignal {
        match number {
            libc::SIGHUP => ExitSignal::Hup,
            libc::SIGINT => ExitSignal::Int,
            libc::SIGQUIT => ExitSignal::Quit,
            libc::SIGILL => ExitSignal::Ill,
            libc::SIGTRAP => ExitSignal::Trap,
            libc::SIGABRT => ExitSignal::Abrt,
            libc::SIGBUS => ExitSignal::Bus,
            libc::SIGFPE => ExitSignal::Fpe,
            libc::SIGKILL => ExitSignal::Kill,
            libc::SIGUSR1 => ExitSignal::Usr1,
            libc::SIGSEGV => ExitSignal::Segv,
            libc::SIGUSR2 => ExitSignal::Usr2,
            libc::SIGPIPE => ExitSignal::Pipe,
            libc::SIGALRM => ExitSignal::Alrm,
            libc::SIGTERM => ExitSignal::Term,
            _ => ExitSignal::Other,
        }
    }
}

/// How the command ended: with an exit status, or by a signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum Ended {
    Status { status: i32 },
    Signal { signal: ExitSignal },
}

impl From<Exit> for Ended {
    fn from(exit: Exit) -> Ended {
        match exit {
            Exit::Exited(status) => Ended::Status { status },
            Exit::Signaled(signal) => Ended::Signal {
                signal: signal.into(),
            },
        }
    }
}

/// A message of the server in an exec session. After exit the server closes with 1000, and
/// after error with 1011. Error is the one way a session ends without exit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ExecServer {
    Stdout {
        data: Text,
    },
    Stderr {
        data: Text,
    },
    Exit {
        #[serde(flatten)]
        ended: Ended,
    },
    Error {
        message: String,
    },
}
