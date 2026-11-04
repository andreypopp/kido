use std::borrow::Cow;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Serialize};

use crate::values::{Payload, ranged};

const MENU_OWNED: [&str; 40] = [
    "super+q",
    "super+n",
    "super+t",
    "super+shift+k",
    "super+s",
    "super+shift+s",
    "super+p",
    "super+shift+p",
    "super+f",
    "super+g",
    "super+shift+g",
    "super+z",
    "super+shift+z",
    "super+x",
    "super+c",
    "super+v",
    "super+alt+shift+v",
    "super+a",
    "super+o",
    "super+shift+c",
    "super+d",
    "super+shift+d",
    "super+w",
    "super+shift+enter",
    "super+alt+left",
    "super+alt+up",
    "super+alt+right",
    "super+alt+down",
    "super+h",
    "super+j",
    "super+k",
    "super+l",
    "super+[",
    "super+]",
    "super+alt+[",
    "super+alt+]",
    "super+shift+[",
    "super+shift+]",
    "super+{",
    "super+}",
];

#[rustfmt::skip]
const KEYS: [&str; 177] = [
    "backquote", "backslash", "bracket_left", "bracket_right", "comma", "digit_0", "digit_1",
    "digit_2", "digit_3", "digit_4", "digit_5", "digit_6", "digit_7", "digit_8", "digit_9",
    "equal", "intl_backslash", "intl_ro", "intl_yen", "key_a", "key_b", "key_c", "key_d", "key_e",
    "key_f", "key_g", "key_h", "key_i", "key_j", "key_k", "key_l", "key_m", "key_n", "key_o",
    "key_p", "key_q", "key_r", "key_s", "key_t", "key_u", "key_v", "key_w", "key_x", "key_y",
    "key_z", "minus", "period", "quote", "semicolon", "slash", "alt_left", "alt_right",
    "backspace", "context_menu", "control_left", "control_right", "enter",
    "meta_left", "meta_right", "shift_left", "shift_right", "space", "tab", "convert", "kana_mode",
    "non_convert", "delete", "end", "help", "home", "insert", "page_down", "page_up", "arrow_down",
    "arrow_left", "arrow_right", "arrow_up", "numpad_0", "numpad_1", "numpad_2",
    "numpad_3", "numpad_4", "numpad_5", "numpad_6", "numpad_7", "numpad_8", "numpad_9",
    "numpad_add", "numpad_backspace", "numpad_clear", "numpad_clear_entry", "numpad_comma",
    "numpad_decimal", "numpad_divide", "numpad_enter", "numpad_equal", "numpad_memory_add",
    "numpad_memory_clear", "numpad_memory_recall", "numpad_memory_store",
    "numpad_memory_subtract", "numpad_multiply", "numpad_paren_left", "numpad_paren_right",
    "numpad_subtract", "numpad_separator", "numpad_up", "numpad_down", "numpad_right",
    "numpad_left", "numpad_begin", "numpad_home", "numpad_end", "numpad_insert", "numpad_delete",
    "numpad_page_up", "numpad_page_down", "escape", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8",
    "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21",
    "f22", "f23", "f24", "f25", "fn", "fn_lock", "print_screen", "scroll_lock", "pause",
    "browser_back", "browser_favorites", "browser_forward", "browser_home", "browser_refresh",
    "browser_search", "browser_stop", "eject", "launch_app_1", "launch_app_2", "launch_mail",
    "media_play_pause", "media_select", "media_stop", "media_track_next", "media_track_previous",
    "power", "sleep", "audio_volume_down", "audio_volume_mute", "audio_volume_up", "wake_up",
    "copy", "cut", "paste", "up", "down", "left", "right",
];

const MODIFIERS: [(&str, usize); 9] = [
    ("super", 0),
    ("cmd", 0),
    ("command", 0),
    ("ctrl", 1),
    ("control", 1),
    ("alt", 2),
    ("opt", 2),
    ("option", 2),
    ("shift", 3),
];
const MODIFIER_NAMES: [&str; 4] = ["super", "ctrl", "alt", "shift"];

/// A key combination in Ghostty's `modifier+key` syntax, with its modifiers in the order super,
/// ctrl, alt, shift.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Trigger(String);

fn key_valid(key: &str) -> bool {
    let mut chars = key.chars();
    match (chars.next(), chars.next()) {
        (Some(only), None) => !only.is_whitespace() && !only.is_control() && !"=>".contains(only),
        _ => KEYS.contains(&key),
    }
}

fn short_key(key: &str) -> String {
    let key = key.to_ascii_lowercase();
    match key.as_str() {
        "bracket_left" => "[".to_owned(),
        "bracket_right" => "]".to_owned(),
        _ => key
            .strip_prefix("arrow_")
            .or_else(|| key.strip_prefix("key_"))
            .or_else(|| key.strip_prefix("digit_"))
            .unwrap_or(&key)
            .to_owned(),
    }
}

impl TryFrom<String> for Trigger {
    type Error = String;

    fn try_from(text: String) -> Result<Trigger, String> {
        let mut mods = [false; 4];
        let mut key: Option<&str> = None;
        let mut rest = text.as_str();
        while !rest.is_empty() {
            let (part, tail) = rest.split_once('+').unwrap_or((rest, ""));
            rest = tail;
            let modifier = MODIFIERS
                .iter()
                .find_map(|(name, at)| (*name == part).then_some(*at));
            if let Some(at) = modifier {
                if std::mem::replace(&mut mods[at], true) {
                    return Err(format!("{text:?} repeats a modifier"));
                }
            } else if key.is_some() {
                return Err(format!("{text:?} has more than one key"));
            } else if part.is_empty() {
                key = Some("+");
            } else if key_valid(part) {
                key = Some(part);
            } else {
                return Err(format!("{part:?} is not a key"));
            }
        }
        let Some(key) = key else {
            return Err(format!("{text:?} has no key"));
        };
        let held: Vec<&str> = MODIFIER_NAMES
            .iter()
            .zip(mods)
            .filter_map(|(name, held)| held.then_some(*name))
            .collect();
        let short = short_key(key);
        let joined = |key: &str| {
            held.iter()
                .copied()
                .chain([key])
                .collect::<Vec<_>>()
                .join("+")
        };
        let canonical = joined(key);
        if MENU_OWNED.contains(&joined(&short).as_str()) {
            return Err(format!("{canonical:?} belongs to a menu of the app"));
        }
        Ok(Trigger(canonical))
    }
}

impl From<Trigger> for String {
    fn from(Trigger(text): Trigger) -> String {
        text
    }
}

impl JsonSchema for Trigger {
    fn schema_name() -> Cow<'static, str> {
        "Trigger".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "pattern": "^((super|cmd|command|ctrl|control|alt|opt|option|shift)\\+)*(\\+|[^+]+)$",
            "description": "Modifiers and one key joined by +, in Ghostty's syntax: super, ctrl, alt and shift, then a key name such as key_a, enter or arrow_up, or one character. The triggers of the app's menus are refused."
        })
    }
}

ranged!(FontStep, 0.1..=72.0, 1.0);

/// What a key does, in Ghostty's keybind syntax.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub enum Action {
    Text(Payload),
    Csi(Payload),
    Esc(Payload),
    Unbind,
    PasteFromClipboard,
    CopyToClipboard,
    IncreaseFontSize(FontStep),
    DecreaseFontSize(FontStep),
    ResetFontSize,
}

impl TryFrom<String> for Action {
    type Error = String;

    fn try_from(text: String) -> Result<Action, String> {
        let (name, argument) = match text.split_once(':') {
            Some((name, argument)) => (name, Some(argument)),
            None => (text.as_str(), None),
        };
        let step = |argument: &str| {
            argument
                .parse::<f64>()
                .map_err(|_| format!("{argument:?} is not a number"))
                .and_then(FontStep::try_from)
        };
        let payload = |argument: &str| Payload::try_from(argument.to_owned());
        match (name, argument) {
            ("text", Some(argument)) => payload(argument).map(Action::Text),
            ("csi", Some(argument)) => payload(argument).map(Action::Csi),
            ("esc", Some(argument)) => payload(argument).map(Action::Esc),
            ("increase_font_size", Some(argument)) => step(argument).map(Action::IncreaseFontSize),
            ("decrease_font_size", Some(argument)) => step(argument).map(Action::DecreaseFontSize),
            ("unbind", None) => Ok(Action::Unbind),
            ("paste_from_clipboard", None) => Ok(Action::PasteFromClipboard),
            ("copy_to_clipboard", None) => Ok(Action::CopyToClipboard),
            ("reset_font_size", None) => Ok(Action::ResetFontSize),
            _ => Err(format!("{text:?} is not an action")),
        }
    }
}

impl From<Action> for String {
    fn from(action: Action) -> String {
        match action {
            Action::Text(text) => format!("text:{}", text.as_str()),
            Action::Csi(text) => format!("csi:{}", text.as_str()),
            Action::Esc(text) => format!("esc:{}", text.as_str()),
            Action::Unbind => "unbind".to_owned(),
            Action::PasteFromClipboard => "paste_from_clipboard".to_owned(),
            Action::CopyToClipboard => "copy_to_clipboard".to_owned(),
            Action::IncreaseFontSize(step) => format!("increase_font_size:{}", step.get()),
            Action::DecreaseFontSize(step) => format!("decrease_font_size:{}", step.get()),
            Action::ResetFontSize => "reset_font_size".to_owned(),
        }
    }
}

impl JsonSchema for Action {
    fn schema_name() -> Cow<'static, str> {
        "Action".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "string",
            "pattern": "^(unbind|paste_from_clipboard|copy_to_clipboard|reset_font_size|(text|csi|esc):[^\\u0000-\\u001f\\u007f ]([^\\u0000-\\u001f\\u007f]*[^\\u0000-\\u001f\\u007f ])?|(increase|decrease)_font_size:[0-9.]+)$",
            "description": "unbind, paste_from_clipboard, copy_to_clipboard, reset_font_size, increase_font_size:POINTS, decrease_font_size:POINTS (0.1 to 72), or text:, csi: or esc: and the text to send, with Ghostty's escapes such as \\x1b. The text has no control character and no space at either end."
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trigger(text: &str) -> Result<String, String> {
        Trigger::try_from(text.to_owned()).map(String::from)
    }

    fn action(text: &str) -> Result<String, String> {
        Action::try_from(text.to_owned()).map(String::from)
    }

    #[test]
    fn a_trigger_is_written_with_modifiers_in_the_canonical_order_and_aliases_resolved() {
        for (text, canonical) in [
            ("ctrl+e", "ctrl+e"),
            ("shift+ctrl+e", "ctrl+shift+e"),
            ("cmd+opt+control+shift+key_e", "super+ctrl+alt+shift+key_e"),
            ("alt+arrow_up", "alt+arrow_up"),
            ("f5", "f5"),
            ("ctrl++", "ctrl++"),
            ("ctrl+;", "ctrl+;"),
            ("super+shift+e", "super+shift+e"),
            ("alt+left", "alt+left"),
        ] {
            assert_eq!(trigger(text), Ok(canonical.to_owned()), "{text}");
        }
    }

    #[test]
    fn a_trigger_with_no_key_two_keys_a_repeat_or_an_unknown_key_is_refused() {
        for (text, message) in [
            ("", "\"\" has no key"),
            ("ctrl", "\"ctrl\" has no key"),
            ("ctrl+", "\"ctrl+\" has no key"),
            ("a+b", "\"a+b\" has more than one key"),
            ("ctrl+cmd+ctrl+a", "\"ctrl+cmd+ctrl+a\" repeats a modifier"),
            ("cmd+command+a", "\"cmd+command+a\" repeats a modifier"),
            ("ctrl+foo", "\"foo\" is not a key"),
            ("ctrl+KeyA", "\"KeyA\" is not a key"),
            ("ctrl+=", "\"=\" is not a key"),
            ("ctrl+ ", "\" \" is not a key"),
            ("caps_lock+a", "\"caps_lock\" is not a key"),
        ] {
            assert_eq!(trigger(text), Err(message.to_owned()), "{text}");
        }
    }

    #[test]
    fn a_trigger_of_a_menu_is_refused_in_every_spelling_of_its_key() {
        for text in [
            "super+d",
            "cmd+key_d",
            "command+D",
            "shift+super+d",
            "super+bracket_left",
            "super+alt+arrow_left",
            "opt+cmd+left",
            "super+shift+enter",
            "super+q",
        ] {
            let error = trigger(text).unwrap_err();
            assert!(
                error.ends_with("belongs to a menu of the app"),
                "{text}: {error}"
            );
        }
        for text in ["super+e", "ctrl+d", "super+alt+d", "super+m", "alt+left"] {
            assert!(trigger(text).is_ok(), "{text}");
        }
        for owned in MENU_OWNED {
            assert!(
                Trigger::try_from(owned.to_owned()).is_err(),
                "{owned} must be refused"
            );
        }
    }

    #[test]
    fn an_action_is_written_in_ghosttys_syntax_and_reads_back() {
        for text in [
            "text:X",
            "text:\\x1b[1;5A",
            "text:two words",
            "csi:1;5A",
            "esc:b",
            "unbind",
            "paste_from_clipboard",
            "copy_to_clipboard",
            "increase_font_size:1",
            "increase_font_size:1.5",
            "decrease_font_size:0.1",
            "reset_font_size",
        ] {
            assert_eq!(action(text), Ok(text.to_owned()), "{text}");
        }
    }

    #[test]
    fn an_unknown_action_a_missing_or_stray_argument_or_a_bad_payload_is_refused() {
        for (text, message) in [
            ("", "\"\" is not an action"),
            ("quit", "\"quit\" is not an action"),
            ("text", "\"text\" is not an action"),
            ("unbind:x", "\"unbind:x\" is not an action"),
            (
                "reset_font_size:1",
                "\"reset_font_size:1\" is not an action",
            ),
            (
                "increase_font_size",
                "\"increase_font_size\" is not an action",
            ),
            ("increase_font_size:x", "\"x\" is not a number"),
            (
                "increase_font_size:0",
                "0 is not at least 0.1 and at most 72",
            ),
            (
                "decrease_font_size:73",
                "73 is not at least 0.1 and at most 72",
            ),
            (
                "increase_font_size:nan",
                "NaN is not at least 0.1 and at most 72",
            ),
            (
                "text:",
                "\"\" is not text without control characters or a leading or trailing space",
            ),
            (
                "text: X",
                "\" X\" is not text without control characters or a leading or trailing space",
            ),
            (
                "text:X ",
                "\"X \" is not text without control characters or a leading or trailing space",
            ),
            (
                "text:a\nb",
                "\"a\\nb\" is not text without control characters or a leading or trailing space",
            ),
            (
                "csi:\r",
                "\"\\r\" is not text without control characters or a leading or trailing space",
            ),
        ] {
            assert_eq!(action(text), Err(message.to_owned()), "{text:?}");
        }
    }
}
