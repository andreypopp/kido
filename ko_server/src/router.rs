use ko_sys::event::{Poll, Token};
use serde::Serialize;

use crate::client::Client;
use crate::conn::{Conn, Payload, Phase, Request};
use crate::http::{self, LAST_CHUNK, Status};
use crate::ids::ClientId;
use crate::link::{Link, Role};
use crate::pane_proc::{Life, Refusal};
use crate::protocol::{
    self, Error, ErrorKind, Input, PROTOCOL_HEADER, PasteResult, PutLayout, Route, Selection,
    VT_HEADER, check_version,
};
use crate::state::{Owner, PutFailure, SelectFailure, State};
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
    | Route::ClearHistory(id)
    | Route::Input(id)
    | Route::Screen(id, ..)
    | Route::View(id, ..) = route
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
            let rows = state.rows();
            ok(&mut state.conns[index], &rows);
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
                Err(PutFailure::Invalid(message)) => {
                    error(&mut state.conns[index], ErrorKind::Invalid, message);
                }
                Err(PutFailure::Io(message)) => {
                    error(&mut state.conns[index], ErrorKind::Io, message);
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

    fn kinds(events: &[serde_json::Value]) -> Vec<String> {
        events
            .iter()
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
            let new_window = |name: &str| {
                json!({"name": name, "tree": {"pane": {"new": {"command":
                    {"type": "shell", "command": "exec cat"}}}}})
            };
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

    use serde_json::json;

    #[test]
    fn a_client_gets_the_layout_after_its_welcome_and_every_change_after_that() {
        let mut server = harness("layout-events");
        let mut peer = server.peer(&hello("", false, 80, 24));
        assert_eq!(kinds(&peer.events(&mut server)), ["welcome", "layout"]);
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": {}}}]});
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
                {"pane": "pane_1"}, {"pane": {"new": {}}},
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
        assert!(a.events(&mut server).is_empty());
        a.send(&mut server, r#"{"type":"select","session":"session_1"}"#);
        assert_eq!(kinds(&a.events(&mut server)), ["selected pane_2"]);
        a.send(&mut server, r#"{"type":"select","window":"window_9"}"#);
        assert!(b.events(&mut server).is_empty());
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
        assert!(a.events(&mut server).is_empty());
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
                {"pane": "pane_2"}, {"pane": {"new": {"command":
                    {"type": "shell", "command": "exec cat"}}}}]});
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
                {"pane": "pane_1"}, {"pane": {"new": {}}}]});
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
                {"pane": "pane_1"}, {"pane": {"new": {}}}]});
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
                {"pane": "pane_1"}, {"pane": {"new": {}}}]});
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
                {"pane": "pane_1"}, {"pane": {"new": {}}}]});
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
                {"pane": "pane_1"}, {"pane": {"new": {}}},
                {"pane": {"new": {"cwd": "/nonexistent"}}}]});
        });
        assert!(reply.starts_with("HTTP/1.1 400"), "{reply}");
        assert_eq!(server.state.panes.len(), 1);
        let reply = server.put(|layout| {
            layout["sessions"][0]["windows"][0]["tree"] = json!({"split": "h", "children": [
                {"pane": "pane_1"}, {"pane": {"new": {}}}]});
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
}
