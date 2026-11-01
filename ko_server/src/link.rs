use crate::client::Client;
use crate::conn::Output;
use crate::view::View;
use crate::ws::Ws;

#[derive(Debug)]
pub(crate) enum Role {
    Client(Client),
    View(View),
}

#[derive(Debug)]
pub(crate) struct Link {
    pub(crate) ws: Ws,
    pub(crate) role: Role,
}

#[derive(Debug)]
pub(crate) struct Wire<'a> {
    pub(crate) ws: &'a mut Ws,
    pub(crate) out: &'a mut Output,
}
