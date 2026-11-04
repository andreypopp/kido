use std::borrow::Cow;
use std::fmt;
use std::io;
use std::str::FromStr;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidId(String);

impl fmt::Display for InvalidId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid id {:?}", self.0)
    }
}

fn parse(prefix: &str, text: &str) -> Result<u64, InvalidId> {
    text.strip_prefix(prefix)
        .filter(|digits| {
            digits.bytes().all(|byte| byte.is_ascii_digit())
                && (digits.len() == 1 || !digits.starts_with('0'))
        })
        .and_then(|digits| digits.parse().ok())
        .ok_or_else(|| InvalidId(text.to_owned()))
}

macro_rules! id {
    ($vis:vis $name:ident, $prefix:literal) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        $vis struct $name(u64);

        impl $name {
            pub(crate) fn new(number: u64) -> $name {
                $name(number)
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                json_schema!({"type": "string", "pattern": concat!("^", $prefix, "(0|[1-9][0-9]*)$")})
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, concat!($prefix, "{}"), self.0)
            }
        }

        impl FromStr for $name {
            type Err = InvalidId;

            fn from_str(text: &str) -> Result<$name, InvalidId> {
                parse($prefix, text).map($name)
            }
        }

        impl TryFrom<String> for $name {
            type Error = InvalidId;

            fn try_from(text: String) -> Result<$name, InvalidId> {
                text.parse()
            }
        }

        impl From<$name> for String {
            fn from(id: $name) -> String {
                id.to_string()
            }
        }
    };
}

id!(pub PaneId, "pane_");
id!(pub ClientId, "client_");
id!(pub SessionId, "session_");
id!(pub WindowId, "window_");

fn hex32(text: String) -> Result<String, InvalidId> {
    if text.len() == 32
        && text
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    {
        Ok(text)
    } else {
        Err(InvalidId(text))
    }
}

macro_rules! hex_id {
    ($vis:vis $name:ident) => {
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        $vis struct $name(String);

        impl $name {
            pub(crate) fn mint() -> io::Result<$name> {
                ko_sys::entropy::hex(16).map($name)
            }
        }

        impl TryFrom<String> for $name {
            type Error = InvalidId;

            fn try_from(text: String) -> Result<$name, InvalidId> {
                hex32(text).map($name)
            }
        }

        impl FromStr for $name {
            type Err = InvalidId;

            fn from_str(text: &str) -> Result<$name, InvalidId> {
                $name::try_from(text.to_owned())
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                json_schema!({"type": "string", "pattern": "^[0-9a-f]{32}$"})
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<$name> for String {
            fn from(id: $name) -> String {
                id.0
            }
        }
    };
}

hex_id!(pub Instance);
hex_id!(pub RunId);
hex_id!(pub PaneToken);

impl PaneToken {
    pub(crate) fn matches(&self, other: &PaneToken) -> bool {
        let (ours, theirs) = (self.0.as_bytes(), other.0.as_bytes());
        ours.len() == theirs.len()
            && ours
                .iter()
                .zip(theirs)
                .fold(0u8, |difference, (a, b)| difference | (a ^ b))
                == 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct MessageId(String);

impl MessageId {
    pub fn mint() -> io::Result<MessageId> {
        let text = ko_pane_wire::base64::encode(&ko_sys::entropy::bytes()?);
        Ok(MessageId(
            text.trim_end_matches('=')
                .replace('+', "-")
                .replace('/', "_"),
        ))
    }

    pub(crate) fn ended(pane: PaneId) -> MessageId {
        MessageId(format!("ended-{pane}"))
    }
}

impl JsonSchema for MessageId {
    fn schema_name() -> Cow<'static, str> {
        "MessageId".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "pattern": "^[A-Za-z0-9_-]{8,64}$",
            "description": "The sender's id of a message: 8 to 64 characters of A-Z, a-z, 0-9, _ and -."
        })
    }
}

impl TryFrom<String> for MessageId {
    type Error = &'static str;

    fn try_from(text: String) -> Result<MessageId, &'static str> {
        let plain = text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'));
        if plain && (8..=64).contains(&text.len()) {
            Ok(MessageId(text))
        } else {
            Err("invalid message id")
        }
    }
}

impl From<MessageId> for String {
    fn from(MessageId(text): MessageId) -> String {
        text
    }
}

const MAX_NAME: usize = 256;

fn plain(text: &str) -> bool {
    text.len() <= MAX_NAME && !text.chars().any(char::is_control)
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Name(String);

impl JsonSchema for Name {
    fn schema_name() -> Cow<'static, str> {
        "Name".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "maxLength": MAX_NAME,
            "description": format!("At most {MAX_NAME} bytes, without control characters.")
        })
    }
}

impl TryFrom<String> for Name {
    type Error = &'static str;

    fn try_from(text: String) -> Result<Name, &'static str> {
        if plain(&text) {
            Ok(Name(text))
        } else {
            Err("invalid name")
        }
    }
}

impl From<Name> for String {
    fn from(Name(text): Name) -> String {
        text
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct VarName(Cow<'static, str>);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidName;

impl fmt::Display for InvalidName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid variable name")
    }
}

impl VarName {
    pub fn new(name: &str) -> Result<VarName, InvalidName> {
        if !name.is_empty() && plain(name) {
            Ok(VarName(Cow::Owned(name.to_owned())))
        } else {
            Err(InvalidName)
        }
    }

    pub const fn known(name: &'static str) -> VarName {
        VarName(Cow::Borrowed(name))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl JsonSchema for VarName {
    fn schema_name() -> Cow<'static, str> {
        "VarName".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "minLength": 1,
            "maxLength": MAX_NAME,
            "description": format!("One to {MAX_NAME} bytes, without control characters.")
        })
    }
}

impl TryFrom<String> for VarName {
    type Error = InvalidName;

    fn try_from(name: String) -> Result<VarName, InvalidName> {
        VarName::new(&name)
    }
}

impl From<VarName> for String {
    fn from(name: VarName) -> String {
        name.0.into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_one_to_256_bytes_without_control_characters() {
        assert!(VarName::new("").is_err());
        assert!(VarName::new(&"n".repeat(256)).is_ok());
        assert!(VarName::new(&"n".repeat(257)).is_err());
        assert!(VarName::new("a\nb").is_err());
        assert!(VarName::new("pi.session é").is_ok());
        assert!(VarName::new(&"é".repeat(129)).is_err());
    }

    #[test]
    fn a_message_id_is_8_to_64_url_safe_characters() {
        let parse = |text: &str| MessageId::try_from(text.to_owned());
        assert!(parse("abcdefgh").is_ok());
        assert!(parse(&"A-_9".repeat(16)).is_ok());
        for bad in [
            "",
            "abcdefg",
            "abcdefgh+",
            "abcdefg=",
            "abcdefgé",
            &"a".repeat(65),
        ] {
            assert_eq!(parse(bad), Err("invalid message id"), "{bad}");
        }
        let minted = MessageId::mint().unwrap();
        assert_eq!(String::from(minted.clone()).len(), 22);
        assert_eq!(parse(&String::from(minted.clone())), Ok(minted));
        assert_eq!(
            String::from(MessageId::ended(PaneId::new(3))),
            "ended-pane_3"
        );
        assert!(parse(&String::from(MessageId::ended(PaneId::new(0)))).is_ok());
    }

    #[test]
    fn an_id_round_trips_and_only_its_canonical_form_parses() {
        assert_eq!(PaneId::new(7).to_string(), "pane_7");
        assert_eq!("pane_7".parse(), Ok(PaneId::new(7)));
        assert_eq!("client_0".parse(), Ok(ClientId::new(0)));
        for text in [
            "pane_",
            "pane_x",
            "pane_07",
            "pane_-1",
            "client_1",
            "pane_99999999999999999999",
        ] {
            assert_eq!(
                text.parse::<PaneId>().unwrap_err().to_string(),
                format!("invalid id {text:?}")
            );
        }
    }

    #[test]
    fn a_token_matches_only_itself() {
        let (one, other) = (PaneToken::mint().unwrap(), PaneToken::mint().unwrap());
        assert!(one.matches(&one.clone()));
        assert!(!one.matches(&other));
        let near = PaneToken::try_from("0123456789abcdef0123456789abcdef".to_owned()).unwrap();
        let far = PaneToken::try_from("0123456789abcdef0123456789abcdee".to_owned()).unwrap();
        assert!(!near.matches(&far));
    }

    #[test]
    fn an_instance_is_32_lowercase_hex_digits() {
        let minted = Instance::mint().unwrap();
        assert_eq!(Instance::try_from(String::from(minted.clone())), Ok(minted));
        for text in [
            "",
            "0123456789abcdef0123456789abcde",
            "0123456789abcdef0123456789abcdef0",
            "0123456789ABCDEF0123456789abcdef",
            "0123456789abcdef0123456789abcdeg",
        ] {
            assert_eq!(
                Instance::try_from(text.to_owned()).unwrap_err().to_string(),
                format!("invalid id {text:?}")
            );
        }
    }
}
