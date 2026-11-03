use ko_pane_wire::frame::Req;
use ko_vt::ReadId;

#[derive(Debug, Default)]
pub(crate) struct Reads {
    open: Vec<(Req, ReadId)>,
    next: u64,
}

impl Reads {
    pub(crate) fn open(&mut self, read: ReadId) -> Req {
        let req = Req::of_serial(self.next);
        self.next = self.next.wrapping_add(1);
        self.open.push((req, read));
        req
    }

    pub(crate) fn close(&mut self, req: Req) -> Option<ReadId> {
        let at = self.open.iter().position(|(open, _)| open.same(req))?;
        Some(self.open.swap_remove(at).1)
    }
}
