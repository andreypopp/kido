use std::time::Duration;

use ko_pane_wire::frame::Req;
use ko_sys::event::{Poll, Timer};

use ko_wire::ids::{ClientId, PaneId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Viewer {
    pub(crate) client: ClientId,
    pub(crate) focused: bool,
    pub(crate) on_pane: bool,
}

pub(crate) fn answerer(viewers: impl IntoIterator<Item = Viewer>) -> Option<ClientId> {
    viewers
        .into_iter()
        .max_by_key(|viewer| {
            (
                viewer.focused && viewer.on_pane,
                viewer.focused,
                viewer.client,
            )
        })
        .map(|viewer| viewer.client)
}

#[derive(Debug)]
pub(crate) struct Read {
    pub(crate) id: u64,
    pub(crate) pane: PaneId,
    pub(crate) req: Req,
    pub(crate) client: ClientId,
    timer: Timer,
}

#[derive(Debug, Default)]
pub(crate) struct Reads {
    open: Vec<Read>,
    next: u64,
}

impl Reads {
    pub(crate) fn open(
        &mut self,
        poll: &mut Poll,
        wait: Duration,
        pane: PaneId,
        req: Req,
        client: ClientId,
    ) -> u64 {
        let id = self.next;
        self.next = self.next.saturating_add(1);
        let timer = poll.timer();
        let _ = poll.start(timer, wait, None);
        self.open.push(Read {
            id,
            pane,
            req,
            client,
            timer,
        });
        id
    }

    fn take(&mut self, poll: &mut Poll, at: Option<usize>) -> Option<Read> {
        let read = self.open.swap_remove(at?);
        poll.free(read.timer);
        Some(read)
    }

    pub(crate) fn answered(&mut self, poll: &mut Poll, id: u64, client: ClientId) -> Option<Read> {
        let at = self
            .open
            .iter()
            .position(|read| read.id == id && read.client == client);
        self.take(poll, at)
    }

    pub(crate) fn due(&mut self, poll: &mut Poll, timer: Timer) -> Option<Read> {
        let at = self.open.iter().position(|read| read.timer == timer);
        self.take(poll, at)
    }

    pub(crate) fn drop_where(
        &mut self,
        poll: &mut Poll,
        matching: impl Fn(&Read) -> bool,
    ) -> Vec<Read> {
        let mut dropped = Vec::new();
        while let Some(at) = self.open.iter().position(&matching) {
            dropped.extend(self.take(poll, Some(at)));
        }
        dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn viewer(client: u64, focused: bool, on_pane: bool) -> Viewer {
        Viewer {
            client: ClientId::new(client),
            focused,
            on_pane,
        }
    }

    #[test]
    fn the_focus_on_the_pane_answers_then_a_focused_client_then_the_newest() {
        let pick = |viewers: &[Viewer]| answerer(viewers.iter().copied()).map(|id| id.to_string());
        assert_eq!(
            pick(&[
                viewer(1, true, true),
                viewer(2, true, false),
                viewer(3, false, true)
            ]),
            Some("client_1".to_owned())
        );
        assert_eq!(
            pick(&[
                viewer(1, false, true),
                viewer(2, true, false),
                viewer(3, false, false)
            ]),
            Some("client_2".to_owned())
        );
        assert_eq!(
            pick(&[
                viewer(1, false, true),
                viewer(3, false, false),
                viewer(2, false, true)
            ]),
            Some("client_3".to_owned())
        );
        assert_eq!(pick(&[]), None);
    }

    #[test]
    fn only_the_chosen_client_answers_and_only_once() {
        let mut poll = Poll::new();
        let mut reads = Reads::default();
        let (pane, req) = (PaneId::new(1), Req::of_serial(4));
        let id = reads.open(
            &mut poll,
            Duration::from_secs(60),
            pane,
            req,
            ClientId::new(2),
        );
        assert!(reads.answered(&mut poll, id, ClientId::new(3)).is_none());
        assert!(
            reads
                .answered(&mut poll, id + 1, ClientId::new(2))
                .is_none()
        );
        let read = reads.answered(&mut poll, id, ClientId::new(2)).unwrap();
        assert_eq!((read.pane, read.req), (pane, req));
        assert!(reads.answered(&mut poll, id, ClientId::new(2)).is_none());
    }
}
