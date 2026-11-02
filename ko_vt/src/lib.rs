#![allow(unsafe_code)]

use std::ffi::c_void;
use std::fmt;
use std::io::{self, Read};
use std::num::NonZeroUsize;
use std::ptr::{self, NonNull};

use ko_pane_wire::frame::{Dim, Limits, Medium, Scrollback, Size};
use ko_vt_sys as sys;

pub mod compress;
mod cut;
pub mod input;
pub mod render;
pub mod unicode;

#[derive(Debug)]
pub enum Error {
    Ghostty(sys::GhosttyResult),
    NoHandle,
    NoTerminal,
    NotWatched,
    CellCount,
    Rows(usize),
    Read(io::Error),
    Stopped,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Ghostty(code) => write!(f, "libghostty-vt operation failed ({code})"),
            Error::NoHandle => write!(f, "libghostty-vt returned no terminal handle"),
            Error::NoTerminal => write!(f, "the snapshot decoder returned no terminal"),
            Error::NotWatched => write!(f, "the terminal does not track rendering"),
            Error::CellCount => write!(f, "the render state has the wrong cell count"),
            Error::Rows(rows) => write!(f, "{rows} rows exceed a grid coordinate"),
            Error::Read(error) => write!(f, "snapshot read: {error}"),
            Error::Stopped => write!(f, "the output stopped the encoder"),
        }
    }
}

fn check(result: sys::GhosttyResult) -> Result<(), Error> {
    if result == sys::GHOSTTY_SUCCESS {
        Ok(())
    } else {
        Err(Error::Ghostty(result))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Plain,
    Vt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Extent {
    Screen,
    Full,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub x: u16,
    pub y: u16,
    pub visible: bool,
    pub pending_wrap: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Memory {
    pub pages: u64,
    pub compressed_pages: u64,
    pub resident_bytes: u64,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Changes {
    pub title: bool,
    pub pwd: bool,
}

#[derive(Debug, Default)]
struct Notes {
    replies: Vec<u8>,
    changes: Changes,
    render: Option<render::Render>,
}

// SAFETY: libghostty-vt keeps no thread-local or thread-affine state, and terminal.h requires
// only that the caller serializes every access to one terminal (ghostty_terminal_compress
// names writes, rendering, searches and other terminal access). The one thread that owns a
// terminal at a time is the holder of the mutex that wraps it, and the callbacks run inside
// the call that triggers them, on the calling thread.
unsafe impl Send for Terminal {}

#[derive(Debug)]
pub struct Terminal {
    vt: NonNull<sys::GhosttyTerminalImpl>,
    notes: Box<Notes>,
}

unsafe extern "C" fn write_pty(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    // SAFETY: userdata is the `Notes` that `serve` registered, which the terminal owns and
    // nothing else touches during a write; data holds len readable bytes (terminal.h).
    unsafe {
        (*userdata.cast::<Notes>())
            .replies
            .extend_from_slice(std::slice::from_raw_parts(data, len));
    }
}

unsafe extern "C" fn title_changed(_terminal: sys::GhosttyTerminal, userdata: *mut c_void) {
    // SAFETY: as in `write_pty`.
    unsafe { (*userdata.cast::<Notes>()).changes.title = true };
}

unsafe extern "C" fn pwd_changed(_terminal: sys::GhosttyTerminal, userdata: *mut c_void) {
    // SAFETY: as in `write_pty`.
    unsafe { (*userdata.cast::<Notes>()).changes.pwd = true };
}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.notes.render = None;
        // SAFETY: the terminal owns its handle, and no decoder borrows it after `decode` returns.
        unsafe { sys::ghostty_terminal_free(self.vt.as_ptr()) }
    }
}

struct Source<'a, R> {
    reader: &'a mut R,
    error: Option<io::Error>,
}

unsafe extern "C" fn read_into<R: Read>(
    userdata: *mut c_void,
    buffer: *mut u8,
    capacity: usize,
    out_read: *mut usize,
) -> bool {
    // SAFETY: userdata is the `Source` that `decode` keeps alive and does not touch while the
    // decoder runs; buffer holds capacity writable bytes and out_read is valid (io.h).
    let (source, buffer) = unsafe {
        (
            &mut *userdata.cast::<Source<'_, R>>(),
            std::slice::from_raw_parts_mut(buffer, capacity),
        )
    };
    loop {
        match source.reader.read(buffer) {
            Ok(count) if count <= capacity => {
                // SAFETY: out_read is non-NULL for the duration of the callback, and io.h
                // requires count <= capacity, which the guard checked: a safe `Read` may lie.
                unsafe { *out_read = count };
                return true;
            }
            Ok(count) => {
                source.error = Some(io::Error::other(format!(
                    "the reader returned {count} bytes for a buffer of {capacity}"
                )));
                return false;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => {
                source.error = Some(error);
                return false;
            }
        }
    }
}

unsafe extern "C" fn call_back<F: FnMut(&[u8]) -> bool>(
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) -> bool {
    // SAFETY: userdata is the closure that `callback_writer` lends for one libghostty-vt call,
    // and data holds len readable bytes (io.h).
    unsafe { (*userdata.cast::<F>())(std::slice::from_raw_parts(data, len)) }
}

fn callback_writer<F: FnMut(&[u8]) -> bool>(sink: &mut F) -> sys::GhosttyWriter {
    sys::GhosttyWriter {
        write: Some(call_back::<F>),
        userdata: ptr::from_mut(sink).cast(),
    }
}

unsafe extern "C" fn append(userdata: *mut c_void, data: *const u8, len: usize) -> bool {
    // SAFETY: userdata is the `Vec` that `writer` lends for one libghostty-vt call, and data
    // holds len readable bytes (io.h).
    unsafe {
        (*userdata.cast::<Vec<u8>>()).extend_from_slice(std::slice::from_raw_parts(data, len))
    };
    true
}

fn writer(out: &mut Vec<u8>) -> sys::GhosttyWriter {
    sys::GhosttyWriter {
        write: Some(append),
        userdata: ptr::from_mut(out).cast(),
    }
}

fn restore(
    decoder: sys::GhosttySnapshotDecoder,
    vt: &mut sys::GhosttyTerminal,
    extent: Extent,
) -> Result<(), Error> {
    let compress = true;
    // SAFETY: the decoder is live, and COMPRESS_HISTORY takes a bool.
    check(unsafe {
        sys::ghostty_snapshot_decoder_set(
            decoder,
            sys::GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY,
            ptr::from_ref(&compress).cast(),
        )
    })?;
    // SAFETY: the decoder is live, and vt receives the terminal that the caller frees after
    // the decoder, as snapshot.h requires.
    check(unsafe { sys::ghostty_snapshot_decoder_ready(decoder, vt) })?;
    if extent == Extent::Full {
        loop {
            // SAFETY: the decoder is live, and the terminal it restores into is alive.
            match unsafe { sys::ghostty_snapshot_decoder_next(decoder) } {
                sys::GHOSTTY_SUCCESS => {}
                sys::GHOSTTY_NO_VALUE => break,
                result => return Err(Error::Ghostty(result)),
            }
        }
    }
    Ok(())
}

impl Terminal {
    pub fn new(cols: Dim, rows: Dim, limits: Limits) -> Result<Terminal, Error> {
        let mut vt = ptr::null_mut();
        // SAFETY: a NULL allocator selects the default one; vt receives the new handle.
        check(unsafe { sys::ghostty_terminal_new(ptr::null(), &mut vt, cols.get(), rows.get()) })?;
        let mut terminal = Terminal {
            vt: NonNull::new(vt).ok_or(Error::NoHandle)?,
            notes: Box::default(),
        };
        terminal.configure(limits)?;
        Ok(terminal)
    }

    pub fn configure(&mut self, limits: Limits) -> Result<(), Error> {
        let (bytes, lines) = match limits.scrollback {
            Scrollback::Disabled => (Some(0), None),
            Scrollback::Bounded {
                max_bytes,
                max_lines,
            } => (
                max_bytes.map(NonZeroUsize::get),
                max_lines.map(NonZeroUsize::get),
            ),
        };
        let set = |option, value: Option<*const c_void>| {
            // SAFETY: each value points to the type that terminal.h documents for its option, and
            // NULL removes a scrollback limit.
            check(unsafe {
                sys::ghostty_terminal_set(self.vt.as_ptr(), option, value.unwrap_or(ptr::null()))
            })
        };
        let pointer = |value: &usize| ptr::from_ref(value).cast::<c_void>();
        set(
            sys::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
            bytes.as_ref().map(pointer),
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            lines.as_ref().map(pointer),
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES,
            Some(pointer(&limits.apc_max_bytes)),
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
            Some(ptr::from_ref(&limits.kitty_images_max_bytes).cast()),
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
            Some(pointer(&limits.continuation_max_bytes)),
        )
    }

    pub fn decode<R: Read>(reader: &mut R, extent: Extent) -> Result<Terminal, Error> {
        let mut source = Source {
            reader,
            error: None,
        };
        let reader = sys::GhosttyReader {
            read: Some(read_into::<R>),
            userdata: ptr::from_mut(&mut source).cast(),
        };
        let mut decoder = ptr::null_mut();
        let mut vt = ptr::null_mut();
        // SAFETY: source outlives the decoder, which is freed before this function reads it again.
        let result =
            check(unsafe { sys::ghostty_snapshot_decoder_new(ptr::null(), &mut decoder, reader) })
                .and_then(|()| restore(decoder, &mut vt, extent));
        // SAFETY: the decoder is freed once, whatever the result; snapshot.h permits NULL.
        unsafe { sys::ghostty_snapshot_decoder_free(decoder) };
        let terminal = NonNull::new(vt).map(|vt| Terminal {
            vt,
            notes: Box::default(),
        });
        if let Some(error) = source.error {
            return Err(Error::Read(error));
        }
        result?;
        terminal.ok_or(Error::NoTerminal)
    }

    pub fn serve(&mut self, media: &[Medium], tmpdir: &str) -> Result<(), Error> {
        let flag = |medium| media.contains(&medium);
        let set = |option, value: *const c_void| {
            // SAFETY: each caller passes the type that terminal.h documents for its option.
            check(unsafe { sys::ghostty_terminal_set(self.vt.as_ptr(), option, value) })
        };
        set(
            sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
            ptr::from_ref(&flag(Medium::File)).cast(),
        )?;
        let tmpdir = sys::GhosttyString {
            ptr: tmpdir.as_ptr(),
            len: tmpdir.len(),
        };
        set(
            sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
            if flag(Medium::TempFile) {
                ptr::from_ref(&tmpdir).cast()
            } else {
                ptr::null()
            },
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
            ptr::from_ref(&flag(Medium::SharedMem)).cast(),
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_USERDATA,
            ptr::from_mut(&mut *self.notes).cast(),
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY,
            write_pty as unsafe extern "C" fn(_, _, _, _) as *const c_void,
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
            title_changed as unsafe extern "C" fn(_, _) as *const c_void,
        )?;
        set(
            sys::GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
            pwd_changed as unsafe extern "C" fn(_, _) as *const c_void,
        )
    }

    pub fn replies(&mut self) -> &mut Vec<u8> {
        &mut self.notes.replies
    }

    pub fn take_changes(&mut self) -> Changes {
        std::mem::take(&mut self.notes.changes)
    }

    pub fn title(&self) -> Result<&[u8], Error> {
        self.string(sys::GHOSTTY_TERMINAL_DATA_TITLE)
    }

    pub fn pwd(&self) -> Result<&[u8], Error> {
        self.string(sys::GHOSTTY_TERMINAL_DATA_PWD)
    }

    fn string(&self, data: sys::GhosttyTerminalData) -> Result<&[u8], Error> {
        let empty = sys::GhosttyString {
            ptr: ptr::null(),
            len: 0,
        };
        let string = self.get(data, empty)?;
        Ok(if string.len == 0 {
            &[]
        } else {
            // SAFETY: the string holds len readable bytes until the next terminal call, which
            // the borrow of self excludes.
            unsafe { std::slice::from_raw_parts(string.ptr, string.len) }
        })
    }

    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: the handle is live and bytes is a valid slice for the call.
        unsafe { sys::ghostty_terminal_vt_write(self.vt.as_ptr(), bytes.as_ptr(), bytes.len()) }
    }

    pub fn resize(&mut self, size: Size) -> Result<(), Error> {
        let (width, height) = size.cell_pixels();
        // SAFETY: the handle is live.
        check(unsafe {
            sys::ghostty_terminal_resize(
                self.vt.as_ptr(),
                size.cols.get(),
                size.rows.get(),
                u32::from(width),
                u32::from(height),
            )
        })
    }

    pub(crate) fn compression_activity(&self) -> Result<u64, Error> {
        let mut activity = 0;
        // SAFETY: the handle is live, and activity is writable.
        check(unsafe {
            sys::ghostty_terminal_compression_activity(self.vt.as_ptr(), &mut activity)
        })?;
        Ok(activity)
    }

    pub(crate) fn compress_step(&mut self) -> Result<bool, Error> {
        let mut result = 0;
        // SAFETY: the handle is live, and result is writable.
        check(unsafe {
            sys::ghostty_terminal_compress(
                self.vt.as_ptr(),
                sys::GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
                &mut result,
            )
        })?;
        Ok(result == sys::GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING)
    }

    pub fn scroll(&mut self, delta: isize) {
        let to = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_DELTA,
            value: sys::GhosttyTerminalScrollViewportValue { delta },
        };
        // SAFETY: the handle is live, and the viewport request is initialized.
        unsafe { sys::ghostty_terminal_scroll_viewport(self.vt.as_ptr(), to) };
    }

    fn scrollbar(&self) -> Result<u64, Error> {
        let bar = sys::GhosttyTerminalScrollbar {
            total: 0,
            offset: 0,
            len: 0,
        };
        Ok(self.get(sys::GHOSTTY_TERMINAL_DATA_SCROLLBAR, bar)?.offset)
    }

    pub fn bottom(&mut self) -> Result<bool, Error> {
        let before = self.scrollbar()?;
        let to = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            value: sys::GhosttyTerminalScrollViewportValue { delta: 0 },
        };
        // SAFETY: the handle is live, and the viewport request is initialized.
        unsafe { sys::ghostty_terminal_scroll_viewport(self.vt.as_ptr(), to) };
        Ok(before != self.scrollbar()?)
    }

    pub fn memory(&self) -> Result<Memory, Error> {
        let usage = sys::GhosttyTerminalMemoryUsage {
            size: size_of::<sys::GhosttyTerminalMemoryUsage>(),
            ..Default::default()
        };
        let usage = self.get(sys::GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, usage)?;
        Ok(Memory {
            pages: usage.primary_pages + usage.alternate_pages,
            compressed_pages: usage.primary_compressed_pages + usage.alternate_compressed_pages,
            resident_bytes: usage.primary_resident_bytes + usage.alternate_resident_bytes,
        })
    }

    pub fn snapshot_bytes(&mut self, screen: bool) -> Result<Vec<u8>, Error> {
        let mut bytes = Vec::new();
        self.snapshot(screen, |piece| {
            bytes.extend_from_slice(piece);
            true
        })?;
        Ok(bytes)
    }

    pub fn snapshot(
        &mut self,
        screen: bool,
        mut emit: impl FnMut(&[u8]) -> bool,
    ) -> Result<(), Error> {
        let mut cut = cut::Cut::new(screen);
        let synchronized = self.mode(2026)?;
        if synchronized {
            self.set_mode(2026, false)?;
        }
        let mut failed = false;
        let mut sink = |bytes: &[u8]| {
            failed = cut
                .feed(bytes, &mut |piece: &[u8]| {
                    if emit(piece) { Ok(()) } else { Err(()) }
                })
                .is_err();
            !failed && !cut.done()
        };
        // SAFETY: the handle is live, and the writer's sink outlives the call.
        let result = check(unsafe {
            sys::ghostty_snapshot_encode(self.vt.as_ptr(), callback_writer(&mut sink))
        });
        let restored = if synchronized {
            self.set_mode(2026, true)
        } else {
            Ok(())
        };
        if failed {
            Err(Error::Stopped)
        } else if cut.done() {
            restored
        } else {
            result.and(restored)
        }
    }

    fn set_mode(&mut self, number: u16, value: bool) -> Result<(), Error> {
        let mode = sys::GhosttyTerminalModeConfig {
            mode: number,
            value,
        };
        // SAFETY: the handle is live, and OPT_MODE takes a mode config.
        check(unsafe {
            sys::ghostty_terminal_set(
                self.vt.as_ptr(),
                sys::GHOSTTY_TERMINAL_OPT_MODE,
                ptr::from_ref(&mode).cast(),
            )
        })
    }

    pub(crate) fn get<T>(&self, data: sys::GhosttyTerminalData, mut value: T) -> Result<T, Error> {
        // SAFETY: each caller names the data whose input and output type terminal.h documents as
        // T.
        check(unsafe {
            sys::ghostty_terminal_get(self.vt.as_ptr(), data, ptr::from_mut(&mut value).cast())
        })?;
        Ok(value)
    }

    pub fn mode(&self, number: u16) -> Result<bool, Error> {
        let mode = sys::GhosttyTerminalModeConfig {
            mode: number,
            value: false,
        };
        Ok(self.get(sys::GHOSTTY_TERMINAL_DATA_MODE, mode)?.value)
    }

    pub fn cursor(&self) -> Result<Cursor, Error> {
        Ok(Cursor {
            x: self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_X, 0u16)?,
            y: self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_Y, 0u16)?,
            visible: self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, false)?,
            pending_wrap: self.get(sys::GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, false)?,
        })
    }

    pub fn total_rows(&self) -> Result<usize, Error> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, 0usize)
    }

    pub fn screen(
        &self,
        format: Format,
        history: u32,
        mut emit: impl FnMut(&[u8]) -> bool,
    ) -> Result<(), Error> {
        let cols: u16 = self.get(sys::GHOSTTY_TERMINAL_DATA_COLS, 0)?;
        let rows: u16 = self.get(sys::GHOSTTY_TERMINAL_DATA_ROWS, 0)?;
        let total = self.total_rows()?;
        let last = total.saturating_sub(1);
        let start = total.saturating_sub(usize::from(rows));
        let start = usize::try_from(history).map_or(0, |history| start.saturating_sub(history));
        let point = |x: u16, y: usize| -> Result<sys::GhosttyPoint, Error> {
            Ok(sys::GhosttyPoint {
                tag: sys::GHOSTTY_POINT_TAG_SCREEN,
                value: sys::GhosttyPointValue {
                    coordinate: sys::GhosttyPointCoordinate {
                        x,
                        y: u32::try_from(y).map_err(|_| Error::Rows(y))?,
                    },
                },
            })
        };
        let mut selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        // SAFETY: both points lie inside the terminal's grid, and the refs receive their result.
        check(unsafe {
            sys::ghostty_terminal_grid_ref(self.vt.as_ptr(), point(0, start)?, &mut selection.start)
        })?;
        // SAFETY: as above.
        check(unsafe {
            sys::ghostty_terminal_grid_ref(
                self.vt.as_ptr(),
                point(cols.saturating_sub(1), last)?,
                &mut selection.end,
            )
        })?;
        let options = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: if format == Format::Vt {
                sys::GHOSTTY_FORMATTER_FORMAT_VT
            } else {
                sys::GHOSTTY_FORMATTER_FORMAT_PLAIN
            },
            trim: true,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                screen: sys::GhosttyFormatterScreenExtra {
                    size: size_of::<sys::GhosttyFormatterScreenExtra>(),
                    ..Default::default()
                },
                ..Default::default()
            },
            selection: &selection,
            ..Default::default()
        };
        let mut formatter = ptr::null_mut();
        // SAFETY: the options and the selection outlive the formatter, which is freed below.
        check(unsafe {
            sys::ghostty_formatter_terminal_new(
                ptr::null(),
                &mut formatter,
                self.vt.as_ptr(),
                options,
            )
        })?;
        // SAFETY: the formatter is live, and the writer's sink outlives the call.
        let result =
            unsafe { sys::ghostty_formatter_format(formatter, callback_writer(&mut emit)) };
        // SAFETY: the formatter was created above and is not used again.
        unsafe { sys::ghostty_formatter_free(formatter) };
        check(result)
    }

    pub fn dump(&self, format: Format) -> Result<Vec<u8>, Error> {
        self.format(format, Extent::Screen)
    }

    pub fn dump_history(&self, format: Format) -> Result<Vec<u8>, Error> {
        self.format(format, Extent::Full)
    }

    fn format(&self, format: Format, extent: Extent) -> Result<Vec<u8>, Error> {
        let cols: u16 = self.get(sys::GHOSTTY_TERMINAL_DATA_COLS, 0)?;
        let (tag, rows) = match extent {
            Extent::Screen => (
                sys::GHOSTTY_POINT_TAG_ACTIVE,
                usize::from(self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_ROWS, 0)?),
            ),
            Extent::Full => (sys::GHOSTTY_POINT_TAG_SCREEN, self.total_rows()?),
        };
        let last = u32::try_from(rows.saturating_sub(1)).map_err(|_| Error::Rows(rows))?;
        let point = |x, y| sys::GhosttyPoint {
            tag,
            value: sys::GhosttyPointValue {
                coordinate: sys::GhosttyPointCoordinate { x, y },
            },
        };
        let mut selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        // SAFETY: both points lie inside the terminal's grid, and the refs receive their result.
        check(unsafe {
            sys::ghostty_terminal_grid_ref(self.vt.as_ptr(), point(0, 0), &mut selection.start)
        })?;
        // SAFETY: as above.
        check(unsafe {
            sys::ghostty_terminal_grid_ref(
                self.vt.as_ptr(),
                point(cols.saturating_sub(1), last),
                &mut selection.end,
            )
        })?;
        let vt = format == Format::Vt;
        let options = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: if vt {
                sys::GHOSTTY_FORMATTER_FORMAT_VT
            } else {
                sys::GHOSTTY_FORMATTER_FORMAT_PLAIN
            },
            trim: false,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                modes: vt,
                scrolling_region: vt,
                keyboard: vt,
                screen: sys::GhosttyFormatterScreenExtra {
                    size: if vt {
                        size_of::<sys::GhosttyFormatterScreenExtra>()
                    } else {
                        0
                    },
                    cursor: vt,
                    style: vt,
                    hyperlink: vt,
                    protection: vt,
                    kitty_keyboard: vt,
                    charsets: vt,
                },
                ..Default::default()
            },
            selection: &selection,
            ..Default::default()
        };
        let mut formatter = ptr::null_mut();
        // SAFETY: the options and the selection outlive the formatter, which is freed below.
        check(unsafe {
            sys::ghostty_formatter_terminal_new(
                ptr::null(),
                &mut formatter,
                self.vt.as_ptr(),
                options,
            )
        })?;
        let mut out = Vec::new();
        // SAFETY: the formatter is live, and the writer's Vec outlives the call.
        let result = unsafe { sys::ghostty_formatter_format(formatter, writer(&mut out)) };
        // SAFETY: the formatter was created above and is not used again.
        unsafe { sys::ghostty_formatter_free(formatter) };
        check(result)?;
        Ok(out)
    }
}

const MODES: [u16; 13] = [
    1, 6, 7, 25, 47, 1000, 1002, 1003, 1004, 1006, 1049, 2004, 2026,
];

pub fn differences(
    a: &Terminal,
    b: &Terminal,
    history: bool,
    strip: impl Fn(&[u8]) -> Vec<u8>,
) -> Result<Vec<String>, Error> {
    let mut found = Vec::new();
    if a.dump(Format::Plain)? != b.dump(Format::Plain)? {
        found.push("plain text".to_owned());
    }
    if strip(&a.dump(Format::Vt)?) != strip(&b.dump(Format::Vt)?) {
        found.push("vt dump".to_owned());
    }
    if a.cursor()? != b.cursor()? {
        found.push("cursor".to_owned());
    }
    for mode in MODES {
        if a.mode(mode)? != b.mode(mode)? {
            found.push(format!("mode {mode}"));
        }
    }
    if history
        && (a.total_rows()? != b.total_rows()?
            || strip(&a.dump_history(Format::Vt)?) != strip(&b.dump_history(Format::Vt)?))
    {
        found.push("history".to_owned());
    }
    Ok(found)
}

#[derive(Debug)]
pub struct ReadyScan(cut::Cut);

impl ReadyScan {
    pub fn new() -> ReadyScan {
        ReadyScan(cut::Cut::new(true))
    }

    pub fn feed(&mut self, bytes: &[u8]) -> bool {
        let _ = self.0.feed::<()>(bytes, &mut |_| Ok(()));
        self.0.done()
    }
}

impl Default for ReadyScan {
    fn default() -> ReadyScan {
        ReadyScan::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ko_pane_wire::frame::Key;

    fn dim(value: u16) -> Dim {
        Dim::new(value).unwrap()
    }

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
        Terminal::new(dim(cols), dim(rows), limits).unwrap()
    }

    fn snapshot(terminal: &Terminal) -> Vec<u8> {
        let mut out = Vec::new();
        // SAFETY: the handle is live, and the writer's Vec outlives the call.
        check(unsafe { sys::ghostty_snapshot_encode(terminal.vt.as_ptr(), writer(&mut out)) })
            .unwrap();
        out
    }

    fn osc8(i: usize) -> String {
        format!("\x1b]8;;https://example.org/{i}\x1b\\link {i}\x1b]8;;\x1b\\\r\n")
    }

    struct Chunks<'a> {
        bytes: &'a [u8],
        chunk: usize,
    }

    impl Read for Chunks<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let len = self.chunk.min(buffer.len()).min(self.bytes.len());
            let (piece, rest) = self.bytes.split_at(len);
            buffer[..len].copy_from_slice(piece);
            self.bytes = rest;
            Ok(len)
        }
    }

    fn decode(bytes: &[u8], extent: Extent) -> Terminal {
        Terminal::decode(&mut Chunks { bytes, chunk: 7 }, extent).unwrap()
    }

    #[test]
    fn state_open_at_a_snapshot() {
        let cases = [
            (
                "open hyperlink",
                "\x1b]8;;https://example.org\x1b\\ab".to_owned(),
                "cd\x1b]8;;\x1b\\ ef".to_owned(),
                true,
            ),
            ("pen", "\x1b[1;31mab".to_owned(), "cd".to_owned(), true),
            ("pending wrap", "x".repeat(30), "y".to_owned(), true),
            ("charset", "\x1b(0ab".to_owned(), "qq".to_owned(), true),
            (
                "inside OSC 8 uri",
                "\x1b]8;;file:///tmp/1".to_owned(),
                "06\x1b\\/tmp/106\x1b]8;;\x1b\\ ef".to_owned(),
                true,
            ),
            (
                "alternate screen",
                "primary\r\n\x1b[?1049halt".to_owned(),
                "\x1b[?1049l".to_owned(),
                true,
            ),
            (
                "OSC 8 rows scrolled after decode",
                osc8(0),
                (1..=8).map(osc8).collect(),
                false,
            ),
        ];
        for (label, before, after, same_vt) in cases {
            let mut server = make(30, 6);
            server.write(before.as_bytes());
            let bytes = snapshot(&server);
            let mut screen = decode(&bytes, Extent::Screen);
            let mut full = decode(&bytes, Extent::Full);
            for terminal in [&mut server, &mut screen, &mut full] {
                terminal.write(after.as_bytes());
            }
            for terminal in [&screen, &full] {
                let vt = server.dump(Format::Vt).unwrap() == terminal.dump(Format::Vt).unwrap();
                assert_eq!(vt, same_vt, "{label}");
                assert_eq!(
                    server.dump(Format::Plain).unwrap(),
                    terminal.dump(Format::Plain).unwrap(),
                    "{label}"
                );
            }
        }
    }

    #[test]
    fn full_mirror_applies_resizes_and_a_screen_decode_matches() {
        let mut server = make(20, 5);
        let mut mirror = make(20, 5);
        for i in 0..100 {
            let bytes = osc8(i);
            server.write(bytes.as_bytes());
            mirror.write(bytes.as_bytes());
        }
        for (cols, rows) in [(10, 8), (40, 3), (20, 5)] {
            let size = Size {
                cols: dim(cols),
                rows: dim(rows),
                cell_px: None,
            };
            server.resize(size).unwrap();
            mirror.resize(size).unwrap();
            let screen = decode(&snapshot(&server), Extent::Screen);
            let expected = server.dump(Format::Vt).unwrap();
            assert_eq!(expected, mirror.dump(Format::Vt).unwrap());
            assert_eq!(expected, screen.dump(Format::Vt).unwrap());
        }
    }

    #[test]
    fn a_screen_decode_stops_before_the_history() {
        let mut server = make(16, 2);
        for i in 0..10_000 {
            server.write(format!("line{i:05}\r\n").as_bytes());
        }
        let bytes = snapshot(&server);
        let screen = decode(&bytes, Extent::Screen);
        let full = decode(&bytes, Extent::Full);
        assert!(screen.total_rows().unwrap() < full.total_rows().unwrap());
        assert_eq!(full.total_rows().unwrap(), 10_001);
        assert_eq!(
            full.dump_history(Format::Vt).unwrap(),
            server.dump_history(Format::Vt).unwrap()
        );
    }

    #[test]
    fn modes_survive_a_decode() {
        let mut server = make(8, 2);
        server.write(b"\x1b[?1h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h");
        let restored = decode(&snapshot(&server), Extent::Full);
        for mode in [1, 1002, 1004, 1006, 2004] {
            assert!(restored.mode(mode).unwrap(), "mode {mode}");
        }
        assert!(!restored.mode(2026).unwrap());
    }

    #[test]
    fn errors() {
        struct Stopped;
        impl Read for Stopped {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::other("reader stopped"))
            }
        }
        let stopped = Terminal::decode(&mut Stopped, Extent::Full).unwrap_err();
        assert_eq!(stopped.to_string(), "snapshot read: reader stopped");
        struct Overlong;
        impl Read for Overlong {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                Ok(buffer.len() + 1)
            }
        }
        let overlong = Terminal::decode(&mut Overlong, Extent::Full).unwrap_err();
        assert!(
            overlong
                .to_string()
                .starts_with("snapshot read: the reader returned "),
            "{overlong}"
        );
        let truncated = Terminal::decode(&mut &b"GHOSTSNP"[..], Extent::Screen).unwrap_err();
        assert_eq!(truncated.to_string(), "libghostty-vt operation failed (-2)");
    }

    fn served(cols: u16, rows: u16) -> Terminal {
        let mut vt = make(cols, rows);
        vt.serve(&[], "/tmp").unwrap();
        vt
    }

    #[test]
    fn callbacks_collect_replies_and_changes_without_touching_the_terminal() {
        let mut vt = served(20, 4);
        vt.write(b"\x1b[5n\x1b]2;a title\x07\x1b]7;file://localhost/tmp\x07\x1b]2;second\x07");
        assert_eq!(vt.replies().as_slice(), b"\x1b[0n");
        assert_eq!(
            vt.take_changes(),
            Changes {
                title: true,
                pwd: true
            }
        );
        assert_eq!(vt.title().unwrap(), b"second");
        assert_eq!(vt.pwd().unwrap(), b"file://localhost/tmp");
        assert_eq!(vt.take_changes(), Changes::default());
        vt.write(b"plain text\r\n");
        assert_eq!(vt.take_changes(), Changes::default());
    }

    #[test]
    fn a_snapshot_is_taken_with_synchronized_output_off_and_leaves_it_on() {
        let mut vt = served(20, 4);
        vt.write(b"\x1b[?2026hhello");
        let bytes = vt.snapshot_bytes(false).unwrap();
        assert!(vt.mode(2026).unwrap());
        assert!(!decode(&bytes, Extent::Full).mode(2026).unwrap());
    }

    #[test]
    fn a_screen_cut_ends_at_the_ready_record_and_a_stopped_encoder_is_an_error() {
        let mut vt = served(16, 2);
        for i in 0..5_000 {
            vt.write(format!("line{i:05}\r\n").as_bytes());
        }
        let (screen, full) = (
            vt.snapshot_bytes(true).unwrap(),
            vt.snapshot_bytes(false).unwrap(),
        );
        assert!(screen.len() < full.len(), "{} {}", screen.len(), full.len());
        assert_eq!(
            decode(&screen, Extent::Screen).dump(Format::Plain).unwrap(),
            vt.dump(Format::Plain).unwrap()
        );
        let stopped = vt.snapshot(false, |_| false);
        assert!(matches!(stopped, Err(Error::Stopped)));
    }

    #[test]
    fn a_screen_request_starts_the_given_number_of_rows_above_the_visible_ones() {
        let mut vt = served(10, 3);
        for i in 0..10 {
            vt.write(format!("row {i}\r\n").as_bytes());
        }
        let screen = |history| {
            let mut bytes = Vec::new();
            vt.screen(Format::Plain, history, |piece| {
                bytes.extend_from_slice(piece);
                true
            })
            .unwrap();
            String::from_utf8(bytes).unwrap()
        };
        assert_eq!(screen(0), "row 8\nrow 9");
        assert_eq!(screen(2), "row 6\nrow 7\nrow 8\nrow 9");
        assert_eq!(screen(u32::MAX).lines().count(), 10);
        assert!(screen(u32::MAX).starts_with("row 0\n"));
    }

    #[test]
    fn input_is_encoded_for_the_modes_the_program_set() {
        use ko_pane_wire::frame::{KeyAction, KeyCode, Mouse, MouseAction, MouseButton};
        let mut vt = served(20, 4);
        let alt_a = Key {
            action: KeyAction::Press,
            key: KeyCode::new(sys::GHOSTTY_KEY_A as u16).unwrap(),
            mods: sys::GHOSTTY_MODS_ALT as u16,
            unshifted: 'a',
            text: "\u{e5}".to_owned(),
            composing: false,
        };
        assert_eq!(vt.encode_key(&alt_a).unwrap(), b"\x1ba");
        let left = Mouse {
            action: MouseAction::Press,
            button: MouseButton::Left,
            col: 3,
            row: 2,
            mods: 0,
        };
        assert_eq!(vt.encode_mouse(&left).unwrap(), b"");
        assert_eq!(vt.encode_focus(true).unwrap(), b"");
        vt.write(b"\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[?2004h");
        assert_eq!(vt.encode_mouse(&left).unwrap(), b"\x1b[<0;4;3M");
        assert_eq!(vt.encode_focus(true).unwrap(), b"\x1b[I");
        assert_eq!(vt.encode_focus(false).unwrap(), b"\x1b[O");
        let pasted = vt.paste("hi", true).unwrap();
        assert_eq!(
            (pasted, vt.replies().as_slice()),
            (
                input::Pasted {
                    written: true,
                    rejected: false
                },
                &b"\x1b[200~hi\x1b[201~"[..]
            )
        );
        vt.replies().clear();
        let unsafe_text = vt.paste("a\x1b[201~b", true).unwrap();
        assert_eq!(
            (unsafe_text, vt.replies().as_slice()),
            (
                input::Pasted {
                    written: false,
                    rejected: true
                },
                &b""[..]
            )
        );
    }

    fn tags(bytes: &[u8]) -> Vec<u16> {
        let mut at = 10;
        let mut tags = Vec::new();
        while let Some(header) = bytes.get(at..at + 10) {
            tags.push(u16::from_le_bytes([header[0], header[1]]));
            at += 10 + u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
        }
        tags
    }

    #[test]
    fn a_snapshot_drops_kitty_payloads_and_a_screen_cut_ends_at_ready() {
        let mut vt = served(20, 5);
        vt.write(b"\x1b_Ga=T,f=32,s=1,v=1,i=1;AQIDBA==\x1b\\\x1b[?2026himage");
        assert_eq!(
            tags(&vt.snapshot_bytes(false).unwrap()),
            [1, 2, 3, 8, 7, 5, 4, 6]
        );
        assert_eq!(tags(&vt.snapshot_bytes(true).unwrap()), [1, 2, 3, 8, 7, 5]);
    }

    #[test]
    fn ready_publishes_a_screen_before_the_full_history() {
        let mut server = served(16, 2);
        for i in 0..10_000 {
            server.write(format!("line{i:05}\r\n").as_bytes());
        }
        let bytes = server.snapshot_bytes(false).unwrap();
        let mut scan = ReadyScan::new();
        let ready = bytes
            .chunks(4096)
            .scan(0, |end, chunk| {
                *end += chunk.len();
                Some((*end, scan.feed(chunk)))
            })
            .find_map(|(end, seen)| seen.then_some(end))
            .unwrap();
        let screen = decode(&bytes[..ready], Extent::Screen);
        let full = decode(&bytes, Extent::Full);
        assert!(screen.total_rows().unwrap() < full.total_rows().unwrap());
        assert_eq!(full.total_rows().unwrap(), 10_001);
    }

    #[test]
    fn a_decoded_snapshot_starts_compressed_and_the_line_limit_prunes() {
        let fill = |vt: &mut Terminal| {
            for i in 0..20_000 {
                vt.write(format!("compressible line {i}\r\n").as_bytes());
            }
        };
        let mut server = make(80, 24);
        fill(&mut server);
        assert_eq!(server.memory().unwrap().compressed_pages, 0);
        let restored = decode(&snapshot(&server), Extent::Full);
        assert!(restored.memory().unwrap().compressed_pages > 0);
        assert_eq!(restored.total_rows().unwrap(), server.total_rows().unwrap());
        let limits = Limits {
            scrollback: Scrollback::Bounded {
                max_bytes: NonZeroUsize::new(50_000_000),
                max_lines: NonZeroUsize::new(1000),
            },
            apc_max_bytes: 0,
            kitty_images_max_bytes: 0,
            continuation_max_bytes: 0,
        };
        let mut limited = Terminal::new(dim(80), dim(24), limits).unwrap();
        fill(&mut limited);
        assert!(limited.total_rows().unwrap() < 3000);
    }

    #[test]
    fn the_frame_key_bound_is_the_last_ghostty_key() {
        assert_eq!(
            i32::from(ko_pane_wire::frame::MAX_KEY),
            sys::GHOSTTY_KEY_PASTE
        );
    }
}
