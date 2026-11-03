use std::ffi::c_void;
use std::ptr;
use std::time::{Duration, Instant};

use ko_vt_sys as sys;

use crate::{Error, Notes, Terminal, check, get};

const HOLD: Duration = Duration::from_millis(150);
const LOCAL: usize = 128;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Colour {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attribute {
    Bold,
    Italic,
    Underline,
    Inverse,
    Dim,
    Blink,
    Hidden,
    Strikethrough,
    Overline,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Attributes(u16);

impl Attributes {
    pub fn has(self, attribute: Attribute) -> bool {
        self.0 & (1 << attribute as u16) != 0
    }

    pub fn with(self, attribute: Attribute) -> Attributes {
        Attributes(self.0 | 1 << attribute as u16)
    }

    fn of(style: &sys::GhosttyStyle) -> Attributes {
        let flags = [
            style.bold,
            style.italic,
            style.underline != 0,
            style.inverse,
            style.faint,
            style.blink,
            style.invisible,
            style.strikethrough,
            style.overline,
        ];
        Attributes(
            flags
                .iter()
                .enumerate()
                .fold(0, |bits, (bit, on)| bits | u16::from(*on) << bit),
        )
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Style {
    pub fg: Colour,
    pub bg: Colour,
    pub attrs: Attributes,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub width: u8,
    pub style: Style,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CursorShape {
    Bar,
    #[default]
    Block,
    Underline,
    HollowBlock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameCursor {
    pub x: u16,
    pub y: u16,
    pub shape: CursorShape,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MouseTracking {
    #[default]
    Off,
    Press,
    Button,
    Any,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Frame {
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<Cell>,
    pub cursor: Option<FrameCursor>,
    pub mouse: MouseTracking,
    pub keyboard: u8,
}

#[derive(Debug)]
pub(crate) struct Render {
    state: sys::GhosttyRenderState,
    rows: sys::GhosttyRenderStateRowIterator,
    cells: sys::GhosttyRenderStateRowCells,
    held: bool,
    started: Instant,
    id: u64,
    error: sys::GhosttyResult,
}

impl Drop for Render {
    fn drop(&mut self) {
        // SAFETY: each handle was created by `Render::new` (or is NULL, which the frees permit)
        // and is freed once.
        unsafe {
            sys::ghostty_render_state_row_cells_free(self.cells);
            sys::ghostty_render_state_row_iterator_free(self.rows);
            sys::ghostty_render_state_free(self.state);
        }
    }
}

impl Render {
    fn new() -> Result<Render, Error> {
        let mut render = Render {
            state: ptr::null_mut(),
            rows: ptr::null_mut(),
            cells: ptr::null_mut(),
            held: false,
            started: Instant::now(),
            id: 0,
            error: sys::GHOSTTY_SUCCESS,
        };
        // SAFETY: each handle receives a new object that `Render` frees.
        check(unsafe { sys::ghostty_render_state_new(ptr::null(), &mut render.state) })?;
        // SAFETY: as above.
        check(unsafe {
            sys::ghostty_render_state_row_iterator_new(ptr::null(), &mut render.rows)
        })?;
        // SAFETY: as above.
        check(unsafe { sys::ghostty_render_state_row_cells_new(ptr::null(), &mut render.cells) })?;
        Ok(render)
    }
}

unsafe extern "C" fn hold(terminal: sys::GhosttyTerminal, userdata: *mut c_void, held: bool) {
    // SAFETY: userdata is the `Notes` that `watch` registered, which the terminal owns and nothing
    // else touches during a write; the callback does not call back into the terminal except
    // through the render state's own update, which terminal.h permits.
    let Some(render) = (unsafe { &mut *userdata.cast::<Notes>() }).render.as_mut() else {
        return;
    };
    if held {
        if render.error == sys::GHOSTTY_SUCCESS {
            // SAFETY: the render state is live, and terminal is the handle that is writing.
            render.error = unsafe { sys::ghostty_render_state_update(render.state, terminal) };
        }
        render.started = Instant::now();
        render.id += 1;
    }
    render.held = held;
}

fn colour(color: sys::GhosttyStyleColor) -> Colour {
    match color.tag {
        // SAFETY: the tag names the palette member as the active one.
        sys::GHOSTTY_STYLE_COLOR_PALETTE => Colour::Indexed(unsafe { color.value.palette }),
        sys::GHOSTTY_STYLE_COLOR_RGB => {
            // SAFETY: the tag names the rgb member as the active one.
            let rgb = unsafe { color.value.rgb };
            Colour::Rgb(rgb.r, rgb.g, rgb.b)
        }
        _ => Colour::Default,
    }
}

impl Terminal {
    pub fn watch(&mut self) -> Result<(), Error> {
        self.notes.render = Some(Render::new()?);
        let userdata = ptr::from_mut(&mut *self.notes).cast::<c_void>();
        let set = |option, value: *const c_void| {
            // SAFETY: each caller passes the type that terminal.h documents for its option.
            check(unsafe { sys::ghostty_terminal_set(self.vt.as_ptr(), option, value) })
        };
        set(sys::GHOSTTY_TERMINAL_OPT_USERDATA, userdata)?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
            hold as unsafe extern "C" fn(_, _, _) as *const c_void,
        )
    }

    fn render_state(&mut self) -> Result<&mut Render, Error> {
        self.notes.render.as_mut().ok_or(Error::NotWatched)
    }

    pub fn hold(&self) -> Option<(u64, Instant)> {
        let render = self.notes.render.as_ref().filter(|render| render.held)?;
        let expires = render.started + HOLD;
        (expires > Instant::now()).then_some((render.id, expires))
    }

    pub fn render_into(&mut self, frame: &mut Frame) -> Result<(), Error> {
        let vt = self.vt.as_ptr();
        let (held, expired, error) = {
            let render = self.render_state()?;
            (render.held, render.started.elapsed() >= HOLD, render.error)
        };
        check(error)?;
        if held && expired {
            self.set_mode(2026, false)?;
            self.render_state()?.held = false;
        }
        let (state, rows, cells, held) = {
            let render = self.render_state()?;
            (render.state, render.rows, render.cells, render.held)
        };
        if !held {
            // SAFETY: both handles are live.
            check(unsafe { sys::ghostty_render_state_update(state, vt) })?;
        }
        let state_get = |data| {
            move |out| {
                // SAFETY: each caller names the data whose output type render.h documents as T.
                unsafe { sys::ghostty_render_state_get(state, data, out) }
            }
        };
        let cols = get(state_get(sys::GHOSTTY_RENDER_STATE_DATA_COLS), 0u16)?;
        let height = get(state_get(sys::GHOSTTY_RENDER_STATE_DATA_ROWS), 0u16)?;
        let mut count = 0;
        let mut iterator = rows;
        check(state_get(sys::GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR)(
            ptr::from_mut(&mut iterator).cast(),
        ))?;
        // SAFETY: the iterator is live until the next state update.
        while unsafe { sys::ghostty_render_state_row_iterator_next(rows) } {
            let mut row_cells = cells;
            // SAFETY: the iterator is positioned on a row, and row_cells receives its cell cursor.
            check(unsafe {
                sys::ghostty_render_state_row_get(
                    rows,
                    sys::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                    ptr::from_mut(&mut row_cells).cast(),
                )
            })?;
            // SAFETY: the cell cursor is live.
            while unsafe { sys::ghostty_render_state_row_cells_next(cells) } {
                match frame.cells.get_mut(count) {
                    Some(slot) => fill(cells, slot)?,
                    None => {
                        let mut slot = Cell::default();
                        fill(cells, &mut slot)?;
                        frame.cells.push(slot);
                    }
                }
                count += 1;
            }
        }
        if count != usize::from(cols) * usize::from(height) {
            return Err(Error::CellCount);
        }
        frame.cells.truncate(count);
        let cursor = get(
            state_get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR),
            sys::GhosttyRenderStateCursor {
                size: size_of::<sys::GhosttyRenderStateCursor>(),
                ..Default::default()
            },
        )?;
        let tracking = self.get(sys::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false)?;
        let mouse = if !tracking {
            MouseTracking::Off
        } else if self.mode(1003)? {
            MouseTracking::Any
        } else if self.mode(1002)? {
            MouseTracking::Button
        } else {
            MouseTracking::Press
        };
        let keyboard = self.get(sys::GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, 0u8)?;
        // SAFETY: the render state is live.
        check(unsafe { sys::ghostty_render_state_clean(state) })?;
        frame.cols = cols;
        frame.rows = height;
        frame.cursor = (cursor.viewport_has_value && cursor.visible).then_some(FrameCursor {
            x: cursor.viewport_x,
            y: cursor.viewport_y,
            shape: match cursor.visual_style {
                sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => CursorShape::Bar,
                sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => CursorShape::Underline,
                sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => {
                    CursorShape::HollowBlock
                }
                _ => CursorShape::Block,
            },
        });
        frame.mouse = mouse;
        frame.keyboard = keyboard;
        Ok(())
    }
}

fn of<T>(raw: sys::GhosttyCell, data: sys::GhosttyCellData, value: T) -> Result<T, Error> {
    get(
        |out| {
            // SAFETY: each caller names the data whose output type cell.h documents as T.
            unsafe { sys::ghostty_cell_get(raw, data, out) }
        },
        value,
    )
}

fn fill(cells: sys::GhosttyRenderStateRowCells, target: &mut Cell) -> Result<(), Error> {
    let at = |data| {
        move |out| {
            // SAFETY: each caller names the data whose output type render.h documents as T.
            unsafe { sys::ghostty_render_state_row_cells_get(cells, data, out) }
        }
    };
    let raw: sys::GhosttyCell = get(at(sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW), 0)?;
    let style = get(
        at(sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE),
        sys::GhosttyStyle {
            size: size_of::<sys::GhosttyStyle>(),
            ..Default::default()
        },
    )?;
    let wide: sys::GhosttyCellWide = of(raw, sys::GHOSTTY_CELL_DATA_WIDE, 0)?;
    let content: sys::GhosttyCellContentTag = of(raw, sys::GHOSTTY_CELL_DATA_CONTENT_TAG, 0)?;
    let bg = match content {
        sys::GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE => {
            Colour::Indexed(of(raw, sys::GHOSTTY_CELL_DATA_COLOR_PALETTE, 0u8)?)
        }
        sys::GHOSTTY_CELL_CONTENT_BG_COLOR_RGB => {
            let rgb = of(
                raw,
                sys::GHOSTTY_CELL_DATA_COLOR_RGB,
                sys::GhosttyColorRgb { r: 0, g: 0, b: 0 },
            )?;
            Colour::Rgb(rgb.r, rgb.g, rgb.b)
        }
        _ => colour(style.bg_color),
    };
    let mut local = [0u8; LOCAL];
    let mut large = Vec::new();
    let mut buffer = sys::GhosttyBuffer {
        ptr: local.as_mut_ptr(),
        cap: LOCAL,
        len: 0,
    };
    let grapheme = |buffer: &mut sys::GhosttyBuffer| {
        // SAFETY: the cursor is live, and the buffer's cap bytes are writable.
        unsafe {
            sys::ghostty_render_state_row_cells_get(
                cells,
                sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                ptr::from_mut(buffer).cast(),
            )
        }
    };
    let mut result = grapheme(&mut buffer);
    if result == sys::GHOSTTY_OUT_OF_SPACE {
        large.resize(buffer.len, 0);
        buffer.ptr = large.as_mut_ptr();
        buffer.cap = large.len();
        result = grapheme(&mut buffer);
    }
    check(result)?;
    let bytes = if buffer.len == 0 {
        &[]
    } else {
        // SAFETY: the buffer holds len initialized bytes at ptr, which local or large keeps alive.
        unsafe { std::slice::from_raw_parts(buffer.ptr, buffer.len) }
    };
    target.text.clear();
    match std::str::from_utf8(bytes) {
        Ok(text) => target.text.push_str(text),
        Err(_) => target.text.push_str(&String::from_utf8_lossy(bytes)),
    }
    target.width = match wide {
        sys::GHOSTTY_CELL_WIDE_WIDE => 2,
        sys::GHOSTTY_CELL_WIDE_SPACER_TAIL => 0,
        _ => 1,
    };
    target.style = Style {
        fg: colour(style.fg_color),
        bg,
        attrs: Attributes::of(&style),
    };
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;

    use ko_pane_wire::frame::{Dim, Limits, Scrollback};

    use super::*;
    use crate::{Extent, Format};

    fn make(cols: u16, rows: u16) -> Terminal {
        let limits = Limits {
            scrollback: Scrollback::Bounded {
                max_bytes: NonZeroUsize::new(50_000_000),
                max_lines: None,
            },
            apc_max_bytes: 65 * 1024 * 1024,
            kitty_images_max_bytes: 10_000_000,
            continuation_max_bytes: 65 * 1024 * 1024,
        };
        let mut vt =
            Terminal::new(Dim::new(cols).unwrap(), Dim::new(rows).unwrap(), limits).unwrap();
        vt.watch().unwrap();
        vt
    }

    fn rendered(vt: &mut Terminal) -> Frame {
        let mut frame = Frame::default();
        vt.render_into(&mut frame).unwrap();
        frame
    }

    #[test]
    fn synchronized_output_keeps_the_frame_at_the_start_of_the_hold() {
        let mut vt = make(8, 2);
        vt.write(b"old\x1b[?2026h\rnew");
        assert_eq!(rendered(&mut vt).cells[0].text, "o");
        assert!(vt.hold().is_some_and(|(id, _)| id > 0));
        vt.write(b"\x1b[?2026l");
        assert_eq!(rendered(&mut vt).cells[0].text, "n");
        assert_eq!(vt.hold(), None);
    }

    #[test]
    fn render_keeps_palette_indices_rgb_overrides_wide_tails_and_viewport_modes() {
        let mut server = make(8, 2);
        let mut bytes = b"first\r\nsecond\r\n\x1b[32;48;2;1;2;3m".to_vec();
        bytes.extend_from_slice("界x".as_bytes());
        bytes.extend_from_slice(
            b"\x1b[?1h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[=3;1u",
        );
        server.write(&bytes);
        let mut snapshot = Vec::new();
        server
            .snapshot(false, |piece| {
                snapshot.extend_from_slice(piece);
                true
            })
            .unwrap();
        let mut vt = Terminal::decode(&mut &snapshot[..], Extent::Full).unwrap();
        vt.watch().unwrap();
        for mode in [1, 1002, 1004, 1006, 2004] {
            assert!(vt.mode(mode).unwrap(), "mode {mode}");
        }
        let frame = rendered(&mut vt);
        assert_eq!(
            (frame.cols, frame.rows, frame.mouse, frame.keyboard),
            (8, 2, MouseTracking::Button, 3)
        );
        let cells: Vec<String> = frame
            .cells
            .iter()
            .enumerate()
            .filter(|(_, cell)| !cell.text.is_empty())
            .map(|(i, cell)| {
                format!(
                    "{i} {:?} {} {:?} {:?}",
                    cell.text, cell.width, cell.style.fg, cell.style.bg
                )
            })
            .collect();
        assert_eq!(
            cells,
            [
                "0 \"s\" 1 Default Default",
                "1 \"e\" 1 Default Default",
                "2 \"c\" 1 Default Default",
                "3 \"o\" 1 Default Default",
                "4 \"n\" 1 Default Default",
                "5 \"d\" 1 Default Default",
                "8 \"界\" 2 Indexed(2) Rgb(1, 2, 3)",
                "10 \"x\" 1 Indexed(2) Rgb(1, 2, 3)",
            ]
        );
        vt.scroll(-1);
        assert_eq!(rendered(&mut vt).cells[0].text, "f");
        assert!(vt.bottom().unwrap());
        assert!(!vt.bottom().unwrap());
        assert_eq!(rendered(&mut vt).cells[0].text, "s");
        assert!(vt.dump(Format::Plain).unwrap().starts_with(b"second"));
    }

    #[test]
    fn an_unwatched_terminal_does_not_render() {
        let mut vt = make(4, 2);
        vt.notes.render = None;
        assert!(matches!(
            vt.render_into(&mut Frame::default()),
            Err(Error::NotWatched)
        ));
    }
}
