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
use crate::ids::{ClientId, PaneId};
use crate::pane_proc::{self, Death};

const PROTOCOL: &str = "2.0";
const PROTOCOL_MAJOR: &str = "2";
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
pub(crate) enum ErrorKind {
    Invalid,
    Refused,
    Gone,
    Io,
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
            ErrorKind::ProtocolMismatch(_) => Status::UpgradeRequired,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Error {
    #[serde(flatten)]
    pub(crate) kind: ErrorKind,
    pub(crate) message: String,
}

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
    cell_px: Option<RawCellPx>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "RawSize", into = "RawSize")]
pub struct Size(pub frame::Size);

impl TryFrom<RawSize> for Size {
    type Error = &'static str;

    fn try_from(raw: RawSize) -> Result<Size, &'static str> {
        let cell_px = match raw.cell_px {
            None => None,
            Some(cell) => Some(CellPx {
                width: NonZeroU16::new(cell.width).ok_or("invalid size")?,
                height: NonZeroU16::new(cell.height).ok_or("invalid size")?,
            }),
        };
        Ok(Size(frame::Size {
            cols: Dim::new(raw.cols).ok_or("invalid size")?,
            rows: Dim::new(raw.rows).ok_or("invalid size")?,
            cell_px,
        }))
    }
}

impl From<Size> for RawSize {
    fn from(Size(size): Size) -> RawSize {
        RawSize {
            cols: size.cols.get(),
            rows: size.rows.get(),
            cell_px: size.cell_px.map(|cell| RawCellPx {
                width: cell.width.get(),
                height: cell.height.get(),
            }),
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub id: PaneId,
    pub pid: i32,
    pub command: Vec<String>,
    pub cwd: String,
    pub title: String,
    pub dead: Option<Dead>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Created {
    pub pane: PaneId,
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

fn base64_encode(bytes: &[u8]) -> String {
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
    Focus { focused: bool },
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
            Input::Focus { focused } => pane_proc::Input::Focus(*focused),
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<PaneId>,
    pub focused: bool,
    pub size: Size,
    #[serde(default)]
    pub ignore_size: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientRequest {
    Hello(Hello),
    Select { pane: PaneId },
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
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    Welcome(Welcome),
    Topology { panes: Vec<Row> },
    Title(Title),
    Pwd(Pwd),
    Dead(PaneDead),
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
    CreatePane,
    Client,
    DeletePane(PaneId),
    Input(PaneId),
    Screen(PaneId, ScreenFormat, ScreenRows),
    View(PaneId, ViewOptions, Option<u64>),
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
            ("POST", ["", "panes"]) => Some(Route::CreatePane),
            ("GET", ["", "client"]) => Some(Route::Client),
            (_, ["", "panes", id, rest @ ..]) => {
                let Ok(id) = id.parse::<PaneId>() else {
                    return Ok(None);
                };
                match (method, rest) {
                    ("DELETE", []) => Some(Route::DeletePane(id)),
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
            Route::CreatePane => ("POST", "/panes".to_owned()),
            Route::Client => ("GET", "/client".to_owned()),
            Route::DeletePane(id) => ("DELETE", pane(id)),
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
    fn every_wire_type_round_trips_the_protocol_2_0_json() {
        same::<Version>(
            r#"{"protocol":"2.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty"}"#,
        );
        for json in [
            r#"{"kind":"invalid","message":"m"}"#,
            r#"{"kind":"refused","message":"m"}"#,
            r#"{"kind":"gone","message":"m"}"#,
            r#"{"kind":"io","message":"m"}"#,
            r#"{"kind":"not_found","message":"m"}"#,
            r#"{"kind":"protocol_mismatch","protocol":"2.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty","message":"m"}"#,
            r#"{"kind":"vt_mismatch","protocol":"2.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty","message":"m"}"#,
        ] {
            same::<Error>(json);
        }
        for json in [
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":null}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"exited","code":7}}}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"signaled","signal":9}}}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"failed","message":"boom"}}}"#,
        ] {
            same::<Row>(json);
        }
        same::<Created>(r#"{"pane":"pane_3"}"#);
        for json in [
            r#"{"pasted":true,"unsafe":false}"#,
            r#"{"id":41,"pasted":false,"unsafe":true}"#,
        ] {
            same::<PasteResult>(json);
        }
        for json in [
            r#"{"type":"hello","kind":"terminal","name":"test","focused":true,"size":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"ignore_size":false}"#,
            r#"{"type":"hello","kind":"app","name":"app","pane":"pane_3","focused":false,"size":{"cols":4096,"rows":1},"ignore_size":true}"#,
            r#"{"type":"select","pane":"pane_3"}"#,
            r#"{"type":"size","cols":80,"rows":24,"cell_px":{"width":8,"height":16}}"#,
            r#"{"type":"focused","focused":true}"#,
        ] {
            same::<ClientRequest>(json);
        }
        for json in [
            r#"{"env":[]}"#,
            r#"{"cwd":"/tmp","command":{"type":"argv","argv":["/bin/sh","-c","x"]},"env":[{"name":"X","value":"y"}]}"#,
            r#"{"command":{"type":"shell","command":"exec cat"},"env":[]}"#,
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
            r#"{"type":"input","input":{"type":"focus","focused":false}}"#,
        ] {
            same::<ViewRequest>(json);
        }
        for json in [
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback","max_bytes":50000000},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]}}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"disabled"},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":["file","temp_file","shared_mem"]}}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback","max_bytes":83886080,"max_lines":5000},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]}}"#,
            r#"{"type":"welcome","client":"client_2","limits":{"terminal":{"scrollback":{"type":"scrollback"},"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]}}"#,
            r#"{"type":"topology","panes":[{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":null},{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":{"type":"exited","code":0}}}]}"#,
            r#"{"type":"topology","panes":[]}"#,
            r#"{"type":"title","pane":"pane_3","title":"x"}"#,
            r#"{"type":"pwd","pane":"pane_3","pwd":"file://h/tmp"}"#,
            r#"{"type":"dead","pane":"pane_3","dead":{"at":123456789012345,"cause":{"type":"signaled","signal":15}}}"#,
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
            r#"{"type":"select"}"#,
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
        for route in [
            Route::Version,
            Route::ListPanes,
            Route::CreatePane,
            Route::Client,
            Route::DeletePane(pane),
            Route::Input(pane),
            Route::Screen(pane, ScreenFormat::Ansi, ScreenRows::Last(40)),
            Route::Screen(pane, ScreenFormat::Plain, ScreenRows::Full),
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
            ("GET", "/panes?x=1"),
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
                "Some(ListPanes)",
            ]
        );
    }

    #[test]
    fn the_version_check_takes_a_higher_minor_and_refuses_another_major_or_terminal() {
        let checked: Vec<String> = [
            (Some("2.0"), Some(VT)),
            (Some("2.7"), Some(VT)),
            (Some("1.0"), Some(VT)),
            (Some("2."), Some(VT)),
            (None, Some(VT)),
            (Some("2.0"), Some("wrong")),
            (Some("2.0"), None),
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
                decoded::<ClientEvent>(r#"{"type":"topology","panes":[]}"#),
                r#"{"type":"topology","panes":[]}"#,
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
            decoded::<ClientEvent>(r#"{"type":"topology","panes":[["pane_1",1,[],"/","t",null]]}"#),
            decoded::<ClientEvent>(r#"{"type":"welcome","client":"client_1","limits":[]}"#),
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
            path in prop::sample::select(vec!["/version", "/panes", "/client", "/panes/pane_1", "/panes/pane_1/view", "/panes/pane_1/screen", "/panes/pane_1/input", "/panes/1/view", "/", ""]),
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
