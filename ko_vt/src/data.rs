use std::ffi::c_int;
use std::marker::PhantomData;

use ko_vt_sys as sys;

#[derive(Debug, Clone, Copy)]
pub(super) struct Terminal;

#[derive(Debug, Clone, Copy)]
pub(super) struct RenderState;

#[derive(Debug, Clone, Copy)]
pub(super) struct Cells;

#[derive(Debug, Clone, Copy)]
pub(super) struct Cell;

#[derive(Debug, Clone, Copy)]
pub(super) struct Key<D, T> {
    raw: c_int,
    ty: PhantomData<(D, T)>,
}

impl<D, T> Key<D, T> {
    pub(super) fn raw(&self) -> c_int {
        self.raw
    }

    const fn new(raw: c_int) -> Self {
        Self {
            raw,
            ty: PhantomData,
        }
    }
}

pub(super) const COLS: Key<Terminal, u16> = Key::new(sys::GHOSTTY_TERMINAL_DATA_COLS);
pub(super) const ROWS: Key<Terminal, u16> = Key::new(sys::GHOSTTY_TERMINAL_DATA_ROWS);
pub(super) const CURSOR_X: Key<Terminal, u16> = Key::new(sys::GHOSTTY_TERMINAL_DATA_CURSOR_X);
pub(super) const CURSOR_Y: Key<Terminal, u16> = Key::new(sys::GHOSTTY_TERMINAL_DATA_CURSOR_Y);
pub(super) const CURSOR_VISIBLE: Key<Terminal, bool> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE);
pub(super) const CURSOR_PENDING_WRAP: Key<Terminal, bool> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP);
pub(super) const ACTIVE_SCREEN: Key<Terminal, sys::GhosttyTerminalScreen> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN);
pub(super) const TITLE: Key<Terminal, sys::GhosttyString> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_TITLE);
pub(super) const PWD: Key<Terminal, sys::GhosttyString> = Key::new(sys::GHOSTTY_TERMINAL_DATA_PWD);
pub(super) const SCROLLBAR: Key<Terminal, sys::GhosttyTerminalScrollbar> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_SCROLLBAR);
pub(super) const MEMORY_USAGE: Key<Terminal, sys::GhosttyTerminalMemoryUsage> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_MEMORY_USAGE);
pub(super) const MODE: Key<Terminal, sys::GhosttyTerminalModeConfig> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_MODE);
pub(super) const TOTAL_ROWS: Key<Terminal, usize> = Key::new(sys::GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
pub(super) const MOUSE_TRACKING: Key<Terminal, bool> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING);
pub(super) const KITTY_KEYBOARD_FLAGS: Key<Terminal, u8> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS);
pub(super) const KITTY_GRAPHICS: Key<Terminal, sys::GhosttyKittyGraphics> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS);
pub(super) const KITTY_PENDING_GENERATION: Key<Terminal, u64> =
    Key::new(sys::GHOSTTY_TERMINAL_DATA_KITTY_PENDING_GENERATION);

pub(super) mod render {
    use super::{Cells, Key, RenderState, sys};

    pub(crate) const ROW_ITERATOR: Key<RenderState, sys::GhosttyRenderStateRowIterator> =
        Key::new(sys::GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR);
    pub(crate) const COLS: Key<RenderState, u16> = Key::new(sys::GHOSTTY_RENDER_STATE_DATA_COLS);
    pub(crate) const ROWS: Key<RenderState, u16> = Key::new(sys::GHOSTTY_RENDER_STATE_DATA_ROWS);
    pub(crate) const CURSOR: Key<RenderState, sys::GhosttyRenderStateCursor> =
        Key::new(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR);
    pub(crate) const RAW: Key<Cells, sys::GhosttyCell> =
        Key::new(sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW);
    pub(crate) const STYLE: Key<Cells, sys::GhosttyStyle> =
        Key::new(sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE);
}

pub(super) mod cell {
    use super::{Cell, Key, sys};

    pub(crate) const WIDE: Key<Cell, sys::GhosttyCellWide> = Key::new(sys::GHOSTTY_CELL_DATA_WIDE);
    pub(crate) const CONTENT_TAG: Key<Cell, sys::GhosttyCellContentTag> =
        Key::new(sys::GHOSTTY_CELL_DATA_CONTENT_TAG);
    pub(crate) const COLOR_PALETTE: Key<Cell, u8> = Key::new(sys::GHOSTTY_CELL_DATA_COLOR_PALETTE);
    pub(crate) const COLOR_RGB: Key<Cell, sys::GhosttyColorRgb> =
        Key::new(sys::GHOSTTY_CELL_DATA_COLOR_RGB);
}
