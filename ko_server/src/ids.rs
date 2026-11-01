use std::fmt;
use std::str::FromStr;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct PaneId(u64);

impl PaneId {
    pub fn new(number: u64) -> PaneId {
        PaneId(number)
    }
}

impl fmt::Display for PaneId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "pane_{}", self.0)
    }
}

impl FromStr for PaneId {
    type Err = InvalidId;

    fn from_str(text: &str) -> Result<PaneId, InvalidId> {
        parse("pane_", text).map(PaneId)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ClientId(u64);

impl ClientId {
    pub fn new(number: u64) -> ClientId {
        ClientId(number)
    }
}

impl fmt::Display for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "client_{}", self.0)
    }
}

impl FromStr for ClientId {
    type Err = InvalidId;

    fn from_str(text: &str) -> Result<ClientId, InvalidId> {
        parse("client_", text).map(ClientId)
    }
}

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
