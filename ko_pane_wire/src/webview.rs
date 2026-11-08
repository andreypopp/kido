#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use crate::base64;

pub const MAX_BYTES: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Enter(crate::frame::OwnedWebviewPath),
    Leave,
    Query,
}

pub fn parse(bytes: &[u8]) -> Option<Command> {
    let text = bytes.strip_prefix(b"7502;")?;
    if text == b"?" {
        return Some(Command::Query);
    }
    let (mut action, mut path) = (None, None);
    for pair in text.split(|byte| *byte == b':') {
        let Ok(pair) = std::str::from_utf8(pair) else {
            continue;
        };
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        if key.is_empty()
            || !key.bytes().all(|byte| byte.is_ascii_lowercase())
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_.,+/=-".contains(&byte))
        {
            continue;
        }
        match key {
            "a" => action = Some(value),
            "p" => path = Some(value),
            _ => {}
        }
    }
    match action? {
        "leave" => Some(Command::Leave),
        "enter" => {
            let path = match path {
                None => crate::frame::OwnedWebviewPath::try_from("/".to_owned()).ok()?,
                Some(path) => {
                    let bytes = base64::decode(path)?;
                    crate::frame::OwnedWebviewPath::try_from(String::from_utf8(bytes).ok()?).ok()?
                }
            };
            Some(Command::Enter(path))
        }
        _ => None,
    }
}

pub fn reply(supported: bool, terminator: &[u8]) -> Vec<u8> {
    let mut reply = encode(&Command::Query);
    reply.pop();
    reply.extend_from_slice(b":actions=enter,leave:supported=");
    reply.push(if supported { b'1' } else { b'0' });
    reply.extend_from_slice(terminator);
    reply
}

pub fn encode(command: &Command) -> Vec<u8> {
    match command {
        Command::Query => b"\x1b]7502;?\x07".to_vec(),
        Command::Leave => b"\x1b]7502;a=leave\x07".to_vec(),
        Command::Enter(path) if path.as_str() == "/" => b"\x1b]7502;a=enter\x07".to_vec(),
        Command::Enter(path) => format!(
            "\x1b]7502;a=enter:p={}\x07",
            base64::encode(path.as_str().as_bytes())
        )
        .into_bytes(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairs_drop_malformed_and_unknown_fields_and_keep_the_last_value() {
        assert_eq!(
            parse(b"7502;a=enter"),
            Some(Command::Enter(
                crate::frame::OwnedWebviewPath::try_from("/".to_owned()).unwrap()
            ))
        );
        assert_eq!(
            parse(b"7502;a=enter:x=\xff"),
            Some(Command::Enter(
                crate::frame::OwnedWebviewPath::try_from("/".to_owned()).unwrap()
            ))
        );
        assert_eq!(
            parse(b"7502;a=leave:bad:a=enter:p=L29sZA==:p=L25ldz9hPWI=:x=ok:a!=leave"),
            Some(Command::Enter(
                crate::frame::OwnedWebviewPath::try_from("/new?a=b".to_owned()).unwrap()
            ))
        );
        assert_eq!(parse(b"7502;p=Lw=="), None);
        assert_eq!(parse(b"7502;a=unknown"), None);
        assert_eq!(parse(b"75020;a=enter"), None);
        assert_eq!(parse(b"7502;?"), Some(Command::Query));
        assert_eq!(parse(b"7502;a=leave:p=bad"), Some(Command::Leave));
    }

    #[test]
    fn paths_are_absolute_printable_ascii_and_bounded() {
        for bytes in [b"relative".as_slice(), b"", b"/\n", b"/\x7f", b"/\xff"] {
            assert_eq!(
                parse(format!("7502;a=enter:p={}", base64::encode(bytes)).as_bytes()),
                None
            );
        }
        assert_eq!(parse(b"7502;a=enter:p=invalid"), None);
        let path = format!("/{}", "x".repeat(2047));
        assert_eq!(
            parse(format!("7502;a=enter:p={}", base64::encode(path.as_bytes())).as_bytes()),
            Some(Command::Enter(
                crate::frame::OwnedWebviewPath::try_from(path.clone()).unwrap()
            ))
        );
        assert_eq!(
            parse(
                format!(
                    "7502;a=enter:p={}",
                    base64::encode(format!("{path}x").as_bytes())
                )
                .as_bytes()
            ),
            None
        );
    }
}
