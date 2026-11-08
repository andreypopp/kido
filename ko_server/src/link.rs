use ko_pane_wire::frame::Req;

use crate::client::Client;
use crate::conn::Output;
use crate::ids::PaneId;
use crate::runtime::exec::Session;
use crate::state::visit_ops::Visit;
use crate::view::View;
use crate::ws::Ws;
use vstd::prelude::*;

#[derive(Debug)]
pub(crate) enum Role {
    Client(Client),
    View(View),
    Search(Searching),
    Messages(PaneId),
    WebviewServe(PaneId),
    WebviewProxy { pane: PaneId, req: u64 },
    Exec(Session),
    Visit(Visit),
}

impl Role {
    pub(crate) fn reads(&self) -> bool {
        match self {
            Role::Exec(session) => session.reads(),
            Role::Client(_)
            | Role::View(_)
            | Role::Search(_)
            | Role::Messages(_)
            | Role::Visit(_)
            | Role::WebviewServe(_)
            | Role::WebviewProxy { .. } => true,
        }
    }
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
