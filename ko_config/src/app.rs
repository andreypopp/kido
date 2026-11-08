use std::borrow::Cow;
use std::collections::BTreeMap;

use schemars::{JsonSchema, Schema, SchemaGenerator, json_schema};
use serde::{Deserialize, Deserializer, Serialize};

use crate::keys::{Action, Trigger};
use crate::values::{FontFamily, FontFeature, HiddenPages, ThemeName, ranged, word_or_map};

/// Kido.app's settings.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct App {
    /// The colour theme for the light and the dark appearance.
    pub theme: Theme,
    pub font: Font,
    pub keyboard: Keyboard,
    pub mouse: Mouse,
    pub clipboard: Clipboard,
    pub window: WindowSettings,
    /// Webview pane rendering and its limits.
    pub webview: WebviewSettings,
    /// Extra key bindings, by trigger.
    pub keys: BTreeMap<Trigger, Action>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct WebviewSettings {
    /// Render HTML pages over the pane's terminal content.
    pub enabled: bool,
    /// Whether a link may open in the default browser.
    pub links: WebviewLinks,
    /// Allow WebKit's inspector for HTML pages.
    pub inspector: bool,
    /// The number of hidden pages that stay live in each native window.
    pub keep_hidden: HiddenPages,
}

impl Default for WebviewSettings {
    fn default() -> WebviewSettings {
        WebviewSettings {
            enabled: true,
            links: WebviewLinks::Deny,
            inspector: false,
            keep_hidden: HiddenPages::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum WebviewLinks {
    /// Do not open external links.
    #[default]
    Deny,
    /// Open HTTP and HTTPS links in the default browser.
    Open,
}

/// One theme name for both appearances, or a name for each.
#[derive(Debug, Clone, PartialEq, Serialize, JsonSchema)]
#[serde(untagged)]
pub enum Theme {
    One(ThemeName),
    Pair(ThemePair),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ThemePair {
    pub light: ThemeName,
    pub dark: ThemeName,
}

impl Default for ThemePair {
    fn default() -> ThemePair {
        ThemePair {
            light: ThemeName::light(),
            dark: ThemeName::dark(),
        }
    }
}

impl Default for Theme {
    fn default() -> Theme {
        Theme::Pair(ThemePair::default())
    }
}

impl Theme {
    pub(crate) fn pair(&self) -> ThemePair {
        match self {
            Theme::One(name) => ThemePair {
                light: name.clone(),
                dark: name.clone(),
            },
            Theme::Pair(pair) => pair.clone(),
        }
    }
}

impl<'de> Deserialize<'de> for Theme {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Theme, D::Error> {
        word_or_map(
            deserializer,
            "a theme name or a light and dark pair",
            |name| ThemeName::try_from(name.to_owned()).ok().map(Theme::One),
            Theme::Pair,
        )
    }
}

ranged!(FontSize, 4.0..=72.0, 13.0);
ranged!(LineHeight, -50.0..=100.0, 0.0);
ranged!(SidebarShade, -100.0..=100.0, 5.0);
ranged!(UnfocusedShift, -100.0..=100.0, 3.0);
ranged!(PrecisionScroll, 0.01..=100.0, 1.0);
ranged!(DiscreteScroll, 0.01..=100.0, 3.0);

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct Font {
    /// The font family. Absent means the system's monospaced font.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub family: Option<FontFamily>,
    /// The size in points.
    pub size: FontSize,
    /// OpenType features, such as ss01 or -liga.
    pub features: Vec<FontFeature>,
    /// Draw thicker glyphs.
    pub thicken: bool,
    /// The change of the cell height in percent.
    pub line_height: LineHeight,
}

/// Whether the option key acts as alt: off, on, or the left or right one only.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum OptionAsAlt {
    #[default]
    Off,
    On,
    Left,
    Right,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct Keyboard {
    pub option_as_alt: OptionAsAlt,
}

/// The lines that one scroll step moves, with a trackpad (`precision`) and with a wheel
/// (`discrete`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct ScrollMultiplier {
    pub precision: PrecisionScroll,
    pub discrete: DiscreteScroll,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct Mouse {
    pub scroll_multiplier: ScrollMultiplier,
    pub hide_while_typing: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardRead {
    #[default]
    Ask,
    Allow,
    Deny,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardWrite {
    #[default]
    Allow,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct Clipboard {
    /// Whether a program may read the clipboard (OSC 52).
    pub read: ClipboardRead,
    /// Whether a program may write the clipboard (OSC 52).
    pub write: ClipboardWrite,
    pub copy_on_select: bool,
    /// Ask before a paste that looks unsafe.
    pub paste_protection: bool,
    pub trim_trailing_spaces: bool,
}

impl Default for Clipboard {
    fn default() -> Clipboard {
        Clipboard {
            read: ClipboardRead::default(),
            write: ClipboardWrite::default(),
            copy_on_select: false,
            paste_protection: true,
            trim_trailing_spaces: true,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields, default)]
pub struct WindowSettings {
    /// The shade of the sidebar in percent. The sign follows the theme.
    pub sidebar_shade: SidebarShade,
    /// The shift of the background of an unfocused pane in percent.
    pub unfocused_shift: UnfocusedShift,
}

#[cfg(test)]
mod tests {
    use crate::config::parse;

    fn app(text: &str) -> super::App {
        parse(text).unwrap().app
    }

    #[test]
    fn webview_settings_are_checked() {
        let found = app(
            "app: {webview: {enabled: false, links: open, inspector: true, keep_hidden: 16}}\n",
        );
        assert!(!found.webview.enabled);
        assert_eq!(found.webview.links, super::WebviewLinks::Open);
        assert!(found.webview.inspector);
        assert_eq!(u8::from(found.webview.keep_hidden), 16);
        assert_eq!(
            u8::from(
                app("app: {webview: {keep_hidden: 0}}\n")
                    .webview
                    .keep_hidden
            ),
            0
        );
        for value in ["-1", "17", "1.5", "'4'"] {
            assert!(parse(&format!("app: {{webview: {{keep_hidden: {value}}}}}\n")).is_err());
        }
        assert!(parse("app: {webview: {links: allow}}\n").is_err());
    }

    #[test]
    fn an_empty_app_is_every_default() {
        let found = app("");
        assert_eq!(found, app("app:\n"));
        assert_eq!(found, app("app: {}\n"));
        assert_eq!(
            serde_json::to_value(&found).unwrap(),
            serde_json::json!({
                "theme": {"light": "kido-light", "dark": "kido-dark"},
                "font": {"size": 13.0, "features": [], "thicken": false, "line_height": 0.0},
                "keyboard": {"option_as_alt": "off"},
                "mouse": {"scroll_multiplier": {"precision": 1.0, "discrete": 3.0}, "hide_while_typing": false},
                "clipboard": {"read": "ask", "write": "allow", "copy_on_select": false, "paste_protection": true, "trim_trailing_spaces": true},
                "window": {"sidebar_shade": 5.0, "unfocused_shift": 3.0},
                "webview": {"enabled": true, "links": "deny", "inspector": false, "keep_hidden": 4},
                "keys": {}
            })
        );
    }

    #[test]
    fn every_key_takes_its_value() {
        let found = app("
app:
  theme: {light: a, dark: b}
  font:
    family: PragmataPro Mono Liga
    size: 16
    features: [ss13, -ss17, +liga, '0123']
    thicken: true
    line_height: -5.5
  keyboard: {option_as_alt: left}
  mouse:
    scroll_multiplier: {precision: 0.5, discrete: 10}
    hide_while_typing: true
  clipboard:
    read: deny
    write: deny
    copy_on_select: true
    paste_protection: false
    trim_trailing_spaces: false
  window: {sidebar_shade: -10, unfocused_shift: 0}
  keys:
    super+e: text:X
    ctrl+shift+arrow_up: csi:1;5A
    alt+k: unbind
");
        let json = serde_json::to_value(&found).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "theme": {"light": "a", "dark": "b"},
                "font": {"family": "PragmataPro Mono Liga", "size": 16.0, "features": ["ss13", "-ss17", "+liga", "0123"], "thicken": true, "line_height": -5.5},
                "keyboard": {"option_as_alt": "left"},
                "mouse": {"scroll_multiplier": {"precision": 0.5, "discrete": 10.0}, "hide_while_typing": true},
                "clipboard": {"read": "deny", "write": "deny", "copy_on_select": true, "paste_protection": false, "trim_trailing_spaces": false},
                "window": {"sidebar_shade": -10.0, "unfocused_shift": 0.0},
                "webview": {"enabled": true, "links": "deny", "inspector": false, "keep_hidden": 4},
                "keys": {"alt+k": "unbind", "ctrl+shift+arrow_up": "csi:1;5A", "super+e": "text:X"}
            })
        );
        assert_eq!(serde_json::from_value::<super::App>(json).unwrap(), found);
    }

    #[test]
    fn a_theme_is_a_name_for_both_appearances_or_a_pair() {
        let one = app("app:\n  theme: solarized\n");
        assert_eq!(serde_json::to_value(&one.theme).unwrap(), "solarized");
        let pair = one.theme.pair();
        assert_eq!(
            (pair.light.as_str(), pair.dark.as_str()),
            ("solarized", "solarized")
        );
        assert_eq!(
            serde_json::from_str::<super::Theme>("\"x\"").unwrap(),
            app("app:\n  theme: x\n").theme
        );
        crate::config::refusals(&[
            (
                "app:\n  theme: {light: a}\n",
                "app: theme: missing field `dark` at line 2 column 10",
            ),
            (
                "app:\n  theme: {light: a, dark: b, sepia: c}\n",
                "app: theme: unknown field `sepia`, expected `light` or `dark` at line 2 column 30",
            ),
            (
                "app:\n  theme: a/b\n",
                "app: theme: invalid value: string \"a/b\", expected a theme name or a light and dark pair at line 2 column 10",
            ),
            (
                "app:\n  theme: {light: .hidden, dark: b}\n",
                "app: theme: light: \".hidden\" is not a theme name without /, a leading dot, a comma, a colon, an equals sign or a control character at line 2 column 18",
            ),
            (
                "app:\n  theme: [a]\n",
                "app: theme: invalid type: sequence, expected a theme name or a light and dark pair at line 2 column 10",
            ),
        ]);
        for name in ["a:b", "a,b", "a=b", ""] {
            assert!(
                parse(&format!("app:\n  theme: '{name}'\n")).is_err(),
                "{name:?}"
            );
        }
        for name in ["a\nb", "a\rb", "a\0b", "a\tb", "a\u{7f}b"] {
            assert!(
                crate::values::ThemeName::try_from(name.to_owned()).is_err(),
                "{name:?}"
            );
        }
    }

    #[test]
    fn a_number_is_taken_from_its_first_to_its_last_value_and_no_further() {
        for (key, low, high) in [
            ("font: {size: ", 4.0, 72.0),
            ("font: {line_height: ", -50.0, 100.0),
            ("window: {sidebar_shade: ", -100.0, 100.0),
            ("window: {unfocused_shift: ", -100.0, 100.0),
            ("mouse: {scroll_multiplier: {precision: ", 0.01, 100.0),
            ("mouse: {scroll_multiplier: {discrete: ", 0.01, 100.0),
        ] {
            let close = if key.contains("scroll") { "}}" } else { "}" };
            let with = |value: f64| parse(&format!("app: {{{key}{value}{close}}}\n"));
            assert!(with(low).is_ok() && with(high).is_ok(), "{key}");
            assert!(
                with(low - 0.001).is_err() && with(high + 0.001).is_err(),
                "{key}"
            );
        }
        crate::config::refusals(&[
            (
                "app:\n  font: {size: 3}\n",
                "app: font: size: 3 is not at least 4 and at most 72 at line 2 column 16",
            ),
            (
                "app:\n  font: {size: big}\n",
                "app: font: size: invalid type: string \"big\", expected f64 at line 2 column 16",
            ),
            (
                "app:\n  font: {size: '12'}\n",
                "app: font: size: invalid type: string \"12\", expected f64 at line 2 column 16",
            ),
            (
                "app:\n  font: {size: .nan}\n",
                "app: font: size: NaN is not at least 4 and at most 72 at line 2 column 16",
            ),
        ]);
    }

    #[test]
    fn a_font_family_is_not_empty_and_a_feature_is_a_four_character_tag() {
        assert_eq!(
            app("app:\n  font: {family: Menlo}\n")
                .font
                .family
                .unwrap()
                .as_str(),
            "Menlo"
        );
        assert_eq!(app("app:\n  font: {family: }\n").font.family, None);
        for bad in ["''", "\"a\\nb\""] {
            assert!(
                parse(&format!("app:\n  font: {{family: {bad}}}\n")).is_err(),
                "{bad}"
            );
        }
        for good in ["ss01", "-ss01", "+liga", "calt", "ZERO"] {
            assert!(
                parse(&format!("app:\n  font: {{features: ['{good}']}}\n")).is_ok(),
                "{good}"
            );
        }
        for bad in ["", "liga1", "lig", "*liga", "--liga", "li a", "é123"] {
            assert!(
                parse(&format!("app:\n  font: {{features: ['{bad}']}}\n")).is_err(),
                "{bad:?}"
            );
        }
        crate::config::refusals(&[
            (
                "app:\n  font: {features: [ss01, x]}\n",
                "app: font: features: [1]: \"x\" is not an OpenType feature tag with an optional + or - at line 2 column 27",
            ),
            (
                "app:\n  font: {features: ss01}\n",
                "app: font: features: invalid type: string \"ss01\", expected a list at line 2 column 20",
            ),
        ]);
    }

    #[test]
    fn option_as_alt_is_the_enum_not_a_bool() {
        use super::OptionAsAlt;
        for (text, found) in [
            ("on", OptionAsAlt::On),
            ("off", OptionAsAlt::Off),
            ("left", OptionAsAlt::Left),
            ("right", OptionAsAlt::Right),
        ] {
            assert_eq!(
                app(&format!("app:\n  keyboard: {{option_as_alt: {text}}}\n"))
                    .keyboard
                    .option_as_alt,
                found
            );
        }
        for text in ["true", "false", "'on'x", "both"] {
            assert!(
                parse(&format!("app:\n  keyboard: {{option_as_alt: {text}}}\n")).is_err(),
                "{text}"
            );
        }
    }

    #[test]
    fn the_enums_refuse_a_value_that_they_lack() {
        for text in [
            "cursor: {style: beam}",
            "clipboard: {read: on}",
            "clipboard: {write: ask}",
            "clipboard: {copy_on_select: on}",
        ] {
            assert!(parse(&format!("app: {{{text}}}\n")).is_err(), "{text}");
        }
        crate::config::refusals(&[
            (
                "app:\n  cursor: {style: beam}\n",
                "app: unknown field `cursor`, expected one of `theme`, `font`, `keyboard`, `mouse`, `clipboard`, `window`, `webview`, `keys` at line 2 column 3",
            ),
            (
                "app:\n  clipboard: {blink: true}\n",
                "app: clipboard: unknown field `blink`, expected one of `read`, `write`, `copy_on_select`, `paste_protection`, `trim_trailing_spaces` at line 2 column 15",
            ),
        ]);
    }

    #[test]
    fn a_value_of_the_wrong_type_or_an_unknown_key_names_the_key_and_the_place() {
        crate::config::refusals(&[
            (
                "app:\n  font: {thicken: 1}\n",
                "app: font: thicken: invalid type: string \"1\", expected a boolean at line 2 column 19",
            ),
            (
                "app:\n  fonts: {}\n",
                "app: unknown field `fonts`, expected one of `theme`, `font`, `keyboard`, `mouse`, `clipboard`, `window`, `webview`, `keys` at line 2 column 3",
            ),
            (
                "app:\n  font: {colour: red}\n",
                "app: font: unknown field `colour`, expected one of `family`, `size`, `features`, `thicken`, `line_height` at line 2 column 10",
            ),
            (
                "app:\n  mouse: {scroll_multiplier: {rows: 3}}\n",
                "app: mouse: scroll_multiplier: unknown field `rows`, expected `precision` or `discrete` at line 2 column 31",
            ),
            (
                "app:\n  window: {sidebar: 1}\n",
                "app: window: unknown field `sidebar`, expected `sidebar_shade` or `unfocused_shift` at line 2 column 12",
            ),
            (
                "app: [a]\n",
                "app: invalid type: sequence, expected struct App at line 1 column 6",
            ),
        ]);
    }

    #[test]
    fn a_key_binding_is_a_trigger_and_an_action_and_refuses_the_triggers_of_a_menu() {
        let found =
            app("app:\n  keys:\n    cmd+opt+e: esc:b\n    ctrl+shift+a: increase_font_size:2\n");
        let keys: Vec<_> = found
            .keys
            .iter()
            .map(|(trigger, action)| (String::from(trigger.clone()), String::from(action.clone())))
            .collect();
        assert_eq!(
            keys,
            [
                ("ctrl+shift+a".to_owned(), "increase_font_size:2".to_owned()),
                ("super+alt+e".to_owned(), "esc:b".to_owned()),
            ]
        );
        crate::config::refusals(&[
            (
                "app:\n  keys:\n    super+d: unbind\n",
                "app: keys: \"super+d\" belongs to a menu of the app at line 3 column 5",
            ),
            (
                "app:\n  keys:\n    super+e: nothing\n",
                "app: keys: super+e: \"nothing\" is not an action at line 3 column 14",
            ),
            (
                "app:\n  keys:\n    super+: unbind\n",
                "app: keys: \"super+\" has no key at line 3 column 5",
            ),
            (
                "app:\n  keys: [a]\n",
                "app: keys: invalid type: sequence, expected a map at line 2 column 9",
            ),
        ]);
    }
}
