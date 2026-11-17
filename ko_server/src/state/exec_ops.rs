use std::collections::BTreeMap;

use ko_sys::pid::Exit;
use ko_sys::signal::Signal;

use super::*;
use crate::conn::{Close, Handling};
use crate::runtime::exec::{
    Admit, Chunk, Launch, Limiter, MAX_SESSIONS, Mode, Purpose, Request, Retry, Running, Session,
    Source, Stage, Stream, Target, spawn,
};
use crate::runtime::{Ending, RuntimeKey, Wait, Who};
use ko_wire::exec_wire::{Command, Start, ToKo};
use ko_wire::protocol::{
    DROP_IDLE, EXEC_CHUNK, Ended, ExecClient, ExecRequest, ExecServer, LinkState, Text,
};

const FRAMING: usize = 80;
const READS_PER_TURN: usize = 16;
const UPLOAD_REPLY: usize = 16 << 10;

#[derive(Debug)]
pub(super) struct Execs {
    limiters: BTreeMap<Target, Limiter>,
    scratch: Vec<u8>,
}

impl Execs {
    pub(super) fn new() -> Execs {
        Execs {
            limiters: BTreeMap::new(),
            scratch: vec![0; EXEC_CHUNK],
        }
    }

    fn limiter(&mut self, key: &Target) -> &mut Limiter {
        self.limiters
            .entry(key.clone())
            .or_insert_with(|| Limiter::new(MAX_SESSIONS))
    }
}

#[derive(Debug)]
enum ExecOutput<'a> {
    WebSocket {
        wire: Wire<'a>,
    },
    Captured {
        stdout: &'a mut Vec<u8>,
        stderr: &'a mut Vec<u8>,
    },
}

impl ExecOutput<'_> {
    fn room(&self) -> usize {
        match self {
            Self::WebSocket { wire } => fit(wire.out.room()),
            Self::Captured { .. } => EXEC_CHUNK,
        }
    }

    fn forward(&mut self, stream: Stream, data: Vec<u8>) -> Result<(), String> {
        match self {
            Self::WebSocket { wire } => {
                let message = match stream {
                    Stream::Stdout => ExecServer::Stdout { data: Text(data) },
                    Stream::Stderr => ExecServer::Stderr { data: Text(data) },
                };
                wire.ws.send(wire.out, protocol::json(&message));
            }
            Self::Captured { stdout, stderr } => {
                let target = match stream {
                    Stream::Stdout => stdout,
                    Stream::Stderr => stderr,
                };
                if target.len().saturating_add(data.len()) > UPLOAD_REPLY {
                    return Err("ko drop output exceeds 16 KiB".to_owned());
                }
                target.extend(data);
            }
        }
        Ok(())
    }
}

fn fit(room: usize) -> usize {
    room.saturating_sub(FRAMING)
        .saturating_mul(3)
        .checked_div(4)
        .unwrap_or(0)
        .min(EXEC_CHUNK)
}

impl State {
    fn exec_key(&self, index: usize) -> Option<Target> {
        self.conns
            .get(index)?
            .exec()
            .map(|session| session.runtime.clone())
    }

    fn exec_send(&mut self, index: usize, message: &ExecServer) {
        if let Some((Role::Exec(_), wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
            wire.ws.send(wire.out, protocol::json(message));
        }
    }

    pub(super) fn exec_fail(&mut self, poll: &mut Poll, index: usize, message: String) {
        let remaining =
            self.conns
                .get(index)
                .and_then(Conn::exec)
                .and_then(|session| match &session.purpose {
                    Purpose::Drop { remaining, .. } => Some(*remaining),
                    Purpose::Command => None,
                });
        if let Some(remaining) = remaining {
            self.exec_release(poll, index);
            let conn = &mut self.conns[index];
            poll.stop(conn.timer);
            conn.phase = Phase::Closing(Close::body(remaining));
            router::uploaded(conn, Err(std::io::Error::other(message)));
        } else {
            self.exec_send(index, &ExecServer::Error { message });
            if let Some((_, wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
                wire.ws.abort(wire.out, "error");
            }
            self.exec_release(poll, index);
        }
    }

    fn exec_exit(&mut self, poll: &mut Poll, index: usize, ended: Ended) {
        let result = self
            .conns
            .get_mut(index)
            .and_then(Conn::exec_mut)
            .and_then(|session| match &mut session.purpose {
                Purpose::Command => None,
                Purpose::Drop {
                    stdout,
                    stderr,
                    remaining,
                    ..
                } => Some((
                    if ended == (Ended::Status { status: 0 }) && *remaining == 0 {
                        protocol::decode::<protocol::Dropped>(stdout).map_err(std::io::Error::other)
                    } else {
                        let message = String::from_utf8_lossy(stderr).trim().to_owned();
                        Err(std::io::Error::other(if message.is_empty() {
                            format!("ko drop ended: {ended:?}")
                        } else {
                            message
                        }))
                    },
                    *remaining,
                )),
            });
        if let Some((result, remaining)) = result {
            self.exec_release(poll, index);
            let conn = &mut self.conns[index];
            poll.stop(conn.timer);
            conn.phase = if result.is_ok() {
                Phase::Head
            } else {
                Phase::Closing(Close::body(remaining))
            };
            router::uploaded(conn, result);
            self.serve(poll, index);
        } else {
            self.exec_send(index, &ExecServer::Exit { ended });
            if let Some((_, wire)) = self.conns.get_mut(index).and_then(Conn::role_mut) {
                wire.ws.finish(wire.out);
            }
            self.exec_release(poll, index);
        }
    }

    fn exec_release(&mut self, poll: &mut Poll, index: usize) {
        let Some(token) = self.token(index) else {
            return;
        };
        let Some(session) = self.conns.get_mut(index).and_then(Conn::exec_mut) else {
            return;
        };
        let key = session.runtime.clone();
        let stage = std::mem::replace(&mut session.stage, Stage::Ended);
        self.exec_release_stage(poll, token, &key, stage);
    }

    fn exec_release_stage(&mut self, poll: &mut Poll, token: Token, key: &Target, stage: Stage) {
        match stage {
            Stage::Open | Stage::Ended => {}
            Stage::Queued { timer, .. } => {
                if let Some(timer) = timer {
                    poll.free(timer);
                }
                self.execs.limiter(key).forget(token);
                self.runtimes.forget_wait(poll, token);
            }
            Stage::Running(running) => {
                let Running { mut helper, .. } = *running;
                helper.release(poll);
                if helper.reap().is_none() {
                    self.leaving
                        .hand_over(poll, helper.pid(), self.config.stop_escalation);
                }
                for ticket in self.execs.limiter(key).leave() {
                    self.exec_start(poll, ticket);
                }
            }
        }
        if let Target::Runtime(key) = key {
            self.touch_runtime(poll, key);
        }
        self.runtimes_changed(poll);
    }

    pub(super) fn exec_gone(&mut self, poll: &mut Poll, token: Token, session: Session) {
        self.exec_release_stage(poll, token, &session.runtime, session.stage);
    }

    pub(crate) fn begin_upload(
        &mut self,
        poll: &mut Poll,
        index: usize,
        pane: PaneId,
        name: ko_wire::api::DropName,
        length: usize,
    ) -> Result<(), protocol::Error> {
        let target = self.live(pane)?;
        let runtime = target
            .runtime()
            .cloned()
            .map_or(Target::Host, Target::Runtime);
        let visit = target.visit_conn();
        let mut args = vec![
            "drop".to_owned(),
            format!("--name={}", name.as_str()),
            format!("--size={length}"),
        ];
        if runtime == Target::Host {
            let base = self.config.dir.to_str().ok_or_else(|| {
                protocol::Error::new(protocol::ErrorKind::Invalid, "state directory is not UTF-8")
            })?;
            args.push(format!("--base={base}"));
        }
        let session = Session {
            runtime,
            purpose: Purpose::Drop {
                pane,
                visit,
                remaining: length,
                stdout: Vec::new(),
                stderr: Vec::new(),
            },
            stage: Stage::Open,
            backlog: std::collections::VecDeque::new(),
        };
        self.conns[index].phase = Phase::Handling(Handling::Exec(Box::new(session)));
        let _ = poll.start(self.conns[index].timer, DROP_IDLE, None);
        self.exec_begin(
            poll,
            index,
            Request {
                command: Command::Ko { args },
                cwd: None,
                env: BTreeMap::new(),
                stdin: true,
            },
        );
        Ok(())
    }

    pub(super) fn read_upload(&mut self, poll: &mut Poll, index: usize) {
        loop {
            self.conns[index].feed_upload(poll);
            let Some(conn) = self.conns.get_mut(index) else {
                return;
            };
            if !conn.exec().is_some_and(Session::reads) || !conn.read(poll) {
                break;
            }
        }
    }

    pub(super) fn cancel_uploads(&mut self, poll: &mut Poll) {
        let cancelled: Vec<_> = self
            .conns
            .iter()
            .enumerate()
            .filter_map(|(index, conn)| {
                let session = conn.exec()?;
                let Purpose::Drop { pane, visit, .. } = &session.purpose else {
                    return None;
                };
                let live = self.panes.find(*pane).is_some_and(|pane| {
                    pane.proc().dead().is_none()
                        && pane.visit_conn() == *visit
                        && pane
                            .runtime()
                            .cloned()
                            .map_or(Target::Host, Target::Runtime)
                            == session.runtime
                });
                (!live).then_some(index)
            })
            .collect();
        for index in cancelled {
            self.exec_fail(poll, index, "upload cancelled".to_owned());
        }
    }

    pub(super) fn exec_text(&mut self, poll: &mut Poll, index: usize, text: &[u8]) {
        match protocol::decode::<ExecClient>(text) {
            Ok(message) => self.exec_message(poll, index, message),
            Err(_) => self.exec_fail(poll, index, "invalid message".to_owned()),
        }
    }

    fn exec_message(&mut self, poll: &mut Poll, index: usize, message: ExecClient) {
        let handled: Result<Option<ExecRequest>, &'static str> = {
            let Some(session) = self.conns.get_mut(index).and_then(Conn::exec_mut) else {
                return;
            };
            match (&mut session.stage, message) {
                (Stage::Open, ExecClient::Exec(request)) => Ok(Some(request)),
                (Stage::Open, _) => Err("the first message must be exec"),
                (Stage::Queued { .. } | Stage::Running(_), ExecClient::Exec(_)) => {
                    Err("exec was already sent")
                }
                (Stage::Queued { .. }, message) => {
                    session.backlog.push_back(message);
                    Ok(None)
                }
                (Stage::Running(running), ExecClient::Stdin { data }) => {
                    if data.0.len() > EXEC_CHUNK {
                        Err("stdin data exceeds 64 KiB")
                    } else if !running.request.stdin {
                        Err("the session was opened without stdin")
                    } else {
                        running.helper.send(poll, &ToKo::Stdin(&data.0));
                        running.fed = true;
                        Ok(None)
                    }
                }
                (Stage::Running(running), ExecClient::Eof {}) => {
                    if running.request.stdin {
                        running.helper.send(poll, &ToKo::Eof);
                        running.fed = true;
                    }
                    Ok(None)
                }
                (Stage::Running(running), ExecClient::Signal { signal }) => {
                    running.helper.send(poll, &ToKo::Signal(signal));
                    Ok(None)
                }
                (Stage::Ended, _) => Ok(None),
            }
        };
        match handled {
            Ok(None) => {}
            Err(message) => self.exec_fail(poll, index, message.to_owned()),
            Ok(Some(request)) => match request.invalid() {
                Some(message) => self.exec_fail(poll, index, message.to_owned()),
                None => self.exec_begin(poll, index, request.into()),
            },
        }
    }

    fn exec_begin(&mut self, poll: &mut Poll, index: usize, request: Request) {
        let Some(key) = self.exec_key(index) else {
            return;
        };
        if let Some(session) = self.conns.get_mut(index).and_then(Conn::exec_mut) {
            session.stage = Stage::Queued {
                request,
                timer: None,
                retried: false,
            };
        }
        if let Target::Runtime(key) = &key
            && let Err(error) = self.start_runtime(poll, key)
        {
            return self.exec_fail(poll, index, error.message);
        }
        self.exec_proceed(poll, index, &key);
        self.runtimes_changed(poll);
    }

    fn exec_proceed(&mut self, poll: &mut Poll, index: usize, key: &Target) {
        let Target::Runtime(runtime) = key else {
            return self.exec_join(poll, index, key);
        };
        match self.runtimes.state(runtime) {
            LinkState::Up => self.exec_join(poll, index, key),
            LinkState::Failed { message } => self.exec_fail(poll, index, message),
            LinkState::Down => self.exec_fail(poll, index, format!("runtime {runtime} is down")),
            LinkState::Starting => {
                if let Some(conn) = self.token(index) {
                    self.runtimes.wait(
                        runtime,
                        Wait {
                            conn,
                            who: Who::Exec,
                        },
                    );
                }
            }
        }
    }

    pub(super) fn exec_linked(
        &mut self,
        poll: &mut Poll,
        conn: Token,
        key: &RuntimeKey,
        state: LinkState,
    ) {
        let Some(index) = self.index(conn) else {
            return;
        };
        let target = Target::Runtime(key.clone());
        match state {
            LinkState::Up => self.exec_join(poll, index, &target),
            LinkState::Failed { message } => self.exec_fail(poll, index, message),
            LinkState::Down => self.exec_fail(poll, index, format!("runtime {key} went down")),
            LinkState::Starting => self.exec_proceed(poll, index, &target),
        }
    }

    fn exec_wait_timer(&mut self, poll: &mut Poll, index: usize) {
        let timer = poll.timer();
        let _ = poll.start(timer, self.config.runtimes.exec_wait, None);
        if let Some(Session {
            stage: Stage::Queued { timer: slot, .. },
            ..
        }) = self.conns.get_mut(index).and_then(Conn::exec_mut)
        {
            *slot = Some(timer);
        }
    }

    fn exec_join(&mut self, poll: &mut Poll, index: usize, key: &Target) {
        let Some(token) = self.token(index) else {
            return;
        };
        match self.execs.limiter(key).join(token) {
            Admit::Run => self.exec_spawn(poll, index),
            Admit::Wait => self.exec_wait_timer(poll, index),
        }
    }

    fn exec_start(&mut self, poll: &mut Poll, ticket: Token) {
        let Some(index) = self.index(ticket) else {
            return;
        };
        if let Some(Session {
            stage: Stage::Queued { timer, .. },
            ..
        }) = self.conns.get_mut(index).and_then(Conn::exec_mut)
            && let Some(timer) = timer.take()
        {
            poll.free(timer);
        }
        self.exec_spawn(poll, index);
    }

    fn exec_spawn(&mut self, poll: &mut Poll, index: usize) {
        let Some(key) = self.exec_key(index) else {
            return;
        };
        let Some((request, retried)) =
            self.conns
                .get(index)
                .and_then(Conn::exec)
                .and_then(|session| match &session.stage {
                    Stage::Queued {
                        request, retried, ..
                    } => Some((request.clone(), *retried)),
                    _ => None,
                })
        else {
            return;
        };
        let started = self.execs.limiter(&key).ends();
        let launch = match &key {
            Target::Runtime(key) => self
                .runtimes
                .settings(key)
                .map_err(|e| e.message)
                .and_then(|runtime| self.runtimes.exec_launch(key, &runtime, &request)),
            Target::Host => Ok((
                Launch::new(
                    self.config.exe.clone(),
                    vec!["enter".to_owned(), "--exec".to_owned()],
                    &self.config.env,
                ),
                Start {
                    command: request.command.clone(),
                    cwd: request.cwd.clone(),
                    env: Vec::new(),
                    escalation_ms: u64::try_from(self.config.stop_escalation.as_millis())
                        .unwrap_or(u64::MAX),
                },
            )),
        };
        let helper = launch.and_then(|(launch, start)| {
            let mut helper =
                spawn(poll, &launch, Mode::Session).map_err(|error| error.to_string())?;
            helper.send(poll, &ToKo::Start(start));
            Ok(helper)
        });
        match helper {
            Ok(mut helper) => {
                if !request.stdin
                    || matches!(
                        self.conns
                            .get(index)
                            .and_then(Conn::exec)
                            .map(|s| &s.purpose),
                        Some(Purpose::Drop { remaining: 0, .. })
                    )
                {
                    helper.send(poll, &ToKo::Eof);
                }
                let Some(session) = self.conns.get_mut(index).and_then(Conn::exec_mut) else {
                    return;
                };
                session.stage = Stage::Running(Box::new(Running {
                    helper,
                    request,
                    retried,
                    output: false,
                    fed: false,
                    started,
                }));
                let backlog = std::mem::take(&mut session.backlog);
                for message in backlog {
                    self.exec_message(poll, index, message);
                }
                if matches!(self.conns[index].phase, Phase::Ws(_)) {
                    self.read_ws(poll, index);
                } else {
                    self.conns[index].feed_upload(poll);
                }
                self.pump_exec(poll, index);
            }
            Err(message) => {
                self.exec_fail(poll, index, message);
                for ticket in self.execs.limiter(&key).leave() {
                    self.exec_start(poll, ticket);
                }
            }
        }
    }

    pub(super) fn pump_exec(&mut self, poll: &mut Poll, index: usize) {
        let ended = (|| -> Result<Option<Exit>, String> {
            let State { conns, execs, .. } = self;
            let Some(Conn { phase, out, .. }) = conns.get_mut(index) else {
                return Ok(None);
            };
            let (running, runtime, mut output) = match phase {
                Phase::Ws(link) => match &mut link.role {
                    Role::Exec(Session {
                        stage: Stage::Running(running),
                        runtime,
                        ..
                    }) => (
                        running,
                        runtime,
                        ExecOutput::WebSocket {
                            wire: Wire {
                                ws: &mut link.ws,
                                out,
                            },
                        },
                    ),
                    _ => return Ok(None),
                },
                Phase::Handling(Handling::Exec(session)) => match &mut **session {
                    Session {
                        stage: Stage::Running(running),
                        purpose: Purpose::Drop { stdout, stderr, .. },
                        runtime,
                        ..
                    } => (running, runtime, ExecOutput::Captured { stdout, stderr }),
                    _ => return Ok(None),
                },
                _ => return Ok(None),
            };
            running.helper.reap();
            for _ in 0..READS_PER_TURN {
                let mut moved = false;
                let wanted = output.room();
                if let Some((stream, data)) = running.helper.output(poll, wanted) {
                    running.output |= stream == Stream::Stdout;
                    output.forward(stream, data)?;
                    moved = true;
                }
                let wanted = output.room();
                if let Chunk::Data(count) =
                    running
                        .helper
                        .read(poll, Stream::Stderr, &mut execs.scratch, wanted)
                {
                    output.forward(
                        Stream::Stderr,
                        execs.scratch.get(..count).unwrap_or_default().to_vec(),
                    )?;
                    moved = true;
                }
                if !moved || running.helper.broken().is_some() {
                    break;
                }
            }
            running.helper.reading(poll, output.room() > 0);
            if let Some(invalid) = running.helper.broken() {
                Err(match runtime {
                    Target::Runtime(key) => {
                        format!("ko in runtime {key} sent invalid output: {invalid}")
                    }
                    Target::Host => format!("ko sent invalid output: {invalid}"),
                })
            } else if running.helper.drained() {
                Ok(running.helper.exit())
            } else {
                Ok(None)
            }
        })();
        match ended {
            Err(message) => self.exec_fail(poll, index, message),
            Ok(Some(exit)) => self.exec_finished(poll, index, exit),
            Ok(None) => {}
        }
    }

    fn exec_finished(&mut self, poll: &mut Poll, index: usize, exit: Exit) {
        let Some(token) = self.token(index) else {
            return;
        };
        let Some(key) = self.exec_key(index) else {
            return;
        };
        let framed = match self.conns.get(index).and_then(Conn::exec) {
            Some(Session {
                stage: Stage::Running(running),
                ..
            }) => running.helper.ended(),
            _ => return,
        };
        if let Some(ended) = framed {
            return self.exec_exit(poll, index, ended);
        }
        let runtime = match &key {
            Target::Runtime(key) => self.runtimes.settings(key).ok(),
            Target::Host => None,
        };
        let ending = match self.conns.get(index).and_then(Conn::exec) {
            Some(Session {
                stage: Stage::Running(running),
                purpose,
                ..
            }) => match &runtime {
                Some(runtime) => match crate::runtime::ending(runtime, exit, running.helper.tail())
                {
                    Ending::Refused(_)
                        if !running.output
                            && !running.retried
                            && !running.fed
                            && matches!(purpose, Purpose::Command) =>
                    {
                        Err((running.request.clone(), running.started))
                    }
                    Ending::Refused(message) => Ok(Ending::Error(message)),
                    other => Ok(other),
                },
                None => Ok(Ending::Exit),
            },
            _ => return,
        };
        let (request, started) = match ending {
            Ok(Ending::Exit) => return self.exec_exit(poll, index, Ended::from(exit)),
            Ok(Ending::Error(message) | Ending::Refused(message)) => {
                if let Target::Runtime(key) = &key {
                    self.runtimes.suspect(poll, key);
                }
                return self.exec_fail(poll, index, message);
            }
            Err(retry) => retry,
        };
        if let Some(session) = self.conns.get_mut(index).and_then(Conn::exec_mut)
            && let Stage::Running(mut running) = std::mem::replace(
                &mut session.stage,
                Stage::Queued {
                    request,
                    timer: None,
                    retried: true,
                },
            )
        {
            running.helper.release(poll);
        }
        let (when, admitted) = self.execs.limiter(&key).retry(token, started);
        if when == Retry::Later {
            self.exec_wait_timer(poll, index);
        }
        for ticket in admitted {
            self.exec_start(poll, ticket);
        }
    }

    pub(super) fn exec_ready(&mut self, poll: &mut Poll, ready: Ready) -> bool {
        let found = self
            .conns
            .iter()
            .enumerate()
            .find_map(|(index, conn)| match conn.exec() {
                Some(Session {
                    stage: Stage::Running(running),
                    ..
                }) => running
                    .helper
                    .owns(ready.token)
                    .map(|source| (index, source)),
                _ => None,
            });
        let Some((index, source)) = found else {
            return false;
        };
        match source {
            Source::Output => self.pump_exec(poll, index),
            Source::Stdin => {
                if let Some(Session {
                    stage: Stage::Running(running),
                    ..
                }) = self.conns.get_mut(index).and_then(Conn::exec_mut)
                {
                    running.helper.flush_stdin(poll);
                }
                if matches!(self.conns[index].phase, Phase::Ws(_)) {
                    self.read_ws(poll, index);
                } else {
                    self.read_upload(poll, index);
                }
            }
        }
        true
    }

    pub(super) fn exec_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let waiting = self
            .conns
            .iter()
            .enumerate()
            .find_map(|(index, conn)| match conn.exec() {
                Some(Session {
                    stage:
                        Stage::Queued {
                            timer: Some(due), ..
                        },
                    runtime,
                    ..
                }) if *due == timer => Some((index, runtime.clone())),
                _ => None,
            });
        let Some((index, key)) = waiting else {
            return false;
        };
        let wait = self.config.runtimes.exec_wait.as_millis();
        self.exec_fail(
            poll,
            index,
            match key {
                Target::Host => format!("no host exec slot within {wait} ms"),
                Target::Runtime(key) => format!("no exec slot of runtime {key} within {wait} ms"),
            },
        );
        true
    }

    pub(super) fn exec_reap(&mut self, poll: &mut Poll) {
        let running: Vec<_> = self
            .conns
            .iter()
            .enumerate()
            .filter_map(|(index, conn)| {
                matches!(
                    conn.exec(),
                    Some(Session {
                        stage: Stage::Running(_),
                        ..
                    })
                )
                .then_some(index)
            })
            .collect();
        for index in running {
            self.pump_exec(poll, index);
        }
    }

    pub(super) fn exec_shutdown(&mut self) {
        for conn in &self.conns {
            if let Some(Session {
                stage: Stage::Running(running),
                ..
            }) = conn.exec()
            {
                running.helper.signal(Signal::Term);
            }
        }
    }

    pub(crate) fn kill_helpers(&mut self) {
        self.leaving.kill_all();
    }

    pub(super) fn exec_down(&mut self, poll: &mut Poll, key: &RuntimeKey) {
        let (queued, running): (Vec<_>, Vec<_>) = self
            .conns
            .iter()
            .enumerate()
            .filter_map(|(index, conn)| conn.runs_exec(key).then_some(index))
            .partition(|&index| {
                matches!(
                    self.conns[index].exec(),
                    Some(Session {
                        stage: Stage::Queued { .. },
                        ..
                    })
                )
            });
        for index in queued.into_iter().chain(running) {
            self.exec_fail(poll, index, format!("runtime {key} went down"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_always_fits_the_room_it_was_sized_for() {
        assert_eq!(fit(0), 0);
        assert_eq!(fit(FRAMING), 0);
        assert_eq!(fit(1 << 30), EXEC_CHUNK);
        for room in [FRAMING + 1, 100, 1000, 4096, 65536, 262_144] {
            let raw = fit(room);
            let encoded = raw.div_ceil(3) * 4;
            assert!(
                encoded + 64 <= room.max(64),
                "{room}: {raw} raw bytes are {encoded} encoded"
            );
        }
    }
}
