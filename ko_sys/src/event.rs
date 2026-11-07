use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::io;
use std::io::Write;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::retry::check;

const MAX_READS: u8 = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Interest {
    Idle,
    /// Wants no data, but the descriptor stays in the set: a hangup or an error still reports.
    Hangup,
    Read,
    Write,
    ReadWrite,
}

impl Interest {
    pub fn of(read: bool, write: bool) -> Interest {
        match (read, write) {
            (true, true) => Interest::ReadWrite,
            (true, false) => Interest::Read,
            (false, true) => Interest::Write,
            (false, false) => Interest::Idle,
        }
    }

    pub fn reads(self) -> bool {
        matches!(self, Interest::Read | Interest::ReadWrite)
    }

    pub fn writes(self) -> bool {
        matches!(self, Interest::Write | Interest::ReadWrite)
    }

    fn events(self, hangup: libc::c_short) -> libc::c_short {
        match self {
            Interest::Idle => 0,
            Interest::Hangup => hangup,
            Interest::Read => libc::POLLIN,
            Interest::Write => libc::POLLOUT,
            Interest::ReadWrite => libc::POLLIN | libc::POLLOUT,
        }
    }
}

// A pipe that any thread can write to and that a poll loop watches. A wake
// that nobody drains stays readable, which makes it a cancellation that every
// waiter sees.
#[derive(Debug)]
pub struct Wake {
    reader: std::io::PipeReader,
    writer: std::io::PipeWriter,
    set: AtomicBool,
}

impl Wake {
    pub fn new() -> io::Result<Wake> {
        let (reader, writer) = std::io::pipe()?;
        crate::fd::set_nonblocking(reader.as_fd())?;
        crate::fd::set_nonblocking(writer.as_fd())?;
        Ok(Wake {
            reader,
            writer,
            set: AtomicBool::new(false),
        })
    }

    pub fn fd(&self) -> BorrowedFd<'_> {
        self.reader.as_fd()
    }

    // A full pipe is already readable, so a refused byte loses no wake.
    pub fn wake(&self) {
        self.set.store(true, Ordering::SeqCst);
        let _ = (&self.writer).write(&[1]);
    }

    pub fn drain(&self) {
        self.set.store(false, Ordering::SeqCst);
        let mut buffer = [0; 64];
        while matches!(crate::fd::read(self.fd(), &mut buffer), Ok(count) if count == buffer.len())
        {
        }
    }

    pub fn is_set(&self) -> bool {
        self.set.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Key {
    index: u32,
    generation: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token(Key);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timer(Key);

#[derive(Debug)]
struct Slab<T> {
    entries: Vec<(u32, Option<T>)>,
    free: Vec<u32>,
}

impl<T> Default for Slab<T> {
    fn default() -> Slab<T> {
        Slab {
            entries: Vec::new(),
            free: Vec::new(),
        }
    }
}

impl<T> Slab<T> {
    fn insert(&mut self, value: T) -> Key {
        match self.free.pop() {
            Some(index) => {
                let entry = &mut self.entries[index as usize];
                entry.1 = Some(value);
                Key {
                    index,
                    generation: entry.0,
                }
            }
            None => {
                let index = u32::try_from(self.entries.len()).unwrap_or(u32::MAX);
                self.entries.push((0, Some(value)));
                Key {
                    index,
                    generation: 0,
                }
            }
        }
    }

    fn key(&self, index: u32) -> Key {
        Key {
            index,
            generation: self.entries[index as usize].0,
        }
    }

    fn get(&self, key: Key) -> Option<&T> {
        match self.entries.get(key.index as usize)? {
            (generation, Some(value)) if *generation == key.generation => Some(value),
            _ => None,
        }
    }

    fn get_mut(&mut self, key: Key) -> Option<&mut T> {
        match self.entries.get_mut(key.index as usize)? {
            (generation, Some(value)) if *generation == key.generation => Some(value),
            _ => None,
        }
    }

    fn remove(&mut self, key: Key) -> Option<T> {
        self.get(key)?;
        let entry = &mut self.entries[key.index as usize];
        entry.0 = entry.0.wrapping_add(1);
        self.free.push(key.index);
        entry.1.take()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ready {
    pub token: Token,
    pub read: bool,
    pub write: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Due {
    pub timer: Timer,
    armed: u64,
}

#[derive(Debug, Default)]
pub struct Events {
    ready: Vec<Ready>,
    due: Vec<Due>,
}

impl Events {
    pub fn ready(&self) -> &[Ready] {
        &self.ready
    }

    pub fn due(&self) -> &[Due] {
        &self.due
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Wait,
    Peek,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Read {
    Data(usize),
    End,
}

#[derive(Debug)]
pub struct Reads {
    left: u8,
    more: bool,
}

#[derive(Debug)]
pub struct PollRead<'a> {
    poll: &'a mut Poll,
    token: Token,
    fd: BorrowedFd<'a>,
    reads: &'a mut Reads,
}

impl<'a> PollRead<'a> {
    pub fn new(
        poll: &'a mut Poll,
        token: Token,
        fd: BorrowedFd<'a>,
        reads: &'a mut Reads,
    ) -> PollRead<'a> {
        PollRead {
            poll,
            token,
            fd,
            reads,
        }
    }
}

impl io::Read for PollRead<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self.poll.read(self.token, self.fd, buffer, self.reads)? {
            None => Err(io::ErrorKind::WouldBlock.into()),
            Some(Read::Data(count)) => Ok(count),
            Some(Read::End) => Ok(0),
        }
    }
}

impl Reads {
    pub fn new() -> Reads {
        Reads {
            left: MAX_READS,
            more: true,
        }
    }
}

impl Default for Reads {
    fn default() -> Reads {
        Reads::new()
    }
}

#[derive(Debug)]
struct Source {
    fd: RawFd,
    hangup: libc::c_short,
    interest: Interest,
    slot: Option<usize>,
}

// Linux poll reports a hangup or an error whatever the events are.
#[cfg(target_os = "linux")]
fn hangup_events(_fd: RawFd) -> libc::c_short {
    0
}

// macOS poll reports a hangup only for a descriptor that asks for an event that it cannot have
// yet: POLLOUT on a pipe's read end, POLLPRI on a pipe's write end or a socket (measured: they
// report nothing while the peer is open, with data unread or not).
#[cfg(target_os = "macos")]
fn hangup_events(fd: RawFd) -> libc::c_short {
    // SAFETY: F_GETFL only reads the flags of the descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags >= 0 && flags & libc::O_ACCMODE == libc::O_RDONLY {
        libc::POLLOUT
    } else {
        libc::POLLPRI
    }
}

#[derive(Debug)]
struct Clock {
    armed: u64,
    active: bool,
    repeat: Option<Duration>,
}

#[derive(Debug, Default)]
pub struct Poll {
    sources: Slab<Source>,
    fds: Vec<libc::pollfd>,
    owners: Vec<u32>,
    clocks: Slab<Clock>,
    heap: BinaryHeap<Reverse<(Instant, u64, u32)>>,
    arms: u64,
}

// macOS poll takes whole milliseconds, so sub-ms waits round up; select takes microseconds.
// Select only waits. A first poll detects pending hangups that the sets cannot express;
// a poll after readiness reports revents. Descriptors at or above FD_SETSIZE use poll.
#[cfg(target_os = "macos")]
fn wait_for(
    fds: &mut [libc::pollfd],
    count: libc::nfds_t,
    timeout: Option<Duration>,
) -> io::Result<libc::c_int> {
    if let Some(left) = timeout.filter(|left| {
        !left.is_zero()
            && *left < Duration::from_millis(1)
            && fds
                .iter()
                .all(|fd| usize::try_from(fd.fd).map_or(true, |fd| fd < libc::FD_SETSIZE))
    }) {
        // SAFETY: fds holds count initialized pollfd entries.
        let ready = check(unsafe { libc::poll(fds.as_mut_ptr(), count, 0) })?;
        if ready != 0 {
            return Ok(ready);
        }
        // SAFETY: a zeroed fd_set has no descriptors set.
        let (mut reads, mut writes): (libc::fd_set, libc::fd_set) = unsafe { std::mem::zeroed() };
        let mut highest = 0;
        for fd in fds.iter().filter(|fd| fd.fd >= 0) {
            highest = highest.max(fd.fd + 1);
            // SAFETY: fd is nonnegative and below FD_SETSIZE; both sets are initialized.
            unsafe {
                if fd.events & libc::POLLIN != 0 {
                    libc::FD_SET(fd.fd, &mut reads);
                }
                if fd.events & libc::POLLOUT != 0 {
                    libc::FD_SET(fd.fd, &mut writes);
                }
            }
        }
        let mut limit = libc::timeval {
            tv_sec: 0,
            tv_usec: left.subsec_nanos().div_ceil(1000) as libc::suseconds_t,
        };
        // SAFETY: the sets contain only open descriptors below highest; limit is valid.
        if check(unsafe {
            libc::select(
                highest,
                &mut reads,
                &mut writes,
                std::ptr::null_mut(),
                &mut limit,
            )
        })? == 0
        {
            return Ok(0);
        }
        // SAFETY: fds holds count initialized pollfd entries.
        return check(unsafe { libc::poll(fds.as_mut_ptr(), count, 0) });
    }
    let millis = timeout.map_or(-1, |left| {
        let millis = left.as_nanos().div_ceil(1_000_000);
        libc::c_int::try_from(millis).unwrap_or(libc::c_int::MAX)
    });
    // SAFETY: fds holds count initialized pollfd entries.
    check(unsafe { libc::poll(fds.as_mut_ptr(), count, millis) })
}

#[cfg(target_os = "linux")]
fn wait_for(
    fds: &mut [libc::pollfd],
    count: libc::nfds_t,
    timeout: Option<Duration>,
) -> io::Result<libc::c_int> {
    let limit = timeout.map(|left| libc::timespec {
        tv_sec: left.as_secs().try_into().unwrap_or(i64::MAX),
        tv_nsec: libc::c_long::from(left.subsec_nanos()),
    });
    // SAFETY: fds holds count initialized pollfd entries; the timeout is null or one timespec.
    check(unsafe {
        libc::ppoll(
            fds.as_mut_ptr(),
            count,
            limit.as_ref().map_or(std::ptr::null(), std::ptr::from_ref),
            std::ptr::null(),
        )
    })
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

impl Poll {
    pub fn new() -> Poll {
        Poll::default()
    }

    pub fn watch(&mut self, fd: BorrowedFd<'_>, interest: Interest) -> Token {
        let token = Token(self.sources.insert(Source {
            fd: fd.as_raw_fd(),
            hangup: hangup_events(fd.as_raw_fd()),
            interest: Interest::Idle,
            slot: None,
        }));
        self.interest(token, interest);
        token
    }

    pub fn interest_of(&self, token: Token) -> Interest {
        self.sources
            .get(token.0)
            .map_or(Interest::Idle, |source| source.interest)
    }

    pub fn interest(&mut self, token: Token, interest: Interest) {
        let Some(source) = self.sources.get_mut(token.0) else {
            return;
        };
        source.interest = interest;
        match (source.slot, interest) {
            (None, Interest::Idle) => {}
            (Some(slot), Interest::Idle) => {
                source.slot = None;
                self.fds.swap_remove(slot);
                self.owners.swap_remove(slot);
                if let Some(&moved) = self.owners.get(slot) {
                    let key = self.sources.key(moved);
                    if let Some(moved) = self.sources.get_mut(key) {
                        moved.slot = Some(slot);
                    }
                }
            }
            (Some(slot), _) => self.fds[slot].events = interest.events(source.hangup),
            (None, _) => {
                source.slot = Some(self.fds.len());
                self.fds.push(libc::pollfd {
                    fd: source.fd,
                    events: interest.events(source.hangup),
                    revents: 0,
                });
                self.owners.push(token.0.index);
            }
        }
    }

    pub fn unwatch(&mut self, token: Token) {
        self.interest(token, Interest::Idle);
        self.sources.remove(token.0);
    }

    pub fn wants(&self, ready: Ready) -> Ready {
        let interest = self.interest_of(ready.token);
        Ready {
            token: ready.token,
            read: ready.read && interest.reads(),
            write: ready.write && interest.writes(),
        }
    }

    pub fn read(
        &mut self,
        token: Token,
        fd: BorrowedFd<'_>,
        window: &mut [u8],
        reads: &mut Reads,
    ) -> io::Result<Option<Read>> {
        let Some(source) = self.sources.get(token.0) else {
            return Ok(None);
        };
        if source.fd != fd.as_raw_fd() {
            return Err(invalid("a read from another descriptor than the source's"));
        }
        let interest = source.interest;
        if !reads.more || reads.left == 0 || !interest.reads() {
            return Ok(None);
        }
        if window.is_empty() {
            reads.more = false;
            return Err(invalid("a read into a full window"));
        }
        reads.left -= 1;
        match crate::fd::read(fd, window) {
            Ok(0) => {
                reads.more = false;
                self.interest(token, Interest::of(false, interest.writes()));
                Ok(Some(Read::End))
            }
            Ok(count) => {
                reads.more = count == window.len();
                Ok(Some(Read::Data(count)))
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                reads.more = false;
                Ok(None)
            }
            Err(error) => {
                reads.more = false;
                Err(error)
            }
        }
    }

    pub fn timer(&mut self) -> Timer {
        Timer(self.clocks.insert(Clock {
            armed: 0,
            active: false,
            repeat: None,
        }))
    }

    pub fn is_active(&self, timer: Timer) -> bool {
        self.clocks.get(timer.0).is_some_and(|clock| clock.active)
    }

    pub fn current(&self, due: Due) -> bool {
        self.clocks
            .get(due.timer.0)
            .is_some_and(|clock| clock.armed == due.armed)
    }

    pub fn start(
        &mut self,
        timer: Timer,
        after: Duration,
        repeat: Option<Duration>,
    ) -> io::Result<()> {
        if repeat == Some(Duration::ZERO) {
            return Err(invalid("a timer that repeats without a period"));
        }
        let due = Instant::now()
            .checked_add(after)
            .ok_or_else(|| invalid("a timer due beyond the clock"))?;
        self.arms += 1;
        let armed = self.arms;
        let Some(clock) = self.clocks.get_mut(timer.0) else {
            return Ok(());
        };
        *clock = Clock {
            armed,
            active: true,
            repeat,
        };
        self.heap.push(Reverse((due, armed, timer.0.index)));
        Ok(())
    }

    pub fn stop(&mut self, timer: Timer) {
        self.arms += 1;
        if let Some(clock) = self.clocks.get_mut(timer.0) {
            clock.armed = self.arms;
            clock.active = false;
        }
    }

    pub fn free(&mut self, timer: Timer) {
        self.clocks.remove(timer.0);
    }

    fn next_due(&mut self) -> Option<Instant> {
        while let Some(&Reverse((due, armed, index))) = self.heap.peek() {
            let key = self.clocks.key(index);
            match self.clocks.get(key) {
                Some(clock) if clock.active && clock.armed == armed => return Some(due),
                _ => {
                    self.heap.pop();
                }
            }
        }
        None
    }

    pub fn turn(&mut self, mode: Mode, events: &mut Events) -> io::Result<()> {
        events.ready.clear();
        events.due.clear();
        let next = self.next_due();
        if !self.fds.is_empty() || (mode == Mode::Wait && next.is_some()) {
            let timeout = match (mode, next) {
                (Mode::Peek, _) => Some(Duration::ZERO),
                (Mode::Wait, None) => None,
                (Mode::Wait, Some(due)) => Some(due.saturating_duration_since(Instant::now())),
            };
            let count = libc::nfds_t::try_from(self.fds.len()).unwrap_or(libc::nfds_t::MAX);
            match wait_for(&mut self.fds, count, timeout) {
                Ok(found) => self.collect(found, events),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        }
        self.expire(Instant::now(), events);
        Ok(())
    }

    fn collect(&self, found: libc::c_int, events: &mut Events) {
        let failed = libc::POLLERR | libc::POLLHUP | libc::POLLNVAL;
        let found = usize::try_from(found).unwrap_or(0);
        for (fd, &owner) in self.fds.iter().zip(&self.owners) {
            if events.ready.len() == found {
                break;
            }
            if fd.revents != 0 {
                events.ready.push(Ready {
                    token: Token(self.sources.key(owner)),
                    read: fd.revents & (libc::POLLIN | failed) != 0,
                    write: fd.revents & (libc::POLLOUT | failed) != 0,
                });
            }
        }
    }

    fn expire(&mut self, now: Instant, events: &mut Events) {
        while let Some(due) = self.next_due().filter(|&due| due <= now) {
            let Some(Reverse((_, armed, index))) = self.heap.pop() else {
                break;
            };
            let key = self.clocks.key(index);
            events.due.push(Due {
                timer: Timer(key),
                armed,
            });
            let Some(clock) = self.clocks.get_mut(key) else {
                continue;
            };
            let next = clock.repeat.and_then(|period| {
                due.checked_add(period)
                    .filter(|&next| next > now)
                    .or_else(|| now.checked_add(period))
            });
            match next {
                Some(next) => self.heap.push(Reverse((next, armed, index))),
                None => clock.active = false,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::fd::AsFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn a_fine_deadline_does_not_treat_unread_data_as_a_hangup() {
        let (a, mut b) = UnixStream::pair().unwrap();
        b.write_all(b"buffered").unwrap();
        let mut poll = Poll::new();
        poll.watch(a.as_fd(), Interest::Hangup);
        let timer = poll.timer();
        poll.start(timer, Duration::from_micros(500), None).unwrap();
        let mut events = Events::default();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(Instant::now() < deadline);
            poll.turn(Mode::Wait, &mut events).unwrap();
            assert!(events.ready().is_empty());
            if events.due().iter().any(|due| due.timer == timer) {
                break;
            }
        }
    }

    #[test]
    fn a_wake_makes_a_watched_pipe_readable_from_another_thread_until_it_is_drained() {
        let _serial = crate::signal::SERIAL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let wake = std::sync::Arc::new(Wake::new().unwrap());
        let mut poll = Poll::new();
        let mut events = Events::default();
        let token = poll.watch(wake.fd(), Interest::Read);
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert!(events.ready().is_empty() && !wake.is_set());
        let waker = std::sync::Arc::clone(&wake);
        std::thread::spawn(move || {
            waker.wake();
            waker.wake();
        })
        .join()
        .unwrap();
        poll.turn(Mode::Wait, &mut events).unwrap();
        assert_eq!(
            events.ready(),
            [Ready {
                token,
                read: true,
                write: false
            }]
        );
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert!(wake.is_set() && !events.ready().is_empty());
        wake.drain();
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert!(!wake.is_set() && events.ready().is_empty());
    }

    #[test]
    fn a_turn_returns_when_nothing_can_wake_it() {
        let mut poll = Poll::new();
        let mut events = Events::default();
        poll.turn(Mode::Wait, &mut events).unwrap();
        let (read, _write) = std::io::pipe().unwrap();
        let token = poll.watch(read.as_fd(), Interest::Idle);
        poll.turn(Mode::Wait, &mut events).unwrap();
        poll.unwatch(token);
        assert!(events.ready().is_empty() && events.due().is_empty());
    }

    #[test]
    fn a_hangup_interest_reports_a_closed_peer_even_with_data_unread() {
        use std::io::Write;
        let mut poll = Poll::new();
        let mut events = Events::default();
        let (read, mut write) = std::io::pipe().unwrap();
        let (read_end, write_end) = std::io::pipe().unwrap();
        let reading = poll.watch(read.as_fd(), Interest::Hangup);
        let writing = poll.watch(write_end.as_fd(), Interest::Hangup);
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert!(events.ready().is_empty());
        write.write_all(b"unread").unwrap();
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert!(events.ready().is_empty(), "data alone is not a hangup");
        // A spawn in another test thread can hold a peer open for a while.
        drop((write, read_end));
        let limit = poll.timer();
        poll.start(limit, Duration::from_secs(5), None).unwrap();
        let mut seen: Vec<Token> = Vec::new();
        while seen.len() < 2 && events.due().is_empty() {
            poll.turn(Mode::Wait, &mut events).unwrap();
            for ready in events.ready() {
                if !seen.contains(&ready.token) {
                    seen.push(ready.token);
                }
            }
            for ready in events.ready() {
                poll.interest(ready.token, Interest::Idle);
            }
        }
        seen.sort_by_key(|token| token == &writing);
        assert_eq!(seen, [reading, writing]);
    }

    #[test]
    fn timers_fire_in_due_order_repeat_and_cancel() {
        let mut poll = Poll::new();
        let mut events = Events::default();
        let late = poll.timer();
        let early = poll.timer();
        let tick = poll.timer();
        let cancelled = poll.timer();
        let ms = Duration::from_millis;
        poll.start(late, ms(120), None).unwrap();
        poll.start(early, ms(20), None).unwrap();
        poll.start(tick, ms(50), Some(ms(50))).unwrap();
        poll.start(cancelled, ms(10), None).unwrap();
        poll.stop(cancelled);
        let names = [
            (late, "late"),
            (early, "early"),
            (tick, "tick"),
            (cancelled, "cancelled"),
        ];
        let mut log = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(5);
        while log.iter().filter(|name| **name == "tick").count() < 3 && Instant::now() < deadline {
            poll.turn(Mode::Wait, &mut events).unwrap();
            for &due in events.due() {
                if poll.current(due) {
                    log.extend(
                        names
                            .iter()
                            .filter(|(t, _)| *t == due.timer)
                            .map(|(_, n)| *n),
                    );
                }
            }
        }
        poll.stop(tick);
        assert_eq!(log.join(" "), "early tick tick late tick");
        assert_eq!((poll.is_active(late), poll.is_active(tick)), (false, false));
        assert_eq!(
            poll.start(tick, ms(1), Some(Duration::ZERO))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
        assert!(poll.start(tick, Duration::MAX, None).is_err());
    }

    #[test]
    fn a_deadline_wakes_and_a_sub_millisecond_one_wakes_once() {
        let _serial = crate::signal::SERIAL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut poll = Poll::new();
        let mut events = Events::default();
        let timer = poll.timer();
        let start = Instant::now();
        poll.start(timer, Duration::from_millis(50), None).unwrap();
        while poll.is_active(timer) {
            assert!(start.elapsed() < Duration::from_secs(5));
            poll.turn(Mode::Wait, &mut events).unwrap();
        }
        assert!(start.elapsed() >= Duration::from_millis(50));
        assert_eq!(events.due().len(), 1);
        poll.start(timer, Duration::from_micros(400), None).unwrap();
        let mut turns = 0;
        while poll.is_active(timer) {
            poll.turn(Mode::Wait, &mut events).unwrap();
            turns += 1;
        }
        assert_eq!(turns, 1);
    }

    #[test]
    fn a_peer_reset_is_the_end_of_the_source() {
        let _serial = crate::signal::SERIAL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (mut a, b) = UnixStream::pair().unwrap();
        a.set_nonblocking(true).unwrap();
        a.write_all(b"unread").unwrap();
        drop(b);
        let mut poll = Poll::new();
        let mut events = Events::default();
        let token = poll.watch(a.as_fd(), Interest::Read);
        poll.turn(Mode::Wait, &mut events).unwrap();
        assert_eq!(events.ready().len(), 1);
        let read = poll.read(token, a.as_fd(), &mut [0; 8], &mut Reads::new());
        assert_eq!(read.unwrap(), Some(Read::End));
        assert_eq!(poll.interest_of(token), Interest::Idle);
    }

    #[test]
    fn a_stream_reads_up_to_the_bound_per_turn_and_reports_the_end_once() {
        let (a, mut b) = UnixStream::pair().unwrap();
        a.set_nonblocking(true).unwrap();
        let mut poll = Poll::new();
        let mut events = Events::default();
        b.write_all(&[b'x'; 100]).unwrap();
        let token = poll.watch(a.as_fd(), Interest::Read);
        let mut window = [0u8; 4];
        let (mut reads, mut ends) = (0, 0);
        let mut turn = |poll: &mut Poll, events: &mut Events, mode| {
            poll.turn(mode, events).unwrap();
            for &ready in events.ready() {
                if poll.wants(ready).read {
                    let mut budget = Reads::new();
                    while let Some(read) = poll
                        .read(token, a.as_fd(), &mut window, &mut budget)
                        .unwrap()
                    {
                        match read {
                            Read::Data(_) => reads += 1,
                            Read::End => ends += 1,
                        }
                    }
                }
            }
            (reads, ends)
        };
        assert_eq!(turn(&mut poll, &mut events, Mode::Peek), (16, 0));
        turn(&mut poll, &mut events, Mode::Peek);
        assert_eq!(turn(&mut poll, &mut events, Mode::Peek), (25, 0));
        drop(b);
        // A child that another test spawns can inherit b before std marks it close-on-exec.
        let deadline = poll.timer();
        poll.start(deadline, Duration::from_secs(5), None).unwrap();
        while turn(&mut poll, &mut events, Mode::Wait).1 == 0 && poll.is_active(deadline) {}
        poll.stop(deadline);
        assert_eq!(turn(&mut poll, &mut events, Mode::Peek), (25, 1));
    }

    #[test]
    fn a_window_filled_exactly_is_not_a_close() {
        let (a, mut b) = UnixStream::pair().unwrap();
        a.set_nonblocking(true).unwrap();
        let mut poll = Poll::new();
        let mut events = Events::default();
        let token = poll.watch(a.as_fd(), Interest::Read);
        b.write_all(&[7u8; 64]).unwrap();
        let mut window = [0u8; 64];
        let mut seen = Vec::new();
        poll.turn(Mode::Peek, &mut events).unwrap();
        let mut budget = Reads::new();
        while let Some(read) = poll
            .read(token, a.as_fd(), &mut window, &mut budget)
            .unwrap()
        {
            seen.push(read);
        }
        assert_eq!(seen, [Read::Data(64)]);
        assert_eq!(poll.interest_of(token), Interest::Read);
        let error = poll
            .read(token, b.as_fd(), &mut window, &mut Reads::new())
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    type Pipes = Vec<(std::io::PipeReader, std::io::PipeWriter)>;

    fn readable_pipes(poll: &mut Poll, count: usize) -> (Vec<Token>, Pipes) {
        let mut tokens = Vec::new();
        let mut pipes = Vec::new();
        for _ in 0..count {
            let (read, mut write) = std::io::pipe().unwrap();
            write.write_all(b"x").unwrap();
            tokens.push(poll.watch(read.as_fd(), Interest::Read));
            pipes.push((read, write));
        }
        (tokens, pipes)
    }

    #[test]
    fn sources_added_in_a_dispatch_do_not_hide_the_rest_of_the_batch() {
        let mut poll = Poll::new();
        let mut events = Events::default();
        let (tokens, _pipes) = readable_pipes(&mut poll, 2);
        let extra: Vec<_> = (0..100).map(|_| std::io::pipe().unwrap()).collect();
        poll.turn(Mode::Peek, &mut events).unwrap();
        let mut ran = Vec::new();
        for &ready in events.ready() {
            if !poll.wants(ready).read {
                continue;
            }
            let which = tokens.iter().position(|&t| t == ready.token).unwrap();
            ran.push(which);
            poll.interest(ready.token, Interest::Idle);
            if which == 0 {
                for (read, _) in &extra {
                    poll.watch(read.as_fd(), Interest::Read);
                }
            }
        }
        ran.sort();
        assert_eq!(ran, [0, 1]);
    }

    #[test]
    fn an_interest_change_takes_effect_in_the_same_batch_and_the_next_turn() {
        let mut poll = Poll::new();
        let mut events = Events::default();
        let (tokens, _pipes) = readable_pipes(&mut poll, 2);
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert_eq!(events.ready().len(), 2);
        let mut dispatched = 0;
        for &ready in events.ready() {
            if poll.wants(ready).read {
                dispatched += 1;
                for &token in &tokens {
                    poll.interest(token, Interest::Idle);
                }
            }
        }
        assert_eq!(dispatched, 1);
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert!(events.ready().is_empty());
        poll.interest(tokens[1], Interest::Read);
        poll.turn(Mode::Peek, &mut events).unwrap();
        assert_eq!(
            events.ready(),
            [Ready {
                token: tokens[1],
                read: true,
                write: false
            }]
        );
    }

    #[test]
    fn a_stale_token_gets_no_events() {
        let mut poll = Poll::new();
        let mut events = Events::default();
        let (tokens, pipes) = readable_pipes(&mut poll, 1);
        poll.turn(Mode::Peek, &mut events).unwrap();
        poll.unwatch(tokens[0]);
        poll.watch(pipes[0].0.as_fd(), Interest::Read);
        let stale = events.ready()[0];
        assert_eq!(stale.token, tokens[0]);
        assert!(!poll.wants(stale).read);
    }
}
