#![allow(unsafe_code)]

use std::ops::Range;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use loom::cell::UnsafeCell;
use loom::sync::atomic::{AtomicU64, fence};

use super::{Index, Invalid, valid_capacity};

#[derive(Debug)]
pub(super) struct Shared {
    words: [AtomicU64; 3],
    data: Box<[UnsafeCell<u8>]>,
    capacity: u64,
    handshake: Handshake,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Handshake {
    SeqCst,
    AcqRel,
}

impl Shared {
    pub(super) fn new(capacity: u64, handshake: Handshake) -> Result<Arc<Shared>, Invalid> {
        Ok(Arc::new(Shared {
            words: [AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0)],
            data: (0..valid_capacity(capacity, capacity)?)
                .map(|_| UnsafeCell::new(0))
                .collect(),
            capacity,
            handshake,
        }))
    }

    pub(super) fn capacity(&self) -> u64 {
        self.capacity
    }

    fn word(&self, index: Index) -> &AtomicU64 {
        match index {
            Index::Head => &self.words[0],
            Index::Tail => &self.words[1],
            Index::Read => &self.words[2],
        }
    }

    // loom models a SeqCst access as AcqRel but models fence(SeqCst), so a SeqCst access is a
    // SeqCst fence and the access: https://github.com/tokio-rs/loom/issues/180
    pub(super) fn load(&self, index: Index) -> u64 {
        match self.handshake {
            Handshake::SeqCst => {
                fence(Ordering::SeqCst);
                self.word(index).load(Ordering::SeqCst)
            }
            Handshake::AcqRel => self.word(index).load(Ordering::Acquire),
        }
    }

    pub(super) fn store(&self, index: Index, value: u64) {
        match self.handshake {
            Handshake::SeqCst => {
                self.word(index).store(value, Ordering::SeqCst);
                fence(Ordering::SeqCst);
            }
            Handshake::AcqRel => self.word(index).store(value, Ordering::Release),
        }
    }

    fn cells(&self, at: u64, len: usize) -> Option<&[UnsafeCell<u8>]> {
        let index = usize::try_from(at.checked_rem(self.capacity)?).ok()?;
        self.data.get(index..index.checked_add(len)?)
    }

    pub(super) fn copy(&self, readable: Range<u64>, at: u64, out: &mut [u8]) -> Option<()> {
        let end = at.checked_add(u64::try_from(out.len()).ok()?)?;
        if at < readable.start || end > readable.end {
            return None;
        }
        for (cell, byte) in self.cells(at, out.len())?.iter().zip(out) {
            // SAFETY: loom checks that no write to the cell races this read.
            *byte = cell.with(|value| unsafe { *value });
        }
        Some(())
    }

    pub(super) fn write(&self, at: u64, bytes: &[u8]) -> Option<()> {
        for (cell, &byte) in self.cells(at, bytes.len())?.iter().zip(bytes) {
            // SAFETY: loom checks that no access to the cell races this write.
            cell.with_mut(|value| unsafe { *value = byte });
        }
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ring::{Commit, Reader, RecordKind, Writer};

    const CAP: u64 = 64;

    fn ring(handshake: Handshake) -> (Reader, Writer) {
        let shared = Shared::new(CAP, handshake).unwrap();
        (Reader::attach(shared.clone()), Writer::attach(shared))
    }

    fn model(bound: Option<usize>, f: impl Fn() + Sync + Send + 'static) {
        let mut builder = loom::model::Builder::new();
        builder.preemption_bound = bound;
        builder.check(f);
    }

    #[test]
    fn ring_mc() {
        model(Some(5), || {
            let (mut reader, mut writer) = ring(Handshake::SeqCst);
            let records = loom::thread::spawn(move || {
                let mut written = 0;
                for _ in 0..8 {
                    if written == 5 {
                        break;
                    }
                    let offset = writer.woff;
                    let payload: Vec<u8> = (0..9).map(|i| (offset + i) as u8).collect();
                    if writer.available().room < 9 {
                        continue;
                    }
                    assert_ne!(writer.put(RecordKind::Bytes, &payload), Commit::Refused);
                    written += 1;
                }
            });
            let mut expect = 0;
            let mut pos = reader.tail();
            for _ in 0..4 {
                let upper = reader.head();
                while pos < upper {
                    let record = reader.record(pos).unwrap();
                    if record.kind == RecordKind::Bytes {
                        assert_eq!(record.offset.get(), expect);
                        let mut bytes = vec![0; 9];
                        reader.copy(pos.get() + 13, &mut bytes).unwrap();
                        let wanted: Vec<u8> = (0..9).map(|i| (expect + i) as u8).collect();
                        assert_eq!(bytes, wanted);
                        expect += 9;
                    }
                    pos = record.next;
                }
                reader.advance(upper, upper).unwrap();
            }
            records.join().unwrap();
        });
    }

    fn wakeup(handshake: Handshake) {
        model(None, move || {
            let (mut reader, mut writer) = ring(handshake);
            writer.available();
            writer.put(RecordKind::Bytes, &[0; 3]);
            let first = reader.head();
            let commit = loom::thread::spawn(move || {
                writer.available();
                writer.put(RecordKind::Bytes, &[0; 3])
            });
            reader.advance(first, first).unwrap();
            let seen_after = reader.head();
            let commit = commit.join().unwrap();
            assert!(
                !(commit == Commit::Published && seen_after == first),
                "a lost wakeup"
            );
        });
    }

    #[test]
    fn wakeup_mc() {
        wakeup(Handshake::SeqCst);
    }

    #[test]
    #[should_panic(expected = "a lost wakeup")]
    fn wakeup_mc_acquire_release_loses_a_wakeup() {
        wakeup(Handshake::AcqRel);
    }
}
