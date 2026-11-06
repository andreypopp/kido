use crate::ids::{ClientId, PaneId};
use crate::protocol::Selection;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cause {
    Eof,
    Io,
    PeerClosed,
    PingTimeout,
    Stalled,
    Cap,
    Overflow,
    Refused,
    Gone,
    ClientClosed,
    Finished,
    MessageTooLarge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSource {
    View,
    Http,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Hello {
        client: ClientId,
    },
    ClientClosed {
        client: ClientId,
        cause: Option<Cause>,
    },
    ViewOpened {
        pane: PaneId,
        client: Option<ClientId>,
    },
    ViewClosed {
        pane: PaneId,
        client: Option<ClientId>,
        cause: Option<Cause>,
    },
    Selected {
        client: ClientId,
        selection: Selection,
    },
    Input {
        pane: PaneId,
        source: InputSource,
        bytes: usize,
    },
}
