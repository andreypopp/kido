#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use std::borrow::Cow;
use std::ffi::OsStr;
use std::fmt;
use std::num::{NonZeroU16, NonZeroUsize};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use ko_sys::clock::Mono;
use ko_sys::pid::Exit;
use vstd::prelude::*;

use crate::ring::Pos;

pub const MAX_FRAME: u32 = 16 * 1024 * 1024;
pub const MAX_FRAME_BYTES: usize = MAX_FRAME as usize + 4;
const MAX_DIMENSION: u16 = 4096;
pub const MAX_KEY: u16 = 175;
const HEADER: usize = 5;
const INIT_VERSION: u16 = 3;
const MAX_STRINGS: u32 = 4096;

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
    Prompt = 11,
    Record = 12,
    Foreground = 23,
    Alternate = 24,
    Bell = 25,
    Notify = 26,
    Progress = 27,
    ClearHistory = 28,
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
            11 => Kind::Prompt,
            12 => Kind::Record,
            23 => Kind::Foreground,
            24 => Kind::Alternate,
            25 => Kind::Bell,
            26 => Kind::Notify,
            27 => Kind::Progress,
            28 => Kind::ClearHistory,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dim(u16);

impl Dim {
    pub const MIN: Dim = Dim(1);
    pub const MAX: Dim = Dim(MAX_DIMENSION);

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
    pub fn cell_pixels(self) -> (u16, u16) {
        self.cell_px
            .map_or((0, 0), |cell| (cell.width.get(), cell.height.get()))
    }

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptStep {
    Start,
    OutputStart,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Prompt<'a> {
    pub step: PromptStep,
    pub exit: Option<i32>,
    pub at: Mono,
    pub command: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
    Clear,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramKind {
    None,
    Permission,
    Question,
    Auth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Record<'a> {
    pub state: ProgramState,
    pub kind: ProgramKind,
    pub progress: Option<u8>,
    pub id: &'a [u8],
    pub app: &'a [u8],
    pub title: &'a [u8],
    pub msg: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Foreground<'a> {
    pub pid: u32,
    pub name: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressState {
    Set,
    Error,
    Indeterminate,
    Pause,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProgressReport {
    pub state: ProgressState,
    pub progress: Option<u8>,
}

verus! {

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Req(u32);

pub open spec fn low32(serial: u64) -> nat {
    serial as nat % 0x1_0000_0000nat
}

impl Req {
    pub closed spec fn val(self) -> u32 {
        self.0
    }

    pub fn of_serial(serial: u64) -> (r: Req)
        ensures
            r.val() as nat == low32(serial),
    {
        let low = (serial & 0xffff_ffff) as u32;
        assert(low as nat == serial as nat % 0x1_0000_0000nat) by (bit_vector)
            requires
                low == (serial & 0xffff_ffff) as u32,
        ;
        Req(low)
    }

    pub fn same(self, other: Req) -> (r: bool)
        ensures
            r == (self.val() == other.val()),
    {
        self.0 == other.0
    }
}

} // verus!

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

impl TryFrom<u8> for KeyAction {
    type Error = Malformed;

    fn try_from(code: u8) -> Result<KeyAction, Malformed> {
        match code {
            0 => Ok(KeyAction::Release),
            1 => Ok(KeyAction::Press),
            2 => Ok(KeyAction::Repeat),
            _ => Err(Malformed::Field),
        }
    }
}

impl TryFrom<u8> for MouseAction {
    type Error = Malformed;

    fn try_from(code: u8) -> Result<MouseAction, Malformed> {
        match code {
            0 => Ok(MouseAction::Press),
            1 => Ok(MouseAction::Release),
            2 => Ok(MouseAction::Motion),
            _ => Err(Malformed::Field),
        }
    }
}

impl TryFrom<u8> for MouseButton {
    type Error = Malformed;

    fn try_from(code: u8) -> Result<MouseButton, Malformed> {
        Ok(match code {
            0 => MouseButton::Unknown,
            1 => MouseButton::Left,
            2 => MouseButton::Right,
            3 => MouseButton::Middle,
            4 => MouseButton::Four,
            5 => MouseButton::Five,
            6 => MouseButton::Six,
            7 => MouseButton::Seven,
            8 => MouseButton::Eight,
            9 => MouseButton::Nine,
            10 => MouseButton::Ten,
            11 => MouseButton::Eleven,
            _ => return Err(Malformed::Field),
        })
    }
}

#[derive(Debug, Clone)]
pub struct Init<'a> {
    pub size: Size,
    pub limits: Limits,
    pub media: Cow<'a, [Medium]>,
    pub cwd: Cow<'a, Path>,
    pub argv: Cow<'a, [Vec<u8>]>,
    pub env: Cow<'a, [Vec<u8>]>,
    pub id: Cow<'a, str>,
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
    ClearHistory,
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

    fn i32(&mut self, value: i32) {
        self.bytes(&value.to_le_bytes());
    }

    fn prompt(&mut self, prompt: &Prompt<'_>) -> Result<(), Oversize> {
        self.u8(match prompt.step {
            PromptStep::Start => 1,
            PromptStep::OutputStart => 2,
            PromptStep::End => 3,
        });
        self.bool(prompt.exit.is_some());
        self.i32(prompt.exit.unwrap_or(0));
        self.u64(prompt.at.nanos());
        self.string(prompt.command)
    }

    fn record(&mut self, record: &Record<'_>) -> Result<(), Oversize> {
        self.u8(match record.state {
            ProgramState::Idle => 0,
            ProgramState::Working => 1,
            ProgramState::Done => 2,
            ProgramState::Blocked => 3,
            ProgramState::Error => 4,
            ProgramState::Clear => 5,
        });
        self.u8(match record.kind {
            ProgramKind::None => 0,
            ProgramKind::Permission => 1,
            ProgramKind::Question => 2,
            ProgramKind::Auth => 3,
        });
        self.u8(record.progress.unwrap_or(u8::MAX));
        self.string(record.id)?;
        self.string(record.app)?;
        self.string(record.title)?;
        self.string(record.msg)
    }

    fn progress(&mut self, report: Option<ProgressReport>) {
        let Some(report) = report else {
            self.u8(0);
            self.u8(u8::MAX);
            return;
        };
        self.u8(match report.state {
            ProgressState::Set => 1,
            ProgressState::Error => 2,
            ProgressState::Indeterminate => 3,
            ProgressState::Pause => 4,
        });
        self.u8(report.progress.unwrap_or(u8::MAX));
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
        self.bytes(&size_bytes(size));
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
        self.strings(&init.argv)?;
        self.strings(&init.env)?;
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

    fn pane_frame(&mut self, frame: &FromPane<'_>) -> Result<Kind, Oversize> {
        Ok(match *frame {
            FromPane::Ready(pid) => {
                self.i32(i32::try_from(pid).map_err(|_| Oversize)?);
                Kind::Ready
            }
            FromPane::Head(pos) => {
                self.u64(pos.get());
                Kind::Head
            }
            FromPane::Title(title) => {
                self.string(title)?;
                Kind::Title
            }
            FromPane::Pwd(cwd) => {
                self.string(cwd)?;
                Kind::Pwd
            }
            FromPane::Dead(dead) => {
                self.bytes(&dead_bytes(dead));
                Kind::Dead
            }
            FromPane::SnapshotDone(req) => {
                self.u32(req.0);
                Kind::SnapshotDone
            }
            FromPane::PasteDone {
                req,
                pasted,
                unsafe_paste,
            } => {
                self.u32(req.0);
                self.bool(pasted);
                self.bool(unsafe_paste);
                Kind::PasteDone
            }
            FromPane::Screen { req, last, text } => {
                self.u32(req.0);
                self.bool(last);
                self.string(text)?;
                Kind::Screen
            }
            FromPane::Error(message) => {
                self.string(message)?;
                Kind::Error
            }
            FromPane::Full(pos) => {
                self.u64(pos.get());
                Kind::Full
            }
            FromPane::Prompt(prompt) => {
                self.prompt(&prompt)?;
                Kind::Prompt
            }
            FromPane::Record(record) => {
                self.record(&record)?;
                Kind::Record
            }
            FromPane::Foreground(foreground) => {
                self.u32(foreground.pid);
                self.string(foreground.name)?;
                Kind::Foreground
            }
            FromPane::Alternate(on) => {
                self.bool(on);
                Kind::Alternate
            }
            FromPane::Bell => Kind::Bell,
            FromPane::Notify { title, body } => {
                self.string(title)?;
                self.string(body)?;
                Kind::Notify
            }
            FromPane::Progress(report) => {
                self.progress(report);
                Kind::Progress
            }
        })
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
            ToPane::ClearHistory => Kind::ClearHistory,
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

pub(crate) fn size_bytes(size: Size) -> [u8; 8] {
    let (width, height) = size.cell_pixels();
    let [c0, c1] = size.cols.get().to_le_bytes();
    let [r0, r1] = size.rows.get().to_le_bytes();
    let [w0, w1] = width.to_le_bytes();
    let [h0, h1] = height.to_le_bytes();
    [c0, c1, r0, r1, w0, w1, h0, h1]
}

pub(crate) fn dead_bytes(dead: Dead) -> [u8; 16] {
    let (status, signal) = match dead.exit {
        Exit::Exited(status) => (status, 0),
        Exit::Signaled(signal) => (0, signal),
    };
    let [s0, s1, s2, s3] = status.to_le_bytes();
    let [g0, g1, g2, g3] = signal.to_le_bytes();
    let [a0, a1, a2, a3, a4, a5, a6, a7] = dead.at.nanos().to_le_bytes();
    [
        s0, s1, s2, s3, g0, g1, g2, g3, a0, a1, a2, a3, a4, a5, a6, a7,
    ]
}

pub fn encode(frame: &ToPane<'_>, out: &mut Vec<u8>) -> Result<(), Oversize> {
    framed(out, |body| body.frame(frame))
}

pub fn encode_from(frame: &FromPane<'_>, out: &mut Vec<u8>) -> Result<(), Oversize> {
    framed(out, |body| body.pane_frame(frame))
}

fn framed(
    out: &mut Vec<u8>,
    body: impl FnOnce(&mut Body<'_>) -> Result<Kind, Oversize>,
) -> Result<(), Oversize> {
    let start = out.len();
    out.extend_from_slice(&[0; HEADER]);
    let kind = body(&mut Body { out: &mut *out });
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
    Field,
    Trailing,
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
            Malformed::Field => "invalid pane field",
            Malformed::Trailing => "trailing bytes in a pane frame",
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FromPane<'a> {
    Ready(i64),
    Head(Pos),
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
    Full(Pos),
    Prompt(Prompt<'a>),
    Record(Record<'a>),
    Foreground(Foreground<'a>),
    Alternate(bool),
    Bell,
    Notify {
        title: &'a [u8],
        body: &'a [u8],
    },
    Progress(Option<ProgressReport>),
}

pub fn check_sizes(mut input: &[u8]) -> bool {
    while let Ok(Some(size)) = frame_size(input) {
        if size < HEADER || size > input.len() || size > MAX_FRAME_BYTES {
            return false;
        }
        input = input.get(size..).unwrap_or_default();
    }
    true
}

pub fn kind(frame: &[u8]) -> Option<Kind> {
    Kind::of_code(*frame.get(4)?)
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

fn position(body: &[u8]) -> Result<Pos, Malformed> {
    array(body, 0)
        .map(|bytes| Pos::new(u64::from_le_bytes(bytes)))
        .ok_or(Malformed::Short)
}

pub fn decode(frame: &[u8]) -> Result<Option<FromPane<'_>>, Malformed> {
    let (&code, body) = frame
        .get(4..)
        .and_then(<[u8]>::split_first)
        .ok_or(Malformed::Length)?;
    let kind = Kind::of_code(code).ok_or(Malformed::Unknown)?;
    let byte_is_one = |at: usize| body.get(at) == Some(&1);
    Ok(Some(match kind {
        Kind::Ready => match body {
            &[a, b, c, d] => FromPane::Ready(i64::from(i32::from_le_bytes([a, b, c, d]))),
            _ => return Err(Malformed::Ready),
        },
        Kind::Title => FromPane::Title(string_at(body, 0)?),
        Kind::Pwd => FromPane::Pwd(string_at(body, 0)?),
        Kind::Head => FromPane::Head(position(body)?),
        Kind::Dead => FromPane::Dead(dead(body).ok_or(Malformed::Dead)?),
        Kind::Full => FromPane::Full(position(body)?),
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
        Kind::Prompt => {
            let mut fields = Fields(body);
            let step = match fields.u8()? {
                1 => PromptStep::Start,
                2 => PromptStep::OutputStart,
                3 => PromptStep::End,
                _ => return Err(Malformed::Field),
            };
            let has_exit = fields.flag()?;
            let exit = fields.i32()?;
            let at = Mono::from_nanos(fields.u64()?);
            let command = fields.bytes()?;
            fields.end()?;
            FromPane::Prompt(Prompt {
                step,
                exit: has_exit.then_some(exit),
                at,
                command,
            })
        }
        Kind::Record => {
            let mut fields = Fields(body);
            let state = match fields.u8()? {
                0 => ProgramState::Idle,
                1 => ProgramState::Working,
                2 => ProgramState::Done,
                3 => ProgramState::Blocked,
                4 => ProgramState::Error,
                5 => ProgramState::Clear,
                _ => return Err(Malformed::Field),
            };
            let kind = match fields.u8()? {
                0 => ProgramKind::None,
                1 => ProgramKind::Permission,
                2 => ProgramKind::Question,
                3 => ProgramKind::Auth,
                _ => return Err(Malformed::Field),
            };
            let progress = fields.percent()?;
            let record = Record {
                state,
                kind,
                progress,
                id: fields.bytes()?,
                app: fields.bytes()?,
                title: fields.bytes()?,
                msg: fields.bytes()?,
            };
            fields.end()?;
            FromPane::Record(record)
        }
        Kind::Foreground => {
            let mut fields = Fields(body);
            let pid = fields.u32()?;
            let name = fields.bytes()?;
            fields.end()?;
            FromPane::Foreground(Foreground { pid, name })
        }
        Kind::Alternate => {
            let mut fields = Fields(body);
            let on = fields.flag()?;
            fields.end()?;
            FromPane::Alternate(on)
        }
        Kind::Bell => {
            Fields(body).end()?;
            FromPane::Bell
        }
        Kind::Notify => {
            let mut fields = Fields(body);
            let (title, body) = (fields.bytes()?, fields.bytes()?);
            fields.end()?;
            FromPane::Notify { title, body }
        }
        Kind::Progress => {
            let mut fields = Fields(body);
            let state = fields.u8()?;
            let progress = fields.percent()?;
            fields.end()?;
            FromPane::Progress(match state {
                0 => None,
                1 => Some(ProgressReport {
                    state: ProgressState::Set,
                    progress,
                }),
                2 => Some(ProgressReport {
                    state: ProgressState::Error,
                    progress,
                }),
                3 => Some(ProgressReport {
                    state: ProgressState::Indeterminate,
                    progress,
                }),
                4 => Some(ProgressReport {
                    state: ProgressState::Pause,
                    progress,
                }),
                _ => return Err(Malformed::Field),
            })
        }
        Kind::Init
        | Kind::Tail
        | Kind::Resize
        | Kind::Text
        | Kind::Snapshot
        | Kind::Exit
        | Kind::Key
        | Kind::Paste
        | Kind::Mouse
        | Kind::Focus
        | Kind::ClearHistory => return Ok(None),
    }))
}

#[derive(Debug, Clone)]
pub enum Request<'a> {
    Init(Init<'a>),
    Tail,
    Resize(Size),
    Text(&'a [u8]),
    Snapshot {
        req: Req,
        history: History,
    },
    Exit,
    Key(Key),
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
    ClearHistory,
}

#[derive(Debug)]
struct Fields<'a>(&'a [u8]);

impl<'a> Fields<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], Malformed> {
        let (taken, rest) = self.0.split_at_checked(count).ok_or(Malformed::Short)?;
        self.0 = rest;
        Ok(taken)
    }

    fn u8(&mut self) -> Result<u8, Malformed> {
        self.take(1)?.first().copied().ok_or(Malformed::Short)
    }

    fn flag(&mut self) -> Result<bool, Malformed> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(Malformed::Field),
        }
    }

    fn u16(&mut self) -> Result<u16, Malformed> {
        u16_at(self.take(2)?, 0).ok_or(Malformed::Short)
    }

    fn i32(&mut self) -> Result<i32, Malformed> {
        i32_at(self.take(4)?, 0).ok_or(Malformed::Short)
    }

    fn percent(&mut self) -> Result<Option<u8>, Malformed> {
        match self.u8()? {
            u8::MAX => Ok(None),
            percent @ 0..=100 => Ok(Some(percent)),
            _ => Err(Malformed::Field),
        }
    }

    fn u32(&mut self) -> Result<u32, Malformed> {
        u32_at(self.take(4)?, 0).ok_or(Malformed::Short)
    }

    fn u64(&mut self) -> Result<u64, Malformed> {
        array(self.take(8)?, 0)
            .map(u64::from_le_bytes)
            .ok_or(Malformed::Short)
    }

    fn size_of(&mut self) -> Result<usize, Malformed> {
        usize::try_from(self.u64()?).map_err(|_| Malformed::Field)
    }

    fn bytes(&mut self) -> Result<&'a [u8], Malformed> {
        let length = usize::try_from(self.u32()?).map_err(|_| Malformed::String)?;
        self.take(length).map_err(|_| Malformed::String)
    }

    fn text(&mut self) -> Result<&'a [u8], Malformed> {
        let bytes = self.bytes()?;
        if bytes.contains(&0) {
            Err(Malformed::Field)
        } else {
            Ok(bytes)
        }
    }

    fn texts(&mut self) -> Result<Vec<Vec<u8>>, Malformed> {
        let count = self.u32()?;
        if count > MAX_STRINGS {
            return Err(Malformed::Field);
        }
        (0..count)
            .map(|_| self.text().map(<[u8]>::to_vec))
            .collect()
    }

    fn limit(&mut self) -> Result<Option<usize>, Malformed> {
        let present = self.flag()?;
        let value = self.size_of()?;
        Ok(present.then_some(value))
    }

    fn size(&mut self) -> Result<Size, Malformed> {
        size(self.take(8)?).ok_or(Malformed::Field)
    }

    fn end(&self) -> Result<(), Malformed> {
        if self.0.is_empty() {
            Ok(())
        } else {
            Err(Malformed::Trailing)
        }
    }

    fn init(&mut self) -> Result<Init<'a>, Malformed> {
        if self.u16()? != INIT_VERSION {
            return Err(Malformed::Field);
        }
        let size = self.size()?;
        let (bytes, lines) = (self.limit()?, self.limit()?);
        let scrollback = if bytes == Some(0) || lines == Some(0) {
            Scrollback::Disabled
        } else {
            Scrollback::Bounded {
                max_bytes: bytes.and_then(NonZeroUsize::new),
                max_lines: lines.and_then(NonZeroUsize::new),
            }
        };
        let apc_max_bytes = self.size_of()?;
        let kitty_images_max_bytes = self.u64()?;
        let media = self.u8()?;
        let continuation_max_bytes = self.size_of()?;
        let cwd = Path::new(OsStr::from_bytes(self.text()?));
        let (argv, env) = (self.texts()?, self.texts()?);
        let id = String::from_utf8_lossy(self.text()?);
        if !argv
            .first()
            .is_some_and(|program| program.first() == Some(&b'/'))
        {
            return Err(Malformed::Field);
        }
        let media = [
            (1, Medium::File),
            (2, Medium::TempFile),
            (4, Medium::SharedMem),
        ]
        .into_iter()
        .filter(|(bit, _)| media & bit != 0)
        .map(|(_, medium)| medium)
        .collect();
        Ok(Init {
            size,
            limits: Limits {
                scrollback,
                apc_max_bytes,
                kitty_images_max_bytes,
                continuation_max_bytes,
            },
            media: Cow::Owned(media),
            cwd: Cow::Borrowed(cwd),
            argv: Cow::Owned(argv),
            env: Cow::Owned(env),
            id,
        })
    }

    fn key(&mut self) -> Result<Key, Malformed> {
        let action = KeyAction::try_from(self.u8()?)?;
        let key = KeyCode::new(self.u16()?).ok_or(Malformed::Field)?;
        let mods = self.u16()?;
        let unshifted = char::from_u32(self.u32()?).ok_or(Malformed::Field)?;
        let text = std::str::from_utf8(self.bytes()?)
            .map_err(|_| Malformed::Field)?
            .to_owned();
        let composing = self.flag()?;
        Ok(Key {
            action,
            key,
            mods,
            unshifted,
            text,
            composing,
        })
    }

    fn mouse(&mut self) -> Result<Mouse, Malformed> {
        let action = MouseAction::try_from(self.u8()?)?;
        let button = MouseButton::try_from(self.u8()?)?;
        Ok(Mouse {
            action,
            button,
            col: self.u16()?,
            row: self.u16()?,
            mods: self.u16()?,
        })
    }
}

pub fn decode_request(frame: &[u8]) -> Result<Request<'_>, Malformed> {
    let (&code, body) = frame
        .get(4..)
        .and_then(<[u8]>::split_first)
        .ok_or(Malformed::Length)?;
    let mut fields = Fields(body);
    let request = match Kind::of_code(code).ok_or(Malformed::Unknown)? {
        Kind::Init => Request::Init(fields.init()?),
        Kind::Tail => {
            fields.take(8)?;
            Request::Tail
        }
        Kind::Resize => Request::Resize(fields.size()?),
        Kind::Text => return Ok(Request::Text(body)),
        Kind::Snapshot => {
            let req = Req(fields.u32()?);
            let screen = fields.u8()? != 0;
            if fields.u8()? != 0 || !fields.text()?.is_empty() {
                return Err(Malformed::Field);
            }
            let history = if screen { History::None } else { History::All };
            Request::Snapshot { req, history }
        }
        Kind::Exit => return Ok(Request::Exit),
        Kind::ClearHistory => return Ok(Request::ClearHistory),
        Kind::Key => Request::Key(fields.key()?),
        Kind::Mouse => Request::Mouse(fields.mouse()?),
        Kind::Paste => {
            let req = Req(fields.u32()?);
            let text = std::str::from_utf8(fields.bytes()?).map_err(|_| Malformed::Field)?;
            let check_safe = fields.flag()?;
            Request::Paste {
                req,
                text,
                check_safe,
            }
        }
        Kind::Focus => Request::Focus(fields.flag()?),
        Kind::Screen => {
            let req = Req(fields.u32()?);
            let format = if fields.u8()? == 0 {
                ScreenFormat::Plain
            } else {
                ScreenFormat::Ansi
            };
            let rows = match fields.u32()? {
                0 => ScreenRows::Visible,
                u32::MAX => ScreenRows::Full,
                rows => ScreenRows::Last(rows),
            };
            Request::Screen { req, format, rows }
        }
        Kind::Ready
        | Kind::Head
        | Kind::Title
        | Kind::Pwd
        | Kind::Dead
        | Kind::SnapshotDone
        | Kind::Error
        | Kind::Full
        | Kind::PasteDone
        | Kind::Prompt
        | Kind::Record
        | Kind::Foreground
        | Kind::Alternate
        | Kind::Bell
        | Kind::Notify
        | Kind::Progress => return Err(Malformed::Unknown),
    };
    fields.end()?;
    Ok(request)
}

#[cfg(test)]
#[allow(clippy::arithmetic_side_effects)]
mod tests {
    use super::*;

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
    fn every_frame_size_in_a_stream_is_between_the_header_and_the_input() {
        let mut stream = Vec::new();
        for length in [1u32, 2, 300, MAX_FRAME] {
            stream.extend_from_slice(&length.to_le_bytes());
            stream.extend(std::iter::repeat_n(7, length as usize));
        }
        assert!(check_sizes(&stream));
        for input in [
            &[][..],
            &[0, 0, 0],
            &[0, 0, 0, 0],
            &[1, 0, 0, 0],
            &[255, 255, 255, 255, 1],
            &(MAX_FRAME + 1).to_le_bytes(),
        ] {
            assert!(check_sizes(input));
        }
        let mut seed = 182u64;
        for round in 0..2000 {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let size = (seed >> 33) as usize % 200;
            let mut input: Vec<u8> = (0..size).map(|i| (seed >> (i % 56)) as u8).collect();
            if round % 2 == 1 {
                for at in (0..size.saturating_sub(5)).step_by(16) {
                    input[at] = (seed >> 20) as u8 % 70;
                    input[at + 1..at + 4].fill(0);
                }
            }
            assert!(check_sizes(&input));
        }
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
        assert_eq!(decode(&[1, 0, 0, 0, 99]), Err(Malformed::Unknown));
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
        let req = Req::of_serial(2);
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
    fn the_init_frame_has_its_wire_layout() {
        let init = Init {
            size: Size::DEFAULT,
            limits: Limits {
                scrollback: Scrollback::Disabled,
                apc_max_bytes: 3,
                kitty_images_max_bytes: 4,
                continuation_max_bytes: 5,
            },
            media: vec![Medium::File, Medium::SharedMem].into(),
            cwd: Path::new("/").into(),
            argv: vec![b"/bin/sh".to_vec()].into(),
            env: Vec::new().into(),
            id: "pane_1".into(),
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

    fn decoded<T>(frame: &ToPane<'_>, inspect: impl FnOnce(Request<'_>) -> T) -> T {
        let bytes = encoded(frame);
        inspect(decode_request(&bytes).unwrap())
    }

    #[test]
    fn the_pane_decodes_what_the_server_encodes() {
        let init = Init {
            size: Size::DEFAULT,
            limits: Limits {
                scrollback: Scrollback::Bounded {
                    max_bytes: NonZeroUsize::new(50),
                    max_lines: NonZeroUsize::new(7),
                },
                apc_max_bytes: 3,
                kitty_images_max_bytes: 4,
                continuation_max_bytes: 5,
            },
            media: vec![Medium::File, Medium::SharedMem].into(),
            cwd: Path::new("/tmp").into(),
            argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec()].into(),
            env: vec![b"A=b".to_vec()].into(),
            id: "pane_9".into(),
        };
        decoded(&ToPane::Init(&init), |request| {
            let Request::Init(got) = request else {
                panic!("not an init");
            };
            assert_eq!(
                (
                    got.size,
                    got.limits,
                    &*got.media,
                    &*got.cwd,
                    &*got.argv,
                    &*got.env,
                    &*got.id
                ),
                (
                    init.size,
                    init.limits,
                    &*init.media,
                    &*init.cwd,
                    &*init.argv,
                    &*init.env,
                    &*init.id
                )
            );
        });
        let disabled = Init {
            limits: Limits {
                scrollback: Scrollback::Disabled,
                ..init.limits
            },
            ..init.clone()
        };
        decoded(&ToPane::Init(&disabled), |request| {
            assert!(matches!(
                request,
                Request::Init(Init {
                    limits: Limits {
                        scrollback: Scrollback::Disabled,
                        ..
                    },
                    ..
                })
            ));
        });
        let key = Key {
            action: KeyAction::Repeat,
            key: KeyCode::new(MAX_KEY).unwrap(),
            mods: 5,
            unshifted: '\u{e9}',
            text: "\u{c9}".to_owned(),
            composing: true,
        };
        decoded(&ToPane::Key(&key), |request| {
            assert!(matches!(request, Request::Key(got) if got == key));
        });
        let mouse = Mouse {
            action: MouseAction::Motion,
            button: MouseButton::Eleven,
            col: 9,
            row: 8,
            mods: 7,
        };
        decoded(&ToPane::Mouse(mouse), |request| {
            assert!(matches!(request, Request::Mouse(got) if got == mouse));
        });
        let size = Size {
            cell_px: None,
            ..Size::DEFAULT
        };
        decoded(&ToPane::Resize(size), |request| {
            assert!(matches!(request, Request::Resize(got) if got == size));
        });
        let req = Req::of_serial(2);
        decoded(
            &ToPane::Snapshot {
                req,
                history: History::All,
            },
            |request| {
                assert!(matches!(
                    request,
                    Request::Snapshot {
                        history: History::All,
                        ..
                    }
                ));
            },
        );
        for rows in [ScreenRows::Visible, ScreenRows::Full, ScreenRows::Last(12)] {
            let screen = ToPane::Screen {
                req,
                format: ScreenFormat::Ansi,
                rows,
            };
            decoded(&screen, |request| {
                assert!(matches!(
                    request,
                    Request::Screen { format: ScreenFormat::Ansi, rows: got, .. } if got == rows
                ));
            });
        }
        let paste = encoded(&ToPane::Paste {
            req,
            text: "a\nb",
            check_safe: true,
        });
        assert!(matches!(
            decode_request(&paste),
            Ok(Request::Paste {
                text: "a\nb",
                check_safe: true,
                ..
            })
        ));
        let text = encoded(&ToPane::Text(b"\x00x"));
        assert!(matches!(decode_request(&text), Ok(Request::Text(b"\x00x"))));
        decoded(&ToPane::Focus(true), |request| {
            assert!(matches!(request, Request::Focus(true)));
        });
        decoded(&ToPane::ClearHistory, |request| {
            assert!(matches!(request, Request::ClearHistory));
        });
        decoded(&ToPane::Tail(Pos::new(9)), |request| {
            assert!(matches!(request, Request::Tail));
        });
        decoded(&ToPane::Exit, |request| {
            assert!(matches!(request, Request::Exit));
        });
    }

    #[test]
    fn a_request_with_a_field_outside_its_range_is_refused() {
        let key = |action: u8, code: u16, codepoint: u32, composing: u8| {
            let mut body = vec![action];
            body.extend(code.to_le_bytes());
            body.extend(0u16.to_le_bytes());
            body.extend(codepoint.to_le_bytes());
            body.extend(0u32.to_le_bytes());
            body.push(composing);
            frame(Kind::Key, &body)
        };
        let refused = |bytes: Vec<u8>, label: &str| {
            assert!(decode_request(&bytes).is_err(), "{label}");
        };
        assert!(decode_request(&key(1, 20, 97, 0)).is_ok());
        refused(key(3, 20, 97, 0), "key action");
        refused(key(1, MAX_KEY + 1, 97, 0), "key code");
        refused(key(1, 20, 0xd800, 0), "surrogate");
        refused(key(1, 20, 0x11_0000, 0), "codepoint");
        refused(key(1, 20, 97, 2), "composing");
        refused(
            frame(Kind::Mouse, &[3, 1, 0, 0, 0, 0, 0, 0]),
            "mouse action",
        );
        refused(
            frame(Kind::Mouse, &[0, 12, 0, 0, 0, 0, 0, 0]),
            "mouse button",
        );
        refused(frame(Kind::Focus, &[2]), "focus");
        refused(frame(Kind::Tail, &[0; 7]), "short tail");
        refused(
            frame(Kind::Resize, &[0, 0, 24, 0, 8, 0, 16, 0]),
            "zero columns",
        );
        refused(
            frame(Kind::Resize, &[1, 16, 24, 0, 8, 0, 16, 0]),
            "4097 columns",
        );
        refused(
            frame(Kind::Resize, &[80, 0, 24, 0, 8, 0, 16, 0, 0]),
            "trailing byte",
        );
        refused(
            frame(Kind::Snapshot, &[1, 0, 0, 0, 1, 1, 0, 0, 0, 0]),
            "images",
        );
        refused(
            frame(Kind::Snapshot, &[1, 0, 0, 0, 1, 0, 1, 0, 0, 0, b'x']),
            "file",
        );
        refused(
            frame(Kind::Paste, &[1, 0, 0, 0, 0, 0, 0, 0, 2]),
            "check flag",
        );
        refused(
            frame(Kind::Ready, &[1, 0, 0, 0]),
            "a frame of the other direction",
        );
        let init = |version: u16, argv: &[&[u8]], cwd: &[u8]| {
            let mut body = version.to_le_bytes().to_vec();
            body.extend([80, 0, 24, 0, 8, 0, 16, 0]);
            body.extend([0; 18]);
            body.extend([0; 8]);
            body.extend([0; 8]);
            body.push(0);
            body.extend([0; 8]);
            body.extend((cwd.len() as u32).to_le_bytes());
            body.extend(cwd);
            body.extend((argv.len() as u32).to_le_bytes());
            for arg in argv {
                body.extend((arg.len() as u32).to_le_bytes());
                body.extend(*arg);
            }
            body.extend([0; 4]);
            body.extend([0; 4]);
            frame(Kind::Init, &body)
        };
        assert!(decode_request(&init(3, &[b"/bin/sh"], b"/")).is_ok());
        refused(init(2, &[b"/bin/sh"], b"/"), "version");
        refused(init(3, &[], b"/"), "no program");
        refused(init(3, &[b"sh"], b"/"), "relative program");
        refused(init(3, &[b"/bin/sh"], b"/\0"), "NUL in a string");
    }

    #[test]
    fn what_the_pane_sends_decodes_to_what_it_was_built_from() {
        let dead = Dead {
            at: Mono::from_nanos(77),
            exit: Exit::Signaled(9),
        };
        let req = Req::of_serial(1);
        let cases = [
            FromPane::Ready(4242),
            FromPane::Head(Pos::new(123)),
            FromPane::Title(b"a title"),
            FromPane::Pwd(b""),
            FromPane::Dead(dead),
            FromPane::SnapshotDone(req),
            FromPane::PasteDone {
                req,
                pasted: true,
                unsafe_paste: false,
            },
            FromPane::Screen {
                req,
                last: true,
                text: b"rows",
            },
            FromPane::Error(b"openpty: no"),
            FromPane::Full(Pos::new(456)),
            FromPane::Prompt(Prompt {
                step: PromptStep::End,
                exit: Some(-2),
                at: Mono::from_nanos(9),
                command: b"",
            }),
            FromPane::Prompt(Prompt {
                step: PromptStep::OutputStart,
                exit: None,
                at: Mono::from_nanos(10),
                command: b"sleep 2",
            }),
            FromPane::Record(Record {
                state: ProgramState::Blocked,
                kind: ProgramKind::Question,
                progress: Some(42),
                id: b"a/b",
                app: b"",
                title: b"t",
                msg: b"m",
            }),
            FromPane::Record(Record {
                state: ProgramState::Clear,
                kind: ProgramKind::None,
                progress: None,
                id: b"",
                app: b"",
                title: b"",
                msg: b"",
            }),
            FromPane::Foreground(Foreground {
                pid: 77,
                name: b"sleep",
            }),
            FromPane::Alternate(true),
            FromPane::Bell,
            FromPane::Notify {
                title: b"",
                body: b"done",
            },
            FromPane::Progress(None),
            FromPane::Progress(Some(ProgressReport {
                state: ProgressState::Pause,
                progress: Some(100),
            })),
            FromPane::Progress(Some(ProgressReport {
                state: ProgressState::Indeterminate,
                progress: None,
            })),
        ];
        for case in cases {
            let mut out = Vec::new();
            encode_from(&case, &mut out).unwrap();
            assert_eq!(frame_size(&out), Ok(Some(out.len())));
            assert_eq!(decode(&out), Ok(Some(case)));
        }
        let mut exited = Vec::new();
        let ended = Dead {
            exit: Exit::Exited(-3),
            ..dead
        };
        encode_from(&FromPane::Dead(ended), &mut exited).unwrap();
        assert_eq!(decode(&exited), Ok(Some(FromPane::Dead(ended))));
    }

    #[test]
    fn a_report_frame_with_a_field_outside_its_range_is_refused() {
        let tail = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let record = |state: u8, kind: u8, progress: u8| {
            let mut body = vec![state, kind, progress];
            body.extend([0; 16]);
            frame(Kind::Record, &body)
        };
        assert!(decode(&record(5, 3, 100)).is_ok());
        assert!(decode(&record(5, 3, 255)).is_ok());
        for bad in [record(6, 0, 0), record(0, 4, 0), record(0, 0, 101)] {
            assert_eq!(decode(&bad), Err(Malformed::Field));
        }
        let mut prompt = vec![4, 0];
        prompt.extend(tail);
        assert_eq!(decode(&frame(Kind::Prompt, &prompt)), Err(Malformed::Field));
        assert_eq!(
            decode(&frame(Kind::Progress, &[5, 255])),
            Err(Malformed::Field)
        );
        assert_eq!(
            decode(&frame(Kind::Alternate, &[1, 0])),
            Err(Malformed::Trailing)
        );
        assert_eq!(decode(&frame(Kind::Bell, &[0])), Err(Malformed::Trailing));
    }

    #[test]
    fn dim_holds_one_to_the_maximum() {
        assert_eq!(Dim::new(0), None);
        assert_eq!(Dim::new(1).map(Dim::get), Some(1));
        assert_eq!(Dim::new(MAX_DIMENSION).map(Dim::get), Some(MAX_DIMENSION));
        assert_eq!(Dim::new(MAX_DIMENSION + 1), None);
    }
}
