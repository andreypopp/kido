use super::*;
use crate::ffi::webview::{Request, Task, WebviewEvent, Write, post_webview};
use crate::webview::{Event, Kind, Upstream};
use ko_server::protocol::CloseCode;

#[derive(Debug)]
pub(super) struct Open {
    pub(super) task: Arc<Task>,
    upstream: Upstream,
}

pub(super) fn failed(shared: &Arc<Shared>, task: &Arc<Task>, code: Code, message: &str) {
    task.ended();
    post_webview(
        shared,
        task,
        if task.socket() {
            WebviewEvent::Close {
                result: code,
                code: CloseCode::INTERNAL,
                reason: string(message),
            }
        } else {
            WebviewEvent::End(code, string(message))
        },
    );
}

impl Engine<'_> {
    pub(super) fn webview_index(&self, id: u64) -> Option<usize> {
        self.webview.iter().position(|open| open.task.id == id)
    }
    pub(super) fn webview_start(&mut self, task: Arc<Task>, request: Request) {
        if task.cancelled() || self.shared.cancel.is_set() {
            task.finish();
            return;
        }
        let Some(client) = self.session.as_ref().map(|session| session.client) else {
            failed(self.shared, &task, Code::Closed, "client link is closed");
            task.finish();
            return;
        };
        let (_, target) = request.route.to_request();
        let kind = if task.socket() {
            Kind::Upgrade
        } else {
            Kind::Http(request.route.method())
        };
        match Upstream::open(
            &mut self.poll,
            &self.shared.socket,
            kind,
            &target,
            &request.headers,
            crate::webview::Target::Server(client),
            &request.body,
        ) {
            Ok(upstream) => self.webview.push(Open { task, upstream }),
            Err(error) => {
                let (code, message) = failure(&error);
                failed(self.shared, &task, code, &message);
                task.finish();
            }
        }
    }
    pub(super) fn webview_shutdown(&mut self) {
        for open in std::mem::take(&mut self.webview) {
            open.dispose(&mut self.poll);
        }
        for command in std::mem::take(&mut *locked(&self.shared.commands)) {
            if let Command::WebviewStart(task, _) = command {
                task.finish();
            }
        }
    }
    pub(super) fn end_webview(&mut self, at: usize, code: Code, message: &str) {
        let open = self.webview.remove(at);
        if !open.upstream.reported() {
            failed(self.shared, &open.task, code, message);
        }
        open.dispose(&mut self.poll);
    }
    pub(super) fn webview_ready(&mut self, at: usize, ready: Ready) {
        match self.webview[at].ready(self.shared, &mut self.poll, ready) {
            Ok(true) => self.webview.remove(at).dispose(&mut self.poll),
            Ok(false) => {}
            Err((code, message)) => self.end_webview(at, code, &message),
        }
    }
    pub(super) fn webview_write(&mut self, id: u64, write: Write) {
        let Some(at) = self.webview_index(id) else {
            return;
        };
        match self.webview[at].write(write) {
            Ok(()) => {
                let token = self.webview[at].token();
                self.webview_ready(at, buffered(token));
            }
            Err(error) => {
                let (code, message) = failure(&error);
                self.end_webview(at, code, &message);
            }
        }
    }
}
impl Open {
    pub(super) fn token(&self) -> Token {
        self.upstream.token()
    }
    pub(super) fn expired(&self, now: Instant) -> bool {
        self.upstream
            .deadline()
            .is_some_and(|deadline| deadline <= now)
    }
    pub(super) fn dispose(self, poll: &mut Poll) {
        self.upstream.dispose(poll);
        self.task.finish();
    }
    fn write(&mut self, write: Write) -> io::Result<()> {
        match write {
            Write::Send { serial, message } => {
                let range = self.upstream.send(message)?;
                self.task.writing(serial, range);
            }
            Write::Close { code, reason } => self.upstream.close(code, reason)?,
        }
        Ok(())
    }
    fn ready(
        &mut self,
        shared: &Arc<Shared>,
        poll: &mut Poll,
        ready: Ready,
    ) -> Result<bool, Failed> {
        if self.task.cancelled() {
            return Ok(true);
        }
        if ready.write {
            self.upstream.flush(poll).map_err(|error| failure(&error))?;
            self.task.progress(self.upstream.written());
        }
        if self.upstream.reported() && self.upstream.drained() {
            return Ok(true);
        }
        if ready.read && !self.task.backed_up() {
            self.upstream.begin_turn();
            while !self.task.backed_up() {
                let event = self
                    .upstream
                    .next(poll)
                    .map_err(|error| failure(&error.into()))?;
                self.task.progress(self.upstream.written());
                let Some(event) = event else {
                    break;
                };
                let event = match event {
                    Event::Response(head) => {
                        if self.task.socket() {
                            return Err(failure(&ko_server::ws::refused(&head)));
                        }
                        WebviewEvent::Response {
                            status: head.status,
                            headers: head.headers,
                        }
                    }
                    Event::Upgraded(head) => {
                        self.task.opened();
                        if !self.task.accepts_sends() {
                            return Ok(true);
                        }
                        WebviewEvent::Response {
                            status: head.status,
                            headers: head.headers,
                        }
                    }
                    Event::Body(bytes) => WebviewEvent::Body(bytes),
                    Event::End => {
                        post_webview(shared, &self.task, WebviewEvent::End(Code::Ok, string("")));
                        return Ok(true);
                    }
                    Event::Message { data, binary } => WebviewEvent::Message { data, binary },
                    Event::Closed {
                        code,
                        reason,
                        result,
                    } => {
                        self.task.ended();
                        let result = result.map_or_else(
                            |error| {
                                if code == CloseCode::SIZE {
                                    Code::Protocol
                                } else {
                                    failure(&error).0
                                }
                            },
                            |()| Code::Ok,
                        );
                        WebviewEvent::Close {
                            result,
                            code,
                            reason: string(reason.as_str()),
                        }
                    }
                };
                post_webview(shared, &self.task, event);
                if self.upstream.reported() {
                    break;
                }
            }
        }
        self.upstream.flush(poll).map_err(|error| failure(&error))?;
        self.task.progress(self.upstream.written());
        self.upstream.interest(poll, !self.task.backed_up());
        Ok(self.upstream.reported() && self.upstream.drained())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsFd;
    use std::os::unix::net::UnixStream;
    use tungstenite::Message;

    #[test]
    fn a_partial_frame_write_reduces_buffered_payload_bytes() {
        let (ours, _peer) = UnixStream::pair().unwrap();
        ko_sys::sock::set_send_buffer(ours.as_fd(), 4096).unwrap();
        let mut poll = Poll::new();
        let link = Link::of(ours, Vec::new(), protocol::Upgrade::Page);
        let upstream = Upstream::socket(&mut poll, link).unwrap();
        let task = crate::ffi::webview::tests::socket_task();
        let bytes = protocol::EXEC_CHUNK;
        let serial = task.reserve(bytes).unwrap();
        let mut open = Open {
            task: Arc::clone(&task),
            upstream,
        };
        open.write(Write::Send {
            serial,
            message: Message::binary(vec![1; bytes]),
        })
        .unwrap();
        open.upstream.flush(&mut poll).unwrap();
        let written = usize::try_from(open.upstream.written()).unwrap();
        assert!(written > 14 && written < bytes);
        task.progress(open.upstream.written());
        assert_eq!(task.buffered(), bytes - (written - 14));
        open.dispose(&mut poll);
    }
}
