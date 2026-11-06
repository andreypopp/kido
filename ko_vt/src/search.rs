use std::ffi::c_void;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicU64, Ordering};

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
struct Search {
    raw: NonNull<sys::GhosttySearchImpl>,
    progress: Progress,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchId(u64);

static NEXT: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Default)]
pub(crate) struct Searches {
    list: Vec<(SearchId, Search)>,
}

impl Searches {
    fn push(&mut self, search: Search) -> Result<SearchId, Error> {
        let id = NEXT
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |next| {
                next.checked_add(1)
            })
            .map(SearchId)
            .map_err(|_| Error::NoSearch)?;
        self.list.push((id, search));
        Ok(id)
    }

    fn find(&self, id: SearchId) -> Result<&Search, Error> {
        self.list
            .iter()
            .find(|(key, _)| *key == id)
            .map(|(_, search)| search)
            .ok_or(Error::NoSearch)
    }

    fn find_mut(&mut self, id: SearchId) -> Result<&mut Search, Error> {
        self.list
            .iter_mut()
            .find(|(key, _)| *key == id)
            .map(|(_, search)| search)
            .ok_or(Error::NoSearch)
    }

    fn end(&mut self, id: SearchId) {
        self.list.retain(|(key, _)| *key != id);
    }

    pub(crate) fn clear(&mut self) {
        self.list.clear();
    }
}

impl Terminal {
    pub fn search(&mut self, needle: &[u8]) -> Result<SearchId, Error> {
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
        self.searches.push(search)
    }

    pub fn search_end(&mut self, id: SearchId) {
        self.searches.end(id);
    }

    /// One bounded step: a feed if the search waits for one, then ticks until the work is done or
    /// `ticks` are spent.
    pub fn search_step(&mut self, id: SearchId, ticks: usize) -> Result<Progress, Error> {
        let search = self.searches.find_mut(id)?;
        if search.progress == Progress::FeedRequired {
            // SAFETY: the terminal owns the live search, and &mut self excludes other access.
            check(unsafe { sys::ghostty_search_feed(search.raw.as_ptr()) })?;
        }
        let mut status = sys::GHOSTTY_SEARCH_STATUS_RUNNING;
        for _ in 0..ticks {
            // SAFETY: the search is live, and status is writable.
            check(unsafe { sys::ghostty_search_tick(search.raw.as_ptr(), &mut status) })?;
            if status != sys::GHOSTTY_SEARCH_STATUS_RUNNING {
                break;
            }
        }
        search.progress = match status {
            sys::GHOSTTY_SEARCH_STATUS_COMPLETE => Progress::Complete,
            sys::GHOSTTY_SEARCH_STATUS_FEED_REQUIRED => Progress::FeedRequired,
            _ => Progress::Running,
        };
        Ok(search.progress)
    }

    /// Every match of the active screen, oldest first, with rows counted from the top of the
    /// history.
    pub fn search_matches(&self, id: SearchId) -> Result<Vec<Match>, Error> {
        let search = self.searches.find(id)?;
        let mut buffer = sys::GhosttySelectionBuffer {
            ptr: ptr::null_mut(),
            cap: 0,
            len: 0,
        };
        let read = |buffer: &mut sys::GhosttySelectionBuffer| {
            // SAFETY: the search is live; MATCHES takes a GhosttySelectionBuffer.
            unsafe {
                sys::ghostty_search_get(
                    search.raw.as_ptr(),
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
        let mut found = vec![sys::GhosttySelection::default(); buffer.len];
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
                    self.vt.as_ptr(),
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
        // SAFETY: the terminal owns this search and drops it once before freeing the terminal.
        unsafe { sys::ghostty_search_free(self.raw.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::make;

    fn finish(vt: &mut Terminal, search: SearchId) {
        for _ in 0..100 {
            if vt.search_step(search, 1000).unwrap() == Progress::Complete {
                return;
            }
        }
        panic!("the search never completed");
    }

    #[test]
    fn matches_come_oldest_first_with_rows_from_the_top_of_the_history() {
        let mut vt = make(20, 3);
        vt.write(b"one\r\ntwo needle\r\nthree\r\nfour Needle x\r\nfive");
        let search = vt.search(b"needle").unwrap();
        finish(&mut vt, search);
        let found = vt.search_matches(search).unwrap();
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
        let search = vt.search("abc界".as_bytes()).unwrap();
        finish(&mut vt, search);
        assert_eq!(
            vt.search_matches(search).unwrap(),
            [Match {
                start: at(0, 6),
                end: at(1, 1)
            }]
        );
        vt.search_end(search);
        let search = vt.search(b"ABC").unwrap();
        finish(&mut vt, search);
        assert_eq!(vt.search_matches(search).unwrap().len(), 2);
        vt.search_end(search);
        let search = vt.search("é".as_bytes()).unwrap();
        finish(&mut vt, search);
        assert_eq!(vt.search_matches(search).unwrap().len(), 1);
        vt.search_end(search);
        for _ in 0..5324 {
            vt.write(b"padding\r\n");
        }
        while vt.compress_step().unwrap() {}
        assert!(vt.memory().unwrap().compressed_pages > 0);
        let search = vt.search("abc界".as_bytes()).unwrap();
        finish(&mut vt, search);
        assert_eq!(
            vt.search_matches(search).unwrap(),
            [Match {
                start: at(0, 6),
                end: at(1, 1)
            }]
        );
        vt.search_end(search);
        vt.write(b"\x1b[?1049h\x1b[Halternate");
        assert_eq!(vt.total_rows().unwrap(), 3);
        assert_eq!(vt.viewport_offset().unwrap(), 0);
        let search = vt.search("abc界".as_bytes()).unwrap();
        finish(&mut vt, search);
        assert_eq!(vt.search_matches(search).unwrap(), []);
        vt.search_end(search);
        let search = vt.search(b"alternate").unwrap();
        finish(&mut vt, search);
        assert_eq!(
            vt.search_matches(search).unwrap(),
            [Match {
                start: at(0, 0),
                end: at(1, 0)
            }]
        );
    }

    #[test]
    fn searches_are_owned_by_the_terminal_and_cancel_independently() {
        let mut vt = make(20, 3);
        vt.write(b"one two");
        let one = vt.search(b"one").unwrap();
        let two = vt.search(b"two").unwrap();
        finish(&mut vt, one);
        finish(&mut vt, two);
        assert_eq!(vt.search_matches(one).unwrap()[0].start.col, 0);
        assert_eq!(vt.search_matches(two).unwrap()[0].start.col, 4);
        vt.search_end(one);
        assert!(vt.search_step(one, 1).is_err());
        assert!(vt.search_matches(one).is_err());
        assert_eq!(vt.search_matches(two).unwrap().len(), 1);
        let vt = std::thread::spawn(move || {
            vt.search_end(two);
            vt
        })
        .join()
        .unwrap();
        assert!(vt.search_matches(two).is_err());
        let mut other = make(20, 3);
        let fresh = other.search(b"one").unwrap();
        assert_ne!(fresh, one);
        assert!(matches!(other.search_step(one, 1), Err(Error::NoSearch)));
        assert!(matches!(other.search_matches(two), Err(Error::NoSearch)));
    }

    #[test]
    fn a_needle_that_is_nowhere_finds_nothing() {
        let mut vt = make(20, 3);
        vt.write(b"abc");
        let search = vt.search(b"zzz").unwrap();
        finish(&mut vt, search);
        assert_eq!(vt.search_matches(search).unwrap(), []);
    }
}
