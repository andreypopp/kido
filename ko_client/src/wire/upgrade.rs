use std::io;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ko_sys::event::{Poll, Ready, Token, Wake};
use ko_wire::api::Route;
use ko_wire::http::{Response, response};
use ko_wire::ids::ClientId;
use ko_wire::protocol;

use super::exchange::{Destination, Exchange, Request, RequestKind};
use super::{Limit, Link};
use crate::endpoint::Resolved;

#[derive(Debug)]
pub struct Connecting {
    exchange: Box<Exchange>,
    response: Option<Response>,
    cancel: Option<Arc<Wake>>,
}
#[derive(Debug)]
pub enum UpgradeStep {
    Pending(Connecting),
    Open(Box<Link>),
    Refused(Response),
}

impl Connecting {
    pub fn start(
        socket: &Resolved,
        client: Option<ClientId>,
        route: &Route,
        cancel: Option<Arc<Wake>>,
        within: Duration,
        poll: &mut Poll,
    ) -> io::Result<Self> {
        let (_, target) = route.to_request();
        let request = Request {
            kind: RequestKind::WebSocket {
                target,
                headers: Vec::new(),
            },
            destination: Destination::Server {
                client,
                caller: None,
            },
        };
        Ok(Self {
            exchange: Exchange::start(
                poll,
                socket,
                request,
                Limit::Deadline(Instant::now() + within),
            )?
            .into(),
            response: None,
            cancel,
        })
    }
    pub fn token(&self) -> Token {
        self.exchange.token()
    }
    pub(crate) fn deadline(&self) -> Instant {
        self.exchange.deadline()
    }
    pub fn advance(mut self, poll: &mut Poll, ready: &mut Ready) -> io::Result<UpgradeStep> {
        if self.cancel.as_ref().is_some_and(|cancel| cancel.is_set()) {
            return Err(crate::connect::cancelled_error());
        }
        if self.exchange.expired(poll, Instant::now())? {
            return Err(io::ErrorKind::TimedOut.into());
        }
        self.exchange.begin_turn();
        if ready.write || ready.read {
            self.exchange.writable(poll)?;
        }
        self.exchange.flush(poll)?;
        while let Some(event) = self.exchange.next(poll).map_err(io::Error::from)? {
            match event {
                response::Event::Upgrade(head) => {
                    self.exchange.accepted(&head)?;
                    let (stream, rest, token) = self.exchange.into_stream();
                    let mut link = Link::of_stream(stream, rest, protocol::Upgrade::Control);
                    link.cancel = self.cancel;
                    link.token = Some(token);
                    link.interest(poll, true);
                    ready.token = token;
                    return Ok(UpgradeStep::Open(Box::new(link)));
                }
                response::Event::Head(head) => self.response = Some(head),
                response::Event::Body(bytes) => {
                    if let Some(response) = &mut self.response {
                        response.body.extend(bytes);
                    }
                }
                response::Event::End => {
                    return self.response.map(UpgradeStep::Refused).ok_or_else(|| {
                        io::Error::new(io::ErrorKind::InvalidData, "missing HTTP response")
                    });
                }
            }
        }
        self.exchange.interest(poll, true);
        Ok(UpgradeStep::Pending(self))
    }
}
