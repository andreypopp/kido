use std::borrow::Cow;

use ko_config::values::RuntimeName;
use ko_pane_wire::frame::{History, ScreenFormat, ScreenRows};
use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::de::IntoDeserializer;
use serde::de::value::Error as ValueError;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ids::{ClientId, PaneId, SessionId, VarName, WindowId};
use crate::protocol::{
    Candidate, ClientEvent, ClientRequest, DeleteVars, DownRuntime, Empty, ExecClient, ExecServer,
    HistoryDef, Images, Input, InputResult, LayoutPanes, Listing, Message, NewWindow, PanePatch,
    Placement, Posted, PutLayout, RuntimeInfo, RuntimeWait, SearchEvent, SendMessage, SendPrompt,
    Sent, ServerVersion, Snapshot, StopPane, StreamRequest, VarValue, ViewEvent, ViewRequest,
    VisitClient, VisitServer,
};
use crate::route::{Invalid, Param, binary, pixels, routes, text};

pub fn route_paths() -> impl Iterator<Item = (&'static str, &'static [&'static str])> {
    ROUTES.iter().map(|route| (route.path, route.docs))
}

const MAX_OFFSET: u64 = (1 << 62) - 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct WaitMs(u64);

impl TryFrom<u64> for WaitMs {
    type Error = &'static str;

    fn try_from(milliseconds: u64) -> Result<WaitMs, &'static str> {
        if milliseconds > WaitMs::MAX.0 {
            Err("wait is too long")
        } else {
            Ok(WaitMs(milliseconds))
        }
    }
}

impl From<WaitMs> for u64 {
    fn from(wait: WaitMs) -> u64 {
        wait.0
    }
}

impl WaitMs {
    pub const DEFAULT: WaitMs = WaitMs(30_000);
    pub const MAX: WaitMs = WaitMs(3_600_000);
    pub const NONE: WaitMs = WaitMs(0);

    pub fn none() -> WaitMs {
        WaitMs::NONE
    }

    pub fn clamped(milliseconds: u64) -> WaitMs {
        WaitMs(milliseconds.min(WaitMs::MAX.0))
    }

    pub fn get(self) -> u64 {
        self.0
    }
}

impl JsonSchema for WaitMs {
    fn schema_name() -> Cow<'static, str> {
        "WaitMs".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": 0, "maximum": WaitMs::MAX.0, "description": "Milliseconds."})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Offset(u64);

impl Offset {
    pub fn new(offset: u64) -> Option<Offset> {
        (offset <= MAX_OFFSET).then_some(Offset(offset))
    }

    pub fn get(self) -> u64 {
        self.0
    }
}

impl JsonSchema for Offset {
    fn schema_name() -> Cow<'static, str> {
        "Offset".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": 0, "maximum": MAX_OFFSET, "description": "A byte offset of the pane's stream."})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageId(u32);

impl ImageId {
    pub fn get(self) -> u32 {
        self.0
    }
}

impl JsonSchema for ImageId {
    fn schema_name() -> Cow<'static, str> {
        "ImageId".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": 1, "maximum": u32::MAX, "description": "The id a program gave an image."})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameNumber(u32);

impl FrameNumber {
    pub fn get(self) -> u32 {
        self.0
    }
}

impl JsonSchema for FrameNumber {
    fn schema_name() -> Cow<'static, str> {
        "FrameNumber".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": 1, "maximum": u32::MAX, "description": "1 is the image itself; 2 and up are its animation frames."})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Generation(u64);

impl Generation {
    pub fn get(self) -> u64 {
        self.0
    }
}

impl JsonSchema for Generation {
    fn schema_name() -> Cow<'static, str> {
        "Generation".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "integer", "minimum": 1, "maximum": u64::MAX, "description": "The serial that the pane's terminal stamped on the frame."})
    }
}

const MAX_NEEDLE: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Needle(String);

impl Needle {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl JsonSchema for Needle {
    fn schema_name() -> Cow<'static, str> {
        "Needle".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "string", "minLength": 1, "maxLength": MAX_NEEDLE, "description": "The text to search for, percent-encoded in the query."})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowOnly;

impl JsonSchema for WindowOnly {
    fn schema_name() -> Cow<'static, str> {
        "WindowOnly".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "string", "enum": ["true"]})
    }
}

fn natural(value: &str, max: u64) -> Result<u64, Invalid> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(Invalid::message("invalid number"));
    }
    value
        .parse()
        .ok()
        .filter(|&number| number <= max)
        .ok_or_else(|| Invalid::message("invalid number"))
}

fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while let Some(&byte) = bytes.get(at) {
        if byte == b'%' {
            let hex = value.get(at + 1..at + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            at += 3;
        } else {
            out.push(byte);
            at += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn named<'a, T>(
    value: &'a str,
    message: &str,
    decode: impl FnOnce(serde::de::value::StrDeserializer<'a, ValueError>) -> Result<T, ValueError>,
) -> Result<T, Invalid> {
    decode(value.into_deserializer()).map_err(|_| Invalid::message(message))
}

fn name_of(
    encode: impl FnOnce(serde_json::value::Serializer) -> serde_json::Result<Value>,
) -> String {
    match encode(serde_json::value::Serializer) {
        Ok(Value::String(name)) => name,
        _ => String::new(),
    }
}

macro_rules! id_params {
    ($($id:ty => $example:literal),* $(,)?) => {$(
        impl Param for $id {
            const EXAMPLE: &'static str = $example;

            fn parse(value: &str) -> Result<$id, Invalid> {
                value.parse().map_err(|_| Invalid::NoRoute)
            }

            fn render(&self) -> String {
                self.to_string()
            }

            fn schema(generator: &mut SchemaGenerator) -> Schema {
                generator.subschema_for::<$id>()
            }
        }
    )*};
}

id_params! {
    ClientId => "client_1",
    SessionId => "session_1",
    WindowId => "window_1",
}

impl Param for PaneId {
    const EXAMPLE: &'static str = "pane_1";

    fn parse(value: &str) -> Result<PaneId, Invalid> {
        value.parse().map_err(|_| Invalid::NoRoute)
    }

    fn render(&self) -> String {
        self.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<PaneId>()
    }

    fn pane(&self) -> Option<PaneId> {
        Some(*self)
    }
}

impl Param for VarName {
    const EXAMPLE: &'static str = "pi.session";

    fn parse(value: &str) -> Result<VarName, Invalid> {
        percent_decode(value)
            .and_then(|name| VarName::new(&name).ok())
            .ok_or_else(|| Invalid::message("invalid variable name"))
    }

    fn render(&self) -> String {
        percent_encode(self.as_str())
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<VarName>()
    }
}

impl Param for RuntimeName {
    const EXAMPLE: &'static str = "dev";

    fn parse(value: &str) -> Result<RuntimeName, Invalid> {
        value
            .parse()
            .map_err(|_| Invalid::message("invalid runtime name"))
    }

    fn render(&self) -> String {
        self.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<RuntimeName>()
    }
}

impl Param for WaitMs {
    const EXAMPLE: &'static str = "250";

    fn parse(value: &str) -> Result<WaitMs, Invalid> {
        natural(value, WaitMs::MAX.0).map(WaitMs)
    }

    fn render(&self) -> String {
        self.0.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<WaitMs>()
    }
}

impl Param for Offset {
    const EXAMPLE: &'static str = "0";

    fn parse(value: &str) -> Result<Offset, Invalid> {
        natural(value, MAX_OFFSET).map(Offset)
    }

    fn render(&self) -> String {
        self.0.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<Offset>()
    }
}

fn positive(value: &str, max: u64) -> Result<u64, Invalid> {
    natural(value, max).and_then(|number| {
        (number > 0)
            .then_some(number)
            .ok_or_else(|| Invalid::message("invalid number"))
    })
}

impl Param for ImageId {
    const EXAMPLE: &'static str = "7";

    fn parse(value: &str) -> Result<ImageId, Invalid> {
        let number = positive(value, u64::from(u32::MAX))?;
        u32::try_from(number)
            .map(ImageId)
            .map_err(|_| Invalid::message("invalid number"))
    }

    fn render(&self) -> String {
        self.0.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<ImageId>()
    }
}

impl Param for FrameNumber {
    const EXAMPLE: &'static str = "1";

    fn parse(value: &str) -> Result<FrameNumber, Invalid> {
        let number = positive(value, u64::from(u32::MAX))?;
        u32::try_from(number)
            .map(FrameNumber)
            .map_err(|_| Invalid::message("invalid number"))
    }

    fn render(&self) -> String {
        self.0.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<FrameNumber>()
    }
}

impl Param for Generation {
    const EXAMPLE: &'static str = "3";

    fn parse(value: &str) -> Result<Generation, Invalid> {
        positive(value, u64::MAX).map(Generation)
    }

    fn render(&self) -> String {
        self.0.to_string()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<Generation>()
    }
}

impl Param for Needle {
    const EXAMPLE: &'static str = "needle";

    fn parse(value: &str) -> Result<Needle, Invalid> {
        percent_decode(value)
            .filter(|needle| !needle.is_empty() && needle.len() <= MAX_NEEDLE)
            .map(Needle)
            .ok_or_else(|| Invalid::message("invalid needle"))
    }

    fn render(&self) -> String {
        percent_encode(&self.0)
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<Needle>()
    }
}

impl Param for WindowOnly {
    const EXAMPLE: &'static str = "true";

    fn parse(value: &str) -> Result<WindowOnly, Invalid> {
        (value == "true")
            .then_some(WindowOnly)
            .ok_or_else(|| Invalid::message("invalid window"))
    }

    fn render(&self) -> String {
        "true".to_owned()
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<WindowOnly>()
    }
}

impl Param for ScreenFormat {
    const EXAMPLE: &'static str = "ansi";

    fn parse(value: &str) -> Result<ScreenFormat, Invalid> {
        match value {
            "plain" => Ok(ScreenFormat::Plain),
            "ansi" => Ok(ScreenFormat::Ansi),
            _ => Err(Invalid::message("invalid format")),
        }
    }

    fn render(&self) -> String {
        match self {
            ScreenFormat::Plain => "plain",
            ScreenFormat::Ansi => "ansi",
        }
        .to_owned()
    }

    fn schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type": "string", "enum": ["plain", "ansi"]})
    }
}

impl Param for ScreenRows {
    const EXAMPLE: &'static str = "40";

    fn parse(value: &str) -> Result<ScreenRows, Invalid> {
        match value {
            "none" => Ok(ScreenRows::Visible),
            "all" => Ok(ScreenRows::Full),
            rows => u32::try_from(natural(rows, u64::from(u32::MAX))?)
                .map(ScreenRows::Last)
                .map_err(|_| Invalid::message("invalid number")),
        }
    }

    fn render(&self) -> String {
        match self {
            ScreenRows::Visible => "none".to_owned(),
            ScreenRows::Full => "all".to_owned(),
            ScreenRows::Last(rows) => rows.to_string(),
        }
    }

    fn schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "anyOf": [
                {"type": "string", "enum": ["none", "all"]},
                {"type": "integer", "minimum": 0, "maximum": u32::MAX}
            ],
            "description": "none for the visible rows, all for the whole history, or the number of last rows."
        })
    }
}

impl Param for History {
    const EXAMPLE: &'static str = "all";

    fn parse(value: &str) -> Result<History, Invalid> {
        named(value, "invalid history", HistoryDef::deserialize)
    }

    fn render(&self) -> String {
        name_of(|serializer| HistoryDef::serialize(self, serializer))
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<HistoryDef>()
    }
}

impl Param for Images {
    const EXAMPLE: &'static str = "none";

    fn parse(value: &str) -> Result<Images, Invalid> {
        named(value, "P1 supports images=none only", Images::deserialize)
    }

    fn render(&self) -> String {
        name_of(|serializer| self.serialize(serializer))
    }

    fn schema(generator: &mut SchemaGenerator) -> Schema {
        generator.subschema_for::<Images>()
    }
}

routes! {
    /// The protocol and terminal revisions of this server.
    Version { method: GET, path: /version, reply: ServerVersion }
    /// Every pane, with its status and variables.
    ListPanes { method: GET, path: /panes, reply: Vec<Listing> }
    /// One pane, with its status and variables.
    GetPane { method: GET, path: /panes/{id: PaneId}, reply: Listing }
    /// The layout of every session, with its revision, and every pane that it names.
    GetLayout { method: GET, path: /layout, reply: LayoutPanes }
    /// Replaces the layout. A stale revision gets 409 with the current layout.
    PutLayout {
        method: PUT,
        path: /layout,
        body: PutLayout,
        caller: optional,
        reply: Snapshot,
        errors: { 409: Snapshot },
    }
    /// The client-lifetime socket: layout, focus and status events.
    Client { method: WS, path: /client, send: ClientRequest, recv: ClientEvent }
    /// Creates a window with one pane, in one change of the layout. No client switches to it.
    /// The pane's session is the given one, else the parent's, else the caller's, else a new one.
    /// The window goes after the parent's or the caller's window of that session, else at the end.
    NewPane {
        method: POST,
        path: /panes,
        body: NewWindow,
        caller: optional,
        reply: Placement,
    }
    /// Changes pane properties. Only the user or the pane itself may change them.
    /// The close policy applies when the program next dies. A dead pane cannot be changed.
    PatchPane {
        method: PATCH,
        path: /panes/{id: PaneId},
        body: PanePatch,
        caller: optional,
        reply: Empty,
    }
    /// Waits up to wait_ms for the pane to end by itself, then removes it and hangs up its
    /// program. ko kills a removed program that still lives after the escalation time. A dead
    /// pane is removed at once.
    StopPane {
        method: POST,
        path: /panes/{id: PaneId}/stop,
        body: StopPane,
        caller: optional,
        reply: Empty,
    }
    /// The messages that other panes and the user send to a pane, one text message each, in the
    /// order of the pane's queue. The receiver answers each with an ack or a refuse. Only the pane
    /// itself may open the stream, and a pane has one stream at most.
    Messages {
        method: WS,
        path: /panes/{id: PaneId}/messages,
        caller: optional,
        send: StreamRequest,
        recv: Message,
    }
    /// Sends a message to a pane. The server stamps the sender and keeps the message in the pane's
    /// queue until the pane's stream gets it. A message that is written at once waits up to two
    /// seconds for its ack. An id that the pane has seen is not queued again: the reply is the
    /// state of the original, with duplicate set.
    PostMessage {
        method: POST,
        path: /panes/{id: PaneId}/messages,
        body: SendMessage,
        caller: optional,
        reply: Posted,
    }
    /// Closes a pane.
    DeletePane { method: DELETE, path: /panes/{id: PaneId}, reply: Empty }
    /// Closes every pane of a window.
    DeleteWindow { method: DELETE, path: /windows/{id: WindowId}, reply: Empty }
    /// Closes every window of a session.
    DeleteSession { method: DELETE, path: /sessions/{id: SessionId}, reply: Empty }
    /// Drops the scrollback of a pane.
    ClearHistory { method: POST, path: /panes/{id: PaneId}/clear_history, reply: Empty }
    /// Sends a key, a mouse event, a paste or raw text to a pane.
    Input {
        method: POST,
        path: /panes/{id: PaneId}/input,
        body: Input,
        reply: InputResult,
    }
    /// The text of a pane, from the server's terminal.
    Screen {
        method: GET,
        path: /panes/{id: PaneId}/screen,
        query: { format: ScreenFormat = Plain, history: ScreenRows = Visible },
        reply: text,
    }
    /// The view of a pane: the terminal byte stream, and the input of the viewer.
    View {
        method: WS,
        path: /panes/{id: PaneId}/view,
        query: { history: History = None, images: Images = None, offset: Option<Offset> },
        send: ViewRequest,
        recv: ViewEvent | binary,
    }
    /// One frame of an image of a pane. Frame 1 is the image itself. The reply is the pixels as
    /// an application/octet-stream body, with their format, size and timing in the ko-image-*
    /// headers. With the header Ko-Accept-Shm: 1 the reply is instead a JSON body that names a
    /// shared memory object, which the client maps and never unlinks. An image that was evicted,
    /// a frame that does not exist and a generation that moved on are not_found.
    Image {
        method: GET,
        path: /panes/{id: PaneId}/images/{image: ImageId}/frames/{frame: FrameNumber},
        query: { generation: Generation },
        reply: pixels,
    }
    /// A search of the pane's terminal, history included: the matches in batches, oldest first,
    /// then done. The rows count from the top of the history at the time of the search, for
    /// display only. Closing the socket cancels the search.
    Search {
        method: WS,
        path: /panes/{id: PaneId}/search,
        query: { needle: Needle },
        send: Empty,
        recv: SearchEvent,
    }
    /// Sets one variable of a pane.
    SetVar {
        method: PUT,
        path: /panes/{id: PaneId}/vars/{name: VarName},
        body: VarValue,
        caller: optional,
        reply: Empty,
    }
    /// Removes one variable of a pane.
    DeleteVar {
        method: DELETE,
        path: /panes/{id: PaneId}/vars/{name: VarName},
        caller: optional,
        reply: Empty,
    }
    /// Removes variables of a pane, if its condition holds.
    DeleteVars {
        method: DELETE,
        path: /panes/{id: PaneId}/vars,
        body: DeleteVars,
        caller: optional,
        reply: Empty,
        errors: { 412 },
    }
    /// The configured runtimes and the ad-hoc runtimes of the caller's session, with their state.
    /// For the user, lists the ad-hoc runtimes of every session.
    ListRuntimes { method: GET, path: /runtimes, reply: Vec<RuntimeInfo> }
    /// Defines a runtime of the caller pane's session without starting it.
    PutRuntime { method: PUT, path: /runtimes/{name: RuntimeName}, body: ko_config::runtime::Runtime, reply: RuntimeInfo }
    /// One runtime.
    GetRuntime { method: GET, path: /runtimes/{name: RuntimeName}, query: { session: Option<SessionId> }, reply: RuntimeInfo }
    /// Waits up to the timeout for the link of the runtime to be up or failed. Only a pane of the
    /// runtime may wait. An Up reply follows the write of the pane's token file.
    WaitRuntime {
        method: GET,
        path: /runtimes/{name: RuntimeName}/wait,
        query: { timeout_ms: WaitMs = DEFAULT },
        caller: optional,
        reply: RuntimeWait,
    }
    /// Enters a runtime in the caller's existing pane until the WebSocket closes.
    VisitRuntime {
        method: WS,
        path: /runtimes/{name: RuntimeName}/visit,
        caller: optional,
        send: VisitClient,
        recv: VisitServer,
    }
    /// Starts the link of a runtime without a pane and returns without waiting for the link.
    UpRuntime {
        method: POST,
        path: /runtimes/{name: RuntimeName}/up,
        query: { session: Option<SessionId> },
        reply: Empty,
    }
    /// Takes the link of a runtime down. With live panes it is refused, unless force removes the
    /// panes first, as a stop does.
    DownRuntime {
        method: POST,
        path: /runtimes/{name: RuntimeName}/down,
        query: { session: Option<SessionId> },
        body: DownRuntime,
        reply: Empty,
    }
    /// Runs one command inside a runtime, without a terminal: separate stdout and stderr, an exit
    /// status or signal, and stdin from the client. Each message is JSON text, and the first
    /// client message must be exec. The server reads the socket only while the command takes
    /// its stdin, and it sends output only while the connection's queue has room, so nothing is
    /// dropped. After exit the server closes with 1000, and after error with 1011. A runtime that
    /// is down starts as for a first pane. A failed start ends the session with an error.
    /// At most 32 sessions of one runtime run at once, and the others wait in
    /// order for KO_RUNTIME_EXEC_WAIT_MS. A closed socket stops the command. The route is for
    /// the host: a runtime connection is refused.
    Exec {
        method: WS,
        path: /runtimes/{name: RuntimeName}/exec,
        query: { session: Option<SessionId> },
        caller: optional,
        send: ExecClient,
        recv: ExecServer,
    }
    /// Takes the runtime down, as down without force does, and removes its files except the empty io directory.
    DeleteRuntime { method: DELETE, path: /runtimes/{name: RuntimeName}, query: { session: Option<SessionId> }, reply: Empty }
    /// The agents that a prompt can reach from the pane `from`. A pane identity may name only itself.
    PromptResolve {
        method: GET,
        path: /prompt/resolve,
        query: { from: PaneId, window: Option<WindowOnly> },
        caller: optional,
        reply: Vec<Candidate>,
    }
    /// Sends a prompt to an agent.
    SendPrompt {
        method: POST,
        path: /prompt,
        body: SendPrompt,
        caller: optional,
        reply: Sent,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::PasteResult;
    use proptest::prelude::*;

    fn parsed(method: &str, target: &str) -> String {
        match Route::of_request(method, target) {
            Ok(route) => format!("{route:?}"),
            Err(Invalid::NoRoute) => "no route".to_owned(),
            Err(invalid) => invalid.to_string(),
        }
    }

    #[test]
    fn variable_routes_decode_and_encode_their_name() {
        let id: PaneId = "pane_2".parse().unwrap();
        let name = VarName::new("pi.session é/x?").unwrap();
        let encoded = "/panes/pane_2/vars/pi.session%20%C3%A9%2Fx%3F";
        for (method, route) in [
            (
                "PUT",
                Route::SetVar {
                    id,
                    name: name.clone(),
                },
            ),
            (
                "DELETE",
                Route::DeleteVar {
                    id,
                    name: name.clone(),
                },
            ),
        ] {
            assert_eq!(Route::of_request(method, encoded), Ok(route.clone()));
            assert_eq!(route.to_request(), (method, encoded.to_owned()));
        }
        assert_eq!(
            Route::of_request("GET", "/panes/pane_2/vars"),
            Err(Invalid::NoRoute)
        );
        assert_eq!(
            Route::of_request("GET", "/panes/pane_2/vars/a"),
            Err(Invalid::NoRoute)
        );
        assert_eq!(
            Route::of_request("POST", "/panes/pane_2/vars/a"),
            Err(Invalid::NoRoute)
        );
        assert_eq!(
            Route::of_request("POST", "/panes/pane_2/vars/%FF"),
            Err(Invalid::message("invalid variable name"))
        );
        assert_eq!(
            Route::of_request("PATCH", "/panes/pane_2/vars/%0A"),
            Err(Invalid::message("invalid variable name"))
        );
        for bad in [
            "/panes/pane_2/vars/",
            "/panes/pane_2/vars/%FF",
            "/panes/pane_2/vars/%0A",
            "/panes/pane_2/vars/%",
            &format!("/panes/pane_2/vars/{}", "n".repeat(257)),
        ] {
            assert_eq!(
                Route::of_request("PUT", bad),
                Err(Invalid::message("invalid variable name")),
                "{bad}"
            );
        }
        let longest = format!("/panes/pane_2/vars/{}", "n".repeat(256));
        assert!(matches!(
            Route::of_request("PUT", &longest),
            Ok(Route::SetVar { .. })
        ));
    }

    #[test]
    fn a_route_renders_a_request_that_parses_back_to_it() {
        let id = PaneId::new(7);
        for route in [
            Route::Version {},
            Route::ListPanes {},
            Route::GetLayout {},
            Route::PutLayout {},
            Route::GetPane { id },
            Route::ListRuntimes {},
            Route::GetRuntime {
                name: "dev".parse().unwrap(),
                session: None,
            },
            Route::WaitRuntime {
                name: "dev".parse().unwrap(),
                timeout_ms: WaitMs::clamped(250),
            },
            Route::DownRuntime {
                name: "dev".parse().unwrap(),
                session: None,
            },
            Route::DeleteRuntime {
                name: "dev".parse().unwrap(),
                session: None,
            },
            Route::Exec {
                name: "dev".parse().unwrap(),
                session: None,
            },
            Route::ClearHistory { id },
            Route::Client {},
            Route::DeletePane { id },
            Route::DeleteWindow {
                id: WindowId::new(2),
            },
            Route::DeleteSession {
                id: SessionId::new(3),
            },
            Route::DeleteVars { id },
            Route::Input { id },
            Route::Image {
                id,
                image: ImageId(7),
                frame: FrameNumber(2),
                generation: Generation(1 << 40),
            },
            Route::Search {
                id,
                needle: Needle("a b&c=é".to_owned()),
            },
            Route::Screen {
                id,
                format: ScreenFormat::Ansi,
                history: ScreenRows::Last(40),
            },
            Route::Screen {
                id,
                format: ScreenFormat::Plain,
                history: ScreenRows::Full,
            },
            Route::PromptResolve {
                from: id,
                window: None,
            },
            Route::PromptResolve {
                from: id,
                window: Some(WindowOnly),
            },
            Route::Messages { id },
            Route::PostMessage { id },
            Route::SendPrompt {},
            Route::View {
                id,
                history: History::All,
                images: Images::None,
                offset: Offset::new(9),
            },
            Route::View {
                id,
                history: History::None,
                images: Images::None,
                offset: None,
            },
        ] {
            let (method, target) = route.to_request();
            assert_eq!(Route::of_request(method, &target), Ok(route));
        }
    }

    #[test]
    fn a_default_is_not_rendered_and_a_missing_parameter_takes_it() {
        let wait = "/runtimes/dev/wait".to_owned();
        assert_eq!(
            Route::of_request("GET", &wait),
            Ok(Route::WaitRuntime {
                name: "dev".parse().unwrap(),
                timeout_ms: WaitMs::DEFAULT,
            })
        );
        assert_eq!(
            Route::WaitRuntime {
                name: "dev".parse().unwrap(),
                timeout_ms: WaitMs::DEFAULT
            }
            .to_request(),
            ("GET", wait)
        );
        assert_eq!(
            Route::View {
                id: PaneId::new(1),
                history: History::None,
                images: Images::None,
                offset: Offset::new(0),
            }
            .to_request(),
            ("GET", "/panes/pane_1/view?offset=0".to_owned())
        );
    }

    #[test]
    fn a_bad_target_names_what_is_wrong() {
        let wait = "/runtimes/dev/wait".to_owned();
        let table: Vec<String> = [
            ("GET", "/panes/pane_7/screen?history=4294967296"),
            ("GET", "/panes/pane_7/view?offset=4611686018427387904"),
            ("GET", "/panes/pane_7/view?images=all"),
            ("GET", "/panes/pane_7/view?a=b=c"),
            ("GET", "/panes/pane_7/images/0/frames/1?generation=1"),
            ("GET", "/panes/pane_7/images/1/frames/0?generation=1"),
            ("GET", "/panes/pane_7/images/1/frames/1?generation=0"),
            ("GET", "/panes/pane_7/images/1/frames/1"),
            ("GET", "/panes/pane_7/search?needle="),
            ("GET", "/panes/pane_7/search"),
            ("GET", "/panes/pane_7/view?"),
            ("GET", "/panes/pane_x/view"),
            ("PUT", "/panes"),
            ("POST", "/panes/pane_1/clear_history/x"),
            ("GET", "/panes?x=1"),
            ("GET", "/prompt/resolve?from=pane_1&window=1"),
            ("GET", "/version?a=1?b=2"),
            ("GET", &format!("{wait}?timeout_ms=3600001")),
            ("GET", &wait),
        ]
        .into_iter()
        .map(|(method, target)| parsed(method, target))
        .collect();
        assert_eq!(
            table,
            [
                "invalid number",
                "invalid number",
                "P1 supports images=none only",
                "invalid query",
                "invalid number",
                "invalid number",
                "invalid number",
                "missing parameter",
                "invalid needle",
                "missing parameter",
                "invalid query",
                "no route",
                "no route",
                "no route",
                "ListPanes",
                "invalid window",
                "invalid target",
                "invalid number",
                r#"WaitRuntime { name: RuntimeName("dev"), timeout_ms: WaitMs(30000) }"#,
            ]
        );
    }

    #[test]
    fn a_body_is_decoded_for_the_route_that_takes_one_and_refused_for_the_others() {
        let delete = Route::DeleteVars { id: PaneId::new(1) };
        assert_eq!(
            delete.clone().with_body(Some(br#"{"names":["a"]}"#)),
            Ok(Request::DeleteVars {
                id: PaneId::new(1),
                body: DeleteVars {
                    names: vec![VarName::new("a").unwrap()],
                    condition: None,
                },
            })
        );
        assert_eq!(
            delete.clone().with_body(Some(b"[[\"a\"],null]")),
            Err(Invalid::message("a record must be a JSON object"))
        );
        assert_eq!(
            delete.with_body(None),
            Err(Invalid::message("body exceeds 1 MiB"))
        );
        let set = Route::SetVar {
            id: PaneId::new(1),
            name: VarName::new("a").unwrap(),
        };
        assert_eq!(
            set.clone().with_body(Some(b"[1,{\"b\":2}]")),
            Ok(Request::SetVar {
                id: PaneId::new(1),
                name: VarName::new("a").unwrap(),
                body: VarValue(serde_json::json!([1, {"b": 2}])),
            })
        );
        assert_eq!(
            set.with_body(None),
            Err(Invalid::message("variable too large"))
        );
        assert_eq!(
            Route::GetLayout {}.with_body(Some(b"")),
            Ok(Request::GetLayout {})
        );
        for body in [Some(&b"{}"[..]), Some(b"not json"), None] {
            assert_eq!(
                Route::GetLayout {}.with_body(body),
                Err(Invalid::message("this route takes no body"))
            );
        }
    }

    #[test]
    fn every_catalog_entry_parses_back_from_its_example_request() {
        assert!(ROUTES.len() > 20);
        for info in ROUTES {
            let mut path = info.path.to_owned();
            for param in info.path_params {
                path = path.replace(&format!("{{{}}}", param.name), param.example);
            }
            let query: Vec<String> = info
                .query
                .iter()
                .map(|param| format!("{}={}", param.name, param.example))
                .collect();
            let target = if query.is_empty() {
                path
            } else {
                format!("{path}?{}", query.join("&"))
            };
            let route = Route::of_request(info.method.http(), &target)
                .unwrap_or_else(|invalid| panic!("{target}: {invalid}"));
            assert_eq!(route.name(), info.name, "{target}");
            let (method, again) = route.to_request();
            assert_eq!(Route::of_request(method, &again), Ok(route), "{again}");
        }
    }

    #[test]
    fn an_input_reply_decodes_as_a_paste_result_or_as_nothing() {
        let decode = |body: &str| crate::protocol::decode::<InputResult>(body.as_bytes()).unwrap();
        assert_eq!(decode("{}"), InputResult::Sent(Empty {}));
        assert_eq!(
            decode(r#"{"id":3,"pasted":true,"unsafe":false}"#),
            InputResult::Pasted(PasteResult {
                id: Some(3),
                pasted: true,
                unsafe_paste: false,
            })
        );
    }

    proptest! {
        #[test]
        fn routes_return_a_route_nothing_or_invalid(
            method in prop::sample::select(vec!["GET", "POST", "DELETE", "PUT", ""]),
            path in prop::sample::select(vec!["/version", "/panes", "/client", "/panes/pane_1", "/panes/pane_1/view", "/panes/pane_1/screen", "/panes/pane_1/input", "/panes/pane_1/vars", "/panes/pane_1/vars/a%20b", "/panes/pane_1/vars/%FF", "/panes/1/view", "/", ""]),
            query in prop::collection::vec((prop::sample::select(vec!["history", "images", "offset", "format", "x", ""]), prop::sample::select(vec!["", "a", "all", "none", "0", "-1", "99999999999999999999", "4294967296", "%00", "=", "&", "?", "/"])), 0..3),
            with_query in any::<bool>(),
        ) {
            let query: Vec<String> = query.into_iter().map(|(key, value)| format!("{key}={value}")).collect();
            let target = if with_query { format!("{path}?{}", query.join("&")) } else { path.to_owned() };
            if let Ok(route) = Route::of_request(method, &target) {
                let (method, target) = route.to_request();
                prop_assert_eq!(Route::of_request(method, &target), Ok(route));
            }
        }
    }
}
