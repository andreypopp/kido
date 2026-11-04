use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use std::str::FromStr;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};

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
    "a colour as #rrggbb",
    "^#[0-9A-Fa-f]{6}$",
    |text: &str| text.len() == 7
        && text.starts_with('#')
        && text[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
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

impl From<&VolumePath> for AbsPath {
    fn from(path: &VolumePath) -> AbsPath {
        AbsPath(path.0.clone())
    }
}

const OWNED_OPTIONS: [&str; 10] = [
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
    "arguments of `container run` without an option that ko owns",
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
