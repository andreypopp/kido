#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::fmt;
use std::num::{NonZeroU16, NonZeroUsize};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use ko_sys::clock::Mono;
use ko_sys::pid::Exit;

use crate::ring::Pos;

pub const MAX_FRAME: u32 = 16 * 1024 * 1024;
const MAX_DIMENSION: u16 = 4096;
pub const MAX_KEY: u16 = 175;
const HEADER: usize = 5;
const INIT_VERSION: u16 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Init = 1,
    Tail = 2,
    Resize = 3,
    Text = 4,
    Snapshot = 5,
    Exit = 6,
    Ready = 7,
    Head = 8,
    Title = 9,
    Pwd = 10,
    Dead = 13,
    SnapshotDone = 14,
    Error = 15,
    Full = 16,
    Key = 17,
    Paste = 18,
    PasteDone = 19,
    Mouse = 20,
    Focus = 21,
    Screen = 22,
}

impl Kind {
    fn of_code(code: u8) -> Option<Kind> {
        Some(match code {
            1 => Kind::Init,
            2 => Kind::Tail,
            3 => Kind::Resize,
            4 => Kind::Text,
            5 => Kind::Snapshot,
            6 => Kind::Exit,
            7 => Kind::Ready,
            8 => Kind::Head,
            9 => Kind::Title,
            10 => Kind::Pwd,
            13 => Kind::Dead,
            14 => Kind::SnapshotDone,
            15 => Kind::Error,
            16 => Kind::Full,
            17 => Kind::Key,
            18 => Kind::Paste,
            19 => Kind::PasteDone,
            20 => Kind::Mouse,
            21 => Kind::Focus,
            22 => Kind::Screen,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dim(u16);

impl Dim {
    pub fn new(value: u16) -> Option<Dim> {
        (1..=MAX_DIMENSION).contains(&value).then_some(Dim(value))
    }

    pub fn get(self) -> u16 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellPx {
    pub width: NonZeroU16,
    pub height: NonZeroU16,
}

impl CellPx {
    pub const DEFAULT: CellPx = CellPx {
        width: NonZeroU16::new(8).unwrap(),
        height: NonZeroU16::new(16).unwrap(),
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Size {
    pub cols: Dim,
    pub rows: Dim,
    pub cell_px: Option<CellPx>,
}

impl Size {
    pub const DEFAULT: Size = Size {
        cols: Dim(80),
        rows: Dim(24),
        cell_px: Some(CellPx::DEFAULT),
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dead {
    pub at: Mono,
    pub exit: Exit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scrollback {
    Disabled,
    Bounded {
        max_bytes: Option<NonZeroUsize>,
        max_lines: Option<NonZeroUsize>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub scrollback: Scrollback,
    pub apc_max_bytes: usize,
    pub kitty_images_max_bytes: u64,
    pub continuation_max_bytes: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Medium {
    File,
    TempFile,
    SharedMem,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Req(u32);

impl Req {
    pub const FIRST: Req = Req(1);

    pub fn next(self) -> Req {
        Req(self.0.wrapping_add(1))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum History {
    None,
    All,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenFormat {
    Plain,
    Ansi,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenRows {
    Visible,
    Full,
    Last(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Release,
    Press,
    Repeat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyCode(u16);

impl KeyCode {
    pub fn new(code: u16) -> Option<KeyCode> {
        (code <= MAX_KEY).then_some(KeyCode(code))
    }

    pub fn get(self) -> u16 {
        self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    pub action: KeyAction,
    pub key: KeyCode,
    pub mods: u16,
    pub unshifted: char,
    pub text: String,
    pub composing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Unknown,
    Left,
    Right,
    Middle,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,
    Ten,
    Eleven,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mouse {
    pub action: MouseAction,
    pub button: MouseButton,
    pub col: u16,
    pub row: u16,
    pub mods: u16,
}

#[derive(Debug, Clone, Copy)]
pub struct Init<'a> {
    pub size: Size,
    pub limits: Limits,
    pub media: &'a [Medium],
    pub cwd: &'a Path,
    pub argv: &'a [Vec<u8>],
    pub env: &'a [Vec<u8>],
    pub id: &'a str,
}

#[derive(Debug, Clone, Copy)]
pub enum ToPane<'a> {
    Init(&'a Init<'a>),
    Tail(Pos),
    Resize(Size),
    Text(&'a [u8]),
    Snapshot {
        req: Req,
        history: History,
    },
    Exit,
    Key(&'a Key),
    Mouse(Mouse),
    Paste {
        req: Req,
        text: &'a str,
        check_safe: bool,
    },
    Focus(bool),
    Screen {
        req: Req,
        format: ScreenFormat,
        rows: ScreenRows,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Oversize;

impl fmt::Display for Oversize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "pane frame too large")
    }
}

#[derive(Debug)]
struct Body<'a> {
    out: &'a mut Vec<u8>,
}

impl Body<'_> {
    fn bytes(&mut self, bytes: &[u8]) {
        self.out.extend_from_slice(bytes);
    }

    fn u8(&mut self, value: u8) {
        self.out.push(value);
    }

    fn bool(&mut self, value: bool) {
        self.u8(u8::from(value));
    }

    fn u16(&mut self, value: u16) {
        self.bytes(&value.to_le_bytes());
    }

    fn u32(&mut self, value: u32) {
        self.bytes(&value.to_le_bytes());
    }

    fn u64(&mut self, value: u64) {
        self.bytes(&value.to_le_bytes());
    }

    fn string(&mut self, bytes: &[u8]) -> Result<(), Oversize> {
        self.u32(u32::try_from(bytes.len()).map_err(|_| Oversize)?);
        self.bytes(bytes);
        Ok(())
    }

    fn strings(&mut self, values: &[Vec<u8>]) -> Result<(), Oversize> {
        self.u32(u32::try_from(values.len()).map_err(|_| Oversize)?);
        values.iter().try_for_each(|value| self.string(value))
    }

    fn size(&mut self, size: Size) {
        let (width, height) = size
            .cell_px
            .map_or((0, 0), |cell| (cell.width.get(), cell.height.get()));
        for value in [size.cols.get(), size.rows.get(), width, height] {
            self.u16(value);
        }
    }

    fn limit(&mut self, limit: Option<usize>) {
        self.bool(limit.is_some());
        self.u64(limit.map_or(0, |value| value as u64));
    }

    fn init(&mut self, init: &Init<'_>) -> Result<(), Oversize> {
        self.u16(INIT_VERSION);
        self.size(init.size);
        let limits = init.limits;
        let (max_bytes, max_lines) = match limits.scrollback {
            Scrollback::Disabled => (Some(0), None),
            Scrollback::Bounded {
                max_bytes,
                max_lines,
            } => (
                max_bytes.map(NonZeroUsize::get),
                max_lines.map(NonZeroUsize::get),
            ),
        };
        self.limit(max_bytes);
        self.limit(max_lines);
        self.u64(limits.apc_max_bytes as u64);
        self.u64(limits.kitty_images_max_bytes);
        self.u8(init.media.iter().fold(0, |bits, medium| {
            bits | match medium {
                Medium::File => 1,
                Medium::TempFile => 2,
                Medium::SharedMem => 4,
            }
        }));
        self.u64(limits.continuation_max_bytes as u64);
        self.string(init.cwd.as_os_str().as_bytes())?;
        self.strings(init.argv)?;
        self.strings(init.env)?;
        self.string(init.id.as_bytes())
    }

    fn key(&mut self, key: &Key) -> Result<(), Oversize> {
        self.u8(match key.action {
            KeyAction::Release => 0,
            KeyAction::Press => 1,
            KeyAction::Repeat => 2,
        });
        self.u16(key.key.0);
        self.u16(key.mods);
        self.u32(u32::from(key.unshifted));
        self.string(key.text.as_bytes())?;
        self.bool(key.composing);
        Ok(())
    }

    fn mouse(&mut self, mouse: Mouse) {
        self.u8(match mouse.action {
            MouseAction::Press => 0,
            MouseAction::Release => 1,
            MouseAction::Motion => 2,
        });
        self.u8(match mouse.button {
            MouseButton::Unknown => 0,
            MouseButton::Left => 1,
            MouseButton::Right => 2,
            MouseButton::Middle => 3,
            MouseButton::Four => 4,
            MouseButton::Five => 5,
            MouseButton::Six => 6,
            MouseButton::Seven => 7,
            MouseButton::Eight => 8,
            MouseButton::Nine => 9,
            MouseButton::Ten => 10,
            MouseButton::Eleven => 11,
        });
        self.u16(mouse.col);
        self.u16(mouse.row);
        self.u16(mouse.mods);
    }

    fn frame(&mut self, frame: &ToPane<'_>) -> Result<Kind, Oversize> {
        Ok(match *frame {
            ToPane::Init(init) => {
                self.init(init)?;
                Kind::Init
            }
            ToPane::Tail(tail) => {
                self.u64(tail.get());
                Kind::Tail
            }
            ToPane::Resize(size) => {
                self.size(size);
                Kind::Resize
            }
            ToPane::Text(text) => {
                self.bytes(text);
                Kind::Text
            }
            ToPane::Snapshot { req, history } => {
                self.u32(req.0);
                self.bool(history == History::None);
                self.u8(0);
                self.string(b"")?;
                Kind::Snapshot
            }
            ToPane::Exit => Kind::Exit,
            ToPane::Key(key) => {
                self.key(key)?;
                Kind::Key
            }
            ToPane::Mouse(mouse) => {
                self.mouse(mouse);
                Kind::Mouse
            }
            ToPane::Paste {
                req,
                text,
                check_safe,
            } => {
                self.u32(req.0);
                self.string(text.as_bytes())?;
                self.bool(check_safe);
                Kind::Paste
            }
            ToPane::Focus(focused) => {
                self.bool(focused);
                Kind::Focus
            }
            ToPane::Screen { req, format, rows } => {
                self.u32(req.0);
                self.bool(format == ScreenFormat::Ansi);
                self.u32(match rows {
                    ScreenRows::Visible => 0,
                    ScreenRows::Full => u32::MAX,
                    ScreenRows::Last(rows) => rows,
                });
                Kind::Screen
            }
        })
    }
}

pub fn encode(frame: &ToPane<'_>, out: &mut Vec<u8>) -> Result<(), Oversize> {
    let start = out.len();
    out.extend_from_slice(&[0; HEADER]);
    let kind = Body { out: &mut *out }.frame(frame);
    let header = kind.and_then(|kind| {
        let [a, b, c, d] = out
            .len()
            .checked_sub(start)
            .and_then(|total| total.checked_sub(4))
            .and_then(|length| u32::try_from(length).ok())
            .filter(|&length| length <= MAX_FRAME)
            .ok_or(Oversize)?
            .to_le_bytes();
        Ok([a, b, c, d, kind as u8])
    });
    match header {
        Ok(header) => {
            if let Some(at) = out
                .get_mut(start..)
                .and_then(|frame| frame.get_mut(..HEADER))
            {
                at.copy_from_slice(&header);
            }
            Ok(())
        }
        Err(error) => {
            out.truncate(start);
            Err(error)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Malformed {
    Length,
    Unknown,
    Short,
    String,
    Ready,
    Dead,
}

impl fmt::Display for Malformed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Malformed::Length => "invalid control frame length",
            Malformed::Unknown => "unknown pane frame",
            Malformed::Short => "short pane frame",
            Malformed::String => "invalid pane string",
            Malformed::Ready => "invalid ready",
            Malformed::Dead => "invalid dead",
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FromPane<'a> {
    Ready(i64),
    Head,
    Title(&'a [u8]),
    Pwd(&'a [u8]),
    Dead(Dead),
    SnapshotDone(Req),
    PasteDone {
        req: Req,
        pasted: bool,
        unsafe_paste: bool,
    },
    Screen {
        req: Req,
        last: bool,
        text: &'a [u8],
    },
    Error(&'a [u8]),
    Full,
    Ignored,
}

pub fn frame_size(input: &[u8]) -> Result<Option<usize>, Malformed> {
    let Some(&[a, b, c, d]) = input.get(..4) else {
        return Ok(None);
    };
    let length = u32::from_le_bytes([a, b, c, d]);
    if !(1..=MAX_FRAME).contains(&length) {
        return Err(Malformed::Length);
    }
    let size = usize::try_from(length)
        .ok()
        .and_then(|length| length.checked_add(4))
        .ok_or(Malformed::Length)?;
    Ok((input.len() >= size).then_some(size))
}

fn need(body: &[u8], size: usize) -> Result<(), Malformed> {
    if body.len() < size {
        Err(Malformed::Short)
    } else {
        Ok(())
    }
}

pub(crate) fn array<const N: usize>(body: &[u8], at: usize) -> Option<[u8; N]> {
    body.get(at..)?.get(..N)?.try_into().ok()
}

pub(crate) fn u16_at(body: &[u8], at: usize) -> Option<u16> {
    array(body, at).map(u16::from_le_bytes)
}

pub(crate) fn u32_at(body: &[u8], at: usize) -> Option<u32> {
    array(body, at).map(u32::from_le_bytes)
}

fn i32_at(body: &[u8], at: usize) -> Option<i32> {
    array(body, at).map(i32::from_le_bytes)
}

fn string_at(body: &[u8], at: usize) -> Result<&[u8], Malformed> {
    let length = i32_at(body, at).ok_or(Malformed::Short)?;
    let start = at.checked_add(4).ok_or(Malformed::String)?;
    usize::try_from(length)
        .ok()
        .and_then(|length| start.checked_add(length))
        .and_then(|end| body.get(start..end))
        .ok_or(Malformed::String)
}

pub(crate) fn dead(body: &[u8]) -> Option<Dead> {
    if body.len() != 16 {
        return None;
    }
    let status = i32_at(body, 0)?;
    let signal = i32_at(body, 4)?;
    Some(Dead {
        at: Mono::from_nanos(u64::from_le_bytes(array(body, 8)?)),
        exit: if signal == 0 {
            Exit::Exited(status)
        } else {
            Exit::Signaled(signal)
        },
    })
}

pub(crate) fn size(body: &[u8]) -> Option<Size> {
    if body.len() != 8 {
        return None;
    }
    let cell_px = match (u16_at(body, 4)?, u16_at(body, 6)?) {
        (0, 0) => None,
        (width, height) => Some(CellPx {
            width: width.try_into().ok()?,
            height: height.try_into().ok()?,
        }),
    };
    Some(Size {
        cols: Dim::new(u16_at(body, 0)?)?,
        rows: Dim::new(u16_at(body, 2)?)?,
        cell_px,
    })
}

pub fn decode(frame: &[u8]) -> Result<FromPane<'_>, Malformed> {
    let (&code, body) = frame
        .get(4..)
        .and_then(<[u8]>::split_first)
        .ok_or(Malformed::Length)?;
    let kind = Kind::of_code(code).ok_or(Malformed::Unknown)?;
    let byte_is_one = |at: usize| body.get(at) == Some(&1);
    Ok(match kind {
        Kind::Ready => match body {
            &[a, b, c, d] => FromPane::Ready(i64::from(i32::from_le_bytes([a, b, c, d]))),
            _ => return Err(Malformed::Ready),
        },
        Kind::Title => FromPane::Title(string_at(body, 0)?),
        Kind::Pwd => FromPane::Pwd(string_at(body, 0)?),
        Kind::Head => FromPane::Head,
        Kind::Dead => FromPane::Dead(dead(body).ok_or(Malformed::Dead)?),
        Kind::Full => FromPane::Full,
        Kind::SnapshotDone => FromPane::SnapshotDone(Req(u32_at(body, 0).ok_or(Malformed::Short)?)),
        Kind::PasteDone => {
            need(body, 6)?;
            FromPane::PasteDone {
                req: Req(u32_at(body, 0).ok_or(Malformed::Short)?),
                pasted: byte_is_one(4),
                unsafe_paste: byte_is_one(5),
            }
        }
        Kind::Screen => {
            need(body, 9)?;
            FromPane::Screen {
                req: Req(u32_at(body, 0).ok_or(Malformed::Short)?),
                last: byte_is_one(4),
                text: string_at(body, 5)?,
            }
        }
        Kind::Error => FromPane::Error(string_at(body, 0)?),
        Kind::Init
        | Kind::Tail
        | Kind::Resize
        | Kind::Text
        | Kind::Snapshot
        | Kind::Exit
        | Kind::Key
        | Kind::Paste
        | Kind::Mouse
        | Kind::Focus => FromPane::Ignored,
    })
}

#[cfg(test)]
#[allow(clippy::arithmetic_side_effects)]
mod tests {
    use super::*;

    const PROTOCOL: &str = include_str!("../../ko_pane/protocol.h");

    #[test]
    fn constants_match_the_c_ko_pane() {
        assert!(PROTOCOL.contains(&format!("#define KO_MAX_DIMENSION {MAX_DIMENSION}u\n")));
        assert!(PROTOCOL.contains("#define KO_MAX_FRAME (16u*1024u*1024u)\n"));
        assert_eq!(MAX_FRAME, 16 * 1024 * 1024);
        let kinds = [
            (Kind::Init, "INIT"),
            (Kind::Tail, "TAIL"),
            (Kind::Resize, "RESIZE"),
            (Kind::Text, "TEXT"),
            (Kind::Snapshot, "SNAPSHOT"),
            (Kind::Exit, "EXIT"),
            (Kind::Ready, "READY"),
            (Kind::Head, "HEAD"),
            (Kind::Title, "TITLE"),
            (Kind::Pwd, "PWD"),
            (Kind::Dead, "DEAD"),
            (Kind::SnapshotDone, "SNAPSHOT_DONE"),
            (Kind::Error, "ERROR"),
            (Kind::Full, "FULL"),
            (Kind::Key, "KEY"),
            (Kind::Paste, "PASTE"),
            (Kind::PasteDone, "PASTE_DONE"),
            (Kind::Mouse, "MOUSE"),
            (Kind::Focus, "FOCUS"),
            (Kind::Screen, "SCREEN"),
        ];
        for (kind, name) in kinds {
            let defined = format!("KO_{name} = {}", kind as u8);
            assert!(PROTOCOL.contains(&defined), "{defined}");
        }
    }

    fn frame(kind: Kind, body: &[u8]) -> Vec<u8> {
        let mut frame = u32::try_from(body.len() + 1)
            .unwrap()
            .to_le_bytes()
            .to_vec();
        frame.push(kind as u8);
        frame.extend_from_slice(body);
        frame
    }

    #[test]
    fn fragmented_and_multiple_control_frames() {
        let text = frame(Kind::Text, b"abc");
        assert_eq!(frame_size(&text[..6]), Ok(None));
        let input = [text.clone(), frame(Kind::Exit, b"")].concat();
        let mut pos = 0;
        let mut frames = Vec::new();
        while let Some(size) = frame_size(&input[pos..]).unwrap() {
            frames.push((input[pos + 4], input[pos + 5..pos + size].to_vec()));
            pos += size;
        }
        assert_eq!(frames, [(4, b"abc".to_vec()), (6, Vec::new())]);
        assert_eq!(frame_size(&[0, 0, 0, 0]), Err(Malformed::Length));
        assert_eq!(
            frame_size(&(MAX_FRAME + 1).to_le_bytes()),
            Err(Malformed::Length)
        );
    }

    #[test]
    fn a_frame_body_shorter_than_its_fields_fails() {
        for (kind, body) in [
            (Kind::SnapshotDone, &b"\x01\x00"[..]),
            (Kind::PasteDone, b"\x01\x00\x00\x00\x01"),
            (Kind::Title, b"\x05"),
        ] {
            let input = [frame(kind, body), frame(Kind::Head, &[0; 8])].concat();
            let size = frame_size(&input).unwrap().unwrap();
            assert_eq!(decode(&input[..size]), Err(Malformed::Short), "{kind:?}");
        }
        assert_eq!(
            decode(&frame(Kind::Title, b"\x05\x00\x00\x00ab")),
            Err(Malformed::String)
        );
        assert_eq!(
            decode(&frame(Kind::Ready, b"\x05\x00")),
            Err(Malformed::Ready)
        );
        assert_eq!(decode(&frame(Kind::Dead, &[0; 15])), Err(Malformed::Dead));
        assert_eq!(decode(&[1, 0, 0, 0, 11]), Err(Malformed::Unknown));
    }

    fn encoded(frame: &ToPane<'_>) -> Vec<u8> {
        let mut out = Vec::new();
        encode(frame, &mut out).unwrap();
        let size = frame_size(&out).unwrap().unwrap();
        assert_eq!(size, out.len());
        out
    }

    #[test]
    fn typed_input_stays_binary() {
        let text = encoded(&ToPane::Text(b"\x00\n"));
        assert_eq!(&text[4..], [Kind::Text as u8, 0, 10]);
        assert_eq!(&encoded(&ToPane::Focus(true))[5..], [1]);
        let key = Key {
            action: KeyAction::Press,
            key: KeyCode::new(20).unwrap(),
            mods: 2,
            unshifted: 'a',
            text: "a".to_owned(),
            composing: false,
        };
        let body = &encoded(&ToPane::Key(&key))[5..];
        assert_eq!(body.len(), 15);
        assert_eq!(body[5..9], 97u32.to_le_bytes());
        assert_eq!(KeyCode::new(MAX_KEY + 1), None);
    }

    #[test]
    fn requests_carry_their_id_first() {
        let req = Req::FIRST.next();
        assert_eq!(
            encoded(&ToPane::Snapshot {
                req,
                history: History::None
            })[5..],
            [2, 0, 0, 0, 1, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            encoded(&ToPane::Screen {
                req,
                format: ScreenFormat::Ansi,
                rows: ScreenRows::Full
            })[5..],
            [2, 0, 0, 0, 1, 255, 255, 255, 255]
        );
    }

    #[test]
    fn the_init_frame_has_the_c_ko_pane_layout() {
        let init = Init {
            size: Size::DEFAULT,
            limits: Limits {
                scrollback: Scrollback::Disabled,
                apc_max_bytes: 3,
                kitty_images_max_bytes: 4,
                continuation_max_bytes: 5,
            },
            media: &[Medium::File, Medium::SharedMem],
            cwd: Path::new("/"),
            argv: &[b"/bin/sh".to_vec()],
            env: &[],
            id: "pane_1",
        };
        let body = encoded(&ToPane::Init(&init))[5..].to_vec();
        let mut expected = vec![3, 0, 80, 0, 24, 0, 8, 0, 16, 0];
        expected.extend([1, 0, 0, 0, 0, 0, 0, 0, 0]);
        expected.extend([0, 0, 0, 0, 0, 0, 0, 0, 0]);
        expected.extend(3u64.to_le_bytes());
        expected.extend(4u64.to_le_bytes());
        expected.push(5);
        expected.extend(5u64.to_le_bytes());
        expected.extend([1, 0, 0, 0, b'/']);
        expected.extend([1, 0, 0, 0, 7, 0, 0, 0]);
        expected.extend(b"/bin/sh");
        expected.extend([0, 0, 0, 0, 6, 0, 0, 0]);
        expected.extend(b"pane_1");
        assert_eq!(body, expected);
    }

    #[test]
    fn dim_holds_one_to_the_maximum() {
        assert_eq!(Dim::new(0), None);
        assert_eq!(Dim::new(1).map(Dim::get), Some(1));
        assert_eq!(Dim::new(MAX_DIMENSION).map(Dim::get), Some(MAX_DIMENSION));
        assert_eq!(Dim::new(MAX_DIMENSION + 1), None);
    }
}
