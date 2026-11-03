use ko_pane_wire::frame::{ImageKey, Req};
use ko_sys::mapping::{Name, Named};

use super::*;
use crate::clipboard::{self, Viewer};
use crate::link::Searching;
use crate::pane_proc::Object;
use crate::protocol::{
    ClipboardContent, ClipboardLocation, ClipboardServed, SearchEvent, SearchMatch,
};
use crate::router::ImageReply;

const IMAGE_WAIT: Duration = Duration::from_secs(10);

impl State {
    fn mint_object(&mut self) -> Option<Name> {
        let name = Name::new(&format!("/ko-{}-{}", std::process::id(), self.next_object))?;
        self.next_object = self.next_object.wrapping_add(1);
        Some(name)
    }

    pub(crate) fn fetch_image(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        key: ImageKey,
        shm: bool,
    ) {
        let Some(conn) = self.token(index) else {
            return;
        };
        self.conns[index].phase = Phase::Handling;
        let Some(minted) = self
            .mint_object()
            .filter(|minted| self.leaks.record(pane, key, minted).is_ok())
        else {
            return router::failed(self, poll, conn, false, "cannot record the image object");
        };
        let requested = self.call(poll, pane, |pane, io| {
            pane.proc_mut().image(key, &minted, io)
        });
        let Some((req, events)) = requested else {
            self.leaks.gone(&minted);
            return router::failed(self, poll, conn, false, &Refusal::Ended.to_string());
        };
        match req {
            Some(req) => {
                let owner = Owner::Image {
                    conn: Some(conn),
                    shm,
                    key,
                    minted,
                };
                self.owners.insert((pane, req), owner);
                let _ = poll.start(self.conns[index].timer, IMAGE_WAIT, None);
            }
            None => {
                self.leaks.gone(&minted);
                router::failed(self, poll, conn, false, &Refusal::Ended.to_string());
            }
        }
        self.dispatch(poll, pane, events);
    }

    pub(super) fn image_reply(
        &mut self,
        poll: &mut Poll,
        pane: PaneId,
        req: Req,
        object: Option<Object>,
    ) {
        let Some(Owner::Image {
            conn, shm, minted, ..
        }) = self.owners.remove(&(pane, req))
        else {
            return;
        };
        if object.as_ref().is_none_or(|object| object.name != minted) {
            self.leaks.gone(&minted);
        }
        let Some(conn) = conn else {
            return;
        };
        let Some(Object { name, shm: info }) = object else {
            return router::image::<routes::Image>(self, poll, conn, ImageReply::Missing);
        };
        if shm {
            return router::image::<routes::Image>(self, poll, conn, ImageReply::Shm(&info));
        }
        let map = usize::try_from(info.length)
            .ok()
            .and_then(|length| Named::open(&name, length).ok());
        let reply = match map {
            Some(map) => ImageReply::Pixels(&info, map),
            None => ImageReply::Missing,
        };
        router::image::<routes::Image>(self, poll, conn, reply);
    }

    pub(super) fn image_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(conn) = self
            .conns
            .iter()
            .find(|conn| conn.timer == timer)
            .map(|conn| conn.token)
        else {
            return false;
        };
        let Some(waiting) = self.owners.values_mut().find_map(|owner| match owner {
            Owner::Image { conn: waiting, .. } if *waiting == Some(conn) => Some(waiting),
            _ => None,
        }) else {
            return false;
        };
        *waiting = None;
        router::failed(self, poll, conn, false, "image request timed out");
        true
    }

    pub(crate) fn start_search(
        &mut self,
        poll: &mut Poll,
        conn: Token,
        pane: PaneId,
        needle: &str,
    ) -> Option<Searching> {
        let (req, events) = self.call(poll, pane, |pane, io| {
            pane.proc_mut().search(needle.as_bytes(), io)
        })?;
        self.dispatch(poll, pane, events);
        let req = req?;
        self.owners.insert((pane, req), Owner::Search(conn));
        Some(Searching { pane, req })
    }

    pub(super) fn search_matches(&mut self, pane: PaneId, req: Req, matches: Vec<SearchMatch>) {
        if let Some(Owner::Search(conn)) = self.owners.get(&(pane, req)).cloned()
            && let Some((Role::Search(_), wire)) =
                find(&mut self.conns, conn).and_then(Conn::role_mut)
        {
            wire.ws
                .send(wire.out, protocol::json(&SearchEvent::Matches { matches }));
        }
    }

    pub(super) fn search_done(&mut self, pane: PaneId, req: Req) {
        if let Some(Owner::Search(conn)) = self.owners.remove(&(pane, req))
            && let Some((Role::Search(_), wire)) =
                find(&mut self.conns, conn).and_then(Conn::role_mut)
        {
            wire.ws.send(wire.out, protocol::json(&SearchEvent::Done));
            wire.ws.finish(wire.out);
        }
    }

    pub(super) fn search_failed(&mut self, conn: Token) {
        if let Some((Role::Search(_), wire)) = find(&mut self.conns, conn).and_then(Conn::role_mut)
        {
            wire.ws.reject(wire.out, "gone");
        }
    }

    pub(super) fn cancel_search(&mut self, poll: &mut Poll, search: Searching) {
        self.owners.remove(&(search.pane, search.req));
        self.run(poll, search.pane, |pane, io| {
            pane.proc_mut().search_cancel(search.req, io);
        });
    }

    fn viewers(&self, pane: PaneId) -> Vec<(Viewer, usize)> {
        let Some((_, window)) = self.document.layout().locate(pane) else {
            return Vec::new();
        };
        self.conns
            .iter()
            .enumerate()
            .filter_map(|(index, conn)| {
                let client = client_of(conn)?;
                let active = client.active?;
                let current = active
                    .current
                    .filter(|current| current.window == window.id)?;
                Some((
                    Viewer {
                        client: client.id,
                        focused: active.focused,
                        on_pane: current.pane == pane,
                    },
                    index,
                ))
            })
            .collect()
    }

    fn tell(&mut self, index: usize, text: String) {
        if let Some((Role::Client(_), wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
            wire.ws.send(wire.out, text);
        }
    }

    pub(super) fn clipboard_write(
        &mut self,
        pane: PaneId,
        location: ClipboardLocation,
        contents: Vec<ClipboardContent>,
    ) {
        let text = protocol::json(&ClientEvent::ClipboardWrite {
            pane,
            location,
            contents,
        });
        for (viewer, index) in self.viewers(pane) {
            if viewer.focused {
                self.tell(index, text.clone());
            }
        }
    }

    pub(super) fn clipboard_read(
        &mut self,
        poll: &mut Poll,
        pane: PaneId,
        req: Req,
        location: ClipboardLocation,
        mimes: Vec<String>,
        list: bool,
    ) {
        let viewers = self.viewers(pane);
        let chosen = clipboard::answerer(viewers.iter().map(|(viewer, _)| *viewer));
        let Some((client, index)) = chosen.and_then(|client| {
            viewers
                .iter()
                .find(|(viewer, _)| viewer.client == client)
                .map(|(_, index)| (client, *index))
        }) else {
            return self.clipboard_refuse(poll, pane, req);
        };
        let id = self
            .clipboard
            .open(poll, self.config.clipboard_wait, pane, req, client);
        self.tell(
            index,
            protocol::json(&ClientEvent::ClipboardRead {
                pane,
                id,
                location,
                mimes,
                list,
            }),
        );
    }

    fn clipboard_refuse(&mut self, poll: &mut Poll, pane: PaneId, req: Req) {
        self.run(poll, pane, |pane, io| {
            pane.proc_mut().clipboard_answer(req, None, io);
        });
    }

    pub(super) fn clipboard_answered(
        &mut self,
        poll: &mut Poll,
        client: ClientId,
        id: u64,
        served: Option<ClipboardServed>,
    ) {
        if let Some(read) = self.clipboard.answered(poll, id, client) {
            self.run(poll, read.pane, |pane, io| {
                pane.proc_mut()
                    .clipboard_answer(read.req, served.as_ref(), io);
            });
        }
    }

    pub(super) fn clipboard_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let Some(read) = self.clipboard.due(poll, timer) else {
            return false;
        };
        self.clipboard_refuse(poll, read.pane, read.req);
        true
    }

    pub(super) fn clipboard_forget(
        &mut self,
        poll: &mut Poll,
        matching: impl Fn(&clipboard::Read) -> bool,
    ) {
        for read in self.clipboard.drop_where(poll, matching) {
            self.clipboard_refuse(poll, read.pane, read.req);
        }
    }
}
