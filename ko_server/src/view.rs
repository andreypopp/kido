use ko_pane_wire::frame::{History, Req};
use ko_pane_wire::ring::{self, Invalid, Offset, Pos, Reach, Reader, Record, RecordKind};

use crate::conn::{Batch, Output, Written};
use crate::ids::{ClientId, PaneId};
use crate::link::Wire;
use crate::protocol::{self, Marked, Skipped, ViewEvent};
use crate::ws;

const RESUME_THRESHOLD: u64 = 65536;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Decision {
    Resume,
    Snapshot(History),
    Skip,
}

fn decide(
    behind: bool,
    offset: u64,
    head: u64,
    history: History,
    resize: bool,
    blocked: bool,
) -> Decision {
    if blocked && head.saturating_sub(offset) >= RESUME_THRESHOLD {
        Decision::Skip
    } else if behind {
        Decision::Snapshot(history)
    } else if resize && history == History::None {
        Decision::Snapshot(History::None)
    } else {
        Decision::Resume
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Live,
    Snapshotting(Req),
    Closed,
}

fn event(wire: &mut Wire<'_>, event: &ViewEvent) {
    wire.ws.send(wire.out, protocol::json(event));
}

#[derive(Debug)]
pub(crate) struct View {
    pub(crate) pane: PaneId,
    pub(crate) client: Option<ClientId>,
    stage: Stage,
    cpos: Pos,
    coff: u64,
    blocked: bool,
    history: History,
    wanted: Option<History>,
    batch: Batch,
}

impl View {
    pub(crate) fn new(
        pane: PaneId,
        client: Option<ClientId>,
        history: History,
        ring: &Reader,
    ) -> View {
        View {
            pane,
            client,
            stage: Stage::Live,
            cpos: ring.tail(),
            coff: 0,
            blocked: false,
            history,
            wanted: Some(history),
            batch: Batch::default(),
        }
    }

    pub(crate) fn waiting(&self, out: &Output) -> bool {
        match self.stage {
            Stage::Closed => false,
            Stage::Snapshotting(_) => true,
            Stage::Live => out.waiting(),
        }
    }

    pub(crate) fn close(&mut self, out: &mut Output) {
        if self.stage != Stage::Closed {
            self.stage = Stage::Closed;
            out.close();
        }
    }

    pub(crate) fn reject(&mut self, wire: &mut Wire<'_>) {
        wire.ws.reject(wire.out, "io");
        self.close(wire.out);
    }

    pub(crate) fn started(&mut self, req: Req, history: History) {
        if self.stage == Stage::Live {
            self.stage = Stage::Snapshotting(req);
            self.history = history;
        }
    }

    fn flush_wanted(&mut self, out: &Output) -> Option<History> {
        match (self.stage, self.wanted) {
            (Stage::Live, Some(_)) if !out.waiting() => self.wanted.take(),
            _ => None,
        }
    }

    pub(crate) fn request(&mut self, out: &Output, history: History) -> Option<History> {
        self.wanted = Some(history);
        self.flush_wanted(out)
    }

    pub(crate) fn on_done(&mut self, wire: &mut Wire<'_>, req: Req, complete: bool) {
        if self.stage == Stage::Snapshotting(req) {
            if complete {
                self.stage = Stage::Live;
            } else {
                self.reject(wire);
            }
        }
    }

    pub(crate) fn on_slice(
        &mut self,
        out: &mut Output,
        ring: &Reader,
        req: Req,
        at: Pos,
    ) -> Result<(), Invalid> {
        if self.stage != Stage::Snapshotting(req) {
            return Ok(());
        }
        let record = ring.record(at)?;
        let written = out.record(
            true,
            ws::Record::Snapshot,
            record.offset.get(),
            ring.payload(at)?,
        );
        if written == Written::Closed {
            self.close(out);
        } else {
            self.blocked |= written != Written::Accepted;
            self.cpos = record.next;
            self.coff = record.offset.get();
        }
        Ok(())
    }

    fn flush_batch(&mut self, out: &mut Output, ring: &Reader) -> bool {
        let count = self.batch.len();
        if count == 0 {
            return true;
        }
        let accepted = out.send_batch(&self.batch, ring);
        if let Some((next, end)) = self.batch.sent(accepted.unwrap_or(0)) {
            self.cpos = next;
            self.coff = end;
        }
        match accepted {
            None => {
                self.close(out);
                false
            }
            Some(accepted) if accepted < count || out.waiting() => {
                self.blocked = true;
                false
            }
            Some(_) => true,
        }
    }

    fn step_bytes(
        &mut self,
        out: &mut Output,
        ring: &Reader,
        here: Pos,
        record: Record,
    ) -> Result<bool, Invalid> {
        let start = record.offset.get();
        let end = start.saturating_add(record.len);
        let queued = self.batch.len();
        if end <= self.coff && queued == 0 {
            return Ok(true);
        }
        let skip = if queued == 0 && start < self.coff {
            self.coff - start
        } else {
            0
        };
        let len = usize::try_from(record.len - skip).map_err(|_| Invalid::Record)?;
        let skip = usize::try_from(skip).map_err(|_| Invalid::Record)?;
        self.batch
            .add(start + skip as u64, here, skip, len, record.next, end);
        Ok(!self.batch.full() || self.flush_batch(out, ring))
    }

    fn step_marker(
        &mut self,
        wire: &mut Wire<'_>,
        ring: &Reader,
        here: Pos,
        record: Record,
    ) -> Result<bool, Invalid> {
        if !self.flush_batch(wire.out, ring) {
            return Ok(false);
        }
        let marked = Marked {
            offset: record.offset.get(),
            marker: ring.marker(here)?.into(),
        };
        event(wire, &ViewEvent::Marked(marked));
        self.cpos = record.next;
        Ok(true)
    }

    fn resume(&mut self, wire: &mut Wire<'_>, ring: &mut Reader) -> Result<(), Invalid> {
        let upper = ring.head();
        let mut pos = self.cpos;
        let mut going = true;
        while going && pos < upper {
            let record = ring.record(pos)?;
            match record.kind {
                RecordKind::Bytes => {
                    going = self.step_bytes(wire.out, ring, pos, record)?;
                    pos = record.next;
                }
                RecordKind::Marker => {
                    going = self.step_marker(wire, ring, pos, record)?;
                    if going {
                        pos = record.next;
                    }
                }
                RecordKind::Slice | RecordKind::Pad => pos = record.next,
            }
        }
        if going && self.flush_batch(wire.out, ring) && self.cpos < upper && upper <= pos {
            self.cpos = pos;
        }
        Ok(())
    }

    fn resize_pending(&self, ring: &mut Reader, from: Pos) -> Result<bool, Invalid> {
        let upper = ring.head();
        let mut pos = from;
        while pos < upper {
            let record = ring.record(pos)?;
            if record.kind == RecordKind::Marker
                && matches!(ring.marker(pos)?, ring::Marker::Resize(_))
                && self.coff <= record.offset.get()
            {
                return Ok(true);
            }
            pos = record.next;
        }
        Ok(false)
    }

    fn pump_live(
        &mut self,
        wire: &mut Wire<'_>,
        ring: &mut Reader,
    ) -> Result<Option<History>, Invalid> {
        let upper = ring.head();
        if self.cpos >= upper || !wire.out.available() {
            return Ok(None);
        }
        let behind = match ring.reachable(self.cpos) {
            Reach::Behind => true,
            Reach::At(pos) => {
                self.cpos = pos;
                false
            }
        };
        let resize =
            !behind && self.history == History::None && self.resize_pending(ring, self.cpos)?;
        let head = ring.end_offset()?.get();
        let decision = decide(behind, self.coff, head, self.history, resize, self.blocked);
        self.blocked = false;
        match decision {
            Decision::Skip => {
                let head = ring.end_offset()?.get();
                event(
                    wire,
                    &ViewEvent::Skipped(Skipped {
                        offset: head,
                        from: self.coff,
                        to: head,
                    }),
                );
                Ok(self.request(wire.out, History::None))
            }
            Decision::Snapshot(history) => Ok(self.request(wire.out, history)),
            Decision::Resume => self.resume(wire, ring).map(|()| None),
        }
    }

    pub(crate) fn pump(
        &mut self,
        wire: &mut Wire<'_>,
        ring: &mut Reader,
    ) -> Result<Option<History>, Invalid> {
        if let Some(history) = self.flush_wanted(wire.out) {
            return Ok(Some(history));
        }
        if self.stage == Stage::Live {
            self.pump_live(wire, ring)
        } else {
            Ok(None)
        }
    }

    pub(crate) fn open(
        &mut self,
        wire: &mut Wire<'_>,
        ring: &mut Reader,
        offset: Option<u64>,
    ) -> Result<Option<History>, Invalid> {
        let end = ring.end_offset()?.get();
        self.coff = end;
        if let Some(offset) = offset
            && ring.oldest_offset()?.get() <= offset
            && offset <= end
        {
            self.cpos = ring.resume(Offset::new(offset))?;
            self.coff = offset;
            self.wanted = None;
            return self.pump(wire, ring);
        }
        Ok(self.flush_wanted(wire.out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conn::tests::full_output;
    use crate::ws::Ws;
    use std::io::Read as _;

    fn drain(peer: &mut std::os::unix::net::UnixStream) -> Vec<u8> {
        let mut seen = Vec::new();
        let mut buffer = [0; 65536];
        while let Ok(count @ 1..) = peer.read(&mut buffer) {
            seen.extend_from_slice(&buffer[..count]);
        }
        seen
    }

    #[test]
    fn a_view_whose_socket_refused_a_write_whole_decides_no_skip_until_it_is_writable() {
        let (mut out, mut peer) = full_output();
        let mut ring = ring::Reader::create(1 << 20).unwrap();
        let mut writer = ring.writer().unwrap();
        writer.available();
        writer.put(RecordKind::Bytes, &[1; 100_000]);
        ring.head();
        let mut ws = Ws::new(Vec::new());
        let mut view = View::new(PaneId::new(1), None, History::None, &ring);
        view.wanted = None;
        let mut pump = |view: &mut View, out: &mut Output| {
            view.pump(&mut Wire { ws: &mut ws, out }, &mut ring)
                .unwrap()
        };
        assert_eq!(pump(&mut view, &mut out), None);
        assert!(view.blocked && out.waiting());
        assert_eq!(pump(&mut view, &mut out), None);
        assert!(view.blocked && out.waiting());
        let before = drain(&mut peer);
        assert!(!String::from_utf8_lossy(&before).contains("skipped"));
        out.writable();
        assert_eq!(pump(&mut view, &mut out), Some(History::None));
        out.flush();
        assert!(String::from_utf8_lossy(&drain(&mut peer)).contains("skipped"));
    }

    #[test]
    fn resume_resize_and_a_threshold_only_after_a_block() {
        let shown: Vec<&str> = [
            (10, false, true, false, false),
            (9, true, true, false, false),
            (10, false, false, true, false),
            (10, false, true, true, false),
            (10, false, true, false, true),
            (99999, false, false, false, true),
        ]
        .into_iter()
        .map(|(offset, behind, full, resize, blocked)| {
            let history = if full { History::All } else { History::None };
            match decide(behind, offset, 100000, history, resize, blocked) {
                Decision::Resume => "resume",
                Decision::Snapshot(History::All) => "full",
                Decision::Snapshot(History::None) => "screen",
                Decision::Skip => "skip",
            }
        })
        .collect();
        assert_eq!(
            shown,
            ["resume", "full", "screen", "resume", "skip", "resume"]
        );
    }
}
