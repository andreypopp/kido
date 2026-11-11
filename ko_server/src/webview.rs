use ko_sys::event::Token;
use ko_wire::http::Head;
use ko_wire::ids::{ClientId, PaneId};
use ko_wire::protocol::webview::{Page, Rest, ServeOut, Webview};
use ko_wire::protocol::{Error, Method};
use std::collections::{BTreeMap, VecDeque};

#[derive(Debug, Default)]
pub(crate) struct PaneWebview {
    pub(crate) page: Option<Page>,
    pub(crate) serial: u64,
    pub(crate) serving: Option<Serving>,
}

#[derive(Debug)]
pub(crate) struct Serving {
    pub(crate) token: Token,
    pub(crate) sent_supported: Option<bool>,
    pub(crate) waits: BTreeMap<u64, Wait>,
    pub(crate) pending: VecDeque<ServeOut>,
}

impl PaneWebview {
    pub(crate) fn row(&self) -> Option<Webview> {
        (self.page.is_some() || self.serving.is_some()).then(|| Webview {
            page: self.page.clone(),
            serving: self.serving.is_some(),
        })
    }
    pub(crate) fn stream(&self) -> Option<Token> {
        self.serving.as_ref().map(|serving| serving.token)
    }
}

#[derive(Debug)]
pub(crate) struct ProxyRequest {
    pub(crate) caller: Option<PaneId>,
    pub(crate) client: Option<ClientId>,
    pub(crate) pane: PaneId,
    pub(crate) method: Method,
    pub(crate) path: Rest,
    pub(crate) body: Vec<u8>,
    pub(crate) head: Head,
}

#[derive(Debug)]
pub(crate) enum Refusal {
    Error(Error),
    Full,
    Unavailable,
    Exhausted,
}
impl From<Error> for Refusal {
    fn from(error: Error) -> Self {
        Self::Error(error)
    }
}

#[derive(Debug)]
pub(crate) enum Phase {
    Head,
    Body { allowed: bool },
    Upgrade(String),
    Socket,
}

#[derive(Debug)]
pub(crate) struct Wait {
    pub(crate) conn: Token,
    pub(crate) phase: Phase,
}
