use crate::protocol::webview::FrameKind;

use crate::webview::{Phase, ProxyRequest, Refusal, Serving, Wait};
use std::collections::VecDeque;

use super::*;
use crate::http::{self, Policy, Status};
use crate::protocol::Method;
use crate::protocol::webview::{
    AbortReason, Data, Headers, MAX_IN_FLIGHT, Page, ServeIn, ServeOut,
};
use crate::protocol::{CloseCode, CloseReason};
use crate::protocol::{Error, ErrorKind};
use crate::ws::Ws;
use ko_sys::event::Interest;

#[derive(Debug)]
enum Outcome {
    Keep,
    Complete,
    Upgraded { response: Vec<u8>, ws: Box<Ws> },
    Invalid,
    TooLarge,
    InvalidText,
    BadUpgrade,
    Aborted(AbortReason),
}

fn message_req(message: &ServeOut) -> Option<u64> {
    match message {
        ServeOut::Supported { .. } => None,
        ServeOut::Request { req, .. }
        | ServeOut::Upgrade { req, .. }
        | ServeOut::Body { req, .. }
        | ServeOut::Cancel { req }
        | ServeOut::Frame { req, .. }
        | ServeOut::Close { req, .. } => Some(*req),
    }
}

impl State {
    fn bad_gateway(&mut self, poll: &mut Poll, index: usize, message: impl Into<String>) {
        let error = Error::new(ErrorKind::Io, message);
        self.conns[index].out.send_reply(http::error_reply(
            &error,
            Status::BadGateway,
            Policy::Webview,
        ));
        self.conns[index].phase = crate::conn::Phase::Head;
        self.serve(poll, index);
    }

    fn webview_event(&mut self, pane: PaneId) {
        let webview = self.panes.find(pane).and_then(|pane| pane.webview().row());
        self.broadcast(&ClientEvent::Webview { pane, webview });
    }

    pub(super) fn webview_page(&mut self, id: PaneId, page: Option<Page>) {
        let Some(pane) = self.panes.find_mut(id) else {
            return;
        };
        if pane.webview().page != page {
            pane.webview_mut().page = page;
            self.webview_event(id);
        }
    }

    pub(crate) fn open_webview(&mut self, pane: PaneId, stream: Token) {
        if let Some(found) = self.panes.find_mut(pane) {
            let webview = found.webview_mut();
            webview.serving = Some(Serving {
                token: stream,
                sent_supported: None,
                waits: BTreeMap::new(),
                pending: VecDeque::new(),
            });
        }
        self.webview_event(pane);
        self.pump_webview(pane, Some(self.webview_supported()));
    }
    fn webview_send(&mut self, pane: PaneId, message: ServeOut) {
        let Some(found) = self.panes.find_mut(pane) else {
            return;
        };
        let Some(serving) = &mut found.webview_mut().serving else {
            return;
        };
        serving.pending.push_back(message);
        self.pump_webview(pane, None);
    }
    pub(super) fn webview_supported_streams(&mut self) {
        let supported = self.webview_supported();
        let panes: Vec<_> = self
            .panes
            .iter()
            .filter(|pane| pane.webview().serving.is_some())
            .map(Pane::id)
            .collect();
        for pane in panes {
            self.pump_webview(pane, Some(supported));
        }
    }

    pub(crate) fn proxy_webview(
        &mut self,
        index: usize,
        request: ProxyRequest,
    ) -> Result<(), Refusal> {
        let ProxyRequest {
            caller,
            client,
            pane,
            method,
            path,
            body,
            head,
        } = request;
        if caller.is_some() || client.is_none() {
            return Err(Error::new(
                ErrorKind::Refused,
                "webview resources require a live client and no pane identity",
            )
            .into());
        }
        let found = self.live(pane)?;
        if found.webview().page.is_none() {
            return Err(Error::new(ErrorKind::Missing, "pane has no webview page").into());
        }
        let Some(serving) = &found.webview().serving else {
            return Err(Refusal::Unavailable);
        };
        if serving.waits.len() >= MAX_IN_FLIGHT {
            return Err(Refusal::Full);
        }
        let serial = found
            .webview()
            .serial
            .checked_add(1)
            .ok_or(Refusal::Exhausted)?;
        let mut fields: Vec<_> = http::forwarded(
            head.headers(),
            http::ForwardLength::Keep,
            http::ForwardIdentity::Remove,
        )
        .map(|(name, value)| (name.to_owned(), value.to_owned()))
        .collect();
        fields.push((protocol::PANE_HEADER.into(), pane.to_string()));
        let headers =
            Headers::try_from(fields).map_err(|message| Error::new(ErrorKind::Invalid, message))?;
        let path = path.into_target();
        let upgrading = method == Method::Get
            && head
                .header("upgrade")
                .is_some_and(|value| value.eq_ignore_ascii_case("websocket"));
        let mut pending = VecDeque::new();
        let phase = if upgrading {
            let accept = crate::ws::handshake(&head)
                .ok_or_else(|| Error::new(ErrorKind::Invalid, "invalid WebSocket upgrade"))?;
            pending.push_back(ServeOut::Upgrade {
                req: serial,
                path,
                headers,
            });
            Phase::Upgrade(accept)
        } else {
            pending.push_back(ServeOut::Request {
                req: serial,
                method,
                path,
                headers,
            });
            if body.is_empty() {
                pending.push_back(ServeOut::Body {
                    req: serial,
                    data: Data::empty(),
                    more: false,
                });
            } else {
                let mut body = body;
                let mut chunks = Vec::new();
                while body.len() > protocol::EXEC_CHUNK {
                    let split = body
                        .len()
                        .div_ceil(protocol::EXEC_CHUNK)
                        .saturating_sub(1)
                        .saturating_mul(protocol::EXEC_CHUNK);
                    chunks.push(body.split_off(split));
                }
                chunks.push(body);
                let mut chunks = chunks.into_iter().rev().peekable();
                while let Some(body) = chunks.next() {
                    pending.push_back(ServeOut::Body {
                        req: serial,
                        data: Data::new(body)
                            .map_err(|message| Error::new(ErrorKind::Invalid, message))?,
                        more: chunks.peek().is_some(),
                    });
                }
            }
            Phase::Head
        };
        let token = self.conns[index].token;
        self.conns[index].phase = crate::conn::Phase::Webview { pane, req: serial };
        if let Some(found) = self.panes.find_mut(pane) {
            let webview = found.webview_mut();
            webview.serial = serial;
            if let Some(serving) = &mut webview.serving {
                serving.waits.insert(serial, Wait { conn: token, phase });
                serving.pending.extend(pending);
            }
        }
        self.pump_webview(pane, None);
        Ok(())
    }

    fn pump_webview(&mut self, pane: PaneId, supported: Option<bool>) {
        let State { panes, conns, .. } = self;
        let Some(found) = panes.find_mut(pane) else {
            return;
        };
        let Some(serving) = &mut found.webview_mut().serving else {
            return;
        };
        let Some(conn) = find(conns, serving.token) else {
            return;
        };
        if conn.out.is_open()
            && !conn.out.backed_up()
            && let Some(supported) = supported
            && serving.sent_supported != Some(supported)
            && let Some((_, wire)) = conn.role_mut()
        {
            wire.ws
                .send(wire.out, protocol::json(&ServeOut::Supported { supported }));
            serving.sent_supported = Some(supported);
        }
        while conn.out.is_open() && !conn.out.backed_up() {
            let Some(message) = serving.pending.pop_front() else {
                break;
            };
            if let Some((_, wire)) = conn.role_mut() {
                wire.ws.send(wire.out, protocol::json(&message));
            }
        }
    }

    pub(super) fn webview_paused(&self, index: usize) -> bool {
        let Some(conn) = self.conns.get(index) else {
            return false;
        };
        match conn.role() {
            Some(Role::WebviewServe(pane)) => self.panes.find(*pane).is_some_and(|pane| {
                pane.webview().serving.as_ref().is_some_and(|serving| {
                    serving.waits.values().any(|wait| {
                        self.index(wait.conn)
                            .is_some_and(|index| self.conns[index].out.backed_up())
                    })
                })
            }),
            Some(Role::WebviewProxy { pane, .. }) => {
                conn.out.backed_up()
                    || self
                        .panes
                        .find(*pane)
                        .and_then(|pane| pane.webview().stream())
                        .and_then(|token| self.index(token))
                        .is_some_and(|index| self.conns[index].out.backed_up())
            }
            _ => false,
        }
    }

    pub(super) fn webview_interest(&self, index: usize) -> Interest {
        let conn = &self.conns[index];
        if self.webview_paused(index) {
            Interest::of(false, conn.out.waiting())
        } else {
            conn.interest()
        }
    }

    pub(super) fn webview_text(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        bytes: &[u8],
    ) {
        let message = match protocol::decode::<ServeIn>(bytes) {
            Ok(message) => message,
            Err(_) => {
                self.conns[index].out.close();
                return;
            }
        };
        let req = match &message {
            ServeIn::Response { req, .. }
            | ServeIn::Body { req, .. }
            | ServeIn::Frame { req, .. }
            | ServeIn::Close { req, .. }
            | ServeIn::Abort { req, .. } => *req,
        };
        let Some(mut wait) = self
            .panes
            .find_mut(pane)
            .and_then(|pane| pane.webview_mut().serving.as_mut()?.waits.remove(&req))
        else {
            return;
        };
        let Some(target) = self.index(wait.conn) else {
            return;
        };
        let conn = &mut self.conns[target];
        let outcome = match (message, &mut wait.phase) {
            (
                ServeIn::Abort { reason, .. },
                Phase::Head | Phase::Upgrade(_) | Phase::Body { .. },
            ) => Outcome::Aborted(reason),
            (
                ServeIn::Response {
                    status, headers, ..
                },
                phase @ (Phase::Head | Phase::Upgrade(_)),
            ) => {
                if let Phase::Upgrade(accept) = phase
                    && u16::from(status) == 101
                {
                    if headers.pairs().iter().any(|(name, value)| {
                        name.eq_ignore_ascii_case("sec-websocket-extensions")
                            && !value.trim().is_empty()
                    }) {
                        Outcome::BadUpgrade
                    } else {
                        let response =
                            http::switching_protocols(accept, headers.pairs(), Policy::Webview);
                        let ws = Box::new(Ws::proxy(conn.rest()));
                        *phase = Phase::Socket;
                        Outcome::Upgraded { response, ws }
                    }
                } else if u16::from(status) != 101 {
                    conn.out.send_reply(http::proxy_head(status, &headers));
                    *phase = Phase::Body {
                        allowed: !matches!(u16::from(status), 204 | 304),
                    };
                    Outcome::Keep
                } else {
                    Outcome::Invalid
                }
            }
            (ServeIn::Body { data, more, .. }, Phase::Body { allowed }) => {
                if *allowed {
                    conn.out.send_chunk(data.bytes(), more);
                }
                if more {
                    Outcome::Keep
                } else {
                    Outcome::Complete
                }
            }
            (ServeIn::Frame { data, binary, .. }, Phase::Socket) => {
                if data.0.len() > protocol::EXEC_CHUNK {
                    Outcome::TooLarge
                } else {
                    if let Some((_, wire)) = conn.role_mut()
                        && wire.ws.proxy_send(wire.out, data.0, binary).is_err()
                    {
                        Outcome::InvalidText
                    } else {
                        Outcome::Keep
                    }
                }
            }
            (ServeIn::Close { code, reason, .. }, Phase::Socket) => {
                if let Some((_, wire)) = conn.role_mut() {
                    wire.ws.proxy_close(wire.out, code, reason);
                }
                Outcome::Complete
            }
            _ => Outcome::Invalid,
        };
        match outcome {
            Outcome::Aborted(reason) => {
                if matches!(wait.phase, Phase::Body { .. }) {
                    self.conns[target].out.close();
                } else {
                    let message = match reason {
                        AbortReason::Encoded { coding } => {
                            http::response::Error::Encoded { coding }.to_string()
                        }
                        AbortReason::Program => "program response failed".to_owned(),
                    };
                    self.bad_gateway(poll, target, message);
                }
            }
            Outcome::Invalid => {
                self.conns[target].out.close();
                self.conns[index].out.close();
            }
            Outcome::Complete => {
                if matches!(wait.phase, Phase::Body { .. }) {
                    self.conns[target].phase = crate::conn::Phase::Head;
                    self.serve(poll, target);
                }
            }
            Outcome::TooLarge | Outcome::InvalidText => {
                let (code, reason) = if matches!(outcome, Outcome::TooLarge) {
                    (CloseCode::SIZE, CloseReason::SIZE)
                } else {
                    (CloseCode::INVALID, CloseReason::INVALID_UTF8)
                };
                if let Some((_, wire)) = self.conns[target].role_mut() {
                    wire.ws.proxy_close(wire.out, code, reason.clone());
                }
                self.webview_send(pane, ServeOut::Close { req, code, reason });
            }
            Outcome::BadUpgrade => {
                self.webview_send(
                    pane,
                    ServeOut::Close {
                        req,
                        code: CloseCode::PROTOCOL,
                        reason: CloseReason::EXTENSIONS,
                    },
                );
                self.bad_gateway(poll, target, "WebSocket extensions are not supported");
            }
            Outcome::Keep => {
                if let Some(found) = self.panes.find_mut(pane)
                    && let Some(serving) = &mut found.webview_mut().serving
                {
                    serving.waits.insert(req, wait);
                }
            }
            Outcome::Upgraded { response, ws } => {
                if let Some(found) = self.panes.find_mut(pane)
                    && let Some(serving) = &mut found.webview_mut().serving
                {
                    serving.waits.insert(req, wait);
                }
                router::upgrade(
                    self,
                    poll,
                    target,
                    response,
                    Role::WebviewProxy { pane, req },
                    *ws,
                );
                self.read_ws(poll, target);
            }
        }
    }

    pub(super) fn webview_proxy_message(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        req: u64,
        reads: &mut Reads,
    ) -> bool {
        let token = self.conns[index].token;
        let Some((_, wire)) = self.conns[index].role_mut() else {
            return false;
        };
        let outgoing = match wire.ws.message(wire.out, poll, token, reads) {
            Ok(Some(message)) => match FrameKind::from_message(message) {
                Ok((binary, bytes)) => {
                    Data::new(bytes)
                        .ok()
                        .map(|data| ServeOut::Frame { req, data, binary })
                }
                Err(tungstenite::Message::Close(close)) => {
                    let close = close
                        .map(|close| {
                            CloseCode::try_from(u16::from(close.code)).and_then(|code| {
                                CloseReason::try_from(close.reason.to_string())
                                    .map(|reason| (code, reason))
                            })
                        })
                        .transpose();
                    let (code, reason) = match close {
                        Ok(Some(close)) => close,
                        Ok(None) => (CloseCode::NORMAL, CloseReason::EMPTY),
                        Err(_) => {
                            self.conns[index].out.close();
                            return false;
                        }
                    };
                    if let Some((_, wire)) = self.conns[index].role_mut() {
                        wire.ws.proxy_close(wire.out, code, reason.clone());
                    }
                    if let Some(found) = self.panes.find_mut(pane)
                        && let Some(serving) = &mut found.webview_mut().serving
                    {
                        serving.waits.remove(&req);
                    }
                    Some(ServeOut::Close { req, code, reason })
                }
                Err(_) => None,
            },
            Err(cause) => {
                self.conns[index].out.closing(cause);
                self.conns[index].out.close();
                None
            }
            _ => None,
        };
        if let Some(message) = outgoing {
            self.webview_send(pane, message);
            true
        } else {
            false
        }
    }

    pub(super) fn webview_ready(&mut self, poll: &mut Poll, index: usize) {
        let pane = match self.conns[index].role() {
            Some(Role::WebviewServe(pane) | Role::WebviewProxy { pane, .. }) => Some(*pane),
            _ => match self.conns[index].phase {
                crate::conn::Phase::Webview { pane, .. } => Some(pane),
                _ => None,
            },
        };
        let Some(pane) = pane else {
            return;
        };
        self.pump_webview(pane, Some(self.webview_supported()));
        let Some(found) = self.panes.find(pane) else {
            return;
        };
        let Some(serving) = &found.webview().serving else {
            return;
        };
        let tokens: Vec<_> = std::iter::once(serving.token)
            .chain(
                serving
                    .waits
                    .values()
                    .filter(|wait| matches!(wait.phase, Phase::Socket))
                    .map(|wait| wait.conn),
            )
            .collect();
        for token in tokens {
            if let Some(index) = self.index(token) {
                self.read_ws(poll, index);
            }
        }
    }

    fn webview_drain(&mut self, poll: &mut Poll, serving: Serving) {
        if let Some(conn) = find(&mut self.conns, serving.token) {
            conn.out.close();
        }
        for (_, wait) in serving.waits {
            let Some(index) = self.index(wait.conn) else {
                continue;
            };
            let conn = &mut self.conns[index];
            match wait.phase {
                Phase::Head | Phase::Upgrade(_) => {
                    self.bad_gateway(poll, index, "webview serve stream closed");
                }
                Phase::Body { .. } => conn.out.close(),
                Phase::Socket => {
                    if let Some((_, wire)) = conn.role_mut() {
                        wire.ws.proxy_close(
                            wire.out,
                            CloseCode::INTERNAL,
                            CloseReason::STREAM_CLOSED,
                        );
                    }
                }
            }
        }
    }

    pub(super) fn webview_closed(&mut self, poll: &mut Poll, conn: &Conn) {
        if let Some(Role::WebviewServe(pane)) = conn.role() {
            if let Some(serving) = self
                .panes
                .find_mut(*pane)
                .and_then(|found| found.webview_mut().serving.take())
            {
                self.webview_event(*pane);
                self.webview_drain(poll, serving);
            }
            return;
        }
        let reference = match conn.role() {
            Some(Role::WebviewProxy { pane, req }) => Some((*pane, *req)),
            _ => match conn.phase {
                crate::conn::Phase::Webview { pane, req } => Some((pane, req)),
                _ => None,
            },
        };
        let Some((pane, req)) = reference else {
            return;
        };
        let Some(found) = self.panes.find_mut(pane) else {
            return;
        };
        let Some(serving) = &mut found.webview_mut().serving else {
            return;
        };
        let Some(wait) = serving.waits.remove(&req) else {
            return;
        };
        let unsent = serving.pending.iter().any(|message| matches!(message, ServeOut::Request { req: id, .. } | ServeOut::Upgrade { req: id, .. } if *id == req));
        serving
            .pending
            .retain(|message| message_req(message) != Some(req));
        if !unsent {
            self.webview_send(
                pane,
                if matches!(wait.phase, Phase::Socket) {
                    ServeOut::Close {
                        req,
                        code: CloseCode::AWAY,
                        reason: CloseReason::CLIENT_CLOSED,
                    }
                } else {
                    ServeOut::Cancel { req }
                },
            );
        }
    }

    pub(super) fn webview_pane_ended(&mut self, poll: &mut Poll, pane: PaneId) {
        let Some(found) = self.panes.find_mut(pane) else {
            return;
        };
        let webview = found.webview_mut();
        let page = webview.page.take().is_some();
        let serving = webview.serving.take();
        if page || serving.is_some() {
            self.webview_event(pane);
        }
        if let Some(serving) = serving {
            self.webview_drain(poll, serving);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fuzz::Rig;
    use crate::server::{Verified, tests::scratch};
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;

    #[test]
    fn a_full_serve_queue_retains_cancel_and_supported_without_closing() {
        let exe = PathBuf::from(
            std::env::var_os("KO_PANE_EXE").expect("KO_PANE_EXE names the built ko-pane"),
        );
        let mut rig = Rig::new(scratch("webview-full"), exe, "exec cat");
        let pane = rig.pane;
        let (ours, peer) = UnixStream::pair().unwrap();
        peer.set_nonblocking(true).unwrap();
        let mut conn = Conn::new(
            Verified::admit(ours).unwrap().with_send_buffer(4096),
            &mut rig.poll,
            1024,
        );
        let stream = conn.token;
        conn.phase = crate::conn::Phase::Ws(Box::new(crate::link::Link {
            ws: Ws::flow(Vec::new()),
            role: Role::WebviewServe(pane),
        }));
        rig.state.conns.push(conn);
        rig.state.open_webview(pane, stream);
        rig.state.webview_send(
            pane,
            ServeOut::Request {
                req: 1,
                method: Method::Get,
                path: "/".to_owned().try_into().unwrap(),
                headers: Headers::default(),
            },
        );
        for _ in 0..10000 {
            rig.state.webview_send(
                pane,
                ServeOut::Body {
                    req: 1,
                    data: Data::new(vec![b'x'; 32]).unwrap(),
                    more: true,
                },
            );
            if find(&mut rig.state.conns, stream).unwrap().out.backed_up() {
                break;
            }
        }
        assert!(find(&mut rig.state.conns, stream).unwrap().out.backed_up());
        let (ours, _requester) = UnixStream::pair().unwrap();
        let mut requester = Conn::new(Verified::admit(ours).unwrap(), &mut rig.poll, 1024);
        requester.phase = crate::conn::Phase::Webview { pane, req: 1 };
        rig.state
            .panes
            .find_mut(pane)
            .unwrap()
            .webview_mut()
            .serving
            .as_mut()
            .unwrap()
            .waits
            .insert(
                1,
                Wait {
                    conn: requester.token,
                    phase: Phase::Head,
                },
            );
        rig.state.webview_closed(&mut rig.poll, &requester);
        rig.poll.unwatch(requester.token);
        rig.poll.free(requester.timer);
        let (ours, _client_peer) = UnixStream::pair().unwrap();
        let mut client_conn = Conn::new(Verified::admit(ours).unwrap(), &mut rig.poll, 1024);
        let client_token = client_conn.token;
        client_conn.phase = crate::conn::Phase::Ws(Box::new(crate::link::Link {
            ws: Ws::new(Vec::new()),
            role: Role::Client(crate::client::Client::new("client_100".parse().unwrap())),
        }));
        rig.state.conns.push(client_conn);
        for supported in [true, false, true, false, true] {
            let mut client = crate::client::Client::new("client_100".parse().unwrap());
            client.receive(protocol::decode(format!(r#"{{"type":"hello","name":"webview","webview":{supported},"focused":false,"sizing":{{"type":"disabled"}}}}"#).as_bytes()).unwrap()).unwrap();
            let conn = find(&mut rig.state.conns, client_token).unwrap();
            let (role, _) = conn.role_mut().unwrap();
            *role = Role::Client(client);
            rig.state.webview_supported_streams();
        }
        assert!(find(&mut rig.state.conns, stream).unwrap().out.is_open());
        let webview = rig.state.panes.find(pane).unwrap().webview();
        assert_eq!(webview.stream(), Some(stream));
        let serving = webview.serving.as_ref().unwrap();
        assert_eq!(
            serving
                .pending
                .iter()
                .filter(|message| matches!(message, ServeOut::Supported { .. }))
                .count(),
            0
        );
        assert!(
            serving
                .pending
                .iter()
                .any(|message| matches!(message, ServeOut::Cancel { req: 1 }))
        );
        assert_eq!(serving.sent_supported, Some(false));
        assert!(rig.state.webview_supported());
        let mut peer = tungstenite::WebSocket::from_raw_socket(
            peer,
            tungstenite::protocol::Role::Client,
            None,
        );
        let (mut cancel, mut supporteds) = (false, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                Instant::now() < deadline,
                "queued webview control messages did not drain"
            );
            match peer.read() {
                Ok(tungstenite::Message::Text(text)) => {
                    let message: serde_json::Value = serde_json::from_str(text.as_str()).unwrap();
                    cancel |= message["type"] == "cancel" && message["req"] == 1;
                    if message["type"] == "supported" && message["supported"] == true {
                        supporteds += 1;
                        assert_eq!(supporteds, 1);
                    }
                }
                Err(tungstenite::Error::Io(error))
                    if error.kind() == std::io::ErrorKind::WouldBlock =>
                {
                    if cancel
                        && supporteds == 1
                        && !find(&mut rig.state.conns, stream).unwrap().out.waiting()
                        && rig
                            .state
                            .panes
                            .find(pane)
                            .unwrap()
                            .webview()
                            .serving
                            .as_ref()
                            .unwrap()
                            .pending
                            .is_empty()
                    {
                        break;
                    }
                    rig.step(Mode::Wait)
                }
                other => panic!("{other:?}"),
            }
        }
        assert!(find(&mut rig.state.conns, stream).unwrap().out.is_open());
        assert!(
            rig.state
                .panes
                .find(pane)
                .unwrap()
                .webview()
                .row()
                .unwrap()
                .serving
        );
    }
}
