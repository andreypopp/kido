use std::fmt;
use std::time::{Duration, Instant};

use ko_pane_wire::frame::{self, KeyAction, KeyCode, MouseAction, MouseButton};
use ko_vt::input::key as k;
use vte::{Params, Parser, Perform};

const ESCAPE_WAIT: Duration = Duration::from_millis(50);
const INCOMPLETE_WAIT: Duration = Duration::from_millis(100);
const PASTE_WAIT: Duration = Duration::from_secs(5);
const MAX_SEQUENCE: usize = 4096;
const MAX_PASTE: usize = 16 << 20;
const ESC: u8 = 0x1b;
const PASTE_START: &[u8] = b"\x1b[200~";
const PASTE_END: &[u8] = b"\x1b[201~";
const US_PAIRS: &[u8] = b"1!2@3#4$5%6^7&8*9(0)-_=+[{]}\\|;:'\",<.>/?`~";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Mods(u8);

impl Mods {
    const SHIFT: u8 = 1;
    const ALT: u8 = 2;
    const CTRL: u8 = 4;
    const SUPER: u8 = 8;
    const HYPER: u8 = 16;
    const META: u8 = 32;
    const CAPS: u8 = 64;
    const NUM: u8 = 128;

    fn of(bits: u8) -> Mods {
        Mods(if bits & Mods::ALT != 0 {
            bits | Mods::META
        } else {
            bits
        })
    }

    fn has(self, flag: u8) -> bool {
        self.0 & flag != 0
    }

    pub(crate) fn shift(self) -> bool {
        self.has(Mods::SHIFT)
    }

    pub(crate) fn ctrl(self) -> bool {
        self.has(Mods::CTRL)
    }

    fn wire(self, shift: bool) -> u16 {
        [
            (shift || self.has(Mods::SHIFT), 1),
            (self.has(Mods::CTRL), 2),
            (self.has(Mods::ALT) || self.has(Mods::META), 4),
            (self.has(Mods::SUPER), 8),
            (self.has(Mods::CAPS), 16),
            (self.has(Mods::NUM), 32),
        ]
        .iter()
        .fold(0, |bits, (on, bit)| bits | if *on { *bit } else { 0 })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Name {
    Char(char),
    Enter,
    Tab,
    Backspace,
    Delete,
    End,
    Home,
    Insert,
    PageDown,
    PageUp,
    Down,
    Left,
    Right,
    Up,
    Escape,
    F(u8),
    Other(u16),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Press,
    Repeat,
    Release,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct KeyEvent {
    pub(crate) name: Name,
    pub(crate) mods: Mods,
    pub(crate) kind: Kind,
    text: String,
    shifted: Option<char>,
}

impl KeyEvent {
    fn named(name: Name, mods: u8, kind: Kind) -> KeyEvent {
        KeyEvent {
            name,
            mods: Mods::of(mods),
            kind,
            text: String::new(),
            shifted: None,
        }
    }

    pub(crate) fn pressed(&self) -> KeyEvent {
        KeyEvent {
            kind: Kind::Press,
            ..self.clone()
        }
    }

    fn typed(c: char, mods: u8) -> KeyEvent {
        KeyEvent {
            text: c.to_string(),
            ..KeyEvent::named(Name::Char(c), mods, Kind::Press)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MouseKind {
    Down(MouseButton),
    Up(MouseButton),
    Drag(MouseButton),
    Move,
    Scroll { up: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct MouseEvent {
    pub(crate) kind: MouseKind,
    pub(crate) x: usize,
    pub(crate) y: usize,
    mods: Mods,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Reply {
    Modes(Vec<(u16, u16)>),
    Kitty,
    Da1,
    Xtversion(String),
    Clipboard(ko_pane_wire::frame::ClipboardLocation, Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Event {
    Key(KeyEvent),
    Mouse(MouseEvent),
    Paste(String),
    Focus(bool),
    Reply(Reply),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Command {
    ToggleSidebar,
    Pager,
    New,
    Remove,
    Previous,
    Next,
    Detach,
}

pub(crate) fn command(event: &KeyEvent) -> Option<Command> {
    let m = event.mods;
    if !m.ctrl() || m.has(Mods::ALT | Mods::SUPER | Mods::HYPER | Mods::META) {
        return None;
    }
    match (event.kind, event.name) {
        (Kind::Release, _) => None,
        (_, Name::Char('d')) if !m.shift() => Some(Command::Remove),
        _ if !m.shift() => None,
        (_, Name::Char(c)) => match c {
            's' | 'S' => Some(Command::ToggleSidebar),
            'e' | 'E' => Some(Command::Pager),
            'n' | 'N' => Some(Command::New),
            'q' | 'Q' => Some(Command::Detach),
            _ => None,
        },
        (_, Name::Up) => Some(Command::Previous),
        (_, Name::Down) => Some(Command::Next),
        _ => None,
    }
}

fn flip(up: bool, c: u32) -> u32 {
    let ascii = if up {
        (97..=122).contains(&c)
    } else {
        (65..=90).contains(&c)
    };
    let latin = if up {
        (0xe0..=0xfe).contains(&c)
    } else {
        (0xc0..=0xde).contains(&c)
    };
    if ascii || (latin && c != 0xd7 && c != 0xf7) {
        if up { c - 32 } else { c + 32 }
    } else if c > 127 {
        c
    } else {
        let paired = u8::try_from(c)
            .ok()
            .and_then(|byte| US_PAIRS.iter().position(|pair| *pair == byte))
            .filter(|i| i % 2 == usize::from(!up));
        match paired {
            Some(i) => {
                let other = if up { i + 1 } else { i - 1 };
                US_PAIRS.get(other).map_or(c, |pair| u32::from(*pair))
            }
            None => c,
        }
    }
}

fn utf8(c: u32) -> String {
    char::from_u32(c).map(String::from).unwrap_or_default()
}

fn char_code(c: u32) -> u16 {
    let offset = |base: u32, first: u16| u16::try_from(c - base).map_or(0, |n| first + n);
    match char::from_u32(c) {
        Some('a'..='z') => offset(97, k::A),
        Some('A'..='Z') => offset(65, k::A),
        Some('0'..='9') => offset(48, k::DIGIT_0),
        Some('`') => k::BACKQUOTE,
        Some('\\') => k::BACKSLASH,
        Some('[') => k::BRACKET_LEFT,
        Some(']') => k::BRACKET_RIGHT,
        Some(',') => k::COMMA,
        Some('=') => k::EQUAL,
        Some('-') => k::MINUS,
        Some('.') => k::PERIOD,
        Some('\'') => k::QUOTE,
        Some(';') => k::SEMICOLON,
        Some('/') => k::SLASH,
        Some(' ') => k::SPACE,
        _ => 0,
    }
}

fn name_code(name: Name) -> u16 {
    match name {
        Name::Char(_) => 0,
        Name::Backspace => k::BACKSPACE,
        Name::Enter => k::ENTER,
        Name::Tab => k::TAB,
        Name::Delete => k::DELETE,
        Name::End => k::END,
        Name::Home => k::HOME,
        Name::Insert => k::INSERT,
        Name::PageDown => k::PAGE_DOWN,
        Name::PageUp => k::PAGE_UP,
        Name::Down => k::ARROW_DOWN,
        Name::Left => k::ARROW_LEFT,
        Name::Right => k::ARROW_RIGHT,
        Name::Up => k::ARROW_UP,
        Name::Escape => k::ESCAPE,
        Name::F(n) if (1..=25).contains(&n) => k::F1 + u16::from(n) - 1,
        Name::F(_) => 0,
        Name::Other(code) => code,
    }
}

pub(crate) fn key(event: &KeyEvent) -> Option<frame::Key> {
    let typed = match event.name {
        Name::Char(c) => u32::from(c),
        _ => 0,
    };
    let unshifted = flip(false, typed);
    let code = match event.name {
        Name::Char(_) => char_code(unshifted),
        name => name_code(name),
    };
    let m = event.mods;
    let text = if matches!(event.name, Name::Char(_))
        && m.shift()
        && typed == unshifted
        && event.shifted.is_none()
        && !m.has(Mods::CTRL | Mods::SUPER | Mods::HYPER)
        && event.text == utf8(typed)
    {
        utf8(flip(true, typed))
    } else {
        event.text.clone()
    };
    Some(frame::Key {
        action: match event.kind {
            Kind::Release => KeyAction::Release,
            Kind::Press => KeyAction::Press,
            Kind::Repeat => KeyAction::Repeat,
        },
        key: KeyCode::new(code)?,
        mods: m.wire(typed != unshifted),
        unshifted: char::from_u32(unshifted)?,
        text,
        composing: false,
    })
}

pub(crate) fn mouse(pane_x: usize, event: &MouseEvent) -> frame::Mouse {
    let (action, button) = match event.kind {
        MouseKind::Down(button) => (MouseAction::Press, button),
        MouseKind::Up(button) => (MouseAction::Release, button),
        MouseKind::Drag(button) => (MouseAction::Motion, button),
        MouseKind::Move => (MouseAction::Motion, MouseButton::Unknown),
        MouseKind::Scroll { up: true } => (MouseAction::Press, MouseButton::Four),
        MouseKind::Scroll { up: false } => (MouseAction::Press, MouseButton::Five),
    };
    frame::Mouse {
        action,
        button,
        col: u16::try_from(event.x.saturating_sub(pane_x)).unwrap_or(u16::MAX),
        row: u16::try_from(event.y).unwrap_or(u16::MAX),
        mods: event.mods.wire(false),
    }
}

fn pua_key(code: u32) -> Name {
    let other = Name::Other;
    match code {
        57344 => Name::Escape,
        57345 => Name::Enter,
        57346 => Name::Tab,
        57347 => Name::Backspace,
        57348 => Name::Insert,
        57349 => Name::Delete,
        57350 => Name::Left,
        57351 => Name::Right,
        57352 => Name::Up,
        57353 => Name::Down,
        57354 => Name::PageUp,
        57355 => Name::PageDown,
        57356 => Name::Home,
        57357 => Name::End,
        57358 => other(k::CAPS_LOCK),
        57359 => other(k::SCROLL_LOCK),
        57360 => other(k::NUM_LOCK),
        57361 => other(k::PRINT_SCREEN),
        57362 => other(k::PAUSE),
        57363 => other(k::CONTEXT_MENU),
        57364..=57398 => Name::F(u8::try_from(code - 57363).unwrap_or(0)),
        57399..=57408 => other(u16::try_from(code - 57399).map_or(0, |n| k::NUMPAD_0 + n)),
        57409 => other(k::NUMPAD_DECIMAL),
        57410 => other(k::NUMPAD_DIVIDE),
        57411 => other(k::NUMPAD_MULTIPLY),
        57412 => other(k::NUMPAD_SUBTRACT),
        57413 => other(k::NUMPAD_ADD),
        57414 => other(k::NUMPAD_ENTER),
        57415 => other(k::NUMPAD_EQUAL),
        57416 => other(k::NUMPAD_SEPARATOR),
        57417 => other(k::NUMPAD_LEFT),
        57418 => other(k::NUMPAD_RIGHT),
        57419 => other(k::NUMPAD_UP),
        57420 => other(k::NUMPAD_DOWN),
        57421 => other(k::NUMPAD_PAGE_UP),
        57422 => other(k::NUMPAD_PAGE_DOWN),
        57423 => other(k::NUMPAD_HOME),
        57424 => other(k::NUMPAD_END),
        57425 => other(k::NUMPAD_INSERT),
        57426 => other(k::NUMPAD_DELETE),
        57427 => other(k::NUMPAD_BEGIN),
        57430 => other(k::MEDIA_PLAY_PAUSE),
        57432 => other(k::MEDIA_STOP),
        57435 => other(k::MEDIA_TRACK_NEXT),
        57436 => other(k::MEDIA_TRACK_PREVIOUS),
        57438 => other(k::AUDIO_VOLUME_DOWN),
        57439 => other(k::AUDIO_VOLUME_UP),
        57440 => other(k::AUDIO_VOLUME_MUTE),
        57441 => other(k::SHIFT_LEFT),
        57442 => other(k::CONTROL_LEFT),
        57443 => other(k::ALT_LEFT),
        57444 | 57446 => other(k::META_LEFT),
        57447 => other(k::SHIFT_RIGHT),
        57448 => other(k::CONTROL_RIGHT),
        57449 => other(k::ALT_RIGHT),
        57450 | 57452 => other(k::META_RIGHT),
        _ => other(0),
    }
}

fn tilde_key(code: u16) -> Option<Name> {
    Some(match code {
        1 | 7 => Name::Home,
        2 => Name::Insert,
        3 => Name::Delete,
        4 | 8 => Name::End,
        5 => Name::PageUp,
        6 => Name::PageDown,
        11..=15 => Name::F(u8::try_from(code - 10).ok()?),
        17..=21 => Name::F(u8::try_from(code - 11).ok()?),
        23..=26 => Name::F(u8::try_from(code - 12).ok()?),
        28 | 29 => Name::F(u8::try_from(code - 13).ok()?),
        31..=34 => Name::F(u8::try_from(code - 14).ok()?),
        _ => return None,
    })
}

fn button_of(code: u16) -> MouseButton {
    match code {
        0 | 3 => MouseButton::Left,
        1 => MouseButton::Middle,
        2 => MouseButton::Right,
        128 => MouseButton::Eight,
        129 => MouseButton::Nine,
        130 => MouseButton::Ten,
        131 => MouseButton::Eleven,
        _ => MouseButton::Unknown,
    }
}

fn kind_of(event: u16) -> Kind {
    match event {
        2 => Kind::Repeat,
        3 => Kind::Release,
        _ => Kind::Press,
    }
}

fn control_key(byte: u8) -> Option<KeyEvent> {
    Some(match byte {
        0 => KeyEvent::typed(' ', Mods::CTRL),
        8 | 127 => KeyEvent::named(Name::Backspace, 0, Kind::Press),
        9 => KeyEvent::named(Name::Tab, 0, Kind::Press),
        10 | 13 => KeyEvent::named(Name::Enter, 0, Kind::Press),
        _ => KeyEvent::named(Name::Char(ctrl_char(byte)?), Mods::CTRL, Kind::Press),
    })
}

fn values(params: &Params) -> Vec<u16> {
    params
        .iter()
        .map(|param| param.first().copied().unwrap_or(0))
        .collect()
}

fn bits_of(mods: u32) -> u8 {
    u8::try_from(mods.saturating_sub(1)).unwrap_or(0)
}

fn mods_param(params: &Params) -> (u8, Kind) {
    let second = params.iter().nth(1);
    let mods = second.and_then(|param| param.first().copied());
    let kind = second.and_then(|param| param.get(1).copied());
    (
        mods.map_or(0, |mods| bits_of(u32::from(mods))),
        kind_of(kind.unwrap_or(1)),
    )
}

fn number(field: &[u8], limit: u32) -> Option<u32> {
    if field.is_empty() || !field.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let value = std::str::from_utf8(field).ok()?.parse::<u32>().ok()?;
    (value <= limit).then_some(value)
}

fn kitty_key(body: &[u8]) -> Option<KeyEvent> {
    let mut fields = body.split(|b| *b == b';');
    let mut codes = fields.next()?.split(|b| *b == b':');
    let code = codes.next().and_then(|c| number(c, 0x10ffff))?;
    let shifted = codes
        .next()
        .and_then(|c| number(c, 0x10ffff))
        .filter(|c| *c > 0)
        .and_then(char::from_u32);
    let mut second = fields.next().unwrap_or_default().split(|b| *b == b':');
    let bits = bits_of(second.next().and_then(|m| number(m, 255)).unwrap_or(1));
    let kind = kind_of(
        second
            .next()
            .and_then(|e| number(e, 3))
            .map_or(1, |e| u16::try_from(e).unwrap_or(1)),
    );
    let text: String = fields
        .next()
        .unwrap_or_default()
        .split(|b| *b == b':')
        .filter_map(|c| number(c, 0x10ffff))
        .filter(|c| *c > 0)
        .filter_map(char::from_u32)
        .collect();
    let name = match code {
        0 => return None,
        9 => Name::Tab,
        13 => Name::Enter,
        27 => Name::Escape,
        127 => Name::Backspace,
        57344..=63743 => pua_key(code),
        _ => Name::Char(char::from_u32(code)?),
    };
    let mods = Mods::of(bits);
    let text = match name {
        Name::Char(c) if text.is_empty() => {
            shifted.filter(|_| mods.shift()).unwrap_or(c).to_string()
        }
        _ => text,
    };
    Some(KeyEvent {
        name,
        mods,
        kind,
        text,
        shifted,
    })
}

#[derive(Debug, Default)]
struct Collector {
    events: Vec<Event>,
    dcs: Option<Vec<u8>>,
    pressed: Option<MouseButton>,
}

impl Collector {
    fn key(&mut self, name: Name, bits: u8, kind: Kind) {
        self.events
            .push(Event::Key(KeyEvent::named(name, bits, kind)));
    }

    fn sgr_mouse(&mut self, params: &Params, release: bool) {
        let [btn, x, y] = values(params)[..] else {
            return;
        };
        let code = btn & 3 | (btn >> 6) << 6;
        let scroll = code & 64 != 0;
        let motion = btn & 32 != 0 && !scroll;
        let released = release && !scroll && !motion;
        let button = button_of(code);
        let kind = if scroll {
            MouseKind::Scroll { up: code & 3 == 0 }
        } else if motion {
            self.pressed.map_or(MouseKind::Move, MouseKind::Drag)
        } else if released {
            self.pressed = None;
            MouseKind::Up(button)
        } else {
            if matches!(
                button,
                MouseButton::Left | MouseButton::Middle | MouseButton::Right
            ) {
                self.pressed = Some(button);
            }
            MouseKind::Down(button)
        };
        self.events.push(Event::Mouse(MouseEvent {
            kind,
            x: usize::from(x.saturating_sub(1)),
            y: usize::from(y.saturating_sub(1)),
            mods: Mods::of(u8::try_from((btn & 0x1c) >> 2).unwrap_or(0)),
        }));
    }

    fn urxvt_mouse(&mut self, params: &Params) {
        let [btn, x, y] = values(params)[..] else {
            return;
        };
        let base = i32::from(btn) - 32;
        let code = base & 3 | (base >> 6) << 6;
        let scroll = code & 64 != 0;
        let motion = base & 32 != 0 && !scroll;
        let button = button_of(u16::try_from(code).unwrap_or(0));
        let kind = if scroll {
            MouseKind::Scroll { up: code & 3 == 0 }
        } else if motion {
            MouseKind::Drag(button)
        } else if code == 3 {
            MouseKind::Up(MouseButton::Left)
        } else {
            MouseKind::Down(button)
        };
        self.events.push(Event::Mouse(MouseEvent {
            kind,
            x: usize::from(x.saturating_sub(1)),
            y: usize::from(y.saturating_sub(1)),
            mods: Mods::of(u8::try_from((base & 0x1c) >> 2).unwrap_or(0)),
        }));
    }

    fn modified_key(&mut self, params: &Params) {
        let [27, mods, code, ..] = values(params)[..] else {
            return;
        };
        let name = match code {
            13 => Name::Enter,
            27 => Name::Escape,
            9 => Name::Tab,
            127 | 8 => Name::Backspace,
            code => Name::Char(char::from_u32(u32::from(code)).unwrap_or('\0')),
        };
        self.key(name, bits_of(u32::from(mods)), Kind::Press);
    }
}

fn ctrl_char(byte: u8) -> Option<char> {
    match byte {
        0 => Some(' '),
        1..=26 => Some(char::from(b'a' + byte - 1)),
        28 => Some('\\'),
        29 => Some(']'),
        30 => Some('^'),
        31 => Some('_'),
        _ => None,
    }
}

fn alt_key(byte: u8) -> Option<KeyEvent> {
    let alt = |name| Some(KeyEvent::named(name, Mods::ALT, Kind::Press));
    match byte {
        b'\t' => alt(Name::Tab),
        b'\n' | b'\r' => alt(Name::Enter),
        0..=0x1f => Some(match ctrl_char(byte) {
            Some(c) => KeyEvent::named(Name::Char(c), Mods::ALT | Mods::CTRL, Kind::Press),
            None => KeyEvent::named(Name::Char(char::from(byte)), Mods::ALT, Kind::Press),
        }),
        0x7f => alt(Name::Backspace),
        b' ' => alt(Name::Char(' ')),
        b'!'..=b'~' => Some(KeyEvent::named(
            Name::Char(char::from(byte)),
            Mods::ALT
                | if byte.is_ascii_uppercase() {
                    Mods::SHIFT
                } else {
                    0
                },
            Kind::Press,
        )),
        _ => None,
    }
}

fn ss3_key(byte: u8) -> Option<KeyEvent> {
    let key = |name, bits| Some(KeyEvent::named(name, bits, Kind::Press));
    match byte {
        b'A' => key(Name::Up, 0),
        b'B' => key(Name::Down, 0),
        b'C' => key(Name::Right, 0),
        b'D' => key(Name::Left, 0),
        b'F' => key(Name::End, 0),
        b'H' => key(Name::Home, 0),
        b'P'..=b'S' => key(Name::F(byte - b'P' + 1), 0),
        b'a' => key(Name::Up, Mods::CTRL),
        b'b' => key(Name::Down, Mods::CTRL),
        b'c' => key(Name::Right, Mods::CTRL),
        b'd' => key(Name::Left, Mods::CTRL),
        b'e' => key(Name::Other(k::NUMPAD_5), Mods::CTRL),
        b'X' => Some(KeyEvent::typed('=', 0)),
        _ => None,
    }
}

fn escape_key(seq: &[u8]) -> Option<KeyEvent> {
    match (seq.get(1), seq.get(2), seq.get(3)) {
        (None, ..) => Some(KeyEvent::named(Name::Escape, 0, Kind::Press)),
        (Some(&ESC), None, _) => Some(KeyEvent::named(Name::Escape, Mods::ALT, Kind::Press)),
        (Some(b'['), Some(b'['), Some(&last)) if seq.len() == 4 => match last {
            b'A'..=b'E' => Some(KeyEvent::named(Name::F(last - b'A' + 1), 0, Kind::Press)),
            _ => None,
        },
        (Some(b'['), ..) | (Some(b']'), ..) => None,
        (Some(b'O'), Some(&third), _) => ss3_key(third),
        (Some(&second), ..) => alt_key(second),
    }
}

fn x10_mouse(raw: &[u8]) -> Option<MouseEvent> {
    let [button, x, y] = raw[..] else {
        return None;
    };
    let cb = u16::from(button).checked_sub(32)?;
    let (x, y) = (
        usize::from(x.checked_sub(33)?),
        usize::from(y.checked_sub(33)?),
    );
    let base = cb & 3;
    let kind = if cb & 64 != 0 {
        MouseKind::Scroll { up: base == 0 }
    } else if cb & 32 != 0 {
        if base == 3 {
            MouseKind::Move
        } else {
            MouseKind::Drag(button_of(base))
        }
    } else if base == 3 {
        MouseKind::Up(MouseButton::Left)
    } else {
        MouseKind::Down(button_of(base))
    };
    Some(MouseEvent {
        kind,
        x,
        y,
        mods: Mods::of(u8::try_from((cb & 0x1c) >> 2).unwrap_or(0)),
    })
}

enum End {
    Incomplete,
    Restart(usize),
    Token(usize),
}

fn csi_final(byte: u8) -> bool {
    (b'@'..=b'~').contains(&byte)
}

fn find_end(bytes: &[u8]) -> End {
    let Some(&second) = bytes.get(1) else {
        return End::Incomplete;
    };
    let escape_in = |from: usize, to: usize| {
        bytes
            .get(from..to.min(bytes.len()))
            .and_then(|range| range.iter().position(|b| *b == ESC))
            .map(|at| at + from)
    };
    match second {
        b'[' if bytes.get(2) == Some(&b'M') => match escape_in(3, 6) {
            Some(at) => End::Restart(at),
            None if bytes.len() >= 6 => End::Token(6),
            None => End::Incomplete,
        },
        b'[' if bytes.get(2) == Some(&b'[') => match bytes.get(3) {
            None => End::Incomplete,
            Some(b'A'..=b'E') => End::Token(4),
            Some(_) => End::Token(3),
        },
        b'[' => {
            let mut semicolon = false;
            for (i, &c) in bytes.iter().enumerate().skip(2) {
                if c == ESC {
                    return End::Restart(i);
                }
                if c == b'$' {
                    if bytes.get(2) == Some(&b'?') || semicolon {
                        if i + 1 >= bytes.len() {
                            return End::Incomplete;
                        }
                        continue;
                    }
                    return End::Token(i + 1);
                }
                if csi_final(c) {
                    return End::Token(i + 1);
                }
                semicolon |= c == b';';
            }
            End::Incomplete
        }
        b']' | b'P' | b'_' => {
            for (i, &c) in bytes.iter().enumerate().skip(2) {
                if c == 7 && second == b']' {
                    return End::Token(i + 1);
                }
                if c == ESC {
                    return match bytes.get(i + 1) {
                        None => End::Incomplete,
                        Some(b'\\') => End::Token(i + 2),
                        Some(_) => End::Restart(i),
                    };
                }
            }
            End::Incomplete
        }
        b'O' => match bytes.get(2) {
            None => End::Incomplete,
            Some(&ESC) => End::Restart(2),
            Some(_) => End::Token(3),
        },
        _ => End::Token(2),
    }
}

fn partial_sgr_mouse(seq: &[u8]) -> bool {
    seq.starts_with(b"\x1b[<") && seq.iter().skip(3).all(|b| b.is_ascii_digit() || *b == b';')
}

impl Perform for Collector {
    fn print(&mut self, c: char) {
        if c == '\u{7f}' {
            self.key(Name::Backspace, 0, Kind::Press);
            return;
        }
        let upper = c.is_ascii_uppercase();
        self.events.push(Event::Key(KeyEvent::typed(
            c,
            if upper { Mods::SHIFT } else { 0 },
        )));
    }

    fn execute(&mut self, byte: u8) {
        if let Some(event) = control_key(byte) {
            self.events.push(Event::Key(event));
        }
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        self.dcs = (intermediates == b">" && action == '|').then(Vec::new);
    }

    fn put(&mut self, byte: u8) {
        if let Some(text) = self.dcs.as_mut() {
            text.push(byte);
        }
    }

    fn unhook(&mut self) {
        if let Some(text) = self.dcs.take() {
            self.events.push(Event::Reply(Reply::Xtversion(
                String::from_utf8_lossy(&text).into_owned(),
            )));
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if let [b"52", selector, data] = params
            && let Some(location) = frame::ClipboardLocation::of_selector(selector)
            && let Some(text) = std::str::from_utf8(data)
                .ok()
                .and_then(ko_pane_wire::base64::decode)
        {
            self.events
                .push(Event::Reply(Reply::Clipboard(location, text)));
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        if ignore {
            return;
        }
        let first = |index: usize| params.iter().nth(index).and_then(|p| p.first().copied());
        let (bits, kind) = mods_param(params);
        match (intermediates, action) {
            (b"<", 'M' | 'm') => self.sgr_mouse(params, action == 'm'),
            (b"?$", 'y') => {
                let modes = values(params)
                    .chunks(2)
                    .filter_map(|pair| match pair {
                        [mode, value] => Some((*mode, *value)),
                        _ => None,
                    })
                    .collect();
                self.events.push(Event::Reply(Reply::Modes(modes)));
            }
            (b"?", 'u') => self.events.push(Event::Reply(Reply::Kitty)),
            (b"?", 'c') => self.events.push(Event::Reply(Reply::Da1)),
            (b"", 'I') => self.events.push(Event::Focus(true)),
            (b"", 'O') => self.events.push(Event::Focus(false)),
            (b"", 'Z') => self.key(Name::Tab, bits | Mods::SHIFT, kind),
            (b"", 'A') => self.key(Name::Up, bits, kind),
            (b"", 'B') => self.key(Name::Down, bits, kind),
            (b"", 'C') => self.key(Name::Right, bits, kind),
            (b"", 'D') => self.key(Name::Left, bits, kind),
            (b"", 'H') => self.key(Name::Home, bits, kind),
            (b"", 'F') => self.key(Name::End, bits, kind),
            (b"", 'E') => self.key(Name::Other(k::NUMPAD_5), bits, kind),
            (b"", 'a') => self.key(Name::Up, bits | Mods::SHIFT, kind),
            (b"", 'b') => self.key(Name::Down, bits | Mods::SHIFT, kind),
            (b"", 'd') => self.key(Name::Left, bits | Mods::SHIFT, kind),
            (b"", 'e') => self.key(Name::Other(k::NUMPAD_5), bits | Mods::SHIFT, kind),
            (b"", 'c') if params.len() <= 1 => self.key(Name::Right, Mods::SHIFT, Kind::Press),
            (b"", 'M' | 'm') => self.urxvt_mouse(params),
            (b"", '~') => match first(0) {
                Some(27) if params.len() >= 3 => self.modified_key(params),
                Some(code) => {
                    if let Some(name) = tilde_key(code) {
                        self.key(name, bits, kind);
                    }
                }
                None => {}
            },
            _ => {}
        }
    }
}

#[derive(Debug)]
struct Paste {
    body: Vec<u8>,
    discarding: bool,
    expires: Instant,
}

#[derive(Default)]
pub(crate) struct Input {
    parser: Parser,
    collector: Collector,
    pending: Vec<u8>,
    flush: Option<Instant>,
    grace: bool,
    paste: Option<Paste>,
}

impl fmt::Debug for Input {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Input")
            .field("pending", &self.pending)
            .field("flush", &self.flush)
            .field("paste", &self.paste.as_ref().map(|paste| paste.body.len()))
            .finish_non_exhaustive()
    }
}

impl Input {
    pub(crate) fn feed(&mut self, bytes: &[u8], now: Instant, out: &mut Vec<Event>) {
        let mut data = std::mem::take(&mut self.pending);
        data.extend_from_slice(bytes);
        self.flush = None;
        self.grace = false;
        let mut at = 0;
        while at < data.len() {
            let rest = data.get(at..).unwrap_or_default();
            if self.paste.is_some() {
                at += self.paste_bytes(rest, now, out);
                continue;
            }
            if rest.first() != Some(&ESC) {
                let run = rest.iter().position(|b| *b == ESC).unwrap_or(rest.len());
                self.parser
                    .advance(&mut self.collector, rest.get(..run).unwrap_or_default());
                at += run;
            } else if rest.starts_with(PASTE_START) {
                out.append(&mut self.collector.events);
                self.paste = Some(Paste {
                    body: Vec::new(),
                    discarding: false,
                    expires: now + PASTE_WAIT,
                });
                at += PASTE_START.len();
            } else {
                match find_end(rest) {
                    End::Incomplete => {
                        if rest.len() <= MAX_SEQUENCE {
                            self.pending = rest.to_vec();
                            let wait = if rest.len() == 1 {
                                ESCAPE_WAIT
                            } else {
                                INCOMPLETE_WAIT
                            };
                            self.flush = Some(now + wait);
                        }
                        break;
                    }
                    End::Restart(skip) => at += skip,
                    End::Token(len) => {
                        self.token(rest.get(..len).unwrap_or_default(), true);
                        at += len;
                    }
                }
            }
        }
        out.append(&mut self.collector.events);
    }

    fn token(&mut self, seq: &[u8], complete: bool) {
        let event = if !complete || seq.get(1) == Some(&ESC) {
            escape_key(seq)
        } else {
            match (seq.get(1), seq.get(2)) {
                (Some(b'['), Some(b'M')) => {
                    if let Some(mouse) = x10_mouse(seq.get(3..).unwrap_or_default()) {
                        self.collector.events.push(Event::Mouse(mouse));
                    }
                    None
                }
                (Some(b'['), Some(b'[')) | (Some(b'O'), _) => escape_key(seq),
                (Some(b'['), _)
                    if seq.last() == Some(&b'u')
                        && seq.get(2..seq.len() - 1).is_some_and(|body| {
                            body.iter().all(|b| matches!(b, b'0'..=b'9' | b':' | b';'))
                        }) =>
                {
                    kitty_key(seq.get(2..seq.len() - 1).unwrap_or_default())
                }
                (Some(b'['), _) if matches!(seq.last(), Some(b'$' | b'^')) => {
                    self.rxvt(seq);
                    None
                }
                (Some(b'[' | b']' | b'P' | b'_'), _) => {
                    self.parser.advance(&mut self.collector, seq);
                    None
                }
                _ => escape_key(seq),
            }
        };
        if let Some(event) = event {
            self.collector.events.push(Event::Key(event));
        }
    }

    fn rxvt(&mut self, seq: &[u8]) {
        let digits = seq.get(2..seq.len() - 1).unwrap_or_default();
        let code = std::str::from_utf8(digits)
            .ok()
            .filter(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|digits| digits.parse::<u16>().ok());
        let bit = if seq.last() == Some(&b'$') {
            Mods::SHIFT
        } else {
            Mods::CTRL
        };
        if let Some(name) = code.and_then(tilde_key) {
            self.collector.key(name, bit, Kind::Press);
        }
    }

    fn paste_bytes(&mut self, data: &[u8], now: Instant, out: &mut Vec<Event>) -> usize {
        let Some(paste) = self.paste.as_mut() else {
            return 0;
        };
        let from = paste.body.len().saturating_sub(PASTE_END.len());
        paste.body.extend_from_slice(data);
        paste.expires = now + PASTE_WAIT;
        let found = paste
            .body
            .get(from..)
            .and_then(|tail| tail.windows(PASTE_END.len()).position(|w| w == PASTE_END))
            .map(|at| at + from);
        let Some(at) = found else {
            if paste.body.len() > MAX_PASTE {
                paste.discarding = true;
                let keep = paste.body.len().saturating_sub(PASTE_END.len());
                paste.body.drain(..keep);
            }
            return data.len();
        };
        let consumed = data
            .len()
            .saturating_sub(paste.body.len().saturating_sub(at + PASTE_END.len()));
        paste.body.truncate(at);
        if !paste.discarding && at <= MAX_PASTE {
            out.push(Event::Paste(
                String::from_utf8_lossy(&paste.body).into_owned(),
            ));
        }
        self.paste = None;
        consumed
    }

    pub(crate) fn deadline(&self) -> Option<Instant> {
        [self.flush, self.paste.as_ref().map(|paste| paste.expires)]
            .into_iter()
            .flatten()
            .min()
    }

    pub(crate) fn expire(&mut self, now: Instant, out: &mut Vec<Event>) {
        if self
            .paste
            .as_ref()
            .is_some_and(|paste| paste.expires <= now)
        {
            self.paste = None;
        }
        if self.flush.is_some_and(|due| due <= now) {
            self.flush = None;
            let pending = std::mem::take(&mut self.pending);
            if partial_sgr_mouse(&pending) && !self.grace {
                self.grace = true;
                self.flush = Some(now + INCOMPLETE_WAIT);
                self.pending = pending;
            } else {
                self.token(&pending, false);
            }
        }
        out.append(&mut self.collector.events);
    }
}

#[cfg(test)]
mod tests {
    use ko_server::protocol::{Input as Wire, Key, ViewRequest, json};

    use super::*;

    fn parse(reads: &[&[u8]]) -> Vec<Event> {
        let mut input = Input::default();
        let mut events = Vec::new();
        let now = Instant::now();
        for read in reads {
            input.feed(read, now, &mut events);
        }
        input.expire(now + Duration::from_secs(1), &mut events);
        events
    }

    fn keys(text: &str) -> Vec<KeyEvent> {
        parse(&[text.as_bytes()])
            .into_iter()
            .filter_map(|event| match event {
                Event::Key(key) => Some(key),
                _ => None,
            })
            .collect()
    }

    fn input_json(event: &KeyEvent) -> String {
        json(&ViewRequest::Input {
            input: Wire::Key(Key(key(event).unwrap())),
        })
    }

    #[test]
    fn ctrl_shift_commands_do_not_consume_ctrl_keys() {
        let k = keys("\x1b[115;6u").remove(0);
        assert_eq!(command(&k), Some(Command::ToggleSidebar));
        let plain = KeyEvent {
            mods: Mods::of(Mods::CTRL),
            ..k.clone()
        };
        assert_eq!(command(&plain), None);
        let released = KeyEvent {
            kind: Kind::Release,
            ..k.clone()
        };
        assert_eq!(command(&released), None);
        assert_eq!(
            input_json(&k),
            r#"{"type":"input","input":{"type":"key","action":"press","key":38,"mods":3,"unshifted_codepoint":115,"text":"s","composing":false}}"#
        );
    }

    #[test]
    fn shifted_printable_keys_carry_their_text() {
        let cases = [
            "A",
            "!",
            "@",
            "\u{c9}",
            "\x1b[97;2u",
            "\x1b[97;2;65u",
            "\x1b[49;2u",
            "\x1b[49:33;2u",
            "\x1b[233:201;2u",
            "\x1b[233:201;2;201u",
            "\x1b[97;1:3u",
            "\x1b[97;2;937u",
            "\x1b[97;4u",
            "\x1b[97;6u",
            "\x1b[32;2u",
            "\x1b[13;2u",
        ];
        let shown: Vec<String> = cases
            .iter()
            .flat_map(|text| keys(text).into_iter().map(|k| input_json(&k)))
            .collect();
        let line = |action: &str, key: u16, mods: u16, unshifted: u32, text: &str| {
            format!(
                r#"{{"type":"input","input":{{"type":"key","action":"{action}","key":{key},"mods":{mods},"unshifted_codepoint":{unshifted},"text":"{text}","composing":false}}}}"#
            )
        };
        assert_eq!(
            shown,
            [
                line("press", 20, 1, 97, "A"),
                line("press", 7, 1, 49, "!"),
                line("press", 8, 1, 50, "@"),
                line("press", 0, 1, 233, "\u{c9}"),
                line("press", 20, 1, 97, "A"),
                line("press", 20, 1, 97, "A"),
                line("press", 7, 1, 49, "!"),
                line("press", 7, 1, 49, "!"),
                line("press", 0, 1, 233, "\u{c9}"),
                line("press", 0, 1, 233, "\u{c9}"),
                line("release", 20, 0, 97, "a"),
                line("press", 20, 1, 97, "\u{3a9}"),
                line("press", 20, 5, 97, "A"),
                line("press", 20, 3, 97, "a"),
                line("press", 63, 1, 32, " "),
                line("press", 58, 1, 0, ""),
            ]
        );
    }

    #[test]
    fn ctrl_d_legacy_or_csi_u_is_remove_and_ctrl_shift_w_is_no_command() {
        let shown: Vec<Option<Command>> = ["\x04", "\x1b[100;5u", "\x1b[119;6u"]
            .iter()
            .flat_map(|text| keys(text).into_iter().map(|k| command(&k)))
            .collect();
        assert_eq!(shown, [Some(Command::Remove), Some(Command::Remove), None]);
    }

    #[test]
    fn replies_together_or_split_across_reads_are_not_keys() {
        let whole: &[u8] = b"\x1bP>|kitty(0.35.2)\x1b\\\x1b[?1u\x1b[?62;22c\x1b_Gi=1;OK\x1b\\";
        let split: [&[u8]; 3] = [
            b"\x1bP>|kit",
            b"ty(0.35.2)\x1b\\\x1b[?",
            b"1u\x1b[?62;22c\x1b_Gi=1;OK\x1b\\",
        ];
        for reads in [&[whole][..], &split[..]] {
            assert_eq!(
                parse(reads),
                [
                    Event::Reply(Reply::Xtversion("kitty(0.35.2)".to_owned())),
                    Event::Reply(Reply::Kitty),
                    Event::Reply(Reply::Da1),
                ]
            );
        }
    }

    #[test]
    fn a_lone_escape_waits_fifty_milliseconds_and_a_split_sequence_is_not_an_escape() {
        let mut input = Input::default();
        let (mut events, now) = (Vec::new(), Instant::now());
        input.feed(b"\x1b", now, &mut events);
        assert_eq!(
            (events.len(), input.deadline()),
            (0, Some(now + ESCAPE_WAIT))
        );
        input.feed(b"[A", now, &mut events);
        assert_eq!(events.len(), 1);
        assert_eq!(input.deadline(), None);
        input.feed(b"\x1b", now, &mut events);
        input.expire(now + Duration::from_millis(49), &mut events);
        assert_eq!(events.len(), 1);
        input.expire(now + ESCAPE_WAIT, &mut events);
        assert!(matches!(
            events.last(),
            Some(Event::Key(KeyEvent {
                name: Name::Escape,
                ..
            }))
        ));
    }

    #[test]
    fn mouse_focus_and_paste_arrive_whole_or_split() {
        let events = parse(&[
            b"\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;40;5M\x1b[I\x1b[O\x1b[200~ab",
            b"c\x1b[201~z",
        ]);
        let mouse = |kind, x, y| {
            Event::Mouse(MouseEvent {
                kind,
                x,
                y,
                mods: Mods::default(),
            })
        };
        assert_eq!(
            events[..5],
            [
                mouse(MouseKind::Down(MouseButton::Left), 2, 1),
                mouse(MouseKind::Up(MouseButton::Left), 2, 1),
                mouse(MouseKind::Scroll { up: true }, 39, 4),
                Event::Focus(true),
                Event::Focus(false),
            ]
        );
        assert_eq!(events[5], Event::Paste("abc".to_owned()));
        assert!(matches!(events.get(6), Some(Event::Key(k)) if k.name == Name::Char('z')));
    }

    #[test]
    fn every_kitty_functional_key_has_a_valid_code() {
        for code in 57344..=63743 {
            let event = KeyEvent::named(pua_key(code), 0, Kind::Press);
            assert!(key(&event).is_some(), "{code}");
        }
    }

    fn shown(reads: &[&[u8]]) -> Vec<String> {
        parse(reads)
            .into_iter()
            .map(|event| match event {
                Event::Key(k) => format!("{:?} mods={} text={:?}", k.name, k.mods.0, k.text),
                Event::Mouse(m) => format!("{:?} at {},{} mods={}", m.kind, m.x, m.y, m.mods.0),
                other => format!("{other:?}"),
            })
            .collect()
    }

    fn expect(name: &str, mods: u8) -> String {
        format!("{name} mods={mods} text=\"\"")
    }

    const ALT: u8 = Mods::ALT | Mods::META;

    #[test]
    fn legacy_alt_prefixes_follow_matrix() {
        let cases: [(&[u8], String); 15] = [
            (b"\x1b\x01", expect("Char('a')", ALT | Mods::CTRL)),
            (b"\x1b\x00", expect("Char(' ')", ALT | Mods::CTRL)),
            (b"\x1b\x1c", expect("Char('\\\\')", ALT | Mods::CTRL)),
            (b"\x1b\x08", expect("Char('h')", ALT | Mods::CTRL)),
            (b"\x1b\t", expect("Tab", ALT)),
            (b"\x1b\r", expect("Enter", ALT)),
            (b"\x1b\n", expect("Enter", ALT)),
            (b"\x1b ", expect("Char(' ')", ALT)),
            (b"\x1b\x7f", expect("Backspace", ALT)),
            (b"\x1bx", expect("Char('x')", ALT)),
            (b"\x1bX", expect("Char('X')", ALT | Mods::SHIFT)),
            (b"\x1b^", expect("Char('^')", ALT)),
            (b"\x1b7", expect("Char('7')", ALT)),
            (b"\x1b\x1b", expect("Escape", ALT)),
            (b"\x1b\x80", String::new()),
        ];
        for (bytes, expected) in cases {
            let expected: Vec<String> = Some(expected)
                .filter(|s| !s.is_empty())
                .into_iter()
                .collect();
            assert_eq!(shown(&[bytes]), expected, "{bytes:?}");
        }
    }

    #[test]
    fn ss3_rxvt_and_console_keys_follow_matrix() {
        let cases: [(&[u8], String); 17] = [
            (b"\x1bOA", expect("Up", 0)),
            (b"\x1bOH", expect("Home", 0)),
            (b"\x1bOP", expect("F(1)", 0)),
            (b"\x1bOS", expect("F(4)", 0)),
            (b"\x1bOa", expect("Up", Mods::CTRL)),
            (b"\x1bOd", expect("Left", Mods::CTRL)),
            (b"\x1bOe", expect("Other(85)", Mods::CTRL)),
            (b"\x1b[a", expect("Up", Mods::SHIFT)),
            (b"\x1b[e", expect("Other(85)", Mods::SHIFT)),
            (b"\x1b[E", expect("Other(85)", 0)),
            (b"\x1b[c", expect("Right", Mods::SHIFT)),
            (b"\x1b[3$", expect("Delete", Mods::SHIFT)),
            (b"\x1b[3^", expect("Delete", Mods::CTRL)),
            (b"\x1b[[A", expect("F(1)", 0)),
            (b"\x1b[[E", expect("F(5)", 0)),
            (b"\x1b[[F", "Char('F') mods=1 text=\"F\"".to_owned()),
            (b"\x1b[3;5$", String::new()),
        ];
        for (bytes, expected) in cases {
            let expected: Vec<String> = Some(expected)
                .filter(|s| !s.is_empty())
                .into_iter()
                .collect();
            assert_eq!(shown(&[bytes]), expected, "{bytes:?}");
        }
        assert_eq!(shown(&[b"\x1bOX"]), ["Char('=') mods=0 text=\"=\""]);
    }

    #[test]
    fn x10_and_urxvt_mouse_follow_matrix() {
        let cases: [(&[u8], &str); 13] = [
            (b"\x1b[M %#", "Down(Left) at 4,2 mods=0"),
            (b"\x1b[M\"%#", "Down(Right) at 4,2 mods=0"),
            (b"\x1b[M#%#", "Up(Left) at 4,2 mods=0"),
            (b"\x1b[M`%#", "Scroll { up: true } at 4,2 mods=0"),
            (b"\x1b[Ma%#", "Scroll { up: false } at 4,2 mods=0"),
            (b"\x1b[M@%#", "Drag(Left) at 4,2 mods=0"),
            (b"\x1b[MC%#", "Move at 4,2 mods=0"),
            (b"\x1b[M0%#", "Down(Left) at 4,2 mods=4"),
            (b"\x1b[32;5;6M", "Down(Left) at 4,5 mods=0"),
            (b"\x1b[35;5;6M", "Up(Left) at 4,5 mods=0"),
            (b"\x1b[96;5;6M", "Scroll { up: true } at 4,5 mods=0"),
            (b"\x1b[64;5;6M", "Drag(Left) at 4,5 mods=0"),
            (b"\x1b[34;5;6M", "Down(Right) at 4,5 mods=0"),
        ];
        for (bytes, expected) in cases {
            assert_eq!(shown(&[bytes]), [expected], "{bytes:?}");
        }
        assert_eq!(shown(&[b"\x1b[M\x1b"]), [expect("Escape", 0)]);
    }

    #[test]
    fn an_incomplete_sequence_becomes_keys_after_a_hundred_milliseconds() {
        let at = |input: &mut Input, seen: &mut Vec<Event>, start: Instant, millis: u64| {
            input.expire(start + Duration::from_millis(millis), seen);
            seen.len()
        };
        for (bytes, expected) in [
            (
                &b"\x1bP"[..],
                Some(("Char('P')", Mods::ALT | Mods::META | Mods::SHIFT)),
            ),
            (b"\x1b_", Some(("Char('_')", ALT))),
            (b"\x1bO", Some(("Char('O')", ALT | Mods::SHIFT))),
            (b"\x1b[1;5", None),
        ] {
            let (mut input, mut seen, start) = (Input::default(), Vec::new(), Instant::now());
            input.feed(bytes, start, &mut seen);
            let early = at(&mut input, &mut seen, start, 99);
            let late = at(&mut input, &mut seen, start, 100);
            assert_eq!(
                (early, late),
                (0, usize::from(expected.is_some())),
                "{bytes:?}"
            );
            if let Some((name, mods)) = expected {
                assert!(
                    matches!(&seen[0], Event::Key(k) if format!("{:?}", k.name) == name && k.mods.0 == mods)
                );
            }
            input.feed(b"z", start, &mut seen);
            assert!(matches!(seen.last(), Some(Event::Key(k)) if k.name == Name::Char('z')));
        }
    }

    #[test]
    fn an_osc_52_reply_names_its_clipboard_and_carries_the_decoded_text() {
        let mut input = Input::default();
        let mut events = Vec::new();
        input.feed(
            b"\x1b]52;p;aGk=\x1b\\\x1b]52;c;\x07\x1b]52;x;aGk=\x07",
            Instant::now(),
            &mut events,
        );
        assert_eq!(
            events,
            [
                Event::Reply(Reply::Clipboard(
                    frame::ClipboardLocation::Primary,
                    b"hi".to_vec()
                )),
                Event::Reply(Reply::Clipboard(
                    frame::ClipboardLocation::Standard,
                    Vec::new()
                )),
            ]
        );
    }

    #[test]
    fn a_partial_sgr_mouse_report_gets_one_more_hundred_milliseconds() {
        let (mut input, mut seen, start) = (Input::default(), Vec::new(), Instant::now());
        input.feed(b"\x1b[<0;3", start, &mut seen);
        input.expire(start + Duration::from_millis(100), &mut seen);
        let moved = input.deadline();
        input.expire(start + Duration::from_millis(200), &mut seen);
        assert_eq!(
            (seen.len(), moved, input.deadline()),
            (0, Some(start + Duration::from_millis(200)), None)
        );
    }

    #[test]
    fn a_paste_that_never_ends_is_dropped_after_five_seconds() {
        let (mut input, mut seen, start) = (Input::default(), Vec::new(), Instant::now());
        input.feed(b"\x1b[200~abc", start, &mut seen);
        input.expire(start + Duration::from_millis(4999), &mut seen);
        let waiting = input.deadline();
        input.expire(start + Duration::from_secs(5), &mut seen);
        input.feed(b"x", start, &mut seen);
        assert_eq!(
            (
                waiting,
                seen.len(),
                matches!(seen.first(), Some(Event::Key(k)) if k.name == Name::Char('x'))
            ),
            (Some(start + Duration::from_secs(5)), 1, true)
        );
    }

    #[test]
    fn kitty_codepoints_above_the_basic_plane_are_kept() {
        let shown: Vec<String> = [
            "\x1b[128512u",
            "\x1b[97;1;128512u",
            "\x1b[97:128512;2u",
            "\x1b[97;1;70000:128512u",
            "\x1b[1114112u",
        ]
        .iter()
        .flat_map(|text| keys(text).into_iter().map(|k| input_json(&k)))
        .collect();
        let line = |key: u16, mods: u16, unshifted: u32, text: &str| {
            format!(
                r#"{{"type":"input","input":{{"type":"key","action":"press","key":{key},"mods":{mods},"unshifted_codepoint":{unshifted},"text":"{text}","composing":false}}}}"#
            )
        };
        assert_eq!(
            shown,
            [
                line(0, 0, 128512, "\u{1f600}"),
                line(20, 0, 97, "\u{1f600}"),
                line(20, 1, 97, "\u{1f600}"),
                line(20, 0, 97, "\u{11170}\u{1f600}"),
            ]
        );
    }

    #[test]
    fn a_paste_over_the_cap_is_dropped_however_the_reads_split() {
        let over = vec![b'a'; MAX_PASTE + 1];
        let exact = vec![b'a'; MAX_PASTE];
        let end = b"\x1b[201~".as_slice();
        let start = b"\x1b[200~".as_slice();
        let run = |reads: &[&[u8]]| {
            let (mut input, mut seen, now) = (Input::default(), Vec::new(), Instant::now());
            for read in reads {
                input.feed(read, now, &mut seen);
            }
            seen.iter().filter(|e| matches!(e, Event::Paste(_))).count()
        };
        let counts = [
            run(&[start, &over, end]),
            run(&[start, &[&over[..], end].concat()]),
            run(&[&[start, &over[..]].concat(), end]),
            run(&[
                start,
                &over[..MAX_PASTE - 1],
                &[&over[MAX_PASTE - 1..], end].concat(),
            ]),
            run(&[start, &exact, end]),
        ];
        assert_eq!(counts, [0, 0, 0, 0, 1]);
    }
}
