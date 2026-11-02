use std::fmt;
use std::num::{NonZeroU16, NonZeroUsize};

use ko_pane_wire::frame::{
    self, CellPx, Dim, History, KeyAction, KeyCode, MouseAction, MouseButton, ScreenFormat,
    ScreenRows,
};
use ko_pane_wire::ring;
use ko_sys::pid::Exit;
use serde::de::{self, DeserializeOwned};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::BUILD;
use crate::http::Status;
use crate::ids::{ClientId, Instance, Name, PaneId, RunId, SessionId, VarName, WindowId};
use crate::pane_proc::{self, Death};
use crate::runs::{Meta, Parent, RunName, RunOutcome, RunResult};
use crate::timestamp::Timestamp;
use crate::vars::{Loose, Vars};

const PROTOCOL: &str = "1.0";
const PROTOCOL_MAJOR: &str = "1";
const VT: &str = env!("KO_VT");
const MAX_OFFSET: u64 = (1 << 62) - 1;

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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Empty {}

pub(crate) fn check_version(protocol: Option<&str>, vt: Option<&str>) -> Result<(), Error> {
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

#[derive(Serialize, Deserialize)]
struct RawCellPx {
    width: u16,
    height: u16,
}

#[derive(Serialize, Deserialize)]
struct RawSize {
    cols: u16,
    rows: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cell_px: Option<CellPixels>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawSize", into = "RawSize")]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Cause {
    Exited { code: i32 },
    Signaled { signal: i32 },
    Failed { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
                pane_proc::Cause::Failed(message) => Cause::Failed {
                    message: message.clone(),
                },
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProgramKind {
    Permission,
    Question,
    Auth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProgramRecord {
    pub id: String,
    #[serde(flatten)]
    pub state: ProgramState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProgramStatus {
    pub serial: u64,
    pub records: Vec<ProgramRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutcomeResult {
    Success,
    Failure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Outcome {
    pub serial: u64,
    pub result: OutcomeResult,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Agent {
    pub since: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
    pub state: AgentState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandExit {
    pub code: i32,
    pub command: String,
    pub started_at: u64,
    pub ended_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Origin {
    Unknown,
    Command { command: String, started_at: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Phase {
    Unknown,
    Idle {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        last: Option<CommandExit>,
    },
    Running {
        origin: Origin,
        fullscreen: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Remote {
    Terminal { interactive: bool, status: Shell },
    Agent { name: String, status: Agent },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Live {
    Terminal(Shell),
    SomeAgent { name: String, status: Agent },
    PiAgent { session: String, status: Agent },
    Ssh { destination: String, pane: Remote },
}

impl Live {
    pub fn shell(&self) -> Option<&Shell> {
        match self {
            Live::Terminal(shell)
            | Live::Ssh {
                pane: Remote::Terminal { status: shell, .. },
                ..
            } => Some(shell),
            Live::SomeAgent { .. } | Live::PiAgent { .. } | Live::Ssh { .. } => None,
        }
    }

    pub fn agent(&self) -> Option<&Agent> {
        match self {
            Live::SomeAgent { status, .. }
            | Live::PiAgent { status, .. }
            | Live::Ssh {
                pane: Remote::Agent { status, .. },
                ..
            } => Some(status),
            Live::Terminal(_) | Live::Ssh { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Foreground {
    pub pid: u32,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProgressState {
    Set,
    Error,
    Indeterminate,
    Pause,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Progress {
    pub state: ProgressState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub id: PaneId,
    pub pid: i32,
    pub command: Vec<String>,
    pub cwd: String,
    pub title: String,
    pub dead: Option<Dead>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<Foreground>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<PaneStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<Progress>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Listing {
    #[serde(flatten)]
    pub row: Row,
    #[serde(default)]
    pub vars: Vars,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PasteResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub pasted: bool,
    #[serde(rename = "unsafe")]
    pub unsafe_paste: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(remote = "KeyAction", rename_all = "lowercase")]
enum KeyActionDef {
    Release,
    Press,
    Repeat,
}

#[derive(Serialize, Deserialize)]
struct RawKey {
    #[serde(with = "KeyActionDef")]
    action: KeyAction,
    key: u16,
    mods: u16,
    unshifted_codepoint: u32,
    text: String,
    composing: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawKey", into = "RawKey")]
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

#[derive(Serialize, Deserialize)]
#[serde(remote = "MouseAction", rename_all = "lowercase")]
enum MouseActionDef {
    Press,
    Release,
    Motion,
}

#[derive(Serialize, Deserialize)]
#[serde(remote = "MouseButton", rename_all = "lowercase")]
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

#[derive(Serialize, Deserialize)]
#[serde(remote = "frame::Mouse")]
struct MouseDef {
    #[serde(with = "MouseActionDef")]
    action: MouseAction,
    #[serde(with = "MouseButtonDef")]
    button: MouseButton,
    col: u16,
    row: u16,
    mods: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mouse(#[serde(with = "MouseDef")] pub frame::Mouse);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Paste {
    pub text: String,
    pub check_safe: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn sextet(byte: u8) -> Option<u32> {
    BASE64
        .iter()
        .position(|&symbol| symbol == byte)
        .and_then(|index| u32::try_from(index).ok())
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let last = bytes.len() / 4;
    for (index, quad) in bytes.chunks(4).enumerate() {
        let padding = quad.iter().rev().take_while(|&&byte| byte == b'=').count();
        if padding > 2 || (padding > 0 && index + 1 != last) {
            return None;
        }
        let mut word = 0;
        for &byte in &quad[..4 - padding] {
            word = word << 6 | sextet(byte)?;
        }
        word <<= 6 * padding;
        let [_, a, b, c] = word.to_be_bytes();
        out.extend_from_slice(&[a, b, c][..3 - padding]);
    }
    Some(out)
}

pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let mut word = [0; 4];
        word[1..=group.len()].copy_from_slice(group);
        let word = u32::from_be_bytes(word);
        for index in 0..4 {
            if index <= group.len() {
                let symbol = (word >> (18 - 6 * index)) & 63;
                out.push(char::from(BASE64[symbol as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Text(pub Vec<u8>);

impl TryFrom<String> for Text {
    type Error = &'static str;

    fn try_from(text: String) -> Result<Text, &'static str> {
        base64_decode(&text).map(Text).ok_or("invalid base64")
    }
}

impl From<Text> for String {
    fn from(Text(bytes): Text) -> String {
        base64_encode(&bytes)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    Argv { argv: Vec<String> },
    Shell { command: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Variable {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreatePane {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Command>,
    #[serde(default)]
    pub env: Vec<Variable>,
    #[serde(default, skip_serializing_if = "Loose::is_empty")]
    pub vars: Loose,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u16", into = "u16")]
pub struct Cells(Dim);

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawCellPx", into = "RawCellPx")]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Axis {
    #[serde(rename = "h")]
    Horizontal,
    #[serde(rename = "v")]
    Vertical,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Node<L> {
    Split { split: Axis, children: Vec<Node<L>> },
    Leaf(L),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Leaf {
    pub pane: PaneId,
    pub cols: Cells,
    pub rows: Cells,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub id: SessionId,
    pub name: Name,
    pub vars: Vars,
    pub windows: Vec<Window>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Layout {
    pub sessions: Vec<Session>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot {
    pub revision: Revision,
    pub layout: Layout,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum PaneRef {
    Existing(PaneId),
    New { new: CreatePane },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftLeaf {
    pub pane: PaneRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<Cells>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<Cells>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftSession {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<SessionId>,
    pub name: Name,
    #[serde(default)]
    pub vars: Loose,
    pub windows: Vec<DraftWindow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftLayout {
    pub sessions: Vec<DraftSession>,
}

impl DraftWindow {
    pub fn single(request: &CreatePane) -> DraftWindow {
        DraftWindow {
            id: None,
            name: None,
            vars: Loose::new(),
            cols: None,
            rows: None,
            cell_px: None,
            zoom: None,
            tree: Node::Leaf(DraftLeaf {
                pane: PaneRef::New {
                    new: request.clone(),
                },
                cols: None,
                rows: None,
            }),
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

    pub(crate) fn contains(&self, pane: PaneId) -> bool {
        match self {
            Node::Leaf(leaf) => leaf.pane == pane,
            Node::Split { children, .. } => children.iter().any(|child| child.contains(pane)),
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

#[derive(Serialize, Deserialize)]
#[serde(remote = "History", rename_all = "lowercase")]
enum HistoryDef {
    None,
    All,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Images {
    #[default]
    None,
}

fn no_history() -> History {
    History::None
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewOptions {
    #[serde(with = "HistoryDef", default = "no_history")]
    pub history: History,
    #[serde(default)]
    pub images: Images,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Marker {
    Resize(Size),
    Dead(Dead),
}

impl From<ring::Marker> for Marker {
    fn from(marker: ring::Marker) -> Marker {
        match marker {
            ring::Marker::Resize(size) => Marker::Resize(Size(size)),
            ring::Marker::Dead(dead) => Marker::Dead(Dead {
                at: dead.at.nanos(),
                cause: Cause::from(dead.exit),
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClientKind {
    Terminal,
    App,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    pub kind: ClientKind,
    pub name: String,
    #[serde(flatten)]
    pub selection: Selection,
    pub focused: bool,
    pub size: Size,
    #[serde(default)]
    pub ignore_size: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Selection {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<WindowId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<PaneId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Over {
    Session,
    Window,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Next,
    Previous,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Switch {
    pub over: Over,
    pub direction: Direction,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientRequest {
    Hello(Hello),
    Select(Selection),
    Switch(Switch),
    Size(Size),
    Focused { focused: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ViewRequest {
    Resync(ViewOptions),
    Input { input: Input },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Bounds {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_bytes: Option<NonZeroUsize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_lines: Option<NonZeroUsize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum Scrollback {
    Disabled,
    Scrollback(Bounds),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Terminal {
    pub(crate) scrollback: Scrollback,
    pub(crate) apc_max_bytes: usize,
    pub(crate) kitty_images_max_bytes: u64,
    pub(crate) continuation_max_bytes: usize,
}

#[derive(Serialize, Deserialize)]
#[serde(remote = "frame::Medium", rename_all = "snake_case")]
enum MediumDef {
    File,
    TempFile,
    SharedMem,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Medium(#[serde(with = "MediumDef")] pub(crate) frame::Medium);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    pub terminal: Terminal,
    pub(crate) media: Vec<Medium>,
}

impl Limits {
    pub(crate) fn of(limits: frame::Limits, media: &[frame::Medium]) -> Limits {
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    pub client: ClientId,
    pub limits: Limits,
    pub instance: Instance,
    pub now: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Title {
    pub pane: PaneId,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pwd {
    pub(crate) pane: PaneId,
    pub(crate) pwd: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneDead {
    pub pane: PaneId,
    pub dead: Dead,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusChange {
    pub pane: PaneId,
    pub status: PaneStatus,
    pub now: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    Welcome(Welcome),
    Layout(Snapshot),
    Focus {
        window: WindowId,
        pane: PaneId,
    },
    Selected(Selection),
    Title(Title),
    Pwd(Pwd),
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
    Notify {
        pane: PaneId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        body: String,
    },
    Progress {
        pane: PaneId,
        progress: Option<Progress>,
    },
    Run(RunEvent),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunEvent {
    pub id: RunId,
    pub name: RunName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Parent>,
    pub pane: PaneId,
    #[serde(rename = "startedAt")]
    pub started_at: Timestamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<RunOutcome>,
}

impl RunEvent {
    pub fn of(meta: &Meta, outcome: Option<RunOutcome>) -> Option<RunEvent> {
        Some(RunEvent {
            id: meta.id.clone(),
            name: meta.name.clone(),
            parent: meta.parent.clone(),
            pane: meta.pane?,
            started_at: meta.started_at,
            outcome,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Show {
    Live,
    Present,
    All,
}

const SHOWS: [(Show, &str); 3] = [
    (Show::Live, "live"),
    (Show::Present, "present"),
    (Show::All, "all"),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reported {
    Completed,
    Failed,
    Stopped,
}

impl From<Reported> for RunResult {
    fn from(reported: Reported) -> RunResult {
        match reported {
            Reported::Completed => RunResult::Completed,
            Reported::Failed => RunResult::Failed,
            Reported::Stopped => RunResult::Stopped,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Info {
    #[serde(flatten)]
    pub meta: Meta,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub output: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<RunOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Detail {
    #[serde(flatten)]
    pub info: Info,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub enum SessionRef {
    Id(SessionId),
    Name(Name),
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartRun {
    pub name: RunName,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Parent>,
    #[serde(default)]
    pub env: Vec<Variable>,
    pub argv: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Started {
    pub id: RunId,
    pub window: WindowId,
    pub pane: PaneId,
    pub output: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Waited {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<RunOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportOutcome {
    pub result: Reported,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopResult {
    Stopped,
    Completed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StopRun {
    #[serde(default)]
    pub wait_ms: u64,
    pub result: StopResult,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VarCondition {
    pub name: VarName,
    pub value: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeleteVars {
    pub names: Vec<VarName>,
    #[serde(default, rename = "if", skip_serializing_if = "Option::is_none")]
    pub condition: Option<VarCondition>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub pane: PaneId,
    pub session: SessionId,
    pub window: WindowId,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SendPrompt {
    pub target: PaneId,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    Inbox,
    Paste,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sent {
    pub via: Via,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Marked {
    pub offset: u64,
    pub marker: Marker,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Skipped {
    pub offset: u64,
    pub from: u64,
    pub to: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ViewEvent {
    Marked(Marked),
    Skipped(Skipped),
    Pasted(PasteResult),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Invalid(&'static str);

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    Version,
    ListPanes,
    GetLayout,
    PutLayout,
    Client,
    SelectClient(ClientId),
    DeletePane(PaneId),
    DeleteWindow(WindowId),
    DeleteSession(SessionId),
    ClearHistory(PaneId),
    Input(PaneId),
    Screen(PaneId, ScreenFormat, ScreenRows),
    View(PaneId, ViewOptions, Option<u64>),
    Vars(PaneId),
    Var(PaneId, VarName),
    SetVar(PaneId, VarName),
    DeleteVar(PaneId, VarName),
    DeleteVars(PaneId),
    StartRun,
    ListRuns(Show, Option<Parent>),
    Reap,
    GetRun(RunId),
    WaitRun(RunId, u64),
    RunOutcome(RunId),
    StopRun(RunId),
    PromptResolve { window_only: bool },
    SendPrompt,
}

pub const WAIT_DEFAULT_MS: u64 = 30_000;
pub const WAIT_MAX_MS: u64 = 3_600_000;

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while let Some(&byte) = bytes.get(at) {
        if byte == b'%' {
            let hex = text.get(at + 1..at + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            at += 3;
        } else {
            out.push(byte);
            at += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn natural(value: &str, max: u64) -> Result<u64, Invalid> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(Invalid("invalid number"));
    }
    value
        .parse()
        .ok()
        .filter(|&number| number <= max)
        .ok_or(Invalid("invalid number"))
}

impl Route {
    pub fn websocket(&self) -> bool {
        matches!(self, Route::Client | Route::View(..))
    }

    pub fn of_request(method: &str, target: &str) -> Result<Option<Route>, Invalid> {
        let mut parts = target.split('?');
        let path = parts.next().unwrap_or_default();
        let query = parts.next();
        if parts.next().is_some() {
            return Err(Invalid("invalid target"));
        }
        let args: Vec<(&str, &str)> = match query {
            None => Vec::new(),
            Some(query) => query
                .split('&')
                .map(|pair| {
                    let mut sides = pair.split('=');
                    match (sides.next(), sides.next(), sides.next()) {
                        (Some(key), Some(value), None) => Ok((key, value)),
                        _ => Err(Invalid("invalid query")),
                    }
                })
                .collect::<Result<_, _>>()?,
        };
        let arg = |name: &str| {
            args.iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| *value)
        };
        let segments: Vec<&str> = path.split('/').collect();
        Ok(match (method, segments.as_slice()) {
            ("GET", ["", "version"]) => Some(Route::Version),
            ("GET", ["", "panes"]) => Some(Route::ListPanes),
            ("GET", ["", "layout"]) => Some(Route::GetLayout),
            ("PUT", ["", "layout"]) => Some(Route::PutLayout),
            ("GET", ["", "client"]) => Some(Route::Client),
            ("POST", ["", "clients", id, "select"]) => id.parse().ok().map(Route::SelectClient),
            ("DELETE", ["", "windows", id]) => id.parse().ok().map(Route::DeleteWindow),
            ("DELETE", ["", "sessions", id]) => id.parse().ok().map(Route::DeleteSession),
            ("POST", ["", "runs"]) => Some(Route::StartRun),
            ("GET", ["", "runs"]) => {
                let show = match arg("show") {
                    None => Show::Live,
                    Some(name) => SHOWS
                        .iter()
                        .find(|(_, known)| *known == name)
                        .map(|(show, _)| *show)
                        .ok_or(Invalid("invalid show"))?,
                };
                let parent = arg("parent")
                    .map(|parent| parent.parse().map_err(|_| Invalid("invalid parent")))
                    .transpose()?;
                Some(Route::ListRuns(show, parent))
            }
            ("POST", ["", "runs", "reap"]) => Some(Route::Reap),
            (_, ["", "runs", id, rest @ ..]) => {
                let Ok(id) = id.parse::<RunId>() else {
                    return Ok(None);
                };
                match (method, rest) {
                    ("GET", []) => Some(Route::GetRun(id)),
                    ("GET", ["wait"]) => {
                        let timeout = arg("timeout_ms")
                            .map_or(Ok(WAIT_DEFAULT_MS), |timeout| natural(timeout, WAIT_MAX_MS))?;
                        Some(Route::WaitRun(id, timeout))
                    }
                    ("POST", ["outcome"]) => Some(Route::RunOutcome(id)),
                    ("POST", ["stop"]) => Some(Route::StopRun(id)),
                    _ => None,
                }
            }
            ("GET", ["", "prompt", "resolve"]) => {
                let window_only = match arg("window") {
                    None => false,
                    Some("true") => true,
                    Some(_) => return Err(Invalid("invalid window")),
                };
                Some(Route::PromptResolve { window_only })
            }
            ("POST", ["", "prompt"]) => Some(Route::SendPrompt),
            (_, ["", "panes", id, rest @ ..]) => {
                let Ok(id) = id.parse::<PaneId>() else {
                    return Ok(None);
                };
                match (method, rest) {
                    ("DELETE", []) => Some(Route::DeletePane(id)),
                    ("POST", ["clear_history"]) => Some(Route::ClearHistory(id)),
                    ("POST", ["input"]) => Some(Route::Input(id)),
                    ("GET", ["screen"]) => {
                        let format = match arg("format") {
                            None | Some("plain") => ScreenFormat::Plain,
                            Some("ansi") => ScreenFormat::Ansi,
                            Some(_) => return Err(Invalid("invalid format")),
                        };
                        let rows = match arg("history") {
                            None | Some("none") => ScreenRows::Visible,
                            Some("all") => ScreenRows::Full,
                            Some(rows) => ScreenRows::Last(
                                u32::try_from(natural(rows, u64::from(u32::MAX))?)
                                    .map_err(|_| Invalid("invalid number"))?,
                            ),
                        };
                        Some(Route::Screen(id, format, rows))
                    }
                    ("GET", ["vars"]) => Some(Route::Vars(id)),
                    ("DELETE", ["vars"]) => Some(Route::DeleteVars(id)),
                    (_, ["vars", name]) => {
                        let name = percent_decode(name)
                            .and_then(|name| VarName::new(&name).ok())
                            .ok_or(Invalid("invalid variable name"))?;
                        match method {
                            "GET" => Some(Route::Var(id, name)),
                            "PUT" => Some(Route::SetVar(id, name)),
                            "DELETE" => Some(Route::DeleteVar(id, name)),
                            _ => None,
                        }
                    }
                    ("GET", ["view"]) => {
                        let history = match arg("history") {
                            None | Some("none") => History::None,
                            Some("all") => History::All,
                            Some(_) => return Err(Invalid("invalid history")),
                        };
                        let images = match arg("images") {
                            None | Some("none") => Images::None,
                            Some(_) => return Err(Invalid("P1 supports images=none only")),
                        };
                        let offset = arg("offset")
                            .map(|offset| natural(offset, MAX_OFFSET))
                            .transpose()?;
                        Some(Route::View(id, ViewOptions { history, images }, offset))
                    }
                    _ => None,
                }
            }
            _ => None,
        })
    }

    pub fn to_request(&self) -> (&'static str, String) {
        let pane = |id: &PaneId| format!("/panes/{id}");
        match self {
            Route::Version => ("GET", "/version".to_owned()),
            Route::ListPanes => ("GET", "/panes".to_owned()),
            Route::GetLayout => ("GET", "/layout".to_owned()),
            Route::PutLayout => ("PUT", "/layout".to_owned()),
            Route::Client => ("GET", "/client".to_owned()),
            Route::SelectClient(id) => ("POST", format!("/clients/{id}/select")),
            Route::DeletePane(id) => ("DELETE", pane(id)),
            Route::DeleteWindow(id) => ("DELETE", format!("/windows/{id}")),
            Route::DeleteSession(id) => ("DELETE", format!("/sessions/{id}")),
            Route::ClearHistory(id) => ("POST", format!("{}/clear_history", pane(id))),
            Route::Input(id) => ("POST", format!("{}/input", pane(id))),
            Route::Screen(id, format, rows) => {
                let format = match format {
                    ScreenFormat::Plain => "plain",
                    ScreenFormat::Ansi => "ansi",
                };
                let rows = match rows {
                    ScreenRows::Visible => "none".to_owned(),
                    ScreenRows::Full => "all".to_owned(),
                    ScreenRows::Last(rows) => rows.to_string(),
                };
                (
                    "GET",
                    format!("{}/screen?format={format}&history={rows}", pane(id)),
                )
            }
            Route::Vars(id) => ("GET", format!("{}/vars", pane(id))),
            Route::DeleteVars(id) => ("DELETE", format!("{}/vars", pane(id))),
            Route::Var(id, name) => (
                "GET",
                format!("{}/vars/{}", pane(id), percent_encode(name.as_str())),
            ),
            Route::SetVar(id, name) => (
                "PUT",
                format!("{}/vars/{}", pane(id), percent_encode(name.as_str())),
            ),
            Route::DeleteVar(id, name) => (
                "DELETE",
                format!("{}/vars/{}", pane(id), percent_encode(name.as_str())),
            ),
            Route::StartRun => ("POST", "/runs".to_owned()),
            Route::ListRuns(show, parent) => {
                let show = SHOWS
                    .iter()
                    .find(|(known, _)| known == show)
                    .map_or("live", |(_, name)| *name);
                let parent = parent
                    .as_ref()
                    .map_or(String::new(), |parent| format!("&parent={parent}"));
                ("GET", format!("/runs?show={show}{parent}"))
            }
            Route::Reap => ("POST", "/runs/reap".to_owned()),
            Route::GetRun(id) => ("GET", format!("/runs/{id}")),
            Route::WaitRun(id, timeout) => ("GET", format!("/runs/{id}/wait?timeout_ms={timeout}")),
            Route::RunOutcome(id) => ("POST", format!("/runs/{id}/outcome")),
            Route::StopRun(id) => ("POST", format!("/runs/{id}/stop")),
            Route::PromptResolve { window_only } => (
                "GET",
                format!(
                    "/prompt/resolve{}",
                    if *window_only { "?window=true" } else { "" }
                ),
            ),
            Route::SendPrompt => ("POST", "/prompt".to_owned()),
            Route::View(id, options, offset) => {
                let history = match options.history {
                    History::None => "none",
                    History::All => "all",
                };
                let offset = offset.map_or(String::new(), |offset| format!("&offset={offset}"));
                (
                    "GET",
                    format!("{}/view?history={history}&images=none{offset}", pane(id)),
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use serde::de::DeserializeOwned;

    #[test]
    fn variable_routes_decode_and_encode_their_name() {
        let pane: PaneId = "pane_2".parse().unwrap();
        let name = VarName::new("pi.session é/x?").unwrap();
        let encoded = "/panes/pane_2/vars/pi.session%20%C3%A9%2Fx%3F";
        for (method, route) in [
            ("GET", Route::Var(pane, name.clone())),
            ("PUT", Route::SetVar(pane, name.clone())),
            ("DELETE", Route::DeleteVar(pane, name.clone())),
        ] {
            assert_eq!(Route::of_request(method, encoded), Ok(Some(route.clone())));
            assert_eq!(route.to_request(), (method, encoded.to_owned()));
        }
        assert_eq!(
            Route::of_request("GET", "/panes/pane_2/vars"),
            Ok(Some(Route::Vars(pane)))
        );
        assert_eq!(Route::of_request("POST", "/panes/pane_2/vars/a"), Ok(None));
        for bad in [
            "/panes/pane_2/vars/",
            "/panes/pane_2/vars/%FF",
            "/panes/pane_2/vars/%0A",
            "/panes/pane_2/vars/%",
            &format!("/panes/pane_2/vars/{}", "n".repeat(257)),
        ] {
            assert!(Route::of_request("GET", bad).is_err(), "{bad}");
        }
        let longest = format!("/panes/pane_2/vars/{}", "n".repeat(256));
        assert!(matches!(
            Route::of_request("GET", &longest),
            Ok(Some(Route::Var(..)))
        ));
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
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":null}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"exited","code":7}}}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"signaled","signal":9}}}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"failed","message":"boom"}}}"#,
        ] {
            same::<Row>(json);
        }
        same::<Row>(
            r#"{"id":"pane_4","pid":1,"command":["/bin/sh"],"cwd":"/","title":"","dead":null,"foreground":{"pid":77,"name":"sleep"},"status":{"kind":{"type":"terminal","phase":{"type":"running","origin":{"type":"command","command":"sleep 2","started_at":5},"fullscreen":false},"report":{"since":4,"msg":"m","state":{"type":"waiting","kind":"question","progress":42}}},"program_status":{"serial":3,"records":[{"id":"","state":"blocked","kind":"question","progress":42,"app":"pi","title":"t","msg":"m"},{"id":"a/b","state":"working"},{"id":"c","state":"done"}]},"title":"sleep 2","message":"m","progress":42,"since":6},"progress":{"state":"set","progress":50}}"#,
        );
        for json in [
            r#"{"type":"some_agent","name":"claude-code","status":{"since":1,"state":{"type":"idle","outcome":{"serial":2,"result":"success"}}}}"#,
            r#"{"type":"pi_agent","session":"s","status":{"since":1,"state":{"type":"running"}}}"#,
            r#"{"type":"ssh","destination":"deploy@h","pane":{"type":"terminal","interactive":true,"status":{"phase":{"type":"idle","last":{"code":1,"command":"false","started_at":1,"ended_at":2}}}}}"#,
            r#"{"type":"ssh","destination":"h","pane":{"type":"agent","name":"pi","status":{"since":0,"state":{"type":"idle"}}}}"#,
            r#"{"type":"terminal","phase":{"type":"running","origin":{"type":"unknown"},"fullscreen":true}}"#,
            r#"{"type":"terminal","phase":{"type":"unknown"}}"#,
        ] {
            same::<Live>(json);
        }
        same::<Listing>(
            r#"{"id":"pane_4","pid":1,"command":["/bin/sh"],"cwd":"/","title":"","dead":null,"vars":{"n":[1,{"a":null}],"pi.name":"Worker"}}"#,
        );
        for json in [
            r#"{"pasted":true,"unsafe":false}"#,
            r#"{"id":41,"pasted":false,"unsafe":true}"#,
        ] {
            same::<PasteResult>(json);
        }
        for json in [
            r#"{"type":"hello","kind":"terminal","name":"test","focused":true,"size":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"ignore_size":false}"#,
            r#"{"type":"hello","kind":"app","name":"app","pane":"pane_3","focused":false,"size":{"cols":4096,"rows":1},"ignore_size":true}"#,
            r#"{"type":"hello","kind":"app","name":"app","session":"session_1","window":"window_2","pane":"pane_3","focused":false,"size":{"cols":80,"rows":24},"ignore_size":false}"#,
            r#"{"type":"select","pane":"pane_3"}"#,
            r#"{"type":"select","session":"session_1"}"#,
            r#"{"type":"switch","over":"window","direction":"previous"}"#,
            r#"{"type":"size","cols":80,"rows":24,"cell_px":{"width":8,"height":16}}"#,
            r#"{"type":"focused","focused":true}"#,
        ] {
            same::<ClientRequest>(json);
        }
        for json in [
            r#"{"name":"w","env":[],"argv":["/bin/sh"]}"#,
            r#"{"name":"w","cwd":"/tmp","session":"session_2","parent":"pane_1","env":[{"name":"X","value":"y"}],"argv":["/bin/sh","-c","x"]}"#,
            r#"{"name":"w","session":"work","parent":"0123456789abcdef0123456789abcdef","env":[],"argv":["/bin/sh"]}"#,
        ] {
            same::<StartRun>(json);
        }
        same::<Started>(
            r#"{"id":"0123456789abcdef0123456789abcdef","window":"window_2","pane":"pane_3","output":"/tmp/x/output"}"#,
        );
        for json in [
            r#"{}"#,
            r#"{"outcome":{"result":"failed","text":"exit 2","at":"2023-11-14T22:13:20Z"}}"#,
        ] {
            same::<Waited>(json);
        }
        for json in [
            r#"{"result":"completed"}"#,
            r#"{"result":"failed","text":"why"}"#,
            r#"{"result":"stopped"}"#,
        ] {
            same::<ReportOutcome>(json);
        }
        for json in [
            r#"{"wait_ms":0,"result":"stopped"}"#,
            r#"{"wait_ms":1500,"result":"completed"}"#,
        ] {
            same::<StopRun>(json);
        }
        same::<RunEvent>(
            r#"{"id":"0123456789abcdef0123456789abcdef","name":"w","parent":"pane_1","pane":"pane_3","startedAt":"2023-11-14T22:13:20Z","outcome":{"result":"died"}}"#,
        );
        same::<ClientEvent>(
            r#"{"type":"run","id":"0123456789abcdef0123456789abcdef","name":"w","pane":"pane_3","startedAt":"2023-11-14T22:13:20Z"}"#,
        );
        same::<SendPrompt>(r#"{"target":"pane_2","text":"hi\nthere"}"#);
        same::<Sent>(r#"{"via":"inbox"}"#);
        same::<Candidate>(
            r#"{"pane":"pane_2","session":"session_1","window":"window_3","title":"Worker"}"#,
        );
        for bad in [
            r#"{"name":"w","argv":["/bin/sh"],"parent":"../x"}"#,
            r#"{"name":"w","argv":["/bin/sh"],"session":"a\nb"}"#,
            r#"{"name":"a\nb","argv":["/bin/sh"]}"#,
            r#"{"name":"w"}"#,
            r#"["w",["/bin/sh"]]"#,
        ] {
            assert!(decode::<StartRun>(bad.as_bytes()).is_err(), "{bad}");
        }
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
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback","max_bytes":50000000},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":123456789}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"disabled"},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":["file","temp_file","shared_mem"]},"instance":"0123456789abcdef0123456789abcdef","now":123456789}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback","max_bytes":83886080,"max_lines":5000},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":123456789}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback"},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]},"instance":"0123456789abcdef0123456789abcdef","now":123456789}"#,
            r#"{"type":"layout","revision":3,"layout":{"sessions":[{"id":"session_1","name":"s","vars":{"a":1},"windows":[{"id":"window_1","name":"w","vars":{},"cols":80,"rows":24,"cell_px":{"width":8,"height":16},"zoom":"pane_1","focus":"pane_2","tree":{"split":"h","children":[{"pane":"pane_1","cols":40,"rows":24},{"pane":"pane_2","cols":39,"rows":24}]},"floats":[{"pane":"pane_3","x":6,"y":4,"cols":28,"rows":8,"z":0,"border":false,"title":""}]}]}]}}"#,
            r#"{"type":"layout","revision":0,"layout":{"sessions":[]}}"#,
            r#"{"type":"selected","session":"session_1","window":"window_1","pane":"pane_2"}"#,
            r#"{"type":"selected"}"#,
            r#"{"type":"title","pane":"pane_3","title":"x"}"#,
            r#"{"type":"pwd","pane":"pane_3","pwd":"file://h/tmp"}"#,
            r#"{"type":"dead","pane":"pane_3","dead":{"at":123456789012345,"cause":{"type":"signaled","signal":15}}}"#,
            r#"{"type":"status","pane":"pane_3","status":{"kind":{"type":"terminal","phase":{"type":"idle"}},"program_status":{"serial":0,"records":[]},"title":"zsh","since":9},"now":99}"#,
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
            r#"{"type":"marked","offset":7,"marker":{"type":"dead","at":123456789012345,"cause":{"type":"exited","code":7}}}"#,
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
        let hello = r#"{"type":"hello","kind":"terminal","name":"x","focused":true,"size":{"cols":1,"rows":1},"ignore_size":false}"#;
        assert_eq!(
            decoded::<ClientRequest>(
                r#"{"type":"hello","kind":"terminal","name":"x","focused":true,"size":{"cols":1,"rows":1},"extra":1}"#
            ),
            Ok(hello.to_owned())
        );
        assert_eq!(
            decoded::<ClientRequest>(
                r#"{"type":"hello","kind":"terminal","name":"x","focused":true,"size":{"cols":1,"rows":1,"cell_px":null},"pane":null}"#
            ),
            Ok(hello.to_owned())
        );
        for refused in [
            r#"["select","pane_1"]"#,
            r#"{"type":"switch","over":"pane","direction":"next"}"#,
            r#"{"type":"switch","over":"window"}"#,
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
    fn a_route_parses_its_own_request_and_refuses_a_bad_query() {
        let pane = PaneId::new(7);
        let run: RunId = "0123456789abcdef0123456789abcdef".parse().unwrap();
        for route in [
            Route::Version,
            Route::ListPanes,
            Route::GetLayout,
            Route::PutLayout,
            Route::SelectClient(ClientId::new(4)),
            Route::ClearHistory(pane),
            Route::Client,
            Route::DeletePane(pane),
            Route::DeleteWindow(WindowId::new(2)),
            Route::DeleteSession(SessionId::new(3)),
            Route::DeleteVars(pane),
            Route::Input(pane),
            Route::Screen(pane, ScreenFormat::Ansi, ScreenRows::Last(40)),
            Route::Screen(pane, ScreenFormat::Plain, ScreenRows::Full),
            Route::StartRun,
            Route::ListRuns(Show::Live, None),
            Route::ListRuns(Show::All, Some(Parent::Pane(pane))),
            Route::ListRuns(Show::Present, Some(Parent::Run(run.clone()))),
            Route::Reap,
            Route::GetRun(run.clone()),
            Route::WaitRun(run.clone(), 250),
            Route::RunOutcome(run.clone()),
            Route::StopRun(run),
            Route::PromptResolve { window_only: false },
            Route::PromptResolve { window_only: true },
            Route::SendPrompt,
            Route::View(
                pane,
                ViewOptions {
                    history: History::All,
                    images: Images::None,
                },
                Some(9),
            ),
            Route::View(
                pane,
                ViewOptions {
                    history: History::None,
                    images: Images::None,
                },
                None,
            ),
        ] {
            let (method, target) = route.to_request();
            assert_eq!(Route::of_request(method, &target), Ok(Some(route)));
        }
        let parsed: Vec<String> = [
            ("GET", "/panes/pane_7/screen?history=4294967296"),
            ("GET", "/panes/pane_7/view?offset=4611686018427387904"),
            ("GET", "/panes/pane_7/view?images=all"),
            ("GET", "/panes/pane_7/view?a=b=c"),
            ("GET", "/panes/pane_7/view?"),
            ("GET", "/panes/pane_x/view"),
            ("PUT", "/panes"),
            ("POST", "/clients/client_x/select"),
            ("POST", "/panes/pane_1/clear_history/x"),
            ("GET", "/panes?x=1"),
            ("GET", "/runs?show=some"),
            ("GET", "/prompt/resolve?window=1"),
            ("GET", "/runs?parent=nope"),
            (
                "GET",
                "/runs/0123456789abcdef0123456789abcdef/wait?timeout_ms=3600001",
            ),
            ("GET", "/runs/0123456789abcdef0123456789abcdef/wait"),
            ("GET", "/runs/abc"),
            ("POST", "/runs/reap"),
            ("PUT", "/runs"),
        ]
        .into_iter()
        .map(|(method, target)| match Route::of_request(method, target) {
            Ok(route) => format!("{route:?}"),
            Err(invalid) => invalid.to_string(),
        })
        .collect();
        assert_eq!(
            parsed,
            [
                "invalid number",
                "invalid number",
                "P1 supports images=none only",
                "invalid query",
                "invalid query",
                "None",
                "None",
                "None",
                "None",
                "Some(ListPanes)",
                "invalid show",
                "invalid window",
                "invalid parent",
                "invalid number",
                "Some(WaitRun(RunId(\"0123456789abcdef0123456789abcdef\"), 30000))",
                "None",
                "Some(Reap)",
                "None",
            ]
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
            "ignore_size",
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
                    r#"{"type":"size","cols":80,"rows":24,"cell_px":{"width":8,"height":16}}"#,
                ),
                r#"{"type":"size","cols":80,"rows":24,"cell_px":{"width":8,"height":16}}"#,
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
            decoded::<ClientRequest>(r#"{"type":"size","cols":80,"rows":24,"cell_px":[8,16]}"#),
            decoded::<ClientRequest>(
                r#"{"type":"hello","kind":"terminal","name":"t","focused":true,"size":[80,24]}"#,
            ),
            decoded::<ViewRequest>(r#"{"type":"resync","history":"all","images":["x"]}"#),
            decoded::<ViewRequest>(r#"{"type":"input","input":["paste",["x",true]]}"#),
            decoded::<ViewRequest>(
                r#"{"type":"input","input":{"type":"paste","text":"x","check_safe":["true"]}}"#,
            ),
            decoded::<ViewEvent>(
                r#"{"type":"marked","offset":1,"marker":{"type":"dead","at":1,"cause":["exited",7]}}"#,
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

        #[test]
        fn routes_return_a_route_nothing_or_invalid(
            method in prop::sample::select(vec!["GET", "POST", "DELETE", "PUT", ""]),
            path in prop::sample::select(vec!["/version", "/panes", "/client", "/panes/pane_1", "/panes/pane_1/view", "/panes/pane_1/screen", "/panes/pane_1/input", "/panes/pane_1/vars", "/panes/pane_1/vars/a%20b", "/panes/pane_1/vars/%FF", "/panes/1/view", "/", ""]),
            query in prop::collection::vec((prop::sample::select(vec!["history", "images", "offset", "format", "x", ""]), prop::sample::select(vec!["", "a", "all", "none", "0", "-1", "99999999999999999999", "4294967296", "%00", "=", "&", "?", "/"])), 0..3),
            with_query in any::<bool>(),
        ) {
            let query: Vec<String> = query.into_iter().map(|(key, value)| format!("{key}={value}")).collect();
            let target = if with_query { format!("{path}?{}", query.join("&")) } else { path.to_owned() };
            if let Ok(Some(route)) = Route::of_request(method, &target) {
                let (method, target) = route.to_request();
                prop_assert_eq!(Route::of_request(method, &target), Ok(Some(route)));
            }
        }
    }
}
