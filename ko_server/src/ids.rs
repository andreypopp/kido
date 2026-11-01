use std::fmt;
use std::str::FromStr;

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
id!(pub(crate) ClientId, "client_");

#[cfg(test)]
mod tests {
    use super::*;

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
}
