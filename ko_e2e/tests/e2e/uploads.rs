use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use crate::harness::{DEADLINE, Dir, poll, quote, stays, wait_gone, within};
use crate::panes::as_pane;
use crate::runtime::{fifo, pid_of, release, serve_in};
use serde_json::json;

pub(crate) fn check_runtime_drop(s: &crate::harness::Server, runtime: &str, pane: &str) {
    let bytes = b"uploaded through runtime exec\n";
    let (status, reply) = s.exchange(
        "POST",
        &format!("/panes/{pane}/drops?name=runtime.txt"),
        &s.headers(),
        bytes,
    );
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&reply));
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    let mut exec = crate::runtime::start_exec(
        s,
        runtime,
        json!({"argv":["/bin/sh", "-c", "cat \"$1\"; rm -rf -- \"${1%/*}\"", "upload", reply["path"]], "stdin":false}),
    );
    let result = crate::runtime::read_exec(&mut exec);
    assert_eq!(result.end, json!({"type":"exit", "status":0}));
    assert_eq!(result.stdout, bytes);
    assert_eq!(result.stderr, b"");
}

#[test]
fn upload_names_can_start_with_a_hyphen() {
    let s = crate::harness::start(&[]);
    let pane = s.pane("exec cat");
    let (status, body) = s.exchange(
        "POST",
        &format!("/panes/{pane}/drops?name=-notes"),
        &s.headers(),
        b"notes",
    );
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&body));
    let reply: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(fs::read(reply["path"].as_str().unwrap()).unwrap(), b"notes");
}

#[test]
fn uploads_stream_files_and_remove_partial_drops() {
    let home = Dir::new("ko-upload-home-");
    let gate = fifo(&home, "gate");
    let _gate_open = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&gate)
        .unwrap();
    let ready = home.join("ready");
    let script = format!(
        "if [ \"$3\" = --exec ]; then printf '%s\\n' $$ > {}; read answer < {}; fi; exec \"$@\"",
        quote(ready.to_str().unwrap()),
        quote(gate.to_str().unwrap())
    );
    let s = serve_in(
        Dir::new("ko-upload-"),
        &format!(
            "runtimes:\n  dev:\n    command: {{}}\n    env:\n      HOME: {:?}\n  blocked:\n    command:\n      prefix: [/bin/sh, -c, {script:?}, gate]\n    env:\n      HOME: {:?}\n",
            home.to_str().unwrap(),
            home.to_str().unwrap()
        ),
        &[],
    );
    let pane = s.pane("exec cat");
    let target = format!("/panes/{pane}/drops");
    let bytes: Vec<u8> = (0..(2 << 20)).map(|i| (i % 251) as u8).collect();
    let (status, body) = s.exchange(
        "POST",
        &format!("{target}?name=sample.bin"),
        &s.headers(),
        &bytes,
    );
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&body));
    let reply: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let path = Path::new(reply["path"].as_str().unwrap());
    assert!(path.starts_with(s.dir.join("drops")));
    assert_eq!(fs::read(path).unwrap(), bytes);
    assert_eq!(
        fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    for name in ["", ".hidden", "a%2Fb", "a%00b", "a%0Ab"] {
        assert_eq!(
            s.exchange("POST", &format!("{target}?name={name}"), &s.headers(), b"x")
                .0,
            400
        );
    }
    let headers: String = s
        .headers()
        .iter()
        .map(|(key, value)| format!("{key}: {value}\r\n"))
        .collect();
    for (name, framing, status) in [
        ("test", "", "400"),
        ("test", "Content-Length: 2147483649\r\n", "500"),
        ("test", "Transfer-Encoding: chunked\r\n", "400"),
        (".hidden", "Content-Length: 2147483649\r\n", "400"),
    ] {
        let mut stream = s.dial().unwrap();
        within(&stream, Instant::now() + DEADLINE);
        stream
            .write_all(
                format!("POST {target}?name={name} HTTP/1.1\r\nHost: ko\r\n{headers}{framing}\r\n")
                    .as_bytes(),
            )
            .unwrap();
        let mut reply = Vec::new();
        stream.read_to_end(&mut reply).unwrap();
        assert!(
            reply.starts_with(format!("HTTP/1.1 {status} ").as_bytes()),
            "{}",
            String::from_utf8_lossy(&reply)
        );
    }
    let mut complete = s.dial().unwrap();
    within(&complete, Instant::now() + DEADLINE);
    s.write_request(
        &mut complete,
        "POST",
        &format!("{target}?name=half-close"),
        &s.headers(),
        b"abc",
    );
    complete.shutdown(std::net::Shutdown::Write).unwrap();
    let mut reply = Vec::new();
    complete.read_to_end(&mut reply).unwrap();
    assert!(
        reply.starts_with(b"HTTP/1.1 200 "),
        "{}",
        String::from_utf8_lossy(&reply)
    );
    let mut stream = s.dial().unwrap();
    within(&stream, Instant::now() + DEADLINE);
    stream.write_all(format!("POST {target}?name=partial HTTP/1.1\r\nHost: ko\r\n{headers}Content-Length: 100\r\n\r\nx").as_bytes()).unwrap();
    let partial = || {
        fs::read_dir(s.dir.join("drops")).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .as_encoded_bytes()
                .starts_with(b".")
        })
    };
    poll("partial drop created", partial);
    drop(stream);
    poll("partial drop removed", || !partial());

    let caller = s.token_pane("exec cat");
    assert_eq!(
        s.exchange(
            "POST",
            &format!("{target}?name=forbidden"),
            &as_pane(&s, &caller),
            b"x"
        )
        .0,
        409
    );
    let runtime = s.token_pane_with(json!({"runtime":"dev"}), "exec cat");
    let rt_target = format!("/panes/{runtime}/drops?name=runtime.bin");
    let (status, reply) = s.exchange("POST", &rt_target, &s.headers(), &bytes);
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&reply));
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    let path = Path::new(reply["path"].as_str().unwrap());
    assert!(path.starts_with(home.join(".local/state/ko/drops")));
    assert_eq!(fs::read(path).unwrap(), bytes);
    assert_eq!(fs::read_dir(s.dir.join("drops")).unwrap().count(), 2);
    assert_eq!(
        s.exchange_on(
            &s.dir.join("runtimes/dev/io/socket"),
            "POST",
            &rt_target,
            &as_pane(&s, &runtime),
            b"x"
        )
        .0,
        409
    );

    let mut visit = s
        .dial_ws("/runtimes/dev/visit", Some(as_pane(&s, &caller)), 101)
        .unwrap();
    visit.send(&json!({"type":"visit", "cwd":"/tmp"}));
    visit.event("up");
    let mut uploading = s.dial().unwrap();
    within(&uploading, Instant::now() + DEADLINE);
    uploading.write_all(format!("POST /panes/{caller}/drops?name=visit HTTP/1.1\r\nHost: ko\r\n{headers}Content-Length: 100\r\n\r\nx").as_bytes()).unwrap();
    let rt_partial = || {
        fs::read_dir(home.join(".local/state/ko/drops"))
            .unwrap()
            .any(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .as_encoded_bytes()
                    .starts_with(b".")
            })
    };
    poll("visit upload started", rt_partial);
    drop(visit);
    poll("visit upload cancelled", || !rt_partial());
    let mut reply = Vec::new();
    uploading.read_to_end(&mut reply).unwrap();
    assert!(
        reply.starts_with(b"HTTP/1.1 500 "),
        "{}",
        String::from_utf8_lossy(&reply)
    );

    let blocked = s.token_pane_with(json!({"runtime":"blocked"}), "exec cat");
    let mut sending = s.dial().unwrap();
    within(&sending, Instant::now() + DEADLINE);
    ko_sys::sock::set_send_buffer(sending.as_fd(), 65536).unwrap();
    let client_send = ko_sys::sock::buffers(sending.as_fd()).unwrap().send;
    let (probe, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
    let server_receive = ko_sys::sock::buffers(probe.as_fd()).unwrap().receive;
    let mut framing = Vec::new();
    ko_wire::exec_wire::ToKo::Stdin(&[0]).encode(&mut framing);
    ko_wire::exec_wire::ToKo::Eof.encode(&mut framing);
    // Bound = client SO_SNDBUF + default server SO_RCVBUF + HTTP input + one exec payload
    // + its data/EOF headers + one pipe (Linux pipe-max-size defaults to 1 MiB; macOS pipes are smaller).
    let bound = client_send
        + server_receive
        + ko_wire::http::MAX_HEAD
        + ko_wire::protocol::EXEC_CHUNK
        + framing.len()
        - 1
        + (1 << 20);
    assert!(bound < 33554432);
    sending.write_all(format!("POST /panes/{blocked}/drops?name=blocked HTTP/1.1\r\nHost: ko\r\n{headers}Content-Length: 33554432\r\n\r\n").as_bytes()).unwrap();
    poll("upload helper blocks before it reads stdin", || {
        ready.exists()
    });
    sending.set_nonblocking(true).unwrap();
    let chunk = [b'x'; 65536];
    let mut buffered = 0;
    stays(
        "blocked helper bounds the complete input pipeline",
        Duration::from_millis(100),
        || {
            while buffered <= bound {
                match sending.write(&chunk) {
                    Ok(count) if count > 0 => buffered += count,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    other => panic!("upload write: {other:?}"),
                }
            }
            buffered <= bound
        },
    );
    s.request("GET", "/version", None, 200);
    sending.set_nonblocking(false).unwrap();
    release(&home, &gate, "go");
    while buffered < 33554432 {
        let count = chunk.len().min(33554432 - buffered);
        sending.write_all(&chunk[..count]).unwrap();
        buffered += count;
    }
    let (status, reply) = s.read_reply(sending);
    assert_eq!(status, 200, "{}", String::from_utf8_lossy(&reply));
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(
        fs::read(reply["path"].as_str().unwrap()).unwrap(),
        vec![b'x'; 33554432]
    );

    fs::remove_file(&ready).unwrap();
    let mut half = s.dial().unwrap();
    within(&half, Instant::now() + DEADLINE);
    ko_sys::sock::set_send_buffer(half.as_fd(), 1 << 20).unwrap();
    let half_send = ko_sys::sock::buffers(half.as_fd()).unwrap().send;
    let pipe_capacity = {
        let (_read, write) = std::io::pipe().unwrap();
        ko_sys::fd::set_nonblocking(write.as_fd()).unwrap();
        let deadline = Instant::now() + DEADLINE;
        let mut capacity = 0;
        loop {
            assert!(
                Instant::now() < deadline,
                "pipe capacity measurement exceeded deadline"
            );
            match ko_sys::fd::write(write.as_fd(), &chunk) {
                Ok(count) if count > 0 => capacity += count,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break capacity,
                other => panic!("pipe capacity measurement: {other:?}"),
            }
        }
    };
    let half_size =
        pipe_capacity + ko_wire::http::MAX_HEAD + ko_wire::protocol::EXEC_CHUNK + framing.len();
    assert!(
        half_size < half_send + server_receive,
        "half-close needs body ({half_size}) > helper pipe ({pipe_capacity}) + server queues, but < client SO_SNDBUF ({half_send}) + server SO_RCVBUF ({server_receive})"
    );
    half.set_nonblocking(true).unwrap();
    half.write_all(format!("POST /panes/{blocked}/drops?name=gated-half-close HTTP/1.1\r\nHost: ko\r\n{headers}Content-Length: {half_size}\r\n\r\n").as_bytes()).unwrap();
    poll("half-close helper waits at gate", || ready.exists());
    half.write_all(&vec![b'h'; half_size]).unwrap();
    half.shutdown(std::net::Shutdown::Write).unwrap();
    stays(
        "half-close retains buffered body until gate release",
        Duration::from_millis(100),
        || matches!(half.read(&mut [0u8; 1]), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
    );
    release(&home, &gate, "go");
    half.set_nonblocking(false).unwrap();
    let mut reply = Vec::new();
    half.read_to_end(&mut reply).unwrap();
    assert!(
        reply.starts_with(b"HTTP/1.1 200 "),
        "{}",
        String::from_utf8_lossy(&reply)
    );
    let body = reply
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .unwrap()
        + 4;
    let reply: serde_json::Value = serde_json::from_slice(&reply[body..]).unwrap();
    assert_eq!(
        fs::read(reply["path"].as_str().unwrap()).unwrap(),
        vec![b'h'; half_size]
    );

    fs::remove_file(&ready).unwrap();
    let mut short = s.dial().unwrap();
    within(&short, Instant::now() + DEADLINE);
    short.write_all(format!("POST /panes/{blocked}/drops?name=gated-short HTTP/1.1\r\nHost: ko\r\n{headers}Content-Length: 1024\r\n\r\nshort").as_bytes()).unwrap();
    poll("short upload helper waits at gate", || ready.exists());
    let helper = pid_of(&ready);
    short.shutdown(std::net::Shutdown::Write).unwrap();
    release(&home, &gate, "go");
    let mut reply = Vec::new();
    short.read_to_end(&mut reply).unwrap();
    assert!(
        !reply.starts_with(b"HTTP/1.1 200 "),
        "{}",
        String::from_utf8_lossy(&reply)
    );
    wait_gone(helper, "short upload helper exited");
    poll("gated short upload leaves no partial", || !rt_partial());
    assert!(
        !fs::read_dir(home.join(".local/state/ko/drops"))
            .unwrap()
            .any(|entry| entry.unwrap().path().join("gated-short").exists())
    );
}
