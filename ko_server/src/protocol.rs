use std::fmt;
use std::num::{NonZeroU16, NonZeroUsize};

use ko_pane_wire::frame::{
    self, CellPx, Dim, History, KeyAction, KeyCode, MouseAction, MouseButton, ScreenFormat,
    ScreenRows,
};
use ko_pane_wire::ring;
use ko_sys::pid::Exit;
use serde::de::{self, DeserializeOwned, DeserializeSeed, Visitor};
use serde::{Deserialize, Deserializer, Serialize};

use crate::config::BUILD;
use crate::http::Status;
use crate::ids::{ClientId, PaneId};
use crate::pane_proc::{self, Death};

const PROTOCOL: &str = "1.0";
const PROTOCOL_MAJOR: &str = "1";
const VT: &str = env!("KO_VT");
const MAX_OFFSET: u64 = (1 << 62) - 1;

macro_rules! compact {
    (
        $(#[$meta:meta])*
        $vis:vis enum $name:ident {
            units { $($unit:ident = $unit_tag:literal),* $(,)? }
            payloads { $($variant:ident($payload:ty) = $tag:literal),* $(,)? }
        }
    ) => {
        $(#[$meta])*
        $vis enum $name {
            $($unit,)*
            $($variant($payload),)*
        }

        impl Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                use serde::ser::SerializeTuple;
                match self {
                    $($name::$unit => serializer.serialize_str($unit_tag),)*
                    $($name::$variant(payload) => {
                        let mut tuple = serializer.serialize_tuple(2)?;
                        tuple.serialize_element($tag)?;
                        tuple.serialize_element(payload)?;
                        tuple.end()
                    })*
                }
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<$name, D::Error> {
                struct Visitor;

                impl<'de> serde::de::Visitor<'de> for Visitor {
                    type Value = $name;

                    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                        f.write_str(concat!("a compact ", stringify!($name)))
                    }

                    fn visit_str<E: serde::de::Error>(self, tag: &str) -> Result<$name, E> {
                        match tag {
                            $($unit_tag => Ok($name::$unit),)*
                            _ => Err(E::unknown_variant(tag, &[$($unit_tag),*])),
                        }
                    }

                    fn visit_seq<A: serde::de::SeqAccess<'de>>(
                        self,
                        mut seq: A,
                    ) -> Result<$name, A::Error> {
                        use serde::de::Error;
                        let tag: String = seq
                            .next_element()?
                            .ok_or_else(|| A::Error::invalid_length(0, &self))?;
                        let value = match tag.as_str() {
                            $($tag => $name::$variant(
                                seq.next_element()?
                                    .ok_or_else(|| A::Error::invalid_length(1, &self))?,
                            ),)*
                            _ => return Err(A::Error::unknown_variant(&tag, &[$($tag),*])),
                        };
                        match seq.next_element::<serde::de::IgnoredAny>()? {
                            None => Ok(value),
                            Some(_) => Err(A::Error::invalid_length(3, &self)),
                        }
                    }
                }

                deserializer.deserialize_any(Visitor)
            }
        }
    };
}

pub const PROTOCOL_HEADER: &str = "ko-protocol";
pub const VT_HEADER: &str = "ko-vt";

pub fn version_headers() -> [(&'static str, String); 2] {
    [
        (PROTOCOL_HEADER, PROTOCOL.to_owned()),
        (VT_HEADER, VT.to_owned()),
    ]
}

struct Objects<D>(D);
struct Wrap<V>(V);
struct Seed<S>(S);

macro_rules! forward {
    ($($method:ident),*) => {
        $(fn $method<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, D::Error> {
            self.0.$method(Wrap(visitor))
        })*
    };
}

impl<'de, D: Deserializer<'de>> Deserializer<'de> for Objects<D> {
    type Error = D::Error;

    forward!(
        deserialize_any,
        deserialize_bool,
        deserialize_i8,
        deserialize_i16,
        deserialize_i32,
        deserialize_i64,
        deserialize_i128,
        deserialize_u8,
        deserialize_u16,
        deserialize_u32,
        deserialize_u64,
        deserialize_u128,
        deserialize_f32,
        deserialize_f64,
        deserialize_char,
        deserialize_str,
        deserialize_string,
        deserialize_bytes,
        deserialize_byte_buf,
        deserialize_option,
        deserialize_unit,
        deserialize_seq,
        deserialize_map,
        deserialize_identifier,
        deserialize_ignored_any
    );

    fn deserialize_unit_struct<V: Visitor<'de>>(
        self,
        name: &'static str,
        visitor: V,
    ) -> Result<V::Value, D::Error> {
        self.0.deserialize_unit_struct(name, Wrap(visitor))
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        name: &'static str,
        visitor: V,
    ) -> Result<V::Value, D::Error> {
        self.0.deserialize_newtype_struct(name, Wrap(visitor))
    }

    fn deserialize_tuple<V: Visitor<'de>>(
        self,
        len: usize,
        visitor: V,
    ) -> Result<V::Value, D::Error> {
        self.0.deserialize_tuple(len, Wrap(visitor))
    }

    fn deserialize_tuple_struct<V: Visitor<'de>>(
        self,
        name: &'static str,
        len: usize,
        visitor: V,
    ) -> Result<V::Value, D::Error> {
        self.0.deserialize_tuple_struct(name, len, Wrap(visitor))
    }

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _: &'static str,
        _: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, D::Error> {
        self.0.deserialize_map(Wrap(visitor))
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        name: &'static str,
        variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, D::Error> {
        self.0.deserialize_enum(name, variants, Wrap(visitor))
    }
}

macro_rules! pass {
    ($($method:ident($type:ty)),*) => {
        $(fn $method<E: de::Error>(self, value: $type) -> Result<V::Value, E> {
            self.0.$method(value)
        })*
    };
}

impl<'de, V: Visitor<'de>> Visitor<'de> for Wrap<V> {
    type Value = V::Value;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.expecting(f)
    }

    pass!(
        visit_bool(bool),
        visit_i64(i64),
        visit_i128(i128),
        visit_u64(u64),
        visit_u128(u128),
        visit_f64(f64),
        visit_str(&str),
        visit_borrowed_str(&'de str),
        visit_string(String),
        visit_bytes(&[u8]),
        visit_borrowed_bytes(&'de [u8]),
        visit_byte_buf(Vec<u8>)
    );

    fn visit_none<E: de::Error>(self) -> Result<V::Value, E> {
        self.0.visit_none()
    }

    fn visit_unit<E: de::Error>(self) -> Result<V::Value, E> {
        self.0.visit_unit()
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<V::Value, D::Error> {
        self.0.visit_some(Objects(deserializer))
    }

    fn visit_newtype_struct<D: Deserializer<'de>>(
        self,
        deserializer: D,
    ) -> Result<V::Value, D::Error> {
        self.0.visit_newtype_struct(Objects(deserializer))
    }

    fn visit_seq<A: de::SeqAccess<'de>>(self, seq: A) -> Result<V::Value, A::Error> {
        self.0.visit_seq(Wrap(seq))
    }

    fn visit_map<A: de::MapAccess<'de>>(self, map: A) -> Result<V::Value, A::Error> {
        self.0.visit_map(Wrap(map))
    }

    fn visit_enum<A: de::EnumAccess<'de>>(self, data: A) -> Result<V::Value, A::Error> {
        self.0.visit_enum(data)
    }
}

impl<'de, A: de::SeqAccess<'de>> de::SeqAccess<'de> for Wrap<A> {
    type Error = A::Error;

    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, A::Error> {
        self.0.next_element_seed(Seed(seed))
    }

    fn size_hint(&self) -> Option<usize> {
        self.0.size_hint()
    }
}

impl<'de, A: de::MapAccess<'de>> de::MapAccess<'de> for Wrap<A> {
    type Error = A::Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, A::Error> {
        self.0.next_key_seed(seed)
    }

    fn next_value_seed<T: DeserializeSeed<'de>>(&mut self, seed: T) -> Result<T::Value, A::Error> {
        self.0.next_value_seed(Seed(seed))
    }
}

impl<'de, S: DeserializeSeed<'de>> DeserializeSeed<'de> for Seed<S> {
    type Value = S::Value;

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<S::Value, D::Error> {
        self.0.deserialize(Objects(deserializer))
    }
}

pub(crate) fn decode<T: DeserializeOwned>(text: &[u8]) -> serde_json::Result<T> {
    let mut deserializer = serde_json::Deserializer::from_slice(text);
    let value = T::deserialize(Objects(&mut deserializer))?;
    deserializer.end()?;
    Ok(value)
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

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum ErrorKind {
        units {
            Invalid = "invalid",
            Refused = "refused",
            Gone = "gone",
            Io = "io",
            Missing = "not_found",
        }
        payloads {
            ProtocolMismatch(Version) = "protocol_mismatch",
            VtMismatch(Version) = "vt_mismatch",
        }
    }
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
pub(crate) struct Size(pub(crate) frame::Size);

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

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Cause {
        units {}
        payloads {
            Exited(i32) = "exited",
            Signaled(i32) = "signaled",
            Failed(String) = "failed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Dead {
    pub(crate) at: u64,
    pub(crate) cause: Cause,
}

impl From<Exit> for Cause {
    fn from(exit: Exit) -> Cause {
        match exit {
            Exit::Exited(code) => Cause::Exited(code),
            Exit::Signaled(signal) => Cause::Signaled(signal),
        }
    }
}

impl From<&Death> for Dead {
    fn from(death: &Death) -> Dead {
        Dead {
            at: death.at.nanos(),
            cause: match &death.cause {
                pane_proc::Cause::Exit(exit) => Cause::from(*exit),
                pane_proc::Cause::Failed(message) => Cause::Failed(message.clone()),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Row {
    pub(crate) id: PaneId,
    pub(crate) pid: i32,
    pub(crate) command: Vec<String>,
    pub(crate) cwd: String,
    pub(crate) title: String,
    pub(crate) dead: Option<Dead>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Created {
    pub(crate) pane: PaneId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PasteResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) id: Option<u64>,
    pub(crate) pasted: bool,
    #[serde(rename = "unsafe")]
    pub(crate) unsafe_paste: bool,
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
pub(crate) struct Key(pub(crate) frame::Key);

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
pub(crate) struct Mouse(#[serde(with = "MouseDef")] pub(crate) frame::Mouse);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Paste {
    pub(crate) text: String,
    pub(crate) check_safe: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) id: Option<u64>,
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
pub(crate) struct Text(pub(crate) Vec<u8>);

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

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Input {
        units {}
        payloads {
            Key(Key) = "key",
            Mouse(Mouse) = "mouse",
            Paste(Paste) = "paste",
            Text(Text) = "text",
            Focus(bool) = "focus",
        }
    }
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
            Input::Text(text) => pane_proc::Input::Text(&text.0),
            Input::Focus(focused) => pane_proc::Input::Focus(*focused),
        }
    }
}

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Command {
        units {}
        payloads {
            Argv(Vec<String>) = "argv",
            Shell(String) = "shell",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Variable {
    pub(crate) name: String,
    pub(crate) value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct CreatePane {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) command: Option<Command>,
    #[serde(default)]
    pub(crate) env: Vec<Variable>,
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

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum Marker {
        units {}
        payloads {
            Resize(Size) = "resize",
            Dead(Dead) = "dead",
        }
    }
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
pub(crate) enum ClientKind {
    Terminal,
    App,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Hello {
    pub(crate) kind: ClientKind,
    pub(crate) name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) pane: Option<PaneId>,
    pub(crate) focused: bool,
    pub(crate) size: Size,
    #[serde(default)]
    pub(crate) ignore_size: bool,
}

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum ClientRequest {
        units {}
        payloads {
            Hello(Hello) = "hello",
            Select(PaneId) = "select",
            Size(Size) = "size",
            Focused(bool) = "focused",
        }
    }
}

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum ViewRequest {
        units {}
        payloads {
            Resync(ViewOptions) = "resync",
            Input(Input) = "input",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Bounds {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_bytes: Option<NonZeroUsize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_lines: Option<NonZeroUsize>,
}

compact! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Scrollback {
        units { Disabled = "disabled" }
        payloads { Scrollback(Bounds) = "scrollback" }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Terminal {
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
pub(crate) struct Limits {
    pub(crate) terminal: Terminal,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Welcome {
    pub(crate) client: ClientId,
    pub(crate) limits: Limits,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Title {
    pub(crate) pane: PaneId,
    pub(crate) title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Pwd {
    pub(crate) pane: PaneId,
    pub(crate) pwd: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PaneDead {
    pub(crate) pane: PaneId,
    pub(crate) dead: Dead,
}

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum ClientEvent {
        units {}
        payloads {
            Welcome(Welcome) = "welcome",
            Topology(Vec<Row>) = "topology",
            Title(Title) = "title",
            Pwd(Pwd) = "pwd",
            Dead(PaneDead) = "dead",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Marked {
    pub(crate) offset: u64,
    pub(crate) marker: Marker,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Skipped {
    pub(crate) offset: u64,
    pub(crate) from: u64,
    pub(crate) to: u64,
}

compact! {
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) enum ViewEvent {
        units {}
        payloads {
            Marked(Marked) = "marked",
            Skipped(Skipped) = "skipped",
            Pasted(PasteResult) = "pasted",
        }
    }
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

    fn same<T: Serialize + DeserializeOwned>(json: &str) {
        let value: T = decode(json.as_bytes()).unwrap_or_else(|error| panic!("{json}: {error}"));
        assert_eq!(super::json(&value), json);
    }

    #[test]
    fn every_wire_type_round_trips_the_json_of_the_ocaml_codecs() {
        same::<Version>(
            r#"{"protocol":"1.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty"}"#,
        );
        for json in [
            r#"{"kind":"invalid","message":"m"}"#,
            r#"{"kind":"refused","message":"m"}"#,
            r#"{"kind":"gone","message":"m"}"#,
            r#"{"kind":"io","message":"m"}"#,
            r#"{"kind":"not_found","message":"m"}"#,
            r#"{"kind":["protocol_mismatch",{"protocol":"1.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty"}],"message":"m"}"#,
            r#"{"kind":["vt_mismatch",{"protocol":"1.0","vt":"0123456789abcdef0123456789abcdef01234567","build":"abc-dirty"}],"message":"m"}"#,
        ] {
            same::<Error>(json);
        }
        for json in [
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":null}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":["exited",7]}}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":["signaled",9]}}"#,
            r#"{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":["failed","boom"]}}"#,
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
            r#"["hello",{"kind":"terminal","name":"test","focused":true,"size":{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}},"ignore_size":false}]"#,
            r#"["hello",{"kind":"app","name":"app","pane":"pane_3","focused":false,"size":{"cols":4096,"rows":1},"ignore_size":true}]"#,
            r#"["select","pane_3"]"#,
            r#"["size",{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}}]"#,
            r#"["focused",true]"#,
        ] {
            same::<ClientRequest>(json);
        }
        for json in [
            r#"{"env":[]}"#,
            r#"{"cwd":"/tmp","command":["argv",["/bin/sh","-c","x"]],"env":[{"name":"X","value":"y"}]}"#,
            r#"{"command":["shell","exec cat"],"env":[]}"#,
        ] {
            same::<CreatePane>(json);
        }
        for json in [
            r#"["resync",{"history":"all","images":"none"}]"#,
            r#"["resync",{"history":"none","images":"none"}]"#,
            r#"["input",["key",{"action":"press","key":20,"mods":2,"unshifted_codepoint":97,"text":"a","composing":false}]]"#,
            r#"["input",["key",{"action":"release","key":58,"mods":0,"unshifted_codepoint":0,"text":"","composing":true}]]"#,
            r#"["input",["key",{"action":"repeat","key":1,"mods":0,"unshifted_codepoint":0,"text":"","composing":false}]]"#,
            r#"["input",["mouse",{"action":"press","button":"left","col":3,"row":4,"mods":1}]]"#,
            r#"["input",["mouse",{"action":"motion","button":"eleven","col":0,"row":0,"mods":0}]]"#,
            r#"["input",["mouse",{"action":"release","button":"unknown","col":0,"row":0,"mods":0}]]"#,
            r#"["input",["paste",{"text":"hello\n","check_safe":false,"id":23}]]"#,
            r#"["input",["paste",{"text":"x","check_safe":true}]]"#,
            r#"["input",["text","aGk="]]"#,
            r#"["input",["focus",false]]"#,
        ] {
            same::<ViewRequest>(json);
        }
        for json in [
            r#"["welcome",{"client":"client_2","limits":{"terminal":{"scrollback":["scrollback",{"max_bytes":50000000}],"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]}}]"#,
            r#"["welcome",{"client":"client_2","limits":{"terminal":{"scrollback":"disabled","apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":["file","temp_file","shared_mem"]}}]"#,
            r#"["welcome",{"client":"client_2","limits":{"terminal":{"scrollback":["scrollback",{"max_bytes":83886080,"max_lines":5000}],"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]}}]"#,
            r#"["welcome",{"client":"client_2","limits":{"terminal":{"scrollback":["scrollback",{}],"apc_max_bytes":68157440,"kitty_images_max_bytes":10000000,"continuation_max_bytes":68157440},"media":[]}}]"#,
            r#"["topology",[{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":null},{"id":"pane_3","pid":4242,"command":["/bin/sh","-c","echo \"hi\"\n"],"cwd":"/tmp","title":"t\u0001é","dead":{"at":123456789012345,"cause":["exited",0]}}]]"#,
            r#"["topology",[]]"#,
            r#"["title",{"pane":"pane_3","title":"x"}]"#,
            r#"["pwd",{"pane":"pane_3","pwd":"file://h/tmp"}]"#,
            r#"["dead",{"pane":"pane_3","dead":{"at":123456789012345,"cause":["signaled",15]}}]"#,
        ] {
            same::<ClientEvent>(json);
        }
        for json in [
            r#"["marked",{"offset":99,"marker":["resize",{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}}]}]"#,
            r#"["marked",{"offset":5,"marker":["resize",{"cols":4096,"rows":1}]}]"#,
            r#"["marked",{"offset":7,"marker":["dead",{"at":123456789012345,"cause":["exited",7]}]}]"#,
            r#"["skipped",{"offset":100000,"from":10,"to":100000}]"#,
            r#"["pasted",{"id":77,"pasted":true,"unsafe":false}]"#,
        ] {
            same::<ViewEvent>(json);
        }
    }

    fn decoded<T: Serialize + DeserializeOwned>(json: &str) -> Result<String, String> {
        decode::<T>(json.as_bytes())
            .map(|value| super::json(&value))
            .map_err(|error| error.to_string())
    }

    #[test]
    fn decoders_take_defaults_and_nulls_and_refuse_what_the_ocaml_codecs_refuse() {
        let hello = r#"["hello",{"kind":"terminal","name":"x","focused":true,"size":{"cols":1,"rows":1},"ignore_size":false}]"#;
        assert_eq!(
            decoded::<ClientRequest>(
                r#"["hello",{"kind":"terminal","name":"x","focused":true,"size":{"cols":1,"rows":1},"extra":1}]"#
            ),
            Ok(hello.to_owned())
        );
        assert_eq!(
            decoded::<ClientRequest>(
                r#"["hello",{"kind":"terminal","name":"x","focused":true,"size":{"cols":1,"rows":1,"cell_px":null},"pane":null}]"#
            ),
            Ok(hello.to_owned())
        );
        for refused in [
            r#"["select","pane_1","x"]"#,
            r#"["focused"]"#,
            r#""focused""#,
            r#"["nope",1]"#,
        ] {
            assert!(decoded::<ClientRequest>(refused).is_err(), "{refused}");
        }
        assert_eq!(
            decoded::<CreatePane>(r#"{"cwd":null,"command":null}"#),
            Ok(r#"{"env":[]}"#.to_owned())
        );
        assert_eq!(
            decoded::<ViewRequest>(r#"["resync",{}]"#),
            Ok(r#"["resync",{"history":"none","images":"none"}]"#.to_owned())
        );
        assert_eq!(
            decoded::<ViewRequest>(
                r#"["input",["paste",{"text":"x","check_safe":true,"id":null}]]"#
            ),
            Ok(r#"["input",["paste",{"text":"x","check_safe":true}]]"#.to_owned())
        );
    }

    #[test]
    fn input_is_checked_where_it_is_decoded() {
        let key = |key: i64, codepoint: i64| {
            format!(
                r#"["key",{{"action":"press","key":{key},"mods":0,"unshifted_codepoint":{codepoint},"text":"","composing":false}}]"#
            )
        };
        let refused: Vec<bool> = [
            key(-1, 0),
            key(176, 0),
            key(175, 0x10ffff),
            key(1, 0x110000),
            key(1, 0xd800),
            r#"["mouse",{"action":"press","button":"left","col":70000,"row":0,"mods":0}]"#
                .to_owned(),
            r#"["text","aGk"]"#.to_owned(),
            r#"["text","a=Gk"]"#.to_owned(),
        ]
        .iter()
        .map(|json| decoded::<Input>(json).is_err())
        .collect();
        assert_eq!(refused, [true, true, false, true, true, true, true, true]);
        for (text, bytes) in [("", ""), ("aGk=", "hi"), ("aGk/", "hi?"), ("aA==", "h")] {
            let json = format!(r#"["text","{text}"]"#);
            assert_eq!(
                serde_json::from_str::<Input>(&json).unwrap(),
                Input::Text(Text(bytes.as_bytes().to_vec()))
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
            (Some("1.0"), Some(VT)),
            (Some("1.7"), Some(VT)),
            (Some("2.0"), Some(VT)),
            (Some("1."), Some(VT)),
            (None, Some(VT)),
            (Some("1.0"), Some("wrong")),
            (Some("1.0"), None),
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
    fn a_record_is_an_object_at_every_level_and_a_compact_variant_stays_an_array() {
        let refused: Vec<bool> = [
            decoded::<CreatePane>(r#"[]"#),
            decoded::<CreatePane>(r#"["/tmp"]"#),
            decoded::<CreatePane>(r#"{"env":[["A","b"]]}"#),
            decoded::<ClientRequest>(r#"["hello",["terminal","t",null,true,{"cols":1,"rows":1},false]]"#),
            decoded::<ClientRequest>(r#"["size",[80,24]]"#),
            decoded::<ClientRequest>(r#"["size",{"cols":80,"rows":24,"cell_px":[8,16]}]"#),
            decoded::<ViewRequest>(r#"["input",["key",["press",20,0,97,"a",false]]]"#),
            decoded::<ViewRequest>(r#"["input",["paste",["x",true]]]"#),
            decoded::<ViewRequest>(r#"["resync",["all","none"]]"#),
            decoded::<CreatePane>(r#"{"command":["argv",["/bin/sh"]],"env":[{"name":"A","value":"b"}]}"#),
            decoded::<ClientRequest>(r#"["size",{"cols":80,"rows":24,"cell_px":{"width":8,"height":16}}]"#),
            decoded::<ViewRequest>(r#"["input",["mouse",{"action":"press","button":"left","col":1,"row":2,"mods":0}]]"#),
        ]
        .iter()
        .map(Result::is_err)
        .collect();
        assert_eq!(
            refused,
            [
                true, true, true, true, true, true, true, true, true, false, false, false
            ]
        );
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
