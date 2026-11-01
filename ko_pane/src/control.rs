use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::num::NonZeroUsize;
use std::os::fd::OwnedFd;
use std::path::Path;

use ko_pane_wire::frame::{Init, Limits, Scrollback, Size};
use ko_pane_wire::ring::Reader;

use crate::pane::Pane;

const MAX_INPUT: usize = 60000;
const CAPACITY: u64 = 1 << 20;

fn input_file(data: &[u8], at_end: bool) -> Option<File> {
    let path = std::env::temp_dir().join(format!("ko-pane-control-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .ok()?;
    std::fs::remove_file(&path).ok()?;
    file.write_all(data).ok()?;
    file.seek(SeekFrom::Start(if at_end { data.len() as u64 } else { 0 }))
        .ok()?;
    Some(file)
}

fn detached(reader: &Reader, data: &[u8], at_end: bool) -> Option<Pane> {
    let input = OwnedFd::from(input_file(data, at_end)?);
    let output = OwnedFd::from(OpenOptions::new().write(true).open("/dev/null").ok()?);
    Some(Pane::detached(reader.writer().ok()?, input, output))
}

fn fresh(pane: &mut Pane) -> bool {
    let init = Init {
        size: Size::DEFAULT,
        limits: Limits {
            scrollback: Scrollback::Bounded {
                max_bytes: NonZeroUsize::new(1 << 20),
                max_lines: None,
            },
            apc_max_bytes: 1 << 16,
            kitty_images_max_bytes: 1 << 20,
            continuation_max_bytes: 1 << 16,
        },
        media: Vec::new().into(),
        cwd: Path::new("/").into(),
        argv: vec![b"/bin/sh".to_vec()].into(),
        env: Vec::new().into(),
        id: "pane_1".into(),
    };
    pane.init(&init).is_ok()
}

pub fn control(data: &[u8]) -> bool {
    let Some((&mode, data)) = data.split_first() else {
        return false;
    };
    if data.is_empty() || data.len() > MAX_INPUT {
        return false;
    }
    let stream = mode & 2 != 0;
    let Ok(mut reader) = Reader::create(CAPACITY) else {
        return false;
    };
    let Some(mut pane) = detached(&reader, data, !stream) else {
        return false;
    };
    if mode & 1 != 0 && !fresh(&mut pane) {
        return false;
    }
    if stream {
        return pane.control().is_err();
    }
    let mut rest = data;
    while let Ok(Some(size)) = ko_pane_wire::frame::frame_size(rest) {
        let (frame, after) = rest.split_at(size);
        let head = reader.head();
        if reader.advance(head, head).is_err() {
            return false;
        }
        if pane.dispatch(frame).is_err() {
            return true;
        }
        rest = after;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_replayed_corpus_runs_to_the_end() {
        let corpus = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fuzz/corpus/control");
        let mut replayed = 0;
        for entry in std::fs::read_dir(corpus).unwrap() {
            control(&std::fs::read(entry.unwrap().path()).unwrap());
            replayed += 1;
        }
        assert!(replayed > 100, "{replayed}");
    }

    #[test]
    fn a_resize_beyond_the_dimension_limit_is_refused() {
        let huge = [1, 9, 0, 0, 0, 3, 0xff, 0xff, 0xff, 0xff, 8, 0, 16, 0];
        assert!(control(&huge));
        let within = [1, 9, 0, 0, 0, 3, 0x00, 0x10, 24, 0, 8, 0, 16, 0];
        assert!(!control(&within));
    }
}
