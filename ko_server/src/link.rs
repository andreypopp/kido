use ko_pane_wire::frame::Req;

use crate::client::Client;
use crate::conn::Output;
use crate::ids::PaneId;
use crate::view::View;
use crate::ws::Ws;
use vstd::prelude::*;

#[derive(Debug)]
pub(crate) enum Role {
    Client(Client),
    View(View),
    Search(Searching),
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Searching {
    pub(crate) pane: PaneId,
    pub(crate) req: Req,
}

#[derive(Debug)]
pub(crate) struct Link {
    pub(crate) ws: Ws,
    pub(crate) role: Role,
}

verus! {

#[derive(Debug)]
pub(crate) struct Wire<'a> {
    pub(crate) ws: &'a mut Ws,
    pub(crate) out: &'a mut Output,
}

} // verus!
