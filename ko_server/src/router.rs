use ko_sys::event::{Poll, Token};
use serde::Serialize;

use crate::client::Client;
use crate::conn::{Conn, Payload, Phase, Request};
use crate::http::{self, LAST_CHUNK, Status};
use crate::ids::{ClientId, PaneId};
use crate::link::{Link, Role};
use crate::pane_proc::{Life, Refusal};
use crate::protocol::{
    self, DeleteVars, Empty, Error, ErrorKind, Input, PROTOCOL_HEADER, PasteResult, PutLayout,
    ReportOutcome, Route, Selection, SendPrompt, StartRun, StopRun, VT_HEADER, check_version,
};
use crate::state::{Owner, PutFailure, SelectFailure, State};
use crate::view::View;
use crate::ws::{self, Ws};

fn reply<T: Serialize>(conn: &mut Conn, result: Result<T, Error>) {
    match result {
        Ok(value) => ok(conn, &value),
        Err(Error { kind, message }) => error(conn, kind, message),
    }
}

fn respond(conn: &mut Conn, status: Status, body: &str) {
    let length = body.len().to_string();
    conn.out.send(http::response(
        status,
        &[
            ("content-type", "application/json"),
            ("content-length", &length),
        ],
        body.as_bytes(),
    ));
}

fn ok(conn: &mut Conn, value: &impl Serialize) {
    respond(conn, Status::Ok, &protocol::json(value));
}

fn error(conn: &mut Conn, kind: ErrorKind, message: impl Into<String>) {
    let status = kind.status();
    let body = protocol::json(&Error::new(kind, message));
    respond(conn, status, &body);
}

fn upgrade(state: &mut State, poll: &mut Poll, index: usize, response: Vec<u8>, role: Role) {
    let Some(conn) = state.conns.get_mut(index) else {
        return;
    };
    conn.out.send(response);
    let part = conn.rest();
    conn.phase = Phase::Ws(Box::new(Link {
        ws: Ws::new(part),
        role,
    }));
    let _ = poll.start(conn.timer, ws::FIRST_PING, None);
}

fn body<T: serde::Serialize + serde::de::DeserializeOwned>(
    conn: &mut Conn,
    body: &Payload,
) -> Option<T> {
    match body {
        Payload::Oversized => error(conn, ErrorKind::Invalid, "body exceeds 1 MiB"),
        Payload::Bytes(bytes) => match protocol::decode(bytes) {
            Ok(value) => return Some(value),
            Err(message) => error(conn, ErrorKind::Invalid, message.to_string()),
        },
    }
    None
}

pub(crate) fn handle(state: &mut State, poll: &mut Poll, index: usize, request: Request) {
    let Request {
        head,
        body: payload,
    } = request;
    let Some(conn) = state.conns.get_mut(index) else {
        return;
    };
    let route = match Route::of_request(&head.method, &head.target) {
        Ok(route) => route,
        Err(invalid) => return error(conn, ErrorKind::Invalid, invalid.to_string()),
    };
    let ours = protocol::version();
    let discovery = route == Some(Route::Version);
    let protocol = head
        .header(PROTOCOL_HEADER)
        .or(discovery.then_some(ours.protocol.as_str()));
    let vt = head
        .header(VT_HEADER)
        .or(discovery.then_some(ours.vt.as_str()));
    if let Err(Error { kind, message }) = check_version(protocol, vt) {
        return error(conn, kind, message);
    }
    if head.header("origin").is_some() {
        return error(
            conn,
            ErrorKind::Refused,
            "Origin is not permitted on this unix server",
        );
    }
    let client = head
        .header("ko-client")
        .map(|text| text.parse::<ClientId>().ok());
    if let Some(client) = client
        && !client.is_some_and(|client| state.registered(client))
    {
        return error(&mut state.conns[index], ErrorKind::Gone, "client is closed");
    }
    let client = client.flatten();
    let caller = match head.header("ko-pane").map(str::parse::<PaneId>) {
        None => None,
        Some(Ok(pane)) => Some(pane),
        Some(Err(_)) => {
            return error(
                &mut state.conns[index],
                ErrorKind::Invalid,
                "invalid Ko-Pane",
            );
        }
    };
    let Some(route) = route else {
        return error(
            &mut state.conns[index],
            ErrorKind::Missing,
            "resource not found",
        );
    };
    if let Route::DeletePane(id)
    | Route::ClearHistory(id)
    | Route::Input(id)
    | Route::Screen(id, ..)
    | Route::View(id, ..)
    | Route::Vars(id)
    | Route::DeleteVars(id)
    | Route::Var(id, _)
    | Route::SetVar(id, _)
    | Route::DeleteVar(id, _) = route
        && state.panes.find(id).is_none()
    {
        return error(
            &mut state.conns[index],
            ErrorKind::Missing,
            "pane not found",
        );
    }
    let Some(token) = state.token(index) else {
        return;
    };
    match route {
        Route::Version => ok(&mut state.conns[index], &ours),
        Route::ListPanes => {
            let listing = state.listing();
            ok(&mut state.conns[index], &listing);
        }
        Route::GetLayout => {
            let snapshot = state.snapshot_layout();
            ok(&mut state.conns[index], &snapshot);
        }
        Route::PutLayout => {
            let Some(request) = body::<PutLayout>(&mut state.conns[index], &payload) else {
                return;
            };
            match state.put_layout(poll, request) {
                Ok(snapshot) => ok(&mut state.conns[index], &snapshot),
                Err(PutFailure::Stale(snapshot)) => respond(
                    &mut state.conns[index],
                    Status::Conflict,
                    &protocol::json(&snapshot),
                ),
                Err(failure) => {
                    reply::<Empty>(&mut state.conns[index], Err(failure.into()));
                }
            }
        }
        Route::SelectClient(id) => {
            let Some(selection) = body::<Selection>(&mut state.conns[index], &payload) else {
                return;
            };
            match state.select_client(poll, id, selection) {
                Ok(()) => ok(&mut state.conns[index], &Empty {}),
                Err(SelectFailure::NoClient) => {
                    error(
                        &mut state.conns[index],
                        ErrorKind::Missing,
                        "client not found",
                    );
                }
                Err(SelectFailure::NoTarget) => {
                    error(
                        &mut state.conns[index],
                        ErrorKind::Invalid,
                        "nothing to select",
                    );
                }
            }
        }
        Route::ClearHistory(id) => {
            state.clear_history(poll, id);
            ok(&mut state.conns[index], &Empty {});
        }
        Route::Client => match ws::handshake(&head) {
            None => error(
                &mut state.conns[index],
                ErrorKind::Invalid,
                "Didn't pass scrutiny",
            ),
            Some(response) => {
                let id = state.client_id();
                upgrade(state, poll, index, response, Role::Client(Client::new(id)));
                state.read_ws(poll, index);
            }
        },
        Route::DeletePane(id) => {
            state.delete_pane(poll, id);
            ok(&mut state.conns[index], &Empty {});
        }
        Route::DeleteWindow(_) | Route::DeleteSession(_) => {
            let (deleted, what) = match route {
                Route::DeleteWindow(id) => (state.delete_window(poll, id), "window"),
                Route::DeleteSession(id) => (state.delete_session(poll, id), "session"),
                _ => return,
            };
            if deleted {
                ok(&mut state.conns[index], &Empty {});
            } else {
                error(
                    &mut state.conns[index],
                    ErrorKind::Missing,
                    format!("{what} not found"),
                );
            }
        }
        Route::Input(id) => {
            let Some(input) = body::<Input>(&mut state.conns[index], &payload) else {
                return;
            };
            let (sent, events) =
                state.input(poll, id, &input, |paste| Owner::HttpPaste(token, paste));
            let conn = &mut state.conns[index];
            match sent {
                Ok(None) => ok(conn, &Empty {}),
                Ok(Some(_)) => conn.phase = Phase::Handling,
                Err(Refusal::Ended) => error(conn, ErrorKind::Io, Refusal::Ended.to_string()),
                Err(refusal @ Refusal::TooLarge(_)) => {
                    error(conn, ErrorKind::Invalid, refusal.to_string());
                }
            }
            state.dispatch(poll, id, events);
        }
        Route::Screen(id, format, rows) => state.screen(poll, index, id, format, rows),
        Route::Vars(id) => {
            if let Some(pane) = state.panes.find(id) {
                ok(&mut state.conns[index], &pane.vars().all());
            }
        }
        Route::Var(id, name) => {
            let value = state.panes.find(id).and_then(|pane| pane.vars().get(&name));
            match value {
                Some(value) => ok(&mut state.conns[index], value),
                None => error(
                    &mut state.conns[index],
                    ErrorKind::Missing,
                    "variable not found",
                ),
            }
        }
        Route::SetVar(id, name) => {
            let value = match &payload {
                Payload::Oversized => Err("variable too large".to_owned()),
                Payload::Bytes(bytes) => serde_json::from_slice(bytes).map_err(|e| e.to_string()),
            };
            let set = value.and_then(|value| {
                state
                    .set_var(poll, id, name, value)
                    .map_err(|refusal| refusal.to_string())
            });
            match set {
                Ok(()) => ok(&mut state.conns[index], &Empty {}),
                Err(message) => error(&mut state.conns[index], ErrorKind::Invalid, message),
            }
        }
        Route::DeleteVars(id) => {
            let Some(request) = body::<DeleteVars>(&mut state.conns[index], &payload) else {
                return;
            };
            if state.delete_vars(poll, id, request) {
                ok(&mut state.conns[index], &Empty {});
            } else {
                error(
                    &mut state.conns[index],
                    ErrorKind::PreconditionFailed,
                    "variable does not have the expected value",
                );
            }
        }
        Route::DeleteVar(id, name) => {
            state.delete_var(poll, id, name);
            ok(&mut state.conns[index], &Empty {});
        }
        Route::StartRun => {
            let Some(request) = body::<StartRun>(&mut state.conns[index], &payload) else {
                return;
            };
            let result = state.start_run(poll, caller, request);
            reply(&mut state.conns[index], result);
        }
        Route::ListRuns(show, parent) => {
            let infos = state.list_runs(show, parent.as_ref());
            ok(&mut state.conns[index], &infos);
        }
        Route::Reap => {
            state.reap_runs(poll);
            ok(&mut state.conns[index], &Empty {});
        }
        Route::GetRun(id) => {
            let result = state.run_detail(&id);
            reply(&mut state.conns[index], result);
        }
        Route::WaitRun(id, timeout) => {
            if let Some(result) = state.wait_run(poll, index, id, timeout) {
                reply(&mut state.conns[index], result);
            }
        }
        Route::RunOutcome(id) => {
            let Some(report) = body::<ReportOutcome>(&mut state.conns[index], &payload) else {
                return;
            };
            if let Some(result) = state.run_outcome(poll, index, id, report) {
                reply(&mut state.conns[index], result);
            }
        }
        Route::StopRun(id) => {
            let Some(request) = body::<StopRun>(&mut state.conns[index], &payload) else {
                return;
            };
            if let Some(result) = state.stop_run(poll, index, id, request) {
                reply(&mut state.conns[index], result);
            }
        }
        Route::PromptResolve { window_only } => {
            let result = state.resolve_prompt(caller, window_only);
            reply(&mut state.conns[index], result);
        }
        Route::SendPrompt => {
            let Some(request) = body::<SendPrompt>(&mut state.conns[index], &payload) else {
                return;
            };
            if let Some(result) = state.send_prompt(poll, index, caller, request) {
                reply(&mut state.conns[index], result);
            }
        }
        Route::View(id, options, offset) => {
            let opened = state
                .panes
                .find(id)
                .filter(|pane| pane.proc().life() == Life::Open)
                .and_then(|pane| pane.proc().delivery())
                .map(|delivery| View::new(id, client, options.history, delivery));
            let Some(view) = opened else {
                return error(
                    &mut state.conns[index],
                    ErrorKind::Io,
                    Refusal::Ended.to_string(),
                );
            };
            let Some(response) = ws::handshake(&head) else {
                return error(
                    &mut state.conns[index],
                    ErrorKind::Invalid,
                    "Didn't pass scrutiny",
                );
            };
            upgrade(state, poll, index, response, Role::View(view));
            state.open_view(poll, index, offset);
            state.read_ws(poll, index);
        }
    }
}

fn finish(state: &mut State, poll: &mut Poll, conn: Token, reply: impl FnOnce(&mut Conn)) {
    let Some(index) = state.conns.iter().position(|found| found.token == conn) else {
        return;
    };
    reply(&mut state.conns[index]);
    if matches!(state.conns[index].phase, Phase::Handling) {
        state.conns[index].phase = Phase::Head;
        state.serve(poll, index);
    }
}

pub(crate) fn screen(
    state: &mut State,
    poll: &mut Poll,
    conn: Token,
    started: bool,
    text: &[u8],
    last: bool,
) {
    let mut out = Vec::new();
    if !started {
        out = http::response(
            Status::Ok,
            &[
                ("content-type", "text/plain; charset=utf-8"),
                ("transfer-encoding", "chunked"),
            ],
            b"",
        );
    }
    http::chunk(text, &mut out);
    if last {
        out.extend_from_slice(LAST_CHUNK);
        finish(state, poll, conn, |conn| conn.out.send(out));
    } else if let Some(found) = state.conns.iter_mut().find(|found| found.token == conn) {
        found.out.send(out);
    }
}

pub(crate) fn answer<T: Serialize>(
    state: &mut State,
    poll: &mut Poll,
    conn: Token,
    result: Result<T, Error>,
) {
    finish(state, poll, conn, |conn| reply(conn, result));
}

pub(crate) fn pasted(state: &mut State, poll: &mut Poll, conn: Token, result: &PasteResult) {
    finish(state, poll, conn, |conn| ok(conn, result));
}

pub(crate) fn failed(
    state: &mut State,
    poll: &mut Poll,
    conn: Token,
    started: bool,
    message: &str,
) {
    finish(state, poll, conn, |conn| {
        if started {
            conn.out.close();
        } else {
            error(conn, ErrorKind::Io, message);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::DEFAULT_LIMITS;
    use crate::fuzz::Rig;
    use crate::protocol::{ClientEvent, Title, version_headers};
    use crate::server::Verified;
    use crate::ws::masked;
    use ko_sys::event::Mode;
    use proptest::prelude::*;
    use std::io::Write;
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;

    type Harness = Rig;

    fn harness(name: &str) -> Harness {
        Rig::new(
            PathBuf::from(format!("/tmp/ko-router-{name}-{}", std::process::id())),
            PathBuf::from(
                std::env::var_os("KO_PANE_EXE").expect(
                    "KO_PANE_EXE names the Rust ko-pane; make test-ko builds it and sets it",
                ),
            ),
            DEFAULT_LIMITS,
            "stty raw -echo; exec cat",
        )
    }

    impl Harness {
        fn reply(&mut self, request: &str, rest: &str) -> String {
            let request = format!("{request} HTTP/1.1\r\n{}{rest}", ko_headers());
            String::from_utf8_lossy(self.exchange(request.as_bytes())).into_owned()
        }

        fn status(&mut self, request: &str, rest: &str) -> String {
            let reply = self.reply(request, rest);
            reply[..reply.len().min(12)].to_owned()
        }
    }

    fn ko_headers() -> String {
        let mut headers = "Host: ko\r\n".to_owned();
        for (name, value) in version_headers() {
            headers.push_str(&format!("{name}: {value}\r\n"));
        }
        headers
    }

    #[test]
    fn refusals_are_the_bytes_of_the_reference_server() {
        let mut server = harness("refusals");
        let ours = protocol::version();
        let version = protocol::json(&ours);
        let mismatch = format!(
            r#"{{"kind":"protocol_mismatch","protocol":"{}","vt":"{}","build":"{}","message":"protocol major mismatch"}}"#,
            ours.protocol, ours.vt, ours.build
        );
        let json = |status: &str, body: &str| {
            format!(
                "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{body}",
                body.len()
            )
        };
        let replies = [
            server.reply("GET /version", "Bad Header\r\n\r\n"),
            String::from_utf8_lossy(
                server.exchange(b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03\r\n\r\n"),
            )
            .into_owned(),
            server.reply("PUT /layout", "Content-Length: abc\r\n\r\n{}"),
            server.reply(
                "PUT /layout",
                "Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}x",
            ),
            server.reply("PUT /layout", "Transfer-Encoding: chunked\r\n\r\n{}"),
            server.reply(
                &format!("GET /version HTTP/1.1\r\n{}", "A: b\r\n".repeat(4000)),
                "\r\n",
            ),
            server.reply(
                "PUT /layout",
                &format!(
                    "Content-Length: 1048577\r\n\r\n{}GET /version HTTP/1.1\r\n{}\r\n",
                    "x".repeat(1_048_577),
                    ko_headers()
                ),
            ),
            server.reply("GET /client", "\r\n"),
            String::from_utf8_lossy(
                server.exchange(
                    format!(
                        "GET /panes HTTP/1.1\r\nHost: ko\r\nKo-Protocol: 0.9\r\nKo-Vt: {}\r\n\r\n",
                        ours.vt
                    )
                    .as_bytes(),
                ),
            )
            .into_owned(),
        ];
        assert_eq!(
            replies,
            [
                String::from_utf8_lossy(http::BAD_REQUEST).into_owned(),
                String::new(),
                String::from_utf8_lossy(http::BAD_REQUEST).into_owned(),
                String::from_utf8_lossy(http::BAD_REQUEST).into_owned(),
                "HTTP/1.1 411 Length Required\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"
                    .to_owned(),
                "HTTP/1.1 431 Request Header Fields Too Large\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"
                    .to_owned(),
                json("400 Bad Request", r#"{"kind":"invalid","message":"body exceeds 1 MiB"}"#)
                    + &json("200 OK", &version),
                json("400 Bad Request", r#"{"kind":"invalid","message":"Didn't pass scrutiny"}"#),
                json("426 Upgrade Required", &mismatch),
            ]
        );
    }

    fn upgrade(path: &str) -> Vec<u8> {
        format!(
            "GET {path} HTTP/1.1\r\n{}Upgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
            ko_headers()
        )
        .into_bytes()
    }

    fn text(text: &str) -> Vec<u8> {
        masked(1, true, text.as_bytes(), [9, 8, 7, 6], 0)
    }

    impl Harness {
        fn connect(&mut self, bytes: &[u8]) -> UnixStream {
            let (ours, mut theirs) = UnixStream::pair().unwrap();
            self.state
                .accept(&mut self.poll, Verified::admit(ours).unwrap());
            theirs.write_all(bytes).unwrap();
            for _ in 0..20 {
                self.step(Mode::Peek);
            }
            theirs
        }
    }

    #[test]
    fn a_record_sent_as_an_array_is_refused_and_changes_nothing() {
        let mut server = harness("arrays");
        let panes = server.state.panes.len();
        let revision = server.state.snapshot_layout().revision;
        let create = server.status("PUT /layout", "Content-Length: 10\r\n\r\n[\"/tmp\"]  ");
        let nested = format!(
            r#"{{"revision":{},"layout":{{"sessions":[["s",[]]]}}}}"#,
            serde_json::to_string(&revision).unwrap()
        );
        let array_layout = server.status(
            "PUT /layout",
            &format!("Content-Length: {}\r\n\r\n{nested}", nested.len()),
        );
        let text_input = r#"{"type":"text","data":"aGk="}"#;
        let input = server.status(
            "POST /panes/pane_1/input",
            &format!("Content-Length: {}\r\n\r\n{text_input}", text_input.len()),
        );
        let hello = r#"["hello",["terminal","t","pane_1",true,{"cols":7,"rows":7},false]]"#;
        let _array_hello = server.connect(&[upgrade("/client"), text(hello)].concat());
        let size_hello = r#"{"type":"hello","kind":"terminal","name":"t","pane":"pane_1","focused":false,"ignore_size":true,"size":[80,24]}"#;
        let _array_size = server.connect(&[upgrade("/client"), text(size_hello)].concat());
        let key = r#"{"type":"input","input":["key",["press",20,0,97,"a",false]]}"#;
        let _array_key = server.connect(&[upgrade("/panes/pane_1/view"), text(key)].concat());
        assert_eq!(
            (
                create.as_str(),
                array_layout.as_str(),
                input.as_str(),
                server.state.panes.len(),
                server.state.snapshot_layout().revision,
                server.state.conns.len()
            ),
            (
                "HTTP/1.1 400",
                "HTTP/1.1 400",
                "HTTP/1.1 200",
                panes,
                revision,
                0
            )
        );
    }

    #[test]
    fn a_client_that_never_reads_is_closed_before_its_queue_grows_without_bound() {
        let mut server = harness("unread");
        let long = ClientEvent::Title(Title {
            pane: crate::ids::PaneId::new(1),
            title: "x".repeat(400_000),
        });
        let hello = r#"{"type":"hello","kind":"app","name":"t","focused":false,"size":{"cols":80,"rows":24}}"#;
        let client = server.connect(&[upgrade("/client"), text(hello)].concat());
        let registered = server.state.registered(ClientId::new(1));
        let closed_at = (1..400).find(|_| {
            server.state.announce(&long);
            server.step(Mode::Peek);
            !server.state.registered(ClientId::new(1))
        });
        assert!(
            registered && closed_at.is_some_and(|at| at > 100),
            "{closed_at:?}"
        );
        drop(client);
    }

    #[test]
    fn bad_bodies_are_answered_with_400_or_411_not_a_crash_or_a_500() {
        let mut server = harness("bodies");
        let chunked = server.status("PUT /layout", "Transfer-Encoding: chunked\r\n\r\n{}");
        let revision = serde_json::to_string(&server.state.snapshot_layout().revision).unwrap();
        let layout = r#"{"sessions":[{"id":"session_1","name":"s","windows":[{"id":"window_1","name":"w","tree":{"split":"h","children":[{"pane":"pane_1"},{"pane":{"new":{"cwd":"/nonexistent"}}}]}}]}]}"#;
        let body = format!(r#"{{"revision":{revision},"layout":{layout}}}"#);
        let cwd = server.status(
            "PUT /layout",
            &format!("Content-Length: {}\r\n\r\n{body}", body.len()),
        );
        assert_eq!(
            (chunked.as_str(), cwd.as_str()),
            ("HTTP/1.1 411", "HTTP/1.1 400")
        );
    }

    fn message() -> impl Strategy<Value = Vec<u8>> {
        prop_oneof![
            4 => prop::sample::select(vec![
                r#"{"type":"hello","kind":"terminal","name":"t","focused":true,"size":{"cols":80,"rows":24}}"#,
                r#"{"type":"hello","kind":"app","name":"t","pane":"pane_1","focused":false,"size":{"cols":4097,"rows":24}}"#,
                r#"{"type":"select","pane":"pane_1"}"#,
                r#"{"type":"select","pane":"pane_99"}"#,
                r#"{"type":"size","cols":50,"rows":10,"cell_px":{"width":8,"height":16}}"#,
                r#"{"type":"focused","focused":true}"#,
                r#"{"type":"resync","history":"all","images":"none"}"#,
                r#"{"type":"input","input":{"type":"text","data":"aGk="}}"#,
                r#"{"type":"input","input":{"type":"text","data":"!!"}}"#,
                r#"{"type":"input","input":{"type":"paste","text":"x","check_safe":true,"id":3}}"#,
                r#"{"type":"input","input":{"type":"key","action":"press","key":20,"mods":0,"unshifted_codepoint":97,"text":"a","composing":false}}"#,
                r#"{"type":"input","input":{"type":"mouse","action":"press","button":"left","col":3,"row":4,"mods":1}}"#,
                r#"{"type":"input","input":{"type":"focus","focused":false}}"#,
                r#"{"command":{"type":"argv","argv":["/bin/true"]},"cwd":"/tmp"}"#,
                r#"{"cwd":"/nonexistent"}"#,
                r#"["invalid"]"#,
                "{",
                "",
            ])
            .prop_map(|text| text.as_bytes().to_vec()),
            1 => prop::collection::vec(any::<u8>(), 0..12),
        ]
    }

    fn frame() -> impl Strategy<Value = Vec<u8>> {
        (
            prop::sample::select(vec![1u8, 1, 1, 1, 0, 2, 8, 9, 9, 10, 3, 11, 15]),
            prop::bool::weighted(0.85),
            prop_oneof![6 => message(), 1 => prop::collection::vec(any::<u8>(), 130..2000)],
            any::<[u8; 4]>(),
            prop_oneof![12 => Just(0i64), 1 => 1i64..200, 1 => Just(-1i64)],
        )
            .prop_map(|(opcode, fin, payload, key, lie)| masked(opcode, fin, &payload, key, lie))
    }

    fn request() -> impl Strategy<Value = Vec<u8>> {
        let ours = protocol::version();
        let vt = ours.vt.clone();
        let versions = prop_oneof![
            30 => Just(ko_headers()),
            1 => Just(format!("Ko-Protocol: 0.9\r\nKo-Vt: {vt}\r\n")),
            1 => Just(format!("Ko-Protocol: {}\r\n", ours.protocol)),
            1 => Just(String::new()),
        ];
        let extra = prop::sample::select(vec![
            "",
            "",
            "",
            "",
            "",
            "",
            "Ko-Client: client_1\r\n",
            "Ko-Client: c99\r\n",
            "Origin: https://evil.example\r\n",
            "X-a: b\r\n",
        ]);
        let target = prop::sample::select(vec![
            "/version",
            "/panes",
            "/client",
            "/panes/pane_1",
            "/panes/pane_1/input",
            "/panes/pane_1/screen",
            "/panes/pane_1/screen?history=all&format=ansi",
            "/panes/pane_1/screen?history=7",
            "/panes/pane_1/view?history=all",
            "/panes/pane_1/view?history=none&offset=0",
            "/panes/pane_1/view?offset=99999999999",
            "/panes/pane_99/view",
            "/panes/pane_x",
            "/panes/pane_1/view?images=all",
            "/%00",
            "/panes?x",
            "/x?a=b?c",
        ]);
        let method = prop::sample::select(vec![
            "GET", "GET", "GET", "POST", "POST", "DELETE", "PUT", "HEAD", "G\0T",
        ]);
        (
            method,
            target,
            versions,
            extra,
            message(),
            prop::sample::select(vec![0u8, 0, 0, 0, 0, 0, 1, 2, 2, 2]),
            prop::collection::vec(frame(), 1..6),
        )
            .prop_map(|(method, target, versions, extra, body, framing, frames)| {
                let mut request = format!("{method} {target} HTTP/1.1\r\nHost: ko\r\n{versions}{extra}").into_bytes();
                match framing {
                    1 => {
                        request.extend_from_slice(b"Transfer-Encoding: chunked\r\n\r\n");
                        request.extend_from_slice(&body);
                    }
                    2 => {
                        request.extend_from_slice(
                            b"Upgrade: websocket\r\nConnection: Upgrade\r\n\
                              Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
                        );
                        request.extend(frames.concat());
                    }
                    _ => {
                        request.extend_from_slice(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes());
                        request.extend_from_slice(&body);
                    }
                }
                request
            })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(40))]
        #[test]
        fn the_server_answers_any_request_with_a_status_or_a_close_and_stays_healthy(
            requests in prop::collection::vec(request(), 1..6),
        ) {
            let mut server = harness("http");
            for request in &requests {
                let reply = server.exchange(request);
                prop_assert!(!reply.starts_with(b"HTTP/1.1 5"), "{:?}: {:?}", String::from_utf8_lossy(request), String::from_utf8_lossy(reply));
            }
            prop_assert_eq!(server.status("GET /version", "\r\n"), "HTTP/1.1 200");
        }
    }

    struct Peer {
        stream: UnixStream,
        pending: Vec<u8>,
        upgraded: bool,
    }

    impl Peer {
        fn events(&mut self, server: &mut Harness) -> Vec<serde_json::Value> {
            use std::io::Read;
            for _ in 0..10 {
                server.step(Mode::Peek);
            }
            let mut chunk = [0; 65536];
            loop {
                match self.stream.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(count) => self.pending.extend_from_slice(&chunk[..count]),
                }
            }
            if !self.upgraded
                && let Some(end) = self.pending.windows(4).position(|w| w == b"\r\n\r\n")
            {
                self.pending.drain(..end + 4);
                self.upgraded = true;
            }
            let mut found = Vec::new();
            while self.upgraded
                && let Some(frame) = ws::parse_frame(&self.pending)
                && self.pending.len() >= frame.header + frame.length
            {
                let bytes: Vec<u8> = self.pending.drain(..frame.header + frame.length).collect();
                if frame.opcode == 1 {
                    found.push(serde_json::from_slice(&bytes[frame.header..]).unwrap());
                }
            }
            found
        }

        fn send(&mut self, server: &mut Harness, message: &str) {
            self.stream.write_all(&text(message)).unwrap();
            server.step(Mode::Peek);
        }
    }

    impl Harness {
        fn peer(&mut self, hello: &str) -> Peer {
            let stream = self.connect(&[upgrade("/client"), text(hello)].concat());
            stream.set_nonblocking(true).unwrap();
            Peer {
                stream,
                pending: Vec::new(),
                upgraded: false,
            }
        }

        fn put(&mut self, edit: impl FnOnce(&mut serde_json::Value)) -> String {
            let mut snapshot = serde_json::to_value(self.state.snapshot_layout()).unwrap();
            edit(&mut snapshot["layout"]);
            let body = snapshot.to_string();
            self.reply(
                "PUT /layout",
                &format!("Content-Length: {}\r\n\r\n{body}", body.len()),
            )
        }

        fn current(&self, client: u64) -> Option<crate::client::Current> {
            self.state
                .conns
                .iter()
                .filter_map(crate::state::client_of)
                .find(|found| found.id == ClientId::new(client))
                .and_then(|found| found.current())
        }
    }

    fn hello(extra: &str, focused: bool, cols: u16, rows: u16) -> String {
        hello_of("app", extra, focused, cols, rows)
    }

    fn hello_of(kind: &str, extra: &str, focused: bool, cols: u16, rows: u16) -> String {
        format!(
            r#"{{"type":"hello","kind":"{kind}","name":"t",{extra}"focused":{focused},"size":{{"cols":{cols},"rows":{rows}}}}}"#
        )
    }

    fn cat() -> serde_json::Value {
        json!({"command": {"type": "shell", "command": "exec cat"}})
    }

    fn kinds(events: &[serde_json::Value]) -> Vec<String> {
        events
            .iter()
            .filter(|event| event["type"] != "status")
            .map(|event| {
                let kind = event["type"].as_str().unwrap_or_default();
                match event["pane"].as_str() {
                    Some(pane) if kind == "selected" => format!("selected {pane}"),
                    _ => kind.to_owned(),
                }
            })
            .collect()
    }

    fn windows(server: &Harness) -> Vec<(String, String, Vec<String>)> {
        let layout = server.state.snapshot_layout().layout;
        layout
            .windows()
            .map(|(session, window)| {
                (
                    session.id.to_string(),
                    window.id.to_string(),
                    window.panes().iter().map(ToString::to_string).collect(),
                )
            })
            .collect()
    }

    fn three_windows(server: &mut Harness) {
        let reply = server.put(|layout| {
            let new_window = |name: &str| json!({"name": name, "tree": {"pane": {"new": cat()}}});
            layout["sessions"][0]["windows"]
                .as_array_mut()
                .unwrap()
                .push(new_window("second"));
            layout["sessions"].as_array_mut().unwrap().push(json!({
                "name": "other", "windows": [new_window("third")]
            }));
        });
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
    }

    use serde_json::{Value, json};

    #[test]
    fn a_client_gets_the_layout_after_its_welcome_and_every_change_after_that() {
        let mut server = harness("layout-events");
        let mut peer = server.peer(&hello("", false, 80, 24));
        assert_eq!(kinds(&peer.events(&mut server)), ["welcome", "layout"]);
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}}]});
        });
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        let events = peer.events(&mut server);
        assert_eq!(kinds(&events), ["layout"]);
        assert_eq!(events[0]["revision"], 2);
        assert_eq!(
            events[0]["layout"]["sessions"][0]["windows"][0]["tree"]["children"][1]["cols"],
            39
        );
    }

    #[test]
    fn a_put_with_a_stale_revision_gets_409_and_the_current_document() {
        let mut server = harness("stale");
        let current = serde_json::to_value(server.state.snapshot_layout()).unwrap();
        let stale = json!({"revision": 0, "layout": current["layout"]}).to_string();
        let reply = server.reply(
            "PUT /layout",
            &format!("Content-Length: {}\r\n\r\n{stale}", stale.len()),
        );
        let (head, body) = reply.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("HTTP/1.1 409"), "{head}");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(body).unwrap(),
            current
        );
        let get = server.reply("GET /layout", "\r\n");
        let (_, body) = get.split_once("\r\n\r\n").unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(body).unwrap(),
            current
        );
    }

    #[test]
    fn a_failed_pane_start_rolls_the_whole_put_back() {
        let mut server = harness("rollback");
        let before = server.state.snapshot_layout();
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}},
                {"pane": {"new": {"cwd": "/nonexistent"}}}]});
        });
        assert!(reply.starts_with("HTTP/1.1 400"), "{reply}");
        assert_eq!(server.state.snapshot_layout(), before);
        assert_eq!(server.state.panes.len(), 1);
    }

    #[test]
    fn select_switch_and_the_selected_event_move_only_the_one_client() {
        let mut server = harness("select");
        three_windows(&mut server);
        assert_eq!(windows(&server).len(), 3);
        let mut a = server.peer(&hello(r#""pane":"pane_1","#, false, 80, 24));
        let mut b = server.peer(&hello("", false, 80, 24));
        assert_eq!(kinds(&a.events(&mut server)), ["welcome", "layout"]);
        assert_eq!(kinds(&b.events(&mut server)), ["welcome", "layout"]);
        assert_eq!(server.current(2), None);
        let window_of = |server: &Harness, client| {
            server
                .current(client)
                .map(|c| (c.window.to_string(), c.pane.to_string()))
        };
        a.send(
            &mut server,
            r#"{"type":"switch","over":"window","direction":"next"}"#,
        );
        assert_eq!(kinds(&a.events(&mut server)), ["selected pane_2"]);
        a.send(
            &mut server,
            r#"{"type":"switch","over":"session","direction":"next"}"#,
        );
        assert_eq!(kinds(&a.events(&mut server)), ["selected pane_3"]);
        a.send(
            &mut server,
            r#"{"type":"switch","over":"window","direction":"next"}"#,
        );
        assert_eq!(kinds(&a.events(&mut server)), ["selected pane_1"]);
        a.send(
            &mut server,
            r#"{"type":"switch","over":"session","direction":"previous"}"#,
        );
        assert_eq!(
            window_of(&server, 1),
            Some(("window_3".to_owned(), "pane_3".to_owned()))
        );
        a.send(
            &mut server,
            r#"{"type":"switch","over":"session","direction":"previous"}"#,
        );
        assert_eq!(
            window_of(&server, 1),
            Some(("window_1".to_owned(), "pane_1".to_owned()))
        );
        a.events(&mut server);
        a.send(&mut server, r#"{"type":"select","pane":"pane_2"}"#);
        assert!(kinds(&a.events(&mut server)).is_empty());
        a.send(&mut server, r#"{"type":"select","session":"session_1"}"#);
        assert_eq!(kinds(&a.events(&mut server)), ["selected pane_2"]);
        a.send(&mut server, r#"{"type":"select","window":"window_9"}"#);
        assert!(kinds(&b.events(&mut server)).is_empty());
        assert_eq!(server.current(2), None);
        let body = r#"{"window":"window_3"}"#;
        let post = |server: &mut Harness, client: &str, body: &str| {
            server.status(
                &format!("POST /clients/{client}/select"),
                &format!("Content-Length: {}\r\n\r\n{body}", body.len()),
            )
        };
        assert_eq!(post(&mut server, "client_2", body), "HTTP/1.1 200");
        assert_eq!(kinds(&b.events(&mut server)), ["selected pane_3"]);
        assert!(kinds(&a.events(&mut server)).is_empty());
        assert_eq!(post(&mut server, "client_9", body), "HTTP/1.1 404");
        assert_eq!(post(&mut server, "client_2", "{}"), "HTTP/1.1 400");
        assert_eq!(
            post(&mut server, "client_2", r#"{"pane":"pane_9"}"#),
            "HTTP/1.1 400"
        );
    }

    #[test]
    fn removing_the_current_pane_or_window_moves_the_client_and_ends_the_empty_window() {
        let mut server = harness("remove");
        three_windows(&mut server);
        server.put(|layout| {
            layout["sessions"][0]["windows"][1]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_2"}, {"pane": {"new": cat()}}]});
        });
        let mut peer = server.peer(&hello(r#""pane":"pane_2","#, false, 80, 24));
        peer.events(&mut server);
        assert_eq!(
            server.reply("DELETE /panes/pane_2", "\r\n")[..12].to_owned(),
            "HTTP/1.1 200"
        );
        assert_eq!(
            kinds(&peer.events(&mut server)),
            ["layout", "selected pane_4"]
        );
        server.reply("DELETE /panes/pane_4", "\r\n");
        assert_eq!(
            kinds(&peer.events(&mut server)),
            ["layout", "selected pane_3"]
        );
        assert_eq!(
            windows(&server)
                .iter()
                .map(|w| w.1.clone())
                .collect::<Vec<_>>(),
            ["window_1", "window_3"]
        );
        server.reply("DELETE /panes/pane_3", "\r\n");
        server.reply("DELETE /panes/pane_1", "\r\n");
        assert_eq!(server.state.snapshot_layout().layout.sessions, vec![]);
        assert_eq!(server.current(1), None);
        assert_eq!(server.state.panes.len(), 0);
    }

    #[test]
    fn a_pane_whose_process_fails_leaves_the_document_but_an_exited_program_stays() {
        let mut server = harness("death");
        three_windows(&mut server);
        server
            .state
            .panes
            .find(crate::ids::PaneId::new(3))
            .unwrap()
            .proc()
            .kill()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while windows(&server).len() == 3 && std::time::Instant::now() < deadline {
            server.step(Mode::Wait);
        }
        assert_eq!(windows(&server).len(), 2);
    }

    #[test]
    fn a_window_takes_the_size_of_the_client_that_shows_it_and_its_panes_follow() {
        let mut server = harness("sizing");
        three_windows(&mut server);
        server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}}]});
        });
        let size = |server: &Harness, pane: u64| {
            let size = server
                .state
                .panes
                .find(crate::ids::PaneId::new(pane))
                .unwrap()
                .size();
            (size.cols.get(), size.rows.get())
        };
        let window = |server: &Harness, id: &str| {
            let layout = server.state.snapshot_layout().layout;
            let (_, window) = layout
                .windows()
                .find(|(_, w)| w.id.to_string() == id)
                .unwrap();
            (window.cols.get(), window.rows.get())
        };
        let mut a = server.peer(&hello(r#""pane":"pane_1","#, true, 100, 30));
        a.events(&mut server);
        assert_eq!(window(&server, "window_1"), (100, 30));
        assert_eq!((size(&server, 1), size(&server, 4)), ((50, 30), (49, 30)));
        let mut b = server.peer(&hello(r#""pane":"pane_1","#, false, 60, 20));
        b.events(&mut server);
        assert_eq!(window(&server, "window_1"), (100, 30));
        b.send(&mut server, r#"{"type":"size","cols":61,"rows":21}"#);
        assert_eq!(window(&server, "window_1"), (100, 30));
        b.send(&mut server, r#"{"type":"focused","focused":true}"#);
        assert_eq!(window(&server, "window_1"), (61, 21));
        a.send(&mut server, r#"{"type":"size","cols":90,"rows":25}"#);
        assert_eq!(window(&server, "window_1"), (61, 21));
        a.send(&mut server, r#"{"type":"select","window":"window_2"}"#);
        assert_eq!(window(&server, "window_2"), (90, 25));
        assert_eq!(size(&server, 2), (90, 25));
        drop(b);
        for _ in 0..20 {
            server.step(Mode::Peek);
        }
        assert_eq!(window(&server, "window_1"), (61, 21));
    }

    #[test]
    fn a_terminal_client_sizes_only_a_window_with_one_pane_and_no_floats() {
        let mut server = harness("terminal-sizing");
        three_windows(&mut server);
        server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}}]});
        });
        let mut peer = server.peer(&hello_of("terminal", r#""pane":"pane_1","#, true, 70, 20));
        peer.events(&mut server);
        let layout = server.state.snapshot_layout().layout;
        assert_eq!(
            layout
                .window(crate::ids::WindowId::new(1))
                .unwrap()
                .1
                .cols
                .get(),
            80
        );
        peer.send(&mut server, r#"{"type":"select","pane":"pane_2"}"#);
        peer.send(&mut server, r#"{"type":"size","cols":71,"rows":21}"#);
        let layout = server.state.snapshot_layout().layout;
        assert_eq!(
            layout
                .window(crate::ids::WindowId::new(2))
                .unwrap()
                .1
                .cols
                .get(),
            71
        );
    }

    #[test]
    fn a_program_sees_focus_while_a_focused_client_shows_its_pane() {
        let mut server = harness("focus");
        three_windows(&mut server);
        let focused = |server: &Harness| -> Vec<bool> {
            (1..=3)
                .map(|pane| {
                    server
                        .state
                        .panes
                        .find(crate::ids::PaneId::new(pane))
                        .unwrap()
                        .focused()
                })
                .collect()
        };
        assert_eq!(focused(&server), [false, false, false]);
        let mut a = server.peer(&hello(r#""pane":"pane_1","#, true, 80, 24));
        a.events(&mut server);
        assert_eq!(focused(&server), [true, false, false]);
        let mut b = server.peer(&hello(r#""pane":"pane_1","#, false, 80, 24));
        b.events(&mut server);
        a.send(&mut server, r#"{"type":"select","pane":"pane_2"}"#);
        assert_eq!(focused(&server), [false, true, false]);
        b.send(&mut server, r#"{"type":"focused","focused":true}"#);
        assert_eq!(focused(&server), [true, true, false]);
        a.send(&mut server, r#"{"type":"focused","focused":false}"#);
        assert_eq!(focused(&server), [true, false, false]);
        drop(b);
        for _ in 0..20 {
            server.step(Mode::Peek);
        }
        assert_eq!(focused(&server), [false, false, false]);
    }

    #[test]
    fn a_window_returns_a_client_to_the_pane_that_was_focused_last() {
        let mut server = harness("last-focused");
        three_windows(&mut server);
        server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}}]});
        });
        let mut peer = server.peer(&hello(r#""pane":"pane_4","#, true, 80, 24));
        peer.events(&mut server);
        peer.send(&mut server, r#"{"type":"select","window":"window_2"}"#);
        peer.events(&mut server);
        peer.send(&mut server, r#"{"type":"select","window":"window_1"}"#);
        assert_eq!(kinds(&peer.events(&mut server)), ["selected pane_4"]);
    }

    #[test]
    fn only_a_client_with_a_focused_terminal_changes_the_last_focused_pane_of_a_window() {
        let mut server = harness("focus-notes");
        three_windows(&mut server);
        server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}}]});
        });
        let pane_of = |server: &Harness, client| server.current(client).unwrap().pane.to_string();
        let _unfocused = server.peer(&hello(r#""pane":"pane_1","#, false, 80, 24));
        let _focused = server.peer(&hello(r#""pane":"pane_4","#, true, 80, 24));
        let _third = server.peer(&hello(r#""window":"window_1","#, false, 80, 24));
        assert_eq!(pane_of(&server, 3), "pane_4");
        let mut gains = server.peer(&hello(r#""pane":"pane_1","#, false, 80, 24));
        gains.send(&mut server, r#"{"type":"select","pane":"pane_4"}"#);
        let _fourth = server.peer(&hello(r#""window":"window_1","#, false, 80, 24));
        assert_eq!(
            pane_of(&server, 5),
            "pane_4",
            "an unfocused select notes nothing"
        );
        gains.send(&mut server, r#"{"type":"select","pane":"pane_1"}"#);
        gains.send(&mut server, r#"{"type":"focused","focused":true}"#);
        let _fifth = server.peer(&hello(r#""window":"window_1","#, false, 80, 24));
        assert_eq!(
            pane_of(&server, 6),
            "pane_1",
            "gaining focus notes the shown pane"
        );
    }

    #[test]
    fn a_failed_put_keeps_the_ids_it_handed_out() {
        let mut server = harness("ids");
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}},
                {"pane": {"new": {"cwd": "/nonexistent"}}}]});
        });
        assert!(reply.starts_with("HTTP/1.1 400"), "{reply}");
        assert_eq!(server.state.panes.len(), 1);
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": cat()}}]});
        });
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        let panes = windows(&server)[0].2.clone();
        assert_eq!(panes, ["pane_1", "pane_4"]);
    }

    #[test]
    fn clearing_the_history_answers_an_empty_object_and_an_unknown_pane_is_not_found() {
        let mut server = harness("clear-history");
        let ok = server.reply("POST /panes/pane_1/clear_history", "\r\n");
        assert!(ok.starts_with("HTTP/1.1 200") && ok.ends_with("{}"), "{ok}");
        assert_eq!(
            server.status("POST /panes/pane_9/clear_history", "\r\n"),
            "HTTP/1.1 404"
        );
    }

    impl Harness {
        fn call(&mut self, request: &str, body: &Value) -> (String, Value) {
            let body = body.to_string();
            let reply = self.reply(
                request,
                &format!("Content-Length: {}\r\n\r\n{body}", body.len()),
            );
            let status = reply[9..12].to_owned();
            let json = reply
                .split_once("\r\n\r\n")
                .and_then(|(_, body)| serde_json::from_str(body).ok())
                .unwrap_or(Value::Null);
            (status, json)
        }
    }

    #[test]
    fn a_run_is_a_marked_window_whose_first_outcome_stands() {
        let mut server = harness("runs");
        let mut peer = server.peer(&hello("", false, 80, 24));
        assert_eq!(kinds(&peer.events(&mut server)), ["welcome", "layout"]);
        let cat = json!(["/bin/sh", "-c", "exec cat"]);
        let (status, started) = server.call(
            "POST /runs",
            &json!({"name": "job", "session": "s", "env": [], "argv": cat}),
        );
        assert_eq!(status, "200", "{started}");
        let (id, pane) = (
            started["id"].as_str().unwrap(),
            started["pane"].as_str().unwrap(),
        );
        assert_eq!(
            server
                .state
                .panes
                .find(pane.parse().unwrap())
                .and_then(|pane| pane
                    .vars()
                    .text(&crate::ids::VarName::new("ko.run").unwrap())
                    .map(str::to_owned)),
            Some(id.to_owned())
        );
        let (_, listed) = server.call("GET /runs?show=live", &json!(null));
        assert_eq!(listed[0]["name"], "job");
        assert_eq!(listed[0]["pane"], pane);
        assert_eq!(listed[0].get("outcome"), None);

        let events = peer.events(&mut server);
        let runs: Vec<&Value> = events
            .iter()
            .filter(|event| event["type"] == "run")
            .collect();
        assert_eq!(
            runs,
            [
                &json!({"type": "run", "id": id, "name": "job", "pane": pane, "startedAt": listed[0]["startedAt"]})
            ]
        );
        let began = std::time::Instant::now();
        let (_, waited) = server.call(&format!("GET /runs/{id}/wait?timeout_ms=150"), &json!(null));
        assert_eq!(waited, json!({}));
        assert!(began.elapsed() >= std::time::Duration::from_millis(140));

        let outcome = |server: &mut Harness| {
            server
                .call(
                    &format!("POST /runs/{id}/outcome"),
                    &json!({"result": "completed"}),
                )
                .0
        };
        assert_eq!(outcome(&mut server), "200");
        assert_eq!(outcome(&mut server), "409");
        let ended: Vec<Value> = peer
            .events(&mut server)
            .into_iter()
            .filter(|event| event["type"] == "run")
            .collect();
        assert_eq!(ended.len(), 1, "a lost write announces nothing: {ended:?}");
        assert_eq!(ended[0]["outcome"]["result"], "completed");
        let (_, waited) = server.call(&format!("GET /runs/{id}/wait"), &json!(null));
        assert_eq!(waited["outcome"]["result"], "completed");
        let (_, live) = server.call("GET /runs", &json!(null));
        assert_eq!(live, json!([]));
        let (_, all) = server.call("GET /runs?show=all", &json!(null));
        assert_eq!(all[0]["outcome"]["result"], "completed");

        let stop = json!({"wait_ms": 0, "result": "stopped"});
        assert_eq!(
            server.call(&format!("POST /runs/{id}/stop"), &stop).0,
            "200"
        );
        assert!(server.state.panes.find(pane.parse().unwrap()).is_none());
        assert_eq!(
            server.call(&format!("POST /runs/{id}/stop"), &stop).0,
            "409"
        );
        let (_, detail) = server.call(&format!("GET /runs/{id}"), &json!(null));
        assert_eq!(
            detail["outcome"]["result"], "completed",
            "the first outcome stands"
        );
    }

    #[test]
    fn a_run_refuses_a_bad_name_session_and_parent() {
        let mut server = harness("run-refusals");
        let argv = json!(["/bin/sh"]);
        let unknown = "0123456789abcdef0123456789abcdef";
        let long = "n".repeat(65);
        let cases = [
            (json!({"name": long, "session": "s", "argv": argv}), "400"),
            (
                json!({"name": "a", "session": "absent", "argv": argv}),
                "400",
            ),
            (json!({"name": "a", "argv": argv}), "400"),
            (
                json!({"name": "a", "session": "s", "parent": unknown, "argv": argv}),
                "404",
            ),
            (
                json!({"name": "a", "session": "s", "parent": "pane_99", "argv": argv}),
                "410",
            ),
            (json!({"name": "a", "session": "s", "argv": ["sh"]}), "400"),
        ];
        for (body, want) in cases {
            assert_eq!(server.call("POST /runs", &body).0, want, "{body}");
        }
        assert_eq!(server.state.panes.len(), 1, "a refused run starts nothing");
        assert_eq!(server.call("GET /runs/abc", &json!(null)).0, "404");
        assert_eq!(
            server.call(&format!("GET /runs/{unknown}"), &json!(null)).0,
            "404"
        );
        assert_eq!(
            server
                .call(
                    &format!("POST /runs/{unknown}/outcome"),
                    &json!({"result": "failed"})
                )
                .0,
            "404"
        );
    }

    fn pi_pane(inbox: Option<&str>, name: &str) -> Value {
        let mut vars = json!({"pi.session": format!("session-{name}"), "pi.name": name});
        if let Some(inbox) = inbox {
            vars["pi.inbox"] = json!(inbox);
        }
        json!({"command": {"type": "shell", "command":
            "stty raw -echo; printf '\\033]7501;state=idle:app=pi\\007'; exec cat"}, "vars": vars})
    }

    fn add_window(server: &mut Harness, name: &str, pane: Value) -> String {
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"]
                .as_array_mut()
                .unwrap()
                .push(json!({"name": name, "tree": {"pane": {"new": pane}}}));
        });
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
        windows(server).last().unwrap().2[0].clone()
    }

    fn prompt_call(server: &mut Harness, request: &str, body: &Value) -> (String, Value) {
        let body = body.to_string();
        let reply = server.reply(
            request,
            &format!(
                "Ko-Pane: pane_1\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            ),
        );
        let json = reply
            .split_once("\r\n\r\n")
            .and_then(|(_, body)| serde_json::from_str(body).ok())
            .unwrap_or(Value::Null);
        (reply[9..12].to_owned(), json)
    }

    fn wait_for_root(server: &mut Harness, pane: &str) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let (_, candidates) = prompt_call(server, "GET /prompt/resolve", &json!(null));
            if candidates
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["pane"] == pane)
            {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "{pane} never showed a pi root"
            );
            server.step(Mode::Peek);
        }
    }

    #[test]
    fn a_prompt_goes_to_an_agent_of_the_session_by_paste_or_by_inbox() {
        let mut server = harness("prompt");
        let paste = add_window(&mut server, "paste", pi_pane(None, "Paster"));
        let dir = PathBuf::from(format!("/tmp/ko-router-inbox-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("inbox.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let peer = std::thread::spawn(move || {
            use std::io::Read;
            let (mut peer, _) = listener.accept().unwrap();
            let mut got = String::new();
            peer.read_to_string(&mut got).unwrap();
            peer.write_all(b"ok").unwrap();
            got
        });
        let inbox = add_window(&mut server, "inbox", pi_pane(socket.to_str(), "Inboxer"));
        let dead_inbox = add_window(
            &mut server,
            "dead",
            pi_pane(Some("/tmp/ko-no-such.sock"), "Gone"),
        );
        wait_for_root(&mut server, &paste);
        wait_for_root(&mut server, &inbox);
        wait_for_root(&mut server, &dead_inbox);

        let (status, candidates) = prompt_call(&mut server, "GET /prompt/resolve", &json!(null));
        assert_eq!(status, "200");
        let panes: Vec<&str> = candidates
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["pane"].as_str().unwrap())
            .collect();
        assert_eq!(
            panes,
            [paste.as_str(), inbox.as_str(), dead_inbox.as_str()],
            "pane_1 is a terminal"
        );
        assert_eq!(candidates[0]["title"], "Paster");
        let (_, narrowed) =
            prompt_call(&mut server, "GET /prompt/resolve?window=true", &json!(null));
        assert_eq!(narrowed, json!([]), "the caller's window holds no agent");
        assert_eq!(candidates[0]["session"], "session_1");

        let send = |server: &mut Harness, target: &str, text: &str| {
            prompt_call(
                server,
                "POST /prompt",
                &json!({"target": target, "text": text}),
            )
        };
        assert_eq!(
            send(&mut server, &paste, "one two"),
            ("200".to_owned(), json!({"via": "paste"}))
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let screen = server.reply(&format!("GET /panes/{paste}/screen"), "\r\n");
            if screen.contains("two") {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "{screen}");
            server.step(Mode::Peek);
        }
        assert_eq!(
            send(&mut server, &inbox, "hello inbox"),
            ("200".to_owned(), json!({"via": "inbox"}))
        );
        assert_eq!(peer.join().unwrap(), "hello inbox");
        let (status, refused) = send(&mut server, &dead_inbox, "x");
        assert_eq!(
            (status.as_str(), refused["message"].as_str()),
            ("409", Some("Gone is not accepting messages")),
            "an advertised inbox that does not answer is refused, never a paste"
        );
        assert_eq!(
            send(&mut server, "pane_1", "x").0,
            "400",
            "a terminal is no candidate"
        );
        assert_eq!(send(&mut server, &paste, "").0, "400");
        assert_eq!(server.status("GET /prompt/resolve", "\r\n"), "HTTP/1.1 400");
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn step_until(server: &mut Harness, what: &str, mut done: impl FnMut(&mut Harness) -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !done(server) {
            assert!(std::time::Instant::now() < deadline, "wait for {what}");
            server.step(Mode::Wait);
        }
    }

    #[test]
    fn the_sweep_closes_a_dead_run_after_the_grace_unless_a_client_shows_it() {
        let mut server = harness("sweep-grace");
        server.state.config.linger = std::time::Duration::from_millis(150);
        let (_, started) = server.call(
            "POST /runs",
            &json!({"name": "dies", "session": "s", "argv": ["/bin/sh", "-c", "echo last words; exit 3"]}),
        );
        let (id, pane) = (
            started["id"].as_str().unwrap(),
            started["pane"].as_str().unwrap(),
        );
        let mut watcher = server.peer(&hello(&format!(r#""pane":"{pane}","#), true, 80, 24));
        step_until(&mut server, "the pane to die", |server| {
            server
                .state
                .panes
                .find(pane.parse().unwrap())
                .is_some_and(|p| p.proc().dead().is_some())
        });
        let (_, waited) = server.call(&format!("GET /runs/{id}/wait"), &json!(null));
        assert_eq!(
            waited["outcome"],
            json!({"result": "failed", "text": "exit 3"})
        );
        let until = std::time::Instant::now() + std::time::Duration::from_millis(500);
        while std::time::Instant::now() < until {
            server.step(Mode::Wait);
        }
        assert!(
            server.state.panes.find(pane.parse().unwrap()).is_some(),
            "a pane that a client shows stays"
        );
        watcher.send(&mut server, r#"{"type":"select","pane":"pane_1"}"#);
        step_until(&mut server, "the sweep", |server| {
            server.state.panes.find(pane.parse().unwrap()).is_none()
        });
        let (_, detail) = server.call(&format!("GET /runs/{id}"), &json!(null));
        assert_eq!(detail["outcome"]["result"], "failed");
        assert_eq!(detail["outcome"]["text"], "exit 3");
        assert!(
            detail["screen"].as_str().unwrap().contains("last words"),
            "{detail}"
        );
        let layout = server.state.snapshot_layout().layout;
        assert_eq!(layout.windows().count(), 1, "the run's window is gone");
    }

    fn dying_run(server: &mut Harness, name: &str) -> (String, crate::ids::PaneId) {
        let (_, started) = server.call(
            "POST /runs",
            &json!({"name": name, "session": "s", "argv": ["/bin/sh", "-c", "echo bye; exit 3"]}),
        );
        let id = started["id"].as_str().unwrap().to_owned();
        let pane: crate::ids::PaneId = started["pane"].as_str().unwrap().parse().unwrap();
        step_until(server, "the pane to die", |server| {
            server
                .state
                .panes
                .find(pane)
                .is_some_and(|p| p.proc().dead().is_some())
        });
        (id, pane)
    }

    #[test]
    fn a_pane_that_is_no_longer_sweepable_when_its_screen_arrives_stays() {
        let mut server = harness("sweep-recheck");
        server.state.config.linger = std::time::Duration::from_secs(3600);
        let (id, pane) = dying_run(&mut server, "recheck");
        server.state.config.linger = std::time::Duration::from_millis(1);
        server.state.reap_runs(&mut server.poll);
        server.state.config.linger = std::time::Duration::from_secs(3600);
        let until = std::time::Instant::now() + std::time::Duration::from_millis(400);
        while std::time::Instant::now() < until {
            server.step(Mode::Wait);
        }
        assert!(server.state.panes.find(pane).is_some());
        let (_, detail) = server.call(&format!("GET /runs/{id}"), &json!(null));
        assert_eq!(detail["screen"], Value::Null, "nothing was recorded");
    }

    #[test]
    fn a_finished_capture_that_lost_its_write_still_lets_the_sweep_collect_the_pane() {
        let mut server = harness("sweep-after-capture");
        server.state.config.linger = std::time::Duration::from_secs(3600);
        let (id, pane) = dying_run(&mut server, "after");
        let done = json!({"result": "completed"});
        assert_eq!(
            server.call(&format!("POST /runs/{id}/outcome"), &done).0,
            "200"
        );
        server.state.config.linger = std::time::Duration::from_millis(1);
        let failed = json!({"result": "failed", "text": "late"});
        assert_eq!(
            server.call(&format!("POST /runs/{id}/outcome"), &failed).0,
            "409"
        );
        step_until(&mut server, "the pane to be collected", |server| {
            server.state.panes.find(pane).is_none()
        });
        let (_, detail) = server.call(&format!("GET /runs/{id}"), &json!(null));
        assert_eq!(detail["outcome"]["result"], "completed");
    }

    #[test]
    fn the_sweep_stops_a_run_whose_parent_ended() {
        let mut server = harness("sweep-orphan");
        let cat = json!(["/bin/sh", "-c", "exec cat"]);
        let start = |server: &mut Harness, name: &str, parent: Value| {
            let (status, started) = server.call(
                "POST /runs",
                &json!({"name": name, "session": "s", "parent": parent, "argv": cat}),
            );
            assert_eq!(status, "200", "{started}");
            started
        };
        let parent = start(&mut server, "parent", Value::Null);
        let child = start(&mut server, "child", parent["id"].clone());
        let (parent_id, child_id) = (
            parent["id"].as_str().unwrap(),
            child["id"].as_str().unwrap(),
        );
        let child_pane: crate::ids::PaneId = child["pane"].as_str().unwrap().parse().unwrap();
        server.step(Mode::Peek);
        assert!(
            server.state.panes.find(child_pane).is_some(),
            "a live parent keeps its child"
        );
        let outcome = json!({"result": "completed"});
        assert_eq!(
            server
                .call(&format!("POST /runs/{parent_id}/outcome"), &outcome)
                .0,
            "200"
        );
        step_until(&mut server, "the orphan to be collected", |server| {
            server.state.panes.find(child_pane).is_none()
        });
        let (_, detail) = server.call(&format!("GET /runs/{child_id}"), &json!(null));
        assert_eq!(
            (&detail["outcome"]["result"], &detail["outcome"]["text"]),
            (&json!("failed"), &json!("its parent ended")),
            "{detail}"
        );
        assert!(detail["outcome"]["at"].is_string());
        let (status, _) = server.call(
            &format!("POST /runs/{parent_id}/stop"),
            &json!({"result": "stopped"}),
        );
        assert_eq!(status, "200", "the parent's window goes too");
        assert_eq!(windows(&server).len(), 1, "only the first window remains");
    }
}
