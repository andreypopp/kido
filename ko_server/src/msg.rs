use std::io;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use ko_sys::event::{Interest, Poll, Timer, Token};
use ko_sys::fd;

const MAX_REPLY: usize = 64;
const READS_PER_STEP: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Error {
    Unavailable,
    Failed(String),
}

#[derive(Debug)]
pub(crate) enum Step {
    Pending,
    Done(Result<(), Error>),
}

#[derive(Debug)]
pub(crate) struct Delivery {
    path: String,
    stream: UnixStream,
    token: Token,
    timer: Timer,
    text: Vec<u8>,
    sent: usize,
    shut: bool,
    reply: Vec<u8>,
}

impl Delivery {
    pub(crate) fn start(
        poll: &mut Poll,
        path: &str,
        text: &str,
        timeout: Duration,
    ) -> Result<Delivery, Error> {
        let stream = ko_sys::sock::connect_nonblocking(Path::new(path))
            .map(UnixStream::from)
            .map_err(|_| Error::Unavailable)?;
        let timer = poll.timer();
        if poll.start(timer, timeout, None).is_err() {
            poll.free(timer);
            return Err(Error::Failed(format!("inbox {path}: bad timeout")));
        }
        Ok(Delivery {
            path: path.to_owned(),
            token: poll.watch(stream.as_fd(), Interest::Write),
            stream,
            timer,
            text: text.as_bytes().to_vec(),
            sent: 0,
            shut: false,
            reply: Vec::new(),
        })
    }

    pub(crate) fn token(&self) -> Token {
        self.token
    }

    pub(crate) fn timer(&self) -> Timer {
        self.timer
    }

    pub(crate) fn close(self, poll: &mut Poll) {
        poll.unwatch(self.token);
        poll.free(self.timer);
    }

    pub(crate) fn expire(&self) -> Step {
        self.failed(&"timed out")
    }

    fn failed(&self, why: &impl std::fmt::Display) -> Step {
        Step::Done(Err(Error::Failed(format!("inbox {}: {why}", self.path))))
    }

    pub(crate) fn step(&mut self, poll: &mut Poll) -> Step {
        while let Some(rest) = self.text.get(self.sent..).filter(|rest| !rest.is_empty()) {
            match fd::write(self.stream.as_fd(), rest) {
                Ok(count) => self.sent = self.sent.saturating_add(count),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    poll.interest(self.token, Interest::Write);
                    return Step::Pending;
                }
                Err(error) => return self.failed(&error),
            }
        }
        if !self.shut {
            self.shut = true;
            if let Err(error) = self.stream.shutdown(std::net::Shutdown::Write) {
                return self.failed(&error);
            }
        }
        poll.interest(self.token, Interest::Read);
        let mut chunk = [0u8; MAX_REPLY];
        for _ in 0..READS_PER_STEP {
            match fd::read(self.stream.as_fd(), &mut chunk) {
                Ok(0) => return self.answered(),
                Ok(count) => {
                    self.reply
                        .extend_from_slice(chunk.get(..count).unwrap_or_default());
                    if self.reply.len() > MAX_REPLY {
                        return self.failed(&format_args!("answered more than {MAX_REPLY} bytes"));
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Step::Pending,
                Err(error) => return self.failed(&error),
            }
        }
        Step::Pending
    }

    fn answered(&self) -> Step {
        let reply = String::from_utf8_lossy(&self.reply);
        if reply.trim() == "ok" {
            Step::Done(Ok(()))
        } else {
            self.failed(&format_args!("answered {:?}, want \"ok\"", reply.trim()))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::thread;

    use ko_sys::event::{Events, Mode};

    use super::*;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Scratch {
            let dir = PathBuf::from(format!("/tmp/ko-msg-{name}-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn socket(&self) -> String {
            self.0.join("inbox.sock").to_string_lossy().into_owned()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn serve(path: &str, reply: &'static str) -> thread::JoinHandle<Vec<u8>> {
        let listener = UnixListener::bind(path).unwrap();
        thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            let mut got = Vec::new();
            peer.read_to_end(&mut got).unwrap();
            peer.write_all(reply.as_bytes()).unwrap();
            got
        })
    }

    fn deliver(path: &str, text: &str, timeout: Duration) -> Result<(), Error> {
        let mut poll = Poll::new();
        let mut delivery = Delivery::start(&mut poll, path, text, timeout)?;
        let mut step = delivery.step(&mut poll);
        let mut events = Events::default();
        let result = loop {
            if let Step::Done(result) = step {
                break result;
            }
            poll.turn(Mode::Wait, &mut events).unwrap();
            step = Step::Pending;
            for &due in events.due() {
                if poll.current(due) && due.timer == delivery.timer() {
                    step = delivery.expire();
                }
            }
            for &ready in events.ready() {
                if ready.token == delivery.token() && matches!(step, Step::Pending) {
                    step = delivery.step(&mut poll);
                }
            }
        };
        delivery.close(&mut poll);
        result
    }

    #[test]
    fn the_text_arrives_whole_and_an_ok_reply_is_delivery() {
        let scratch = Scratch::new("ok");
        let path = scratch.socket();
        let text = "line one\nline two ".repeat(200_000);
        let peer = serve(&path, "ok\n");
        assert_eq!(deliver(&path, &text, Duration::from_secs(5)), Ok(()));
        assert_eq!(peer.join().unwrap(), text.as_bytes());
    }

    #[test]
    fn no_socket_is_unavailable_and_any_other_reply_is_a_failure() {
        let scratch = Scratch::new("fail");
        let path = scratch.socket();
        assert_eq!(
            deliver(&path, "x", Duration::from_secs(1)),
            Err(Error::Unavailable)
        );
        let peer = serve(&path, "busy");
        assert_eq!(
            deliver(&path, "x", Duration::from_secs(5)),
            Err(Error::Failed(format!(
                "inbox {path}: answered \"busy\", want \"ok\""
            )))
        );
        peer.join().unwrap();
    }

    #[test]
    fn a_peer_that_never_stops_sending_is_refused_at_once() {
        let scratch = Scratch::new("endless");
        let path = scratch.socket();
        let listener = UnixListener::bind(&path).unwrap();
        let peer = thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            peer.read_to_end(&mut request).unwrap();
            let chunk = [b'x'; 8192];
            while peer.write_all(&chunk).is_ok() {}
        });
        let began = std::time::Instant::now();
        assert_eq!(
            deliver(&path, "x", Duration::from_secs(5)),
            Err(Error::Failed(format!(
                "inbox {path}: answered more than {MAX_REPLY} bytes"
            )))
        );
        assert!(began.elapsed() < Duration::from_secs(2));
        peer.join().unwrap();
    }

    #[test]
    fn a_peer_that_never_answers_times_out() {
        let scratch = Scratch::new("timeout");
        let path = scratch.socket();
        let listener = UnixListener::bind(&path).unwrap();
        let (release, held) = std::sync::mpsc::channel::<()>();
        let peer = thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            let mut got = Vec::new();
            peer.read_to_end(&mut got).unwrap();
            let _ = held.recv();
            got
        });
        assert_eq!(
            deliver(&path, "x", Duration::from_millis(50)),
            Err(Error::Failed(format!("inbox {path}: timed out")))
        );
        release.send(()).unwrap();
        assert_eq!(peer.join().unwrap(), b"x");
    }
}
