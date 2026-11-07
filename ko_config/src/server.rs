use std::borrow::Cow;
use std::num::NonZeroUsize;
use std::time::Duration;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::values::{AbsPath, Number, ranged, word_or_map, word_or_number};

const SCROLLBACK_BYTES: NonZeroUsize = NonZeroUsize::new(50_000_000).unwrap();
const KITTY_IMAGES_BYTES: NonZeroUsize = NonZeroUsize::new(320_000_000).unwrap();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Limit {
    Unlimited,
    At(NonZeroUsize),
}

impl Limit {
    pub fn get(self) -> Option<NonZeroUsize> {
        match self {
            Limit::Unlimited => None,
            Limit::At(count) => Some(count),
        }
    }

    fn of(count: u64) -> Option<Limit> {
        usize::try_from(count)
            .ok()
            .and_then(NonZeroUsize::new)
            .map(Limit::At)
    }
}

impl Serialize for Limit {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Limit::Unlimited => serializer.serialize_str("unlimited"),
            Limit::At(count) => serializer.serialize_u64(count.get() as u64),
        }
    }
}

impl<'de> Deserialize<'de> for Limit {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Limit, D::Error> {
        word_or_number(
            deserializer,
            "a positive integer or unlimited",
            |word| (word == "unlimited").then_some(Limit::Unlimited),
            |number| {
                let count = match number {
                    Number::Int(count) => u64::try_from(count).ok(),
                    Number::Unsigned(count) => Some(count),
                    Number::Float(_) => None,
                };
                count
                    .and_then(Limit::of)
                    .ok_or_else(|| "not a positive integer or unlimited".to_owned())
            },
        )
    }
}

impl JsonSchema for Limit {
    fn schema_name() -> Cow<'static, str> {
        "Limit".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "oneOf": [{"type": "integer", "minimum": 1}, {"const": "unlimited"}],
            "description": "A positive integer, or the word unlimited."
        })
    }
}

/// How much terminal history a pane keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct Bounds {
    /// The most bytes of history.
    pub bytes: Limit,
    /// The most lines of history.
    pub lines: Limit,
}

impl Default for Bounds {
    fn default() -> Bounds {
        Bounds {
            bytes: Limit::At(SCROLLBACK_BYTES),
            lines: Limit::Unlimited,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scrollback {
    Off,
    Bounded(Bounds),
}

impl Default for Scrollback {
    fn default() -> Scrollback {
        Scrollback::Bounded(Bounds::default())
    }
}

impl Serialize for Scrollback {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Scrollback::Off => serializer.serialize_str("none"),
            Scrollback::Bounded(bounds) => bounds.serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for Scrollback {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Scrollback, D::Error> {
        word_or_map(
            deserializer,
            "none or a map of bytes and lines",
            |word| (word == "none").then_some(Scrollback::Off),
            Scrollback::Bounded,
        )
    }
}

impl JsonSchema for Scrollback {
    fn schema_name() -> Cow<'static, str> {
        "Scrollback".into()
    }

    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "oneOf": [{"const": "none"}, generator.subschema_for::<Bounds>()],
            "description": "The word none keeps no history. A map of bytes and lines bounds it."
        })
    }
}

ranged!(Seconds, >0.0..=31_536_000.0, 30.0);

impl Seconds {
    pub fn duration(self) -> Duration {
        Duration::from_secs_f64(self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Idle {
    After(Seconds),
    Never,
}

impl Serialize for Idle {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Idle::Never => serializer.serialize_str("none"),
            Idle::After(seconds) => seconds.serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for Idle {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Idle, D::Error> {
        word_or_number(
            deserializer,
            "seconds or none",
            |word| (word == "none").then_some(Idle::Never),
            |number| {
                let seconds = match number {
                    Number::Int(seconds) => seconds as f64,
                    Number::Unsigned(seconds) => seconds as f64,
                    Number::Float(seconds) => seconds,
                };
                Seconds::try_from(seconds).map(Idle::After)
            },
        )
    }
}

impl JsonSchema for Idle {
    fn schema_name() -> Cow<'static, str> {
        "Idle".into()
    }

    fn json_schema(generator: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "oneOf": [generator.subschema_for::<Seconds>(), {"const": "none"}],
            "description": "Seconds, or the word none."
        })
    }
}

/// The server's settings. ko server reads them each time it needs one, so a change applies
/// to the next pane or link.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct Server {
    /// The history that a new pane keeps.
    pub scrollback: Scrollback,
    /// The shell of new panes. Absent means the SHELL of the server's start, else /bin/sh.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shell: Option<AbsPath>,
    /// The most bytes of kitty graphics images that a pane keeps.
    pub kitty_images_max_bytes: NonZeroUsize,
    /// How long a finished pane that closes on exit stays in sight, in seconds.
    pub linger_seconds: Seconds,
    /// How long a runtime link stays up without a pane, in seconds.
    pub runtime_idle_seconds: Idle,
}

impl Default for Server {
    fn default() -> Server {
        Server {
            scrollback: Scrollback::default(),
            shell: None,
            kitty_images_max_bytes: KITTY_IMAGES_BYTES,
            linger_seconds: Seconds(30.0),
            runtime_idle_seconds: Idle::After(Seconds(600.0)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, parse};

    fn server(text: &str) -> Server {
        parse(text).unwrap().server
    }

    #[test]
    fn an_empty_server_section_is_every_default() {
        let found = server("");
        assert_eq!(found, server("server:\n"));
        assert_eq!(found, server("server: {}\n"));
        assert_eq!(
            serde_json::to_value(&found).unwrap(),
            serde_json::json!({
                "scrollback": {"bytes": 50_000_000, "lines": "unlimited"},
                "kitty_images_max_bytes": 320_000_000,
                "linger_seconds": 30.0,
                "runtime_idle_seconds": 600.0
            })
        );
        assert_eq!(found.linger_seconds.duration(), Duration::from_secs(30));
    }

    #[test]
    fn every_key_takes_its_value() {
        let found = server(
            "
server:
  scrollback: {bytes: 1000, lines: 20}
  shell: /bin/zsh
  kitty_images_max_bytes: 5
  linger_seconds: 0.2
  runtime_idle_seconds: 1.5
",
        );
        let json = serde_json::to_value(&found).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "scrollback": {"bytes": 1000, "lines": 20},
                "shell": "/bin/zsh",
                "kitty_images_max_bytes": 5,
                "linger_seconds": 0.2,
                "runtime_idle_seconds": 1.5
            })
        );
        assert_eq!(serde_json::from_value::<Server>(json).unwrap(), found);
        assert_eq!(found.linger_seconds.duration(), Duration::from_millis(200));
    }

    #[test]
    fn scrollback_is_none_or_a_map_whose_missing_member_is_its_default() {
        let none = server("server:\n  scrollback: none\n");
        assert_eq!(none.scrollback, Scrollback::Off);
        assert_eq!(serde_json::to_value(&none).unwrap()["scrollback"], "none");
        let json = serde_json::to_string(&none).unwrap();
        assert_eq!(serde_json::from_str::<Server>(&json).unwrap(), none);
        assert_eq!(
            server("server:\n  scrollback: {lines: 5}\n").scrollback,
            Scrollback::Bounded(Bounds {
                lines: Limit::of(5).unwrap(),
                ..Bounds::default()
            })
        );
        assert_eq!(
            server("server:\n  scrollback: {bytes: unlimited}\n").scrollback,
            Scrollback::Bounded(Bounds {
                bytes: Limit::Unlimited,
                lines: Limit::Unlimited
            })
        );
        assert_eq!(Limit::At(NonZeroUsize::MIN).get(), Some(NonZeroUsize::MIN));
        assert_eq!(Limit::Unlimited.get(), None);
    }

    #[test]
    fn a_limit_a_count_or_a_duration_outside_its_range_is_refused() {
        crate::config::refusals(&[
            (
                "server:\n  scrollback: off\n",
                "server: scrollback: invalid value: string \"off\", expected none or a map of bytes and lines at line 2 column 15",
            ),
            (
                "server:\n  scrollback: {bytes: 0}\n",
                "server: scrollback: bytes: not a positive integer or unlimited at line 2 column 23",
            ),
            (
                "server:\n  scrollback: {lines: -1}\n",
                "server: scrollback: lines: not a positive integer or unlimited at line 2 column 23",
            ),
            (
                "server:\n  scrollback: {lines: 1.5}\n",
                "server: scrollback: lines: not a positive integer or unlimited at line 2 column 23",
            ),
            (
                "server:\n  scrollback: {size: 1}\n",
                "server: scrollback: unknown field `size`, expected `bytes` or `lines` at line 2 column 16",
            ),
            (
                "server:\n  shell: zsh\n",
                "server: shell: \"zsh\" is not an absolute path at line 2 column 10",
            ),
            (
                "server:\n  kitty_images_max_bytes: 0\n",
                "server: kitty_images_max_bytes: invalid value: integer `0`, expected a nonzero usize at line 2 column 27",
            ),
            (
                "server:\n  linger_seconds: 0\n",
                "server: linger_seconds: 0 is not above 0 and at most 31536000 at line 2 column 19",
            ),
            (
                "server:\n  linger_seconds: 31536001\n",
                "server: linger_seconds: 31536001 is not above 0 and at most 31536000 at line 2 column 19",
            ),
            (
                "server:\n  linger_seconds: .inf\n",
                "server: linger_seconds: inf is not above 0 and at most 31536000 at line 2 column 19",
            ),
            (
                "server:\n  runtime_idle_seconds: never\n",
                "server: runtime_idle_seconds: invalid value: string \"never\", expected seconds or none at line 2 column 25",
            ),
            (
                "server:\n  runtime_idle_seconds: 0\n",
                "server: runtime_idle_seconds: 0 is not above 0 and at most 31536000 at line 2 column 25",
            ),
            (
                "server:\n  linger: 1\n",
                "server: unknown field `linger`, expected one of `scrollback`, `shell`, `kitty_images_max_bytes`, `linger_seconds`, `runtime_idle_seconds` at line 2 column 3",
            ),
        ]);
    }

    #[test]
    fn the_edges_of_a_range_are_taken() {
        let found = server(
            "server:\n  linger_seconds: 31536000\n  runtime_idle_seconds: 0.001\n  kitty_images_max_bytes: 1\n",
        );
        assert_eq!(
            found.linger_seconds.duration(),
            Duration::from_secs(31_536_000)
        );
        assert_eq!(found.runtime_idle_seconds, Idle::After(Seconds(0.001)));
        assert_eq!(found.kitty_images_max_bytes, NonZeroUsize::MIN);
        assert_eq!(
            server("server:\n  runtime_idle_seconds: none\n").runtime_idle_seconds,
            Idle::Never
        );
        let never = Config {
            server: server("server:\n  runtime_idle_seconds: none\n"),
            ..Config::default()
        };
        let json = serde_json::to_string(&never).unwrap();
        assert_eq!(serde_json::from_str::<Config>(&json).unwrap(), never);
    }

    #[test]
    fn limits_and_seconds_are_typed_scalars_so_hex_is_a_number_and_a_quoted_number_is_not() {
        let found = server(
            "server:\n  scrollback: {bytes: 0x100, lines: 0o17}\n  runtime_idle_seconds: 0x10\n",
        );
        assert_eq!(
            found.scrollback,
            Scrollback::Bounded(Bounds {
                bytes: Limit::of(256).unwrap(),
                lines: Limit::of(15).unwrap()
            })
        );
        assert_eq!(found.runtime_idle_seconds, Idle::After(Seconds(16.0)));
        crate::config::refusals(&[
            (
                "server:\n  scrollback: {bytes: '600'}\n",
                "server: scrollback: bytes: invalid value: string \"600\", expected a positive integer or unlimited at line 2 column 23",
            ),
            (
                "server:\n  runtime_idle_seconds: '600'\n",
                "server: runtime_idle_seconds: invalid value: string \"600\", expected seconds or none at line 2 column 25",
            ),
            (
                "server:\n  scrollback: {bytes: 12abc}\n",
                "server: scrollback: bytes: invalid value: string \"12abc\", expected a positive integer or unlimited at line 2 column 23",
            ),
        ]);
    }
}
