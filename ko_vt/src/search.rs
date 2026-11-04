use std::ffi::c_void;
use std::ptr::{self, NonNull};

use ko_pane_wire::frame::{Cell, Match};
use ko_vt_sys as sys;

use crate::{Error, Terminal, check};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    Running,
    FeedRequired,
    Complete,
}

#[derive(Debug)]
pub struct Search {
    raw: NonNull<sys::GhosttySearchImpl>,
    progress: Progress,
}

impl Terminal {
    pub fn search(&mut self, needle: &[u8]) -> Result<Search, Error> {
        let mut raw = ptr::null_mut();
        // SAFETY: a NULL allocator selects the default one; the terminal handle is live and
        // nothing else accesses it during the call.
        check(unsafe { sys::ghostty_search_new(ptr::null(), &mut raw, self.vt.as_ptr()) })?;
        let search = Search {
            raw: NonNull::new(raw).ok_or(Error::NoHandle)?,
            progress: Progress::FeedRequired,
        };
        let needle = sys::GhosttyString {
            ptr: needle.as_ptr(),
            len: needle.len(),
        };
        // SAFETY: the option takes a GhosttyString that the call copies.
        check(unsafe {
            sys::ghostty_search_set(
                search.raw.as_ptr(),
                sys::GHOSTTY_SEARCH_OPT_NEEDLE,
                ptr::from_ref(&needle).cast(),
            )
        })?;
        Ok(search)
    }
}

impl Search {
    /// One bounded step: a feed if the search waits for one, then ticks until the work is done or
    /// `ticks` are spent.
    pub fn step(&mut self, ticks: usize) -> Result<Progress, Error> {
        if self.progress == Progress::FeedRequired {
            // SAFETY: the search is live, and the caller serializes terminal access.
            check(unsafe { sys::ghostty_search_feed(self.raw.as_ptr()) })?;
        }
        let mut status = sys::GHOSTTY_SEARCH_STATUS_RUNNING;
        for _ in 0..ticks {
            // SAFETY: the search is live, and status is writable.
            check(unsafe { sys::ghostty_search_tick(self.raw.as_ptr(), &mut status) })?;
            if status != sys::GHOSTTY_SEARCH_STATUS_RUNNING {
                break;
            }
        }
        self.progress = match status {
            sys::GHOSTTY_SEARCH_STATUS_COMPLETE => Progress::Complete,
            sys::GHOSTTY_SEARCH_STATUS_FEED_REQUIRED => Progress::FeedRequired,
            _ => Progress::Running,
        };
        Ok(self.progress)
    }

    /// Every match of the active screen, oldest first, with rows counted from the top of the
    /// history.
    pub fn matches(&self, terminal: &Terminal) -> Result<Vec<Match>, Error> {
        let mut buffer = sys::GhosttySelectionBuffer {
            ptr: ptr::null_mut(),
            cap: 0,
            len: 0,
        };
        let read = |buffer: &mut sys::GhosttySelectionBuffer| {
            // SAFETY: the search is live; MATCHES takes a GhosttySelectionBuffer.
            unsafe {
                sys::ghostty_search_get(
                    self.raw.as_ptr(),
                    sys::GHOSTTY_SEARCH_DATA_MATCHES,
                    ptr::from_mut(buffer).cast::<c_void>(),
                )
            }
        };
        match read(&mut buffer) {
            sys::GHOSTTY_SUCCESS => return Ok(Vec::new()),
            sys::GHOSTTY_OUT_OF_SPACE => {}
            code => return Err(Error::Ghostty(code)),
        }
        // SAFETY: GhosttySelection is plain data, and `size` is set for each entry below.
        let mut found: Vec<sys::GhosttySelection> = vec![unsafe { std::mem::zeroed() }; buffer.len];
        for selection in &mut found {
            selection.size = std::mem::size_of::<sys::GhosttySelection>();
        }
        buffer.ptr = found.as_mut_ptr();
        buffer.cap = found.len();
        check(read(&mut buffer))?;
        found.truncate(buffer.len);
        let cell = |grid: &sys::GhosttyGridRef| -> Result<Cell, Error> {
            let mut point = sys::GhosttyPointCoordinate { x: 0, y: 0 };
            // SAFETY: the terminal is live, and grid came from a search read that no terminal
            // write has followed.
            check(unsafe {
                sys::ghostty_terminal_point_from_grid_ref(
                    terminal.vt.as_ptr(),
                    grid,
                    sys::GHOSTTY_POINT_TAG_SCREEN,
                    &mut point,
                )
            })?;
            Ok(Cell {
                row: point.y,
                col: point.x,
            })
        };
        let mut matches = found
            .iter()
            .map(|selection| {
                Ok(Match {
                    start: cell(&selection.start)?,
                    end: cell(&selection.end)?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        matches.reverse();
        Ok(matches)
    }
}

impl Drop for Search {
    fn drop(&mut self) {
        // SAFETY: the search is freed once; the terminal may already be freed (search.h).
        unsafe { sys::ghostty_search_free(self.raw.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::make;

    fn finish(search: &mut Search) {
        for _ in 0..100 {
            if search.step(1000).unwrap() == Progress::Complete {
                return;
            }
        }
        panic!("the search never completed");
    }

    #[test]
    fn matches_come_oldest_first_with_rows_from_the_top_of_the_history() {
        let mut vt = make(20, 3);
        vt.write(b"one\r\ntwo needle\r\nthree\r\nfour Needle x\r\nfive");
        let mut search = vt.search(b"needle").unwrap();
        finish(&mut search);
        let found = search.matches(&vt).unwrap();
        let at = |row, col| Cell { row, col };
        assert_eq!(
            found,
            [
                Match {
                    start: at(1, 4),
                    end: at(1, 9)
                },
                Match {
                    start: at(3, 5),
                    end: at(3, 10)
                },
            ]
        );
    }

    #[test]
    fn copy_search_wrap_wide_case_and_compressed_history() {
        let mut vt = make(8, 3);
        vt.write("123456abc界 AbC Éé\r\n".as_bytes());
        let at = |row, col| Cell { row, col };
        let mut search = vt.search("abc界".as_bytes()).unwrap();
        finish(&mut search);
        assert_eq!(
            search.matches(&vt).unwrap(),
            [Match {
                start: at(0, 6),
                end: at(1, 1)
            }]
        );
        drop(search);
        let mut search = vt.search(b"ABC").unwrap();
        finish(&mut search);
        assert_eq!(search.matches(&vt).unwrap().len(), 2);
        drop(search);
        let mut search = vt.search("é".as_bytes()).unwrap();
        finish(&mut search);
        assert_eq!(search.matches(&vt).unwrap().len(), 1);
        drop(search);
        for _ in 0..5324 {
            vt.write(b"padding\r\n");
        }
        while vt.compress_step().unwrap() {}
        assert!(vt.memory().unwrap().compressed_pages > 0);
        let mut search = vt.search("abc界".as_bytes()).unwrap();
        finish(&mut search);
        assert_eq!(
            search.matches(&vt).unwrap(),
            [Match {
                start: at(0, 6),
                end: at(1, 1)
            }]
        );
        drop(search);
        vt.write(b"\x1b[?1049h\x1b[Halternate");
        assert_eq!(vt.total_rows().unwrap(), 3);
        assert_eq!(vt.viewport_offset().unwrap(), 0);
        let mut search = vt.search("abc界".as_bytes()).unwrap();
        finish(&mut search);
        assert_eq!(search.matches(&vt).unwrap(), []);
        drop(search);
        let mut search = vt.search(b"alternate").unwrap();
        finish(&mut search);
        assert_eq!(
            search.matches(&vt).unwrap(),
            [Match {
                start: at(0, 0),
                end: at(1, 0)
            }]
        );
    }

    #[test]
    fn a_needle_that_is_nowhere_finds_nothing() {
        let mut vt = make(20, 3);
        vt.write(b"abc");
        let mut search = vt.search(b"zzz").unwrap();
        finish(&mut search);
        assert_eq!(search.matches(&vt).unwrap(), []);
    }
}
