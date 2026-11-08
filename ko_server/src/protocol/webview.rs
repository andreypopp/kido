use std::borrow::Cow;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Page {
    pub path: PagePath,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Webview {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page: Option<Page>,
    pub serving: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rest(String);

impl Rest {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Rest {
    type Error = &'static str;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.bytes().all(|byte| (0x21..=0x7e).contains(&byte)) {
            Ok(Self(value))
        } else {
            Err("invalid webview path")
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct PagePath(ko_pane_wire::frame::OwnedWebviewPath);

impl TryFrom<String> for PagePath {
    type Error = String;
    fn try_from(path: String) -> Result<Self, Self::Error> {
        ko_pane_wire::frame::OwnedWebviewPath::try_from(path).map(Self)
    }
}
impl From<PagePath> for String {
    fn from(path: PagePath) -> Self {
        path.0.into()
    }
}
impl From<ko_pane_wire::frame::WebviewPath<'_>> for PagePath {
    fn from(path: ko_pane_wire::frame::WebviewPath<'_>) -> Self {
        Self(path.into())
    }
}
impl JsonSchema for PagePath {
    fn schema_name() -> Cow<'static, str> {
        "WebviewPath".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type":"string","minLength":1,"maxLength":ko_pane_wire::frame::WEBVIEW_PATH_MAX_BYTES,"pattern":r"^/[\x20-\x7e]*$"})
    }
}

pub const MAX_IN_FLIGHT: usize = 16;

const MAX_ENCODED_DATA: usize = super::EXEC_CHUNK.div_ceil(3).saturating_mul(4);

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};

use super::{CloseCode, CloseReason};
use crate::protocol::Method;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Data(super::Text);

impl Data {
    pub fn new(bytes: Vec<u8>) -> Result<Self, &'static str> {
        if bytes.len() > super::EXEC_CHUNK {
            Err("webview data exceeds 64 KiB")
        } else {
            Ok(Self(super::Text(bytes)))
        }
    }
    pub fn empty() -> Self {
        Self(super::Text(Vec::new()))
    }
    pub fn bytes(&self) -> &[u8] {
        &self.0.0
    }
    pub fn into_bytes(self) -> Vec<u8> {
        self.0.0
    }
}

impl TryFrom<String> for Data {
    type Error = &'static str;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > MAX_ENCODED_DATA {
            return Err("webview data exceeds 64 KiB");
        }
        Self::new(super::Text::try_from(value)?.0)
    }
}

impl From<Data> for String {
    fn from(value: Data) -> Self {
        value.0.into()
    }
}

impl JsonSchema for Data {
    fn schema_name() -> Cow<'static, str> {
        "WebviewData".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"type":"string","contentEncoding":"base64","pattern":r"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$","maxLength":MAX_ENCODED_DATA})
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "Vec<(String, String)>", into = "Vec<(String, String)>")]
pub struct Headers(Vec<(String, String)>);

impl JsonSchema for Headers {
    fn schema_name() -> Cow<'static, str> {
        "WebviewHeaders".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type":"array",
            "items": {"type":"array","minItems":2,"maxItems":2,"prefixItems":[
                {"type":"string","minLength":1,"pattern":r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"},
                {"type":"string","pattern":r"^[^\u0000-\u0008\u000a-\u001f\u007f]*$"}
            ]}
        })
    }
}

impl TryFrom<Vec<(String, String)>> for Headers {
    type Error = &'static str;
    fn try_from(pairs: Vec<(String, String)>) -> Result<Self, Self::Error> {
        for (name, value) in &pairs {
            if name.is_empty()
                || !name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
                || !value
                    .bytes()
                    .all(|b| b == b'\t' || (b >= 0x20 && b != 0x7f))
            {
                return Err("invalid webview headers");
            }
        }
        Ok(Self(pairs))
    }
}

impl From<Headers> for Vec<(String, String)> {
    fn from(value: Headers) -> Self {
        value.0
    }
}

impl Headers {
    pub fn pairs(&self) -> &[(String, String)] {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u16", into = "u16")]
pub struct Status(u16);

impl TryFrom<u16> for Status {
    type Error = &'static str;
    fn try_from(code: u16) -> Result<Self, Self::Error> {
        if code == 101 || (200..=599).contains(&code) {
            Ok(Self(code))
        } else {
            Err("invalid webview response status")
        }
    }
}

impl From<Status> for u16 {
    fn from(value: Status) -> Self {
        value.0
    }
}

impl JsonSchema for Status {
    fn schema_name() -> Cow<'static, str> {
        "WebviewStatus".into()
    }
    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({"anyOf":[{"const":101,"type":"integer"},{"type":"integer","minimum":200,"maximum":599}]})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(from = "bool", into = "bool")]
#[schemars(with = "bool")]
pub enum FrameKind {
    Text,
    Binary,
}

impl FrameKind {
    pub fn into_message(
        self,
        bytes: Vec<u8>,
    ) -> Result<tungstenite::Message, std::string::FromUtf8Error> {
        match self {
            Self::Binary => Ok(tungstenite::Message::Binary(bytes.into())),
            Self::Text => {
                String::from_utf8(bytes).map(|text| tungstenite::Message::Text(text.into()))
            }
        }
    }
    pub(crate) fn from_message(
        message: tungstenite::Message,
    ) -> Result<(Self, Vec<u8>), tungstenite::Message> {
        match message {
            tungstenite::Message::Text(text) => {
                Ok((Self::Text, Vec::from(tungstenite::Bytes::from(text))))
            }
            tungstenite::Message::Binary(bytes) => Ok((Self::Binary, Vec::from(bytes))),
            other => Err(other),
        }
    }
}

impl From<bool> for FrameKind {
    fn from(binary: bool) -> Self {
        if binary { Self::Binary } else { Self::Text }
    }
}
impl From<FrameKind> for bool {
    fn from(kind: FrameKind) -> Self {
        matches!(kind, FrameKind::Binary)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServeOut {
    Supported {
        supported: bool,
    },
    Request {
        req: u64,
        method: Method,
        path: String,
        headers: Headers,
    },
    Body {
        req: u64,
        data: Data,
        more: bool,
    },
    Cancel {
        req: u64,
    },
    Upgrade {
        req: u64,
        path: String,
        headers: Headers,
    },
    Frame {
        req: u64,
        data: Data,
        #[schemars(with = "bool")]
        binary: FrameKind,
    },
    Close {
        req: u64,
        code: CloseCode,
        reason: CloseReason,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServeIn {
    Response {
        req: u64,
        status: Status,
        headers: Headers,
    },
    Body {
        req: u64,
        data: Data,
        more: bool,
    },
    Frame {
        req: u64,
        data: super::Text,
        #[schemars(with = "bool")]
        binary: FrameKind,
    },
    Close {
        req: u64,
        code: CloseCode,
        reason: CloseReason,
    },
}
