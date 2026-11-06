use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use std::str::FromStr;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::de::value::MapAccessDeserializer;
use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};

use crate::ssh_args;

const MAX_RUNTIME_NAME: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RuntimeName(String);

impl RuntimeName {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl JsonSchema for RuntimeName {
    fn schema_name() -> Cow<'static, str> {
        "RuntimeName".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "pattern": "^[a-z0-9-]{1,32}$",
            "description": "One to 32 bytes of a to z, 0 to 9 and -. host is not a runtime name."
        })
    }
}

impl TryFrom<String> for RuntimeName {
    type Error = &'static str;

    fn try_from(text: String) -> Result<RuntimeName, &'static str> {
        let valid = (1..=MAX_RUNTIME_NAME).contains(&text.len())
            && text
                .bytes()
                .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'-'))
            && text != "host";
        if valid {
            Ok(RuntimeName(text))
        } else {
            Err("invalid runtime name")
        }
    }
}

impl FromStr for RuntimeName {
    type Err = &'static str;

    fn from_str(text: &str) -> Result<RuntimeName, &'static str> {
        RuntimeName::try_from(text.to_owned())
    }
}

impl fmt::Display for RuntimeName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<RuntimeName> for String {
    fn from(RuntimeName(text): RuntimeName) -> String {
        text
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeTag {
    name: RuntimeName,
    session: Option<u64>,
}

impl RuntimeTag {
    pub fn new(name: RuntimeName, session: Option<u64>) -> Self {
        Self { name, session }
    }
}

impl FromStr for RuntimeTag {
    type Err = &'static str;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let (name, session) = match text.strip_prefix("session_") {
            None => (text, None),
            Some(rest) => {
                let (digits, name) = rest.split_once('-').ok_or("invalid runtime tag")?;
                let valid = !digits.is_empty()
                    && digits.bytes().all(|byte| byte.is_ascii_digit())
                    && (digits.len() == 1 || !digits.starts_with('0'));
                if !valid {
                    return Err("invalid runtime tag");
                }
                (
                    name,
                    Some(digits.parse().map_err(|_| "invalid runtime tag")?),
                )
            }
        };
        Ok(Self::new(
            name.parse().map_err(|_| "invalid runtime tag")?,
            session,
        ))
    }
}

impl fmt::Display for RuntimeTag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(id) = self.session {
            write!(f, "session_{id}-")?;
        }
        self.name.fmt(f)
    }
}

struct WordOrMap<T, M> {
    expecting: &'static str,
    word: fn(&str) -> Option<T>,
    map: fn(M) -> T,
}

impl<'de, T, M: Deserialize<'de>> Visitor<'de> for WordOrMap<T, M> {
    type Value = T;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.expecting)
    }

    fn visit_str<E: de::Error>(self, text: &str) -> Result<T, E> {
        (self.word)(text).ok_or_else(|| E::invalid_value(de::Unexpected::Str(text), &self))
    }

    fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<T, A::Error> {
        M::deserialize(MapAccessDeserializer::new(map)).map(self.map)
    }
}

pub(crate) fn word_or_map<'de, D: Deserializer<'de>, T, M: Deserialize<'de>>(
    deserializer: D,
    expecting: &'static str,
    word: fn(&str) -> Option<T>,
    map: fn(M) -> T,
) -> Result<T, D::Error> {
    deserializer.deserialize_any(WordOrMap {
        expecting,
        word,
        map,
    })
}

pub(crate) enum Number {
    Int(i64),
    Unsigned(u64),
    Float(f64),
}

struct WordOrNumber<T> {
    expecting: &'static str,
    word: fn(&str) -> Option<T>,
    number: fn(Number) -> Result<T, String>,
}

impl<T> Visitor<'_> for WordOrNumber<T> {
    type Value = T;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.expecting)
    }

    fn visit_str<E: de::Error>(self, text: &str) -> Result<T, E> {
        (self.word)(text).ok_or_else(|| E::invalid_value(de::Unexpected::Str(text), &self))
    }

    fn visit_i64<E: de::Error>(self, number: i64) -> Result<T, E> {
        (self.number)(Number::Int(number)).map_err(E::custom)
    }

    fn visit_u64<E: de::Error>(self, number: u64) -> Result<T, E> {
        (self.number)(Number::Unsigned(number)).map_err(E::custom)
    }

    fn visit_f64<E: de::Error>(self, number: f64) -> Result<T, E> {
        (self.number)(Number::Float(number)).map_err(E::custom)
    }
}

pub(crate) fn word_or_number<'de, D: Deserializer<'de>, T>(
    deserializer: D,
    expecting: &'static str,
    word: fn(&str) -> Option<T>,
    number: fn(Number) -> Result<T, String>,
) -> Result<T, D::Error> {
    deserializer.deserialize_any(WordOrNumber {
        expecting,
        word,
        number,
    })
}

macro_rules! word {
    ($name:ident, $what:literal, $pattern:literal, $valid:expr) => {
        #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        pub struct $name(String);

        impl $name {
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                json_schema!({"type": "string", "pattern": $pattern, "description": $what})
            }
        }

        impl TryFrom<String> for $name {
            type Error = String;

            fn try_from(text: String) -> Result<$name, String> {
                if $valid(text.as_str()) {
                    Ok($name(text))
                } else {
                    Err(format!("{text:?} is not {}", $what))
                }
            }
        }

        impl From<$name> for String {
            fn from($name(text): $name) -> String {
                text
            }
        }
    };
}

macro_rules! list {
    ($(#[$attr:meta])* $name:ident, $what:literal, $valid:expr) => {
        $(#[$attr])*
        #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(try_from = "Vec<String>", into = "Vec<String>")]
        pub struct $name(Vec<String>);

        impl $name {
            pub fn as_slice(&self) -> &[String] {
                &self.0
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                json_schema!({"type": "array", "items": {"type": "string"}, "description": $what})
            }
        }

        impl TryFrom<Vec<String>> for $name {
            type Error = String;

            fn try_from(list: Vec<String>) -> Result<$name, String> {
                if list.iter().any(|arg| arg.contains('\0')) {
                    return Err("contains a NUL".to_owned());
                }
                let valid: fn(&[String]) -> Result<(), String> = $valid;
                valid(&list)?;
                Ok($name(list))
            }
        }

        impl From<$name> for Vec<String> {
            fn from($name(list): $name) -> Vec<String> {
                list
            }
        }
    };
}

fn operand_valid(text: &str) -> bool {
    let mut chars = text.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || "_.:/@+-".contains(c))
}

fn user_valid(text: &str) -> bool {
    !text.starts_with('-') && !text.is_empty() && !text.contains('\0')
}

word!(AbsPath, "an absolute path", "^/", |text: &str| text
    .starts_with('/')
    && !text.contains('\0'));
word!(
    RuntimeColor,
    "an #rrggbb colour",
    "^#[0-9A-Fa-f]{6}$",
    |text: &str| text.len() == 7
        && text.starts_with('#')
        && text[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
);
word!(
    ThemeName,
    "a theme name without /, a leading dot, a comma, a colon, an equals sign or a control character",
    "^[^/.,:=\\u0000-\\u001f\\u007f][^/,:=\\u0000-\\u001f\\u007f]*$",
    |text: &str| !text.is_empty()
        && !text.starts_with('.')
        && !text.contains(['/', ',', ':', '='])
        && !text.chars().any(char::is_control)
);
word!(
    FontFamily,
    "a font family name without a newline",
    "^[^\\r\\n]+$",
    |text: &str| !text.is_empty() && !text.contains(['\r', '\n'])
);
word!(
    FontFeature,
    "an OpenType feature tag with an optional + or -",
    "^[+-]?[a-zA-Z0-9]{4}$",
    |text: &str| {
        let tag = text.strip_prefix(['+', '-']).unwrap_or(text);
        tag.len() == 4 && tag.bytes().all(|byte| byte.is_ascii_alphanumeric())
    }
);
word!(
    Payload,
    "text without control characters or a leading or trailing space",
    "^[^\\u0000-\\u001f\\u007f ]([^\\u0000-\\u001f\\u007f]*[^\\u0000-\\u001f\\u007f ])?$",
    |text: &str| !text.is_empty()
        && !text.chars().any(char::is_control)
        && !text.starts_with(' ')
        && !text.ends_with(' ')
);
word!(
    Operand,
    "an image reference or a container name",
    "^[A-Za-z0-9][A-Za-z0-9_.:/@+-]*$",
    operand_valid
);
word!(
    User,
    "a user name or id",
    "^[^-\\u0000][^\\u0000]*$",
    user_valid
);
word!(
    Program,
    "a program name or path",
    "^[^\\u0000]+$",
    |text: &str| !text.is_empty() && !text.contains('\0')
);
word!(
    Destination,
    "an ssh destination",
    "^[^-\\u0000][^\\u0000]*$",
    user_valid
);
word!(
    VolumePath,
    "an absolute path without a colon",
    "^/[^:\\u0000]*$",
    |text: &str| text.starts_with('/') && !text.contains([':', '\0'])
);
word!(
    MountDir,
    "an absolute path without a comma",
    "^/[^,\\u0000]*$",
    |text: &str| text.starts_with('/') && !text.contains([',', '\0'])
);
word!(
    RemoteDir,
    "an absolute path without a colon, a percent sign or a newline",
    "^/[^:%\\n\\u0000]*$",
    ssh_args::remote_dir_valid
);

impl ThemeName {
    pub(crate) fn light() -> ThemeName {
        ThemeName("kido-light".to_owned())
    }

    pub(crate) fn dark() -> ThemeName {
        ThemeName("kido-dark".to_owned())
    }
}

macro_rules! ranged {
    ($name:ident, $min:literal..=$max:literal, $default:literal) => {
        ranged!($name, true, $min, $max, $default);
    };
    ($name:ident, >$min:literal..=$max:literal, $default:literal) => {
        ranged!($name, false, $min, $max, $default);
    };
    ($name:ident, $inclusive:literal, $min:literal, $max:literal, $default:literal) => {
        #[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
        #[serde(try_from = "f64", into = "f64")]
        pub struct $name(f64);

        impl $name {
            pub fn get(self) -> f64 {
                self.0
            }
        }

        impl Default for $name {
            fn default() -> $name {
                $name($default)
            }
        }

        impl JsonSchema for $name {
            fn schema_name() -> Cow<'static, str> {
                stringify!($name).into()
            }

            fn json_schema(_: &mut SchemaGenerator) -> Schema {
                let mut schema = json_schema!({
                    "type": "number",
                    "maximum": $max,
                    "description": format!(
                        "A number {} {} and at most {}.",
                        if $inclusive { "of at least" } else { "above" },
                        $min,
                        $max
                    )
                });
                schema.insert(
                    if $inclusive { "minimum" } else { "exclusiveMinimum" }.to_owned(),
                    $min.into(),
                );
                schema
            }
        }

        impl TryFrom<f64> for $name {
            type Error = String;

            fn try_from(value: f64) -> Result<$name, String> {
                if (if $inclusive { value >= $min } else { value > $min }) && value <= $max {
                    Ok($name(value))
                } else {
                    Err(format!(
                        "{value} is not {} {} and at most {}",
                        if $inclusive { "at least" } else { "above" },
                        $min,
                        $max
                    ))
                }
            }
        }

        impl From<$name> for f64 {
            fn from($name(value): $name) -> f64 {
                value
            }
        }
    };
}

pub(crate) use ranged;

impl From<&VolumePath> for AbsPath {
    fn from(path: &VolumePath) -> AbsPath {
        AbsPath(path.0.clone())
    }
}

const OWNED_OPTIONS: [&str; 13] = [
    "-v",
    "--volume",
    "--mount",
    "--name",
    "-d",
    "--detach",
    "--rm",
    "--remove",
    "--publish-socket",
    "--ssh",
    "--init",
    "--security-opt",
    "--http-proxy",
];

fn owned_option(arg: &str) -> Option<&'static str> {
    OWNED_OPTIONS.iter().copied().find(|owned| {
        let short = !owned.starts_with("--");
        arg == *owned
            || arg
                .strip_prefix(owned)
                .is_some_and(|rest| rest.starts_with('=') || (short && !arg.starts_with("--")))
    })
}

fn argv_valid(argv: &[String]) -> Result<(), String> {
    if argv.first().is_none_or(|program| !program.starts_with('/')) {
        Err("must start with an absolute program path".to_owned())
    } else {
        Ok(())
    }
}

fn init_valid(argv: &[String]) -> Result<(), String> {
    if argv.first().is_none_or(String::is_empty) {
        Err("must be a command".to_owned())
    } else {
        Ok(())
    }
}

fn run_args_valid(args: &[String]) -> Result<(), String> {
    match args.iter().find_map(|arg| owned_option(arg)) {
        Some(owned) => Err(format!("{owned} is set by ko")),
        None => Ok(()),
    }
}

list!(
    #[derive(Default)]
    ConnectionArgs,
    "ssh connection options, with no destination and no command",
    ssh_args::connection_only
);
list!(
    #[derive(Default)]
    Prefix,
    "an argv",
    |_| Ok(())
);
list!(
    Argv,
    "an argv that starts with an absolute program path",
    argv_valid
);
list!(
    #[derive(Default)]
    RunArgs,
    "arguments of the container engine's `run` without an option that ko owns",
    run_args_valid
);
list!(Init, "a command", init_valid);

impl Default for Init {
    fn default() -> Init {
        Init(vec!["sleep".to_owned(), "infinity".to_owned()])
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    try_from = "BTreeMap<String, String>",
    into = "BTreeMap<String, String>"
)]
pub struct Env(BTreeMap<String, String>);

impl Env {
    pub fn as_map(&self) -> &BTreeMap<String, String> {
        &self.0
    }
}

pub fn env_valid(name: &str, value: &str) -> bool {
    !name.is_empty() && !name.contains(['=', '\0']) && !value.contains('\0')
}

impl JsonSchema for Env {
    fn schema_name() -> Cow<'static, str> {
        "Env".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "object",
            "additionalProperties": {"type": "string"},
            "description": "Environment variables: names without = or NUL, values without NUL."
        })
    }
}

impl TryFrom<BTreeMap<String, String>> for Env {
    type Error = String;

    fn try_from(map: BTreeMap<String, String>) -> Result<Env, String> {
        match map.iter().find(|(name, value)| !env_valid(name, value)) {
            Some((name, _)) => Err(format!("{name:?} is an invalid variable")),
            None => Ok(Env(map)),
        }
    }
}

impl From<Env> for BTreeMap<String, String> {
    fn from(Env(map): Env) -> BTreeMap<String, String> {
        map
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_tags_are_names_or_session_qualified_names() {
        for text in ["dev", "session_3-dev"] {
            assert_eq!(text.parse::<RuntimeTag>().unwrap().to_string(), text);
        }
        for text in [
            "",
            "/x",
            "..",
            "a/b",
            "session_3-",
            "session_03-dev",
            "session_x-dev",
        ] {
            assert!(text.parse::<RuntimeTag>().is_err(), "{text}");
        }
    }

    #[test]
    fn a_runtime_color_is_a_hash_and_six_hex_digits() {
        for good in ["#000000", "#d08a2a", "#D08A2A"] {
            assert!(RuntimeColor::try_from(good.to_owned()).is_ok(), "{good}");
        }
        for bad in [
            "", "#abc", "d08a2a", "#d08a2", "#d08a2ab", "#gggggg", "red", "#é08a2a",
        ] {
            assert!(RuntimeColor::try_from(bad.to_owned()).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_runtime_name_is_one_to_32_lowercase_letters_digits_and_hyphens_but_not_host() {
        for good in ["a", "dev-1", "0", &"x".repeat(32), "host1", "hos"] {
            assert!(RuntimeName::try_from(good.to_owned()).is_ok(), "{good}");
        }
        for bad in ["", "host", "Dev", "a_b", "a b", "é", "a/b", &"x".repeat(33)] {
            assert_eq!(
                RuntimeName::try_from(bad.to_owned()),
                Err("invalid runtime name"),
                "{bad}"
            );
        }
    }
}
