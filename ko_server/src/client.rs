use ko_pane_wire::frame::Size;

use crate::ids::{ClientId, PaneId};
use crate::protocol::ClientRequest;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Active {
    pub(crate) pane: Option<PaneId>,
    pub(crate) size: Size,
    pub(crate) focused: bool,
    ignore_size: bool,
}

#[derive(Debug)]
pub(crate) struct Client {
    pub(crate) id: ClientId,
    pub(crate) active: Option<Active>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Change {
    Hello,
    Claim,
    Resize,
    Nothing,
}

pub(crate) fn claims<'a>(
    client: ClientId,
    active: &Active,
    others: impl IntoIterator<Item = (ClientId, &'a Active)>,
) -> bool {
    let focused_elsewhere = others.into_iter().any(|(id, peer)| {
        id != client && peer.focused && !peer.ignore_size && peer.pane == active.pane
    });
    !active.ignore_size && (active.focused || !focused_elsewhere)
}

impl Client {
    pub(crate) fn new(id: ClientId) -> Client {
        Client { id, active: None }
    }

    pub(crate) fn receive(
        &mut self,
        request: ClientRequest,
        exists: impl FnOnce(PaneId) -> bool,
    ) -> Result<Change, &'static str> {
        match (&mut self.active, request) {
            (None, ClientRequest::Hello(hello)) => {
                self.active = Some(Active {
                    pane: hello.pane,
                    size: hello.size.0,
                    focused: hello.focused,
                    ignore_size: hello.ignore_size,
                });
                Ok(Change::Hello)
            }
            (None, _) => Err("hello must be first"),
            (Some(active), ClientRequest::Select(id)) => {
                if !exists(id) {
                    return Err("pane not found");
                }
                active.pane = Some(id);
                Ok(Change::Claim)
            }
            (Some(active), ClientRequest::Size(size)) => {
                active.size = size.0;
                Ok(Change::Resize)
            }
            (Some(active), ClientRequest::Focused(focused)) => {
                active.focused = focused;
                Ok(if focused {
                    Change::Claim
                } else {
                    Change::Nothing
                })
            }
            (Some(_), ClientRequest::Hello(_)) => Err("hello already received"),
        }
    }
}
