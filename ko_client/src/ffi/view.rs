use std::collections::VecDeque;
use std::ffi::{c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;

use ko_pane_wire::frame::History;
use ko_sys::event::Wake;
use ko_wire::ids::PaneId;
use ko_wire::protocol::{Images, Marker, ViewOptions};
use tungstenite::Bytes;

use crate::wire::Resume;

use super::{Command, FeedFn, FeedItem, Posted, RestoreFn, Shared, User, ViewEvent, locked, post};

const HIGH_WATER: usize = 4 << 20;
const LOW_WATER: usize = 1 << 20;
const FEED_BATCH: usize = 64 << 10;
const QUEUED_LIMIT: usize = 4 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Restored {
    Ok = 0,
    Rejected = 1,
    HistoryIncomplete = 2,
}

impl Restored {
    fn of(code: c_int) -> Restored {
        match code {
            0 => Restored::Ok,
            2 => Restored::HistoryIncomplete,
            _ => Restored::Rejected,
        }
    }
}

#[repr(C)]
pub struct Snapshot {
    pub read: unsafe extern "C" fn(*mut c_void, *mut u8, usize, *mut usize) -> bool,
    pub reader: *mut c_void,
    pub history: bool,
    pub continuation_max_bytes: usize,
    pub generation: u64,
    pub offset: u64,
}

#[derive(Debug, Default)]
struct Slices {
    queue: VecDeque<Bytes>,
    pending: usize,
    last: bool,
    cancelled: bool,
    #[cfg(test)]
    peak: usize,
}

#[derive(Debug, Default)]
pub(super) struct Stream {
    slices: Mutex<Slices>,
    arrived: Condvar,
}

impl Stream {
    fn push(&self, body: Bytes, last: bool, pause: &AtomicBool) {
        let mut slices = locked(&self.slices);
        if slices.cancelled {
            return;
        }
        slices.pending += body.len();
        slices.queue.push_back(body);
        slices.last |= last;
        #[cfg(test)]
        {
            slices.peak = slices.peak.max(slices.pending);
        }
        if slices.pending >= HIGH_WATER {
            pause.store(true, Ordering::SeqCst);
        }
        drop(slices);
        self.arrived.notify_all();
    }

    fn cancel(&self) {
        locked(&self.slices).cancelled = true;
        self.arrived.notify_all();
    }

    // None: cancelled. Some(0): the last slice was read.
    fn read(&self, out: &mut [u8], pause: &AtomicBool, inbox: &Wake) -> Option<usize> {
        let mut slices = locked(&self.slices);
        loop {
            if slices.cancelled {
                return None;
            }
            if let Some(front) = slices.queue.front_mut() {
                let count = front.len().min(out.len());
                let taken = front.split_to(count);
                if let Some(target) = out.get_mut(..count) {
                    target.copy_from_slice(&taken);
                }
                if front.is_empty() {
                    slices.queue.pop_front();
                }
                slices.pending = slices.pending.saturating_sub(count);
                if slices.pending < LOW_WATER && pause.swap(false, Ordering::SeqCst) {
                    inbox.wake();
                }
                return Some(count);
            }
            if slices.last {
                return Some(0);
            }
            slices = self
                .arrived
                .wait(slices)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }
}

#[derive(Debug)]
struct Job {
    generation: u64,
    history: bool,
    continuation: usize,
    offset: u64,
    stream: Arc<Stream>,
}

// What the decoder thread applies to the surface, in the order the server sent it.
#[derive(Debug)]
pub(super) enum Feed {
    Bytes { offset: u64, data: Bytes },
    Marker { offset: u64, marker: Marker },
}

#[derive(Debug)]
enum Work {
    Snapshot(Job),
    Feed(Feed),
}

#[derive(Debug)]
struct State {
    generation: u64,
    work: VecDeque<Work>,
    current: Option<Arc<Stream>>,
    skipping: bool,
    resume: Resume,
    queued: usize,
}

#[derive(Debug)]
pub(super) struct View {
    pub(super) id: u64,
    pub(super) pane: PaneId,
    pub(super) options: Mutex<ViewOptions>,
    pub(super) user: User,
    pub(super) up: AtomicBool,
    pub(super) closed: AtomicBool,
    pub(super) pause: AtomicBool,
    shared: Arc<Shared>,
    restore: RestoreFn,
    feed: FeedFn,
    state: Mutex<State>,
    changed: Condvar,
    decoder: Mutex<Option<JoinHandle<()>>>,
}

pub(super) struct Slice {
    pub(super) first: bool,
    pub(super) last: bool,
    pub(super) history: bool,
    pub(super) offset: u64,
    pub(super) continuation: usize,
}

struct Reader<'a> {
    view: &'a View,
    stream: &'a Stream,
}

unsafe extern "C" fn read_stream(
    reader: *mut c_void,
    buffer: *mut u8,
    capacity: usize,
    out: *mut usize,
) -> bool {
    if reader.is_null() || out.is_null() || (buffer.is_null() && capacity > 0) {
        return false;
    }
    // SAFETY: reader is the Reader that decode keeps on its stack for the whole
    // restore call, which is the only time the app may use it.
    let reader = unsafe { &*reader.cast::<Reader<'_>>() };
    let window = if capacity == 0 {
        &mut []
    } else {
        // SAFETY: the caller promises that buffer is writable for capacity bytes.
        unsafe { std::slice::from_raw_parts_mut(buffer, capacity) }
    };
    match reader
        .stream
        .read(window, &reader.view.pause, &reader.view.shared.wake)
    {
        Some(count) => {
            // SAFETY: out is non-null and writable by contract.
            unsafe { *out = count };
            true
        }
        None => false,
    }
}

impl View {
    pub(super) fn start(
        shared: &Arc<Shared>,
        id: u64,
        pane: PaneId,
        history: History,
        callbacks: (RestoreFn, FeedFn),
        user: User,
    ) -> std::io::Result<Arc<View>> {
        let view = Arc::new(View {
            id,
            pane,
            options: Mutex::new(ViewOptions {
                history,
                images: Images::None,
            }),
            user,
            up: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            pause: AtomicBool::new(false),
            shared: Arc::clone(shared),
            restore: callbacks.0,
            feed: callbacks.1,
            state: Mutex::new(State {
                generation: 0,
                work: VecDeque::new(),
                current: None,
                skipping: false,
                resume: Resume::default(),
                queued: 0,
            }),
            changed: Condvar::new(),
            decoder: Mutex::new(None),
        });
        let worker = Arc::clone(&view);
        let handle = std::thread::Builder::new()
            .name("ko-view-decoder".to_owned())
            .spawn(move || worker.decode())?;
        *locked(&view.decoder) = Some(handle);
        Ok(view)
    }

    fn decode(self: &Arc<View>) {
        let mut batch = Vec::new();
        let mut records = Vec::new();
        loop {
            let work = {
                let mut state = locked(&self.state);
                loop {
                    if self.closed.load(Ordering::SeqCst) {
                        return;
                    }
                    if let Some(work) = state.work.pop_front() {
                        if matches!(work, Work::Snapshot(_)) {
                            state.skipping = false;
                        }
                        break work;
                    }
                    state = self
                        .changed
                        .wait(state)
                        .unwrap_or_else(PoisonError::into_inner);
                }
            };
            match work {
                Work::Snapshot(job) => self.restore(&job),
                Work::Feed(feed) => self.apply(&feed, &mut batch, &mut records),
            }
        }
    }

    fn restore(self: &Arc<View>, job: &Job) {
        let reader = Reader {
            view: self,
            stream: &job.stream,
        };
        let snapshot = Snapshot {
            read: read_stream,
            reader: std::ptr::from_ref(&reader).cast_mut().cast(),
            history: job.history,
            continuation_max_bytes: job.continuation,
            generation: job.generation,
            offset: job.offset,
        };
        // SAFETY: the app promised at ko_view_open that restore accepts this user
        // pointer and a snapshot that is valid until it returns.
        let result = Restored::of(unsafe { (self.restore)(self.user.0, &snapshot) });
        job.stream.cancel();
        let mut state = locked(&self.state);
        if state.generation != job.generation || self.closed.load(Ordering::SeqCst) {
            return;
        }
        let ok = result == Restored::Ok;
        state.skipping = !ok;
        if ok && job.history {
            state.resume.at(job.offset);
        } else {
            state.resume.clear();
        }
        post(
            &self.shared,
            Posted::View(
                Arc::clone(self),
                ViewEvent::Restored {
                    generation: job.generation,
                    result,
                },
            ),
        );
        drop(state);
        if result == Restored::HistoryIncomplete {
            self.resync(History::All);
        }
    }

    fn apply(&self, feed: &Feed, batch: &mut Vec<u8>, records: &mut Vec<Bytes>) {
        batch.clear();
        records.clear();
        let (offset, data) = match feed {
            Feed::Bytes { offset, data } => {
                let mut end = offset.saturating_add(data.len() as u64);
                let mut len = data.len();
                {
                    let mut state = locked(&self.state);
                    while let Some(Work::Feed(Feed::Bytes {
                        offset: next,
                        data: more,
                    })) = state.work.front()
                    {
                        if *next != end || len.saturating_add(more.len()) > FEED_BATCH {
                            break;
                        }
                        let Some(Work::Feed(Feed::Bytes { data: more, .. })) =
                            state.work.pop_front()
                        else {
                            break;
                        };
                        len = len.saturating_add(more.len());
                        end = end.saturating_add(more.len() as u64);
                        records.push(more);
                    }
                }
                let data = if records.is_empty() {
                    data.as_ref()
                } else {
                    batch.extend_from_slice(data);
                    for record in records.iter() {
                        batch.extend_from_slice(record);
                    }
                    batch.as_slice()
                };
                (*offset, data)
            }
            Feed::Marker { offset, .. } => (*offset, &[][..]),
        };
        let bytes = data.len();
        if !locked(&self.state).skipping && !self.closed.load(Ordering::SeqCst) {
            let item = match feed {
                Feed::Bytes { offset, .. } => FeedItem {
                    kind: 1,
                    offset: *offset,
                    data: data.as_ptr(),
                    len: data.len(),
                    cols: 0,
                    rows: 0,
                },
                Feed::Marker {
                    offset,
                    marker: Marker::Resize(size),
                } => FeedItem {
                    kind: 2,
                    offset: *offset,
                    data: std::ptr::null(),
                    len: 0,
                    cols: size.0.cols.get(),
                    rows: size.0.rows.get(),
                },
                Feed::Marker { offset, .. } => FeedItem {
                    kind: 3,
                    offset: *offset,
                    data: std::ptr::null(),
                    len: 0,
                    cols: 0,
                    rows: 0,
                },
            };
            // SAFETY: the app promised at ko_view_open that feed accepts this user pointer
            // and an item that is valid until it returns.
            unsafe { (self.feed)(self.user.0, &item) };
        }
        let mut state = locked(&self.state);
        state.queued = state.queued.saturating_sub(bytes);
        if !state.skipping && bytes > 0 {
            state.resume.advance(offset.saturating_add(bytes as u64));
        }
        if state.queued < LOW_WATER && self.pause.swap(false, Ordering::SeqCst) {
            self.shared.wake.wake();
        }
    }

    pub(super) fn resync(&self, history: History) {
        let options = ViewOptions {
            history,
            images: Images::None,
        };
        *locked(&self.options) = options;
        self.shared.command(Command::Resync(self.id, options));
    }

    pub(super) fn slice(self: &Arc<View>, slice: &Slice, body: Bytes) -> Result<(), &'static str> {
        let mut state = locked(&self.state);
        if slice.first {
            if let Some(old) = state.current.take() {
                old.cancel();
            }
            state.work.clear();
            state.queued = 0;
            state.generation += 1;
            state.resume.clear();
            self.pause.store(false, Ordering::SeqCst);
            let stream = Arc::new(Stream::default());
            state.current = Some(Arc::clone(&stream));
            let job = Job {
                generation: state.generation,
                history: slice.history,
                continuation: slice.continuation,
                offset: slice.offset,
                stream,
            };
            state.work.push_back(Work::Snapshot(job));
            self.changed.notify_all();
        }
        let stream = state
            .current
            .clone()
            .ok_or("snapshot missing first slice")?;
        drop(state);
        stream.push(body, slice.last, &self.pause);
        Ok(())
    }

    pub(super) fn feed(&self, feed: Feed) {
        let mut state = locked(&self.state);
        if let Feed::Bytes { data, .. } = &feed {
            state.queued += data.len();
            if state.queued >= QUEUED_LIMIT {
                self.pause.store(true, Ordering::SeqCst);
            }
        }
        state.work.push_back(Work::Feed(feed));
        self.changed.notify_all();
    }

    #[cfg(test)]
    pub(super) fn peak(&self) -> usize {
        locked(&self.state)
            .current
            .as_ref()
            .map_or(0, |stream| locked(&stream.slices).peak)
    }

    #[cfg(test)]
    pub(super) fn queued(&self) -> usize {
        locked(&self.state).queued
    }

    #[cfg(test)]
    pub(super) fn generation(&self) -> u64 {
        locked(&self.state).generation
    }

    pub(super) fn resume_offset(&self) -> Option<u64> {
        locked(&self.state).resume.offset()
    }

    pub(super) fn abandon(&self) {
        let mut state = locked(&self.state);
        if let Some(stream) = state.current.take() {
            stream.cancel();
        }
        state.work.clear();
        state.queued = 0;
        state.generation += 1;
        state.skipping = false;
        self.pause.store(false, Ordering::SeqCst);
    }

    pub(super) fn shut(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.up.store(false, Ordering::SeqCst);
        self.abandon();
        self.changed.notify_all();
        let decoder = locked(&self.decoder).take();
        if let Some(handle) = decoder
            && handle.thread().id() != std::thread::current().id()
        {
            let _ = handle.join();
        }
    }
}
