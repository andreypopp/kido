#![allow(unsafe_code)]

use std::ffi::c_void;
use std::fmt;
use std::io::{self, Read};
use std::num::NonZeroUsize;
use std::ptr::{self, NonNull};

use ko_pane_wire::frame::{CellPx, Dim, Limits, Scrollback, Size};
use ko_vt_sys as sys;

#[derive(Debug)]
pub enum Error {
    Ghostty(sys::GhosttyResult),
    NoHandle,
    NoTerminal,
    Rows(usize),
    Read(io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Ghostty(code) => write!(f, "libghostty-vt operation failed ({code})"),
            Error::NoHandle => write!(f, "libghostty-vt returned no terminal handle"),
            Error::NoTerminal => write!(f, "the snapshot decoder returned no terminal"),
            Error::Rows(rows) => write!(f, "{rows} rows exceed a grid coordinate"),
            Error::Read(error) => write!(f, "snapshot read: {error}"),
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

#[derive(Debug)]
pub struct Terminal {
    vt: NonNull<sys::GhosttyTerminalImpl>,
}

impl Drop for Terminal {
    fn drop(&mut self) {
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
        let terminal = Terminal {
            vt: NonNull::new(vt).ok_or(Error::NoHandle)?,
        };
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
                sys::ghostty_terminal_set(
                    terminal.vt.as_ptr(),
                    option,
                    value.unwrap_or(ptr::null()),
                )
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
        )?;
        Ok(terminal)
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
        let terminal = NonNull::new(vt).map(|vt| Terminal { vt });
        if let Some(error) = source.error {
            return Err(Error::Read(error));
        }
        result?;
        terminal.ok_or(Error::NoTerminal)
    }

    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: the handle is live and bytes is a valid slice for the call.
        unsafe { sys::ghostty_terminal_vt_write(self.vt.as_ptr(), bytes.as_ptr(), bytes.len()) }
    }

    pub fn resize(&mut self, size: Size) -> Result<(), Error> {
        let cell = size.cell_px.unwrap_or(CellPx::DEFAULT);
        // SAFETY: the handle is live.
        check(unsafe {
            sys::ghostty_terminal_resize(
                self.vt.as_ptr(),
                size.cols.get(),
                size.rows.get(),
                u32::from(cell.width.get()),
                u32::from(cell.height.get()),
            )
        })
    }

    fn get<T>(&self, data: sys::GhosttyTerminalData, mut value: T) -> Result<T, Error> {
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

    pub fn total_rows(&self) -> Result<usize, Error> {
        self.get(sys::GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, 0usize)
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

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn the_frame_key_bound_is_the_last_ghostty_key() {
        assert_eq!(
            i32::from(ko_pane_wire::frame::MAX_KEY),
            sys::GHOSTTY_KEY_PASTE
        );
    }
}
