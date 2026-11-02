use ko_sys::event::{Poll, Token};
use serde::Serialize;

use crate::client::Client;
use crate::conn::{Conn, Payload, Phase, Request};
use crate::http::{self, LAST_CHUNK, Status};
use crate::ids::ClientId;
use crate::link::{Link, Role};
use crate::pane_proc::{Life, Refusal};
use crate::panes::AddError;
use crate::protocol::{
    self, CreatePane, Created, Error, ErrorKind, Input, PROTOCOL_HEADER, PasteResult, Route,
    VT_HEADER, check_version,
};
use crate::state::{Owner, State};
use crate::view::View;
use crate::ws::{self, Ws};

#[derive(Serialize)]
struct Empty {}

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
    let body = protocol::json(&Error {
        kind,
        message: message.into(),
    });
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
    let Some(route) = route else {
        return error(
            &mut state.conns[index],
            ErrorKind::Missing,
            "resource not found",
        );
    };
    if let Route::DeletePane(id)
    | Route::Input(id)
    | Route::Screen(id, ..)
    | Route::View(id, ..)
    | Route::Vars(id)
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
        Route::CreatePane => {
            let Some(request) = body::<CreatePane>(&mut state.conns[index], &payload) else {
                return;
            };
            match state.add_pane(poll, &request) {
                Ok(pane) => {
                    ok(&mut state.conns[index], &Created { pane });
                    state.topology();
                }
                Err(AddError::Invalid(message)) => {
                    error(&mut state.conns[index], ErrorKind::Invalid, message);
                }
                Err(AddError::Io(failure)) => {
                    error(&mut state.conns[index], ErrorKind::Io, failure.to_string());
                }
            }
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
            state.close_views(id);
            state.remove_pane(poll, id);
            state.topology();
            ok(&mut state.conns[index], &Empty {});
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
        Route::DeleteVar(id, name) => {
            state.delete_var(poll, id, name);
            ok(&mut state.conns[index], &Empty {});
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
    use crate::protocol::{Command, version_headers};
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
            server.reply("POST /panes", "Content-Length: abc\r\n\r\n{}"),
            server.reply(
                "POST /panes",
                "Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}x",
            ),
            server.reply("POST /panes", "Transfer-Encoding: chunked\r\n\r\n{}"),
            server.reply(
                &format!("GET /version HTTP/1.1\r\n{}", "A: b\r\n".repeat(4000)),
                "\r\n",
            ),
            server.reply(
                "POST /panes",
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
                        "GET /panes HTTP/1.1\r\nHost: ko\r\nKo-Protocol: 1.0\r\nKo-Vt: {}\r\n\r\n",
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
        let create = server.status("POST /panes", "Content-Length: 10\r\n\r\n[\"/tmp\"]  ");
        let input = server.status(
            "POST /panes/pane_1/input",
            "Content-Length: 31\r\n\r\n{\"type\":\"focus\",\"focused\":true}",
        );
        let hello = r#"["hello",["terminal","t","pane_1",true,{"cols":7,"rows":7},false]]"#;
        let _array_hello = server.connect(&[upgrade("/client"), text(hello)].concat());
        let size_hello = r#"{"type":"hello","kind":"terminal","name":"t","pane":"pane_1","focused":false,"ignore_size":true,"size":[80,24]}"#;
        let _array_size = server.connect(&[upgrade("/client"), text(size_hello)].concat());
        let key = r#"{"type":"input","input":["key",["press",20,0,97,"a",false]]}"#;
        let _array_key = server.connect(&[upgrade("/panes/pane_1/view"), text(key)].concat());
        let sizer = server
            .state
            .panes
            .find(crate::ids::PaneId::new(1))
            .unwrap()
            .sizer();
        assert_eq!(
            (
                create.as_str(),
                input.as_str(),
                server.state.panes.len(),
                sizer,
                server.state.conns.len()
            ),
            ("HTTP/1.1 400", "HTTP/1.1 200", panes, None, 0)
        );
    }

    #[test]
    fn a_client_that_never_reads_is_closed_before_its_queue_grows_without_bound() {
        let mut server = harness("unread");
        let long = CreatePane {
            cwd: None,
            command: Some(Command::Argv {
                argv: vec![
                    "/bin/sh".to_owned(),
                    "-c".to_owned(),
                    "exec cat".to_owned(),
                    "x".repeat(400_000),
                ],
            }),
            env: Vec::new(),
        };
        server.state.add_pane(&mut server.poll, &long).unwrap();
        let hello = r#"{"type":"hello","kind":"app","name":"t","focused":false,"size":{"cols":80,"rows":24}}"#;
        let client = server.connect(&[upgrade("/client"), text(hello)].concat());
        let registered = server.state.registered(ClientId::new(1));
        let closed_at = (1..400).find(|_| {
            server.state.topology();
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
        let chunked = server.status("POST /panes", "Transfer-Encoding: chunked\r\n\r\n{}");
        let cwd = server.status(
            "POST /panes",
            "Content-Length: 26\r\n\r\n{\"cwd\":\"/nonexistent\"}    ",
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
            1 => Just(format!("Ko-Protocol: 1.0\r\nKo-Vt: {vt}\r\n")),
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
}
