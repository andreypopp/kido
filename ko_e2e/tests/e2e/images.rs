use std::io::Read;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use ko_sys::mapping::{Name, Named};
use ko_sys::pid::signal_descendant;
use ko_sys::signal::Signal;
use ko_vt::frames::{Playback, Screen};
use ko_vt::{Extent, Terminal};
use serde_json::Value;

use crate::harness::{
    DEADLINE, Framing, Head, Server, Steady, base64, poll, start, start_serving, within,
};

static OBJECTS: AtomicU32 = AtomicU32::new(0);

const LIMIT: u64 = 300_000_000;
const RED: [u8; 4] = [255, 0, 0, 255];
const GREEN: [u8; 4] = [0, 255, 0, 255];
const BLUE: [u8; 4] = [0, 0, 255, 255];

fn graphics(control: &str, payload: &[u8]) -> String {
    format!("\x1b_G{control},q=2;{}\x1b\\", base64(payload))
}

fn read_object(name: &Name, len: usize) -> Vec<u8> {
    use std::io::Read;
    use std::os::fd::AsFd;
    let object = Named::open(name, len).unwrap();
    let (mut reader, writer) = std::io::pipe().unwrap();
    assert_eq!(object.write_to(writer.as_fd(), 0, len).unwrap(), len);
    let mut bytes = vec![0; len];
    reader.read_exact(&mut bytes).unwrap();
    bytes
}

fn unique_name() -> Name {
    let number = OBJECTS.fetch_add(1, Ordering::SeqCst);
    Name::new(&format!("/ko-e2e-{}-{number}", std::process::id())).unwrap()
}

// A t=s upload: the program names an object, and the pane's terminal reads it and unlinks it.
fn upload(s: &Server, pane: &str, control: &str, pixels: &[u8]) {
    let name = unique_name();
    let mut object = Named::create(&name, pixels.len()).unwrap();
    object.write(0, pixels).unwrap();
    s.text(
        pane,
        &graphics(&format!("{control},t=s"), name.as_str().as_bytes()),
    );
    poll("the terminal to take the object", || {
        Named::open(&name, pixels.len()).is_err()
    });
}

fn mirror(s: &Server, pane: &str) -> Terminal {
    let mut view = s.ws(&format!("/panes/{pane}/view?history=none"));
    let (data, _) = view.snapshot();
    Terminal::decode_limited(&mut &data[..], Extent::Screen, LIMIT).unwrap()
}

fn generation_of(term: &Terminal, image: u32, frame: u32) -> Option<u64> {
    term.frame(Screen::Primary, image, frame)
        .unwrap()
        .map(|frame| frame.generation)
}

fn wait_generation(s: &Server, pane: &str, image: u32, frame: u32) -> u64 {
    let mut found = None;
    poll(&format!("frame {frame} of image {image}"), || {
        found = generation_of(&mirror(s, pane), image, frame);
        found.is_some()
    });
    found.unwrap()
}

fn path(pane: &str, image: u32, frame: u32, generation: u64) -> String {
    format!("/panes/{pane}/images/{image}/frames/{frame}?generation={generation}")
}

// One GET on a connection that the caller keeps, with the body handed to the sink in pieces.
fn get(
    stream: &mut Steady,
    s: &Server,
    target: &str,
    extra: &[(&str, &str)],
    limit: Duration,
    mut sink: impl FnMut(&[u8]),
) -> Head {
    within(stream, Instant::now() + limit);
    let mut headers = s.headers();
    headers.extend(
        extra
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned())),
    );
    s.write_request(stream, "GET", target, &headers, b"");
    let mut buffer = Vec::new();
    let head = s.read_head(stream, &mut buffer);
    let Framing::Length(length) = head.framing else {
        panic!("a body of unknown length");
    };
    let mut got = buffer.len() - head.size;
    sink(&buffer[head.size..]);
    let mut chunk = vec![0u8; 1 << 20];
    while got < length {
        let count = stream.read(&mut chunk).unwrap();
        assert!(count > 0, "closed after {got} of {length} bytes");
        sink(&chunk[..count]);
        got += count;
    }
    assert_eq!(got, length, "more than the declared body");
    head
}

fn fetch(s: &Server, target: &str, extra: &[(&str, &str)]) -> (Head, Vec<u8>) {
    let mut stream = s.dial().unwrap();
    let mut body = Vec::new();
    let reply = get(&mut stream, s, target, extra, DEADLINE, |piece| {
        body.extend_from_slice(piece);
    });
    (reply, body)
}

fn shm(s: &Server, pane: &str, image: u32, frame: u32, generation: u64) -> Value {
    let (reply, body) = fetch(
        s,
        &path(pane, image, frame, generation),
        &[("Ko-Accept-Shm", "1")],
    );
    assert_eq!(reply.status, 200, "{}", String::from_utf8_lossy(&body));
    serde_json::from_slice(&body).unwrap()
}

fn object_name(shm: &Value) -> Name {
    Name::new(shm["name"].as_str().unwrap()).unwrap()
}

fn leaks(s: &Server) -> String {
    std::fs::read_to_string(s.dir.join("shm")).unwrap_or_default()
}

fn not_found(s: &Server, target: &str) {
    let (reply, body) = fetch(s, target, &[]);
    assert_eq!(reply.status, 404, "{target}");
    let error: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(error["kind"], "not_found", "{target}");
}

#[test]
fn a_t_s_image_is_fetched_by_name_and_as_a_body() {
    let s = start(&[]);
    let pane = s.echo_pane();
    let pixels = [255, 0, 0, 255, 0, 255, 0, 255];
    upload(&s, &pane, "a=T,f=32,s=2,v=1,i=5,c=2,r=1", &pixels);
    let generation = wait_generation(&s, &pane, 5, 1);

    let by_name = shm(&s, &pane, 5, 1, generation);
    assert_eq!(by_name["length"], 8);
    assert_eq!(by_name["format"], "rgba");
    assert_eq!(
        (by_name["width"].as_u64(), by_name["height"].as_u64()),
        (Some(2), Some(1))
    );
    assert_eq!(by_name["generation"], generation);
    assert_eq!(by_name["frames"], 1);
    let name = object_name(&by_name);
    assert_eq!(read_object(&name, 8), pixels);

    let (reply, body) = fetch(&s, &path(&pane, 5, 1, generation), &[]);
    assert_eq!(reply.status, 200);
    assert_eq!(
        reply.header("content-type"),
        Some("application/octet-stream")
    );
    assert_eq!(reply.header("ko-image-format"), Some("rgba"));
    assert_eq!(reply.header("ko-image-width"), Some("2"));
    assert_eq!(reply.header("ko-image-height"), Some("1"));
    assert_eq!(reply.header("ko-image-frames"), Some("1"));
    assert_eq!(
        reply.header("ko-image-generation"),
        Some(generation.to_string().as_str())
    );
    assert_eq!(body, pixels);

    not_found(&s, &path(&pane, 5, 1, generation + 1));
    not_found(&s, &path(&pane, 5, 2, generation));
    not_found(&s, &path(&pane, 6, 1, generation));
    assert!(leaks(&s).contains(name.as_str()), "{}", leaks(&s));
}

const PNG: [u8; 71] = [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 1, 8, 6, 0,
    0, 0, 244, 34, 127, 138, 0, 0, 0, 14, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 240, 31, 4,
    1, 16, 248, 3, 253, 78, 149, 193, 111, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

#[test]
fn a_png_sent_as_t_d_is_decoded_to_rgba() {
    let s = start(&[]);
    let pane = s.echo_pane();
    s.text(&pane, &graphics("a=T,f=100,t=d,i=5,c=2,r=1", &PNG));
    let generation = wait_generation(&s, &pane, 5, 1);

    let (reply, body) = fetch(&s, &path(&pane, 5, 1, generation), &[]);
    assert_eq!(reply.status, 200, "{}", String::from_utf8_lossy(&body));
    assert_eq!(reply.header("ko-image-format"), Some("rgba"));
    assert_eq!(reply.header("ko-image-width"), Some("2"));
    assert_eq!(reply.header("ko-image-height"), Some("1"));
    assert_eq!(body, [RED, GREEN].concat());
}

#[test]
fn a_frame_edit_moves_the_generation_so_the_old_object_is_gone_and_the_new_fetch_lands() {
    let s = start(&[]);
    let pane = s.echo_pane();
    s.text(&pane, &graphics("a=T,f=32,s=1,v=1,i=7,c=1,r=1", &RED));
    let before = wait_generation(&s, &pane, 7, 1);
    let first = shm(&s, &pane, 7, 1, before);
    let old = object_name(&first);
    assert_eq!(read_object(&old, 4), RED);

    s.text(&pane, &graphics("a=f,i=7,r=1,f=32,s=1,v=1", &GREEN));
    let mut after = before;
    poll("the edit to move the generation", || {
        after = wait_generation(&s, &pane, 7, 1);
        after != before
    });

    not_found(&s, &path(&pane, 7, 1, before));
    poll("the old object to be unlinked", || {
        Named::open(&old, 4).is_err()
    });
    poll("the old object to leave the record", || {
        !leaks(&s).contains(old.as_str())
    });
    let second = shm(&s, &pane, 7, 1, after);
    let new = object_name(&second);
    assert_ne!(new, old);
    assert_eq!(read_object(&new, 4), GREEN);
    let (_, body) = fetch(&s, &path(&pane, 7, 1, after), &[]);
    assert_eq!(body, GREEN);
}

#[test]
fn an_evicted_image_is_not_found_and_its_object_is_gone() {
    let s = start_serving("  kitty_images_max_bytes: 300\n");
    let pane = s.echo_pane();
    let square = vec![9u8; 256];
    s.text(&pane, &graphics("a=t,f=32,s=8,v=8,i=1", &square));
    let generation = wait_generation(&s, &pane, 1, 1);
    let name = object_name(&shm(&s, &pane, 1, 1, generation));
    assert!(Named::open(&name, 256).is_ok());

    s.text(&pane, &graphics("a=t,f=32,s=8,v=8,i=2", &square));
    wait_generation(&s, &pane, 2, 1);
    poll("the first image to be evicted", || {
        generation_of(&mirror(&s, &pane), 1, 1).is_none()
    });
    not_found(&s, &path(&pane, 1, 1, generation));
    poll("the object of the evicted image to be unlinked", || {
        Named::open(&name, 256).is_err()
    });
    poll("the evicted object to leave the record", || {
        !leaks(&s).contains(name.as_str())
    });
}

#[test]
fn a_killed_pane_process_leaves_no_object_after_the_server_cleans_up() {
    let s = start(&[]);
    let pane = s.echo_pane();
    upload(&s, &pane, "a=T,f=32,s=1,v=1,i=3,c=1,r=1", &RED);
    let generation = wait_generation(&s, &pane, 3, 1);
    let name = object_name(&shm(&s, &pane, 3, 1, generation));
    assert!(Named::open(&name, 4).is_ok());

    let process = s.pane_program(&pane).parent().expect("a pane process");
    signal_descendant(s.child.pid(), process, Signal::Kill).unwrap();
    poll(
        "the server to unlink the object of the dead pane process",
        || Named::open(&name, 4).is_err(),
    );
}

#[test]
fn a_killed_server_leaves_no_object_after_the_next_start() {
    let mut s = start(&[]);
    let pane = s.echo_pane();
    upload(&s, &pane, "a=T,f=32,s=1,v=1,i=3,c=1,r=1", &RED);
    let generation = wait_generation(&s, &pane, 3, 1);
    let name = object_name(&shm(&s, &pane, 3, 1, generation));
    let process = s.pane_program(&pane).parent().expect("a pane process");

    s.child.signal(Signal::Stop).unwrap();
    signal_descendant(s.child.pid(), process, Signal::Kill).unwrap();
    s.child.signal(Signal::Kill).unwrap();
    assert!(s.child.wait(DEADLINE).is_some());
    assert!(
        Named::open(&name, 4).is_ok(),
        "nobody was left to unlink the object"
    );
    assert!(leaks(&s).contains(name.as_str()));

    s.start_again(&[]);
    poll("the new server to unlink the leaked object", || {
        Named::open(&name, 4).is_err()
    });
}

#[test]
fn a_placement_and_its_animation_survive_detach_and_reattach() {
    let s = start(&[]);
    let pane = s.echo_pane();
    s.text(&pane, &graphics("a=T,f=32,s=1,v=1,i=1,c=1,r=1", &RED));
    s.text(&pane, &graphics("a=f,i=1,f=32,s=1,v=1,z=40", &GREEN));
    s.text(&pane, &graphics("a=f,i=1,f=32,s=1,v=1,z=40", &BLUE));
    s.text(&pane, "\x1b_Ga=a,i=1,s=3,v=1,q=2\x1b\\");
    wait_generation(&s, &pane, 1, 3);

    let seen = |term: &Terminal| {
        (
            term.placements().unwrap(),
            term.animation(Screen::Primary, 1).unwrap().unwrap(),
            (1..=3)
                .map(|frame| generation_of(term, 1, frame))
                .collect::<Vec<_>>(),
        )
    };
    let mut first = None;
    poll("the animation to run", || {
        let found = seen(&mirror(&s, &pane));
        let running = found.1.state == Playback::Running;
        first = Some(found);
        running
    });
    let first = first.unwrap();
    assert_eq!(first.0, [(1, 0)]);
    assert_eq!(first.1.frames, 3);
    assert!(first.2.iter().all(Option::is_some));

    let again = seen(&mirror(&s, &pane));
    assert_eq!(again.0, first.0);
    assert_eq!(again.1.frames, first.1.frames);
    assert_eq!(again.1.state, Playback::Running);
    assert_eq!(again.2, first.2);
}

#[test]
fn a_frame_body_of_100_mib_streams_without_closing_the_connection() {
    const SIDE: usize = 5120;
    const SIZE: usize = SIDE * SIDE * 4;
    let pattern = |at: usize| (at % 251) as u8;
    let s = start_serving("  kitty_images_max_bytes: 300000000\n");
    let pane = s.echo_pane();
    let mut frame = vec![0u8; SIZE];
    for (at, byte) in frame.iter_mut().enumerate() {
        *byte = pattern(at);
    }
    upload(
        &s,
        &pane,
        &format!("a=t,f=32,s={SIDE},v={SIDE},i=9"),
        &frame,
    );
    drop(frame);
    let generation = wait_generation(&s, &pane, 9, 1);

    let mut stream = s.dial().unwrap();
    let (mut at, mut wrong) = (0usize, None);
    let limit = Duration::from_secs(30);
    let reply = get(
        &mut stream,
        &s,
        &path(&pane, 9, 1, generation),
        &[],
        limit,
        |piece| {
            for (offset, byte) in piece.iter().enumerate() {
                if *byte != pattern(at + offset) && wrong.is_none() {
                    wrong = Some(at + offset);
                }
            }
            at += piece.len();
        },
    );
    assert_eq!(reply.status, 200);
    assert!(matches!(reply.framing, Framing::Length(SIZE)));
    assert_eq!(at, SIZE);
    assert_eq!(wrong, None, "the first wrong byte");

    let version = get(&mut stream, &s, "/version", &[], DEADLINE, |_| {});
    assert_eq!(
        version.status, 200,
        "the connection serves the next request"
    );
}

#[test]
fn a_pane_process_unlinks_its_objects_when_its_server_goes_away() {
    let mut s = start(&[]);
    let pane = s.echo_pane();
    upload(&s, &pane, "a=T,f=32,s=1,v=1,i=3,c=1,r=1", &RED);
    let generation = wait_generation(&s, &pane, 3, 1);
    let name = object_name(&shm(&s, &pane, 3, 1, generation));
    assert!(Named::open(&name, 4).is_ok());

    s.child.signal(Signal::Kill).unwrap();
    poll(
        "the pane process to unlink its object on its way out",
        || Named::open(&name, 4).is_err(),
    );
    assert!(
        leaks(&s).contains(name.as_str()),
        "the server never ran, so its record is as it was"
    );
    s.start_again(&[]);
}

#[test]
fn the_metadata_of_an_answer_is_read_fresh_from_the_terminal() {
    let s = start(&[]);
    let pane = s.echo_pane();
    s.text(&pane, &graphics("a=T,f=32,s=1,v=1,i=4,c=1,r=1", &RED));
    let generation = wait_generation(&s, &pane, 4, 1);
    let before = shm(&s, &pane, 4, 1, generation);
    assert_eq!(before["frames"], 1);

    s.text(&pane, &graphics("a=f,i=4,f=32,s=1,v=1,z=40", &GREEN));
    wait_generation(&s, &pane, 4, 2);
    let after = shm(&s, &pane, 4, 1, generation);
    assert_eq!(after["frames"], 2);
    assert_eq!(after["name"], before["name"]);
}
