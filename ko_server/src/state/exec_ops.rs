use std::collections::BTreeMap;

use ko_sys::pid::Exit;
use ko_sys::signal::Signal;

use super::*;
use crate::exec_wire::ToKo;
use crate::protocol::{EXEC_CHUNK, Ended, ExecClient, ExecRequest, ExecServer, LinkState, Text};
use crate::runtime::exec::{
    Admit, Chunk, Limiter, MAX_SESSIONS, Mode, Retry, Running, Session, Source, Stage, Stream,
    spawn,
};
use crate::runtime::{Ending, Wait, Who};

const FRAMING: usize = 80;
const READS_PER_TURN: usize = 16;

#[derive(Debug)]
pub(super) struct Execs {
    limiters: BTreeMap<RuntimeName, Limiter>,
    scratch: Vec<u8>,
}

impl Execs {
    pub(super) fn new() -> Execs {
        Execs {
            limiters: BTreeMap::new(),
            scratch: vec![0; EXEC_CHUNK],
        }
    }

    fn limiter(&mut self, name: &RuntimeName) -> &mut Limiter {
        self.limiters
            .entry(name.clone())
            .or_insert_with(|| Limiter::new(MAX_SESSIONS))
    }
}

fn forward(wire: &mut Wire<'_>, stream: Stream, data: Vec<u8>) {
    let data = Text(data);
    let message = match stream {
        Stream::Stdout => ExecServer::Stdout { data },
        Stream::Stderr => ExecServer::Stderr { data },
    };
    wire.ws.send(wire.out, protocol::json(&message));
}

fn fit(room: usize) -> usize {
    room.saturating_sub(FRAMING)
        .saturating_mul(3)
        .checked_div(4)
        .unwrap_or(0)
        .min(EXEC_CHUNK)
}

impl State {
    fn exec_session(&mut self, index: usize) -> Option<(&mut Session, Wire<'_>)> {
        match self.conns.get_mut(index)?.role_mut()? {
            (Role::Exec(session), wire) => Some((session, wire)),
            _ => None,
        }
    }

    fn exec_name(&mut self, index: usize) -> Option<RuntimeName> {
        self.exec_session(index)
            .map(|(session, _)| session.runtime.clone())
    }

    fn exec_send(&mut self, index: usize, message: &ExecServer) {
        if let Some((_, wire)) = self.exec_session(index) {
            wire.ws.send(wire.out, protocol::json(message));
        }
    }

    pub(super) fn exec_fail(&mut self, poll: &mut Poll, index: usize, message: String) {
        self.exec_send(index, &ExecServer::Error { message });
        if let Some((_, wire)) = self.exec_session(index) {
            wire.ws.abort(wire.out, "error");
        }
        self.exec_release(poll, index);
    }

    fn exec_exit(&mut self, poll: &mut Poll, index: usize, ended: Ended) {
        self.exec_send(index, &ExecServer::Exit { ended });
        if let Some((_, wire)) = self.exec_session(index) {
            wire.ws.finish(wire.out);
        }
        self.exec_release(poll, index);
    }

    fn exec_release(&mut self, poll: &mut Poll, index: usize) {
        let Some(token) = self.token(index) else {
            return;
        };
        let Some((session, _)) = self.exec_session(index) else {
            return;
        };
        let name = session.runtime.clone();
        let stage = std::mem::replace(&mut session.stage, Stage::Ended);
        self.exec_release_stage(poll, token, &name, stage);
    }

    fn exec_release_stage(
        &mut self,
        poll: &mut Poll,
        token: Token,
        name: &RuntimeName,
        stage: Stage,
    ) {
        match stage {
            Stage::Open | Stage::Ended => {}
            Stage::Queued { timer, .. } => {
                if let Some(timer) = timer {
                    poll.free(timer);
                }
                self.execs.limiter(name).forget(token);
                self.runtimes.forget_wait(poll, token);
            }
            Stage::Running(Running { mut helper, .. }) => {
                helper.release(poll);
                if helper.reap().is_none() {
                    self.leaving
                        .hand_over(poll, helper.pid(), self.config.stop_escalation);
                }
                for ticket in self.execs.limiter(name).leave() {
                    self.exec_start(poll, ticket);
                }
            }
        }
        self.touch_runtime(poll, name);
        self.runtimes_changed(poll);
    }

    pub(super) fn exec_gone(&mut self, poll: &mut Poll, token: Token, session: Session) {
        let Session { runtime, stage, .. } = session;
        self.exec_release_stage(poll, token, &runtime, stage);
    }

    pub(super) fn exec_text(&mut self, poll: &mut Poll, index: usize, text: &[u8]) {
        match protocol::decode::<ExecClient>(text) {
            Ok(message) => self.exec_message(poll, index, message),
            Err(_) => self.exec_fail(poll, index, "invalid message".to_owned()),
        }
    }

    fn exec_message(&mut self, poll: &mut Poll, index: usize, message: ExecClient) {
        let handled: Result<Option<ExecRequest>, &'static str> = {
            let Some((session, _)) = self.exec_session(index) else {
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
                None => self.exec_begin(poll, index, request),
            },
        }
    }

    fn exec_begin(&mut self, poll: &mut Poll, index: usize, request: ExecRequest) {
        let Some(name) = self.exec_name(index) else {
            return;
        };
        if matches!(
            self.runtimes.state(&name),
            LinkState::Down | LinkState::Failed { .. }
        ) {
            match self.runtimes.settings(&name) {
                Ok(settings) => self.runtimes.begin(poll, &name, settings),
                Err(error) => return self.exec_fail(poll, index, error.message),
            }
        }
        if let Some((session, _)) = self.exec_session(index) {
            session.stage = Stage::Queued {
                request,
                timer: None,
                retried: false,
            };
        }
        self.touch_runtime(poll, &name);
        self.exec_proceed(poll, index, &name);
        self.runtimes_changed(poll);
    }

    fn exec_proceed(&mut self, poll: &mut Poll, index: usize, name: &RuntimeName) {
        match self.runtimes.state(name) {
            LinkState::Up => self.exec_join(poll, index, name),
            LinkState::Failed { message } => self.exec_fail(poll, index, message),
            LinkState::Down => {
                self.exec_fail(poll, index, format!("runtime {name} is down"));
            }
            LinkState::Starting if self.runtimes.needs_pane(name) => {
                let message = format!("runtime {name} needs a pane to log in");
                self.exec_fail(poll, index, message);
            }
            LinkState::Starting => {
                if let Some(conn) = self.token(index) {
                    self.runtimes.wait(
                        name,
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
        name: &RuntimeName,
        state: LinkState,
    ) {
        let Some(index) = self.index(conn) else {
            return;
        };
        match state {
            LinkState::Up => self.exec_join(poll, index, name),
            LinkState::Failed { message } => self.exec_fail(poll, index, message),
            LinkState::Down => {
                self.exec_fail(poll, index, format!("runtime {name} went down"));
            }
            LinkState::Starting => {
                self.exec_fail(
                    poll,
                    index,
                    format!("runtime {name} needs a pane to log in"),
                );
            }
        }
    }

    fn exec_wait_timer(&mut self, poll: &mut Poll, index: usize) {
        let timer = poll.timer();
        let _ = poll.start(timer, self.config.runtimes.exec_wait, None);
        if let Some((session, _)) = self.exec_session(index)
            && let Stage::Queued { timer: slot, .. } = &mut session.stage
        {
            *slot = Some(timer);
        }
    }

    fn exec_join(&mut self, poll: &mut Poll, index: usize, name: &RuntimeName) {
        let Some(token) = self.token(index) else {
            return;
        };
        match self.execs.limiter(name).join(token) {
            Admit::Run => self.exec_spawn(poll, index),
            Admit::Wait => self.exec_wait_timer(poll, index),
        }
    }

    fn exec_start(&mut self, poll: &mut Poll, ticket: Token) {
        let Some(index) = self.index(ticket) else {
            return;
        };
        if let Some((session, _)) = self.exec_session(index)
            && let Stage::Queued { timer, .. } = &mut session.stage
            && let Some(timer) = timer.take()
        {
            poll.free(timer);
        }
        self.exec_spawn(poll, index);
    }

    fn exec_spawn(&mut self, poll: &mut Poll, index: usize) {
        let Some(name) = self.exec_name(index) else {
            return;
        };
        let queued = self
            .exec_session(index)
            .and_then(|(session, _)| match &session.stage {
                Stage::Queued {
                    request, retried, ..
                } => Some((request.clone(), *retried)),
                _ => None,
            });
        let Some((request, retried)) = queued else {
            return;
        };
        let started = self.execs.limiter(&name).ends();
        let helper = self
            .runtimes
            .settings(&name)
            .map_err(|error| error.message)
            .and_then(|runtime| self.runtimes.exec_launch(&name, &runtime, &request))
            .and_then(|(launch, start)| {
                let mut helper =
                    spawn(poll, &launch, Mode::Session).map_err(|error| error.to_string())?;
                helper.send(poll, &ToKo::Start(start));
                Ok(helper)
            });
        match helper {
            Ok(mut helper) => {
                if !request.stdin {
                    helper.send(poll, &ToKo::Eof);
                }
                let backlog = match self.exec_session(index) {
                    Some((session, _)) => {
                        session.stage = Stage::Running(Running {
                            helper,
                            request,
                            retried,
                            output: false,
                            fed: false,
                            started,
                        });
                        std::mem::take(&mut session.backlog)
                    }
                    None => return,
                };
                for message in backlog {
                    self.exec_message(poll, index, message);
                }
                self.read_ws(poll, index);
                self.pump_exec(poll, index);
            }
            Err(message) => {
                self.exec_fail(poll, index, message);
                for ticket in self.execs.limiter(&name).leave() {
                    self.exec_start(poll, ticket);
                }
            }
        }
    }

    pub(super) fn pump_exec(&mut self, poll: &mut Poll, index: usize) {
        let ended = {
            let State { conns, execs, .. } = self;
            let Some((Role::Exec(session), mut wire)) =
                conns.get_mut(index).and_then(Conn::role_mut)
            else {
                return;
            };
            let Stage::Running(running) = &mut session.stage else {
                return;
            };
            running.helper.reap();
            for _ in 0..READS_PER_TURN {
                let mut moved = false;
                while let Some((stream, data)) = running.helper.output(poll, fit(wire.out.room())) {
                    forward(&mut wire, stream, data);
                    running.output |= stream == Stream::Stdout;
                    moved = true;
                }
                let wanted = fit(wire.out.room());
                if let Chunk::Data(count) =
                    running
                        .helper
                        .read(poll, Stream::Stderr, &mut execs.scratch, wanted)
                {
                    let data = execs.scratch.get(..count).unwrap_or_default().to_vec();
                    forward(&mut wire, Stream::Stderr, data);
                    moved = true;
                }
                if !moved || running.helper.broken().is_some() {
                    break;
                }
            }
            running.helper.reading(poll, fit(wire.out.room()) > 0);
            match (running.helper.broken(), running.helper.drained()) {
                (Some(invalid), _) => Err(invalid),
                (None, true) => Ok(running.helper.exit()),
                (None, false) => Ok(None),
            }
        };
        match ended {
            Err(invalid) => {
                let message = match self.exec_name(index) {
                    Some(name) => format!("ko in runtime {name} sent invalid output: {invalid}"),
                    None => format!("ko sent invalid output: {invalid}"),
                };
                self.exec_fail(poll, index, message);
            }
            Ok(Some(exit)) => self.exec_finished(poll, index, exit),
            Ok(None) => {}
        }
    }

    fn exec_finished(&mut self, poll: &mut Poll, index: usize, exit: Exit) {
        let Some(token) = self.token(index) else {
            return;
        };
        let Some(name) = self.exec_name(index) else {
            return;
        };
        let framed = match self.exec_session(index) {
            Some((
                Session {
                    stage: Stage::Running(running),
                    ..
                },
                _,
            )) => running.helper.ended(),
            _ => return,
        };
        if let Some(ended) = framed {
            return self.exec_exit(poll, index, ended);
        }
        let runtime = self.runtimes.settings(&name).ok();
        let ending = match self.exec_session(index) {
            Some((session, _)) => match (&session.stage, &runtime) {
                (Stage::Running(running), Some(runtime)) => {
                    let ending = crate::runtime::ending(runtime, exit, running.helper.tail());
                    match ending {
                        Ending::Refused(_)
                            if !running.output && !running.retried && !running.fed =>
                        {
                            Err((running.request.clone(), running.started))
                        }
                        Ending::Refused(message) => Ok(Ending::Error(message)),
                        other => Ok(other),
                    }
                }
                (Stage::Running(_), None) => Ok(Ending::Exit),
                _ => return,
            },
            None => return,
        };
        let request = match ending {
            Ok(Ending::Exit) => return self.exec_exit(poll, index, Ended::from(exit)),
            Ok(Ending::Error(message) | Ending::Refused(message)) => {
                self.runtimes.suspect(poll, &name);
                return self.exec_fail(poll, index, message);
            }
            Err(retry) => retry,
        };
        let (request, started) = request;
        if let Some((session, _)) = self.exec_session(index)
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
        let (when, admitted) = self.execs.limiter(&name).retry(token, started);
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
            .find_map(|(index, conn)| match conn.role() {
                Some(Role::Exec(Session {
                    stage: Stage::Running(running),
                    ..
                })) => running
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
                if let Some((
                    Session {
                        stage: Stage::Running(running),
                        ..
                    },
                    _,
                )) = self.exec_session(index)
                {
                    running.helper.flush_stdin(poll);
                }
                self.read_ws(poll, index);
            }
        }
        true
    }

    pub(super) fn exec_due(&mut self, poll: &mut Poll, timer: Timer) -> bool {
        let waiting = self
            .conns
            .iter()
            .enumerate()
            .find_map(|(index, conn)| match conn.role() {
                Some(Role::Exec(Session {
                    stage:
                        Stage::Queued {
                            timer: Some(due), ..
                        },
                    runtime,
                    ..
                })) if *due == timer => Some((index, runtime.clone())),
                _ => None,
            });
        let Some((index, name)) = waiting else {
            return false;
        };
        let wait = self.config.runtimes.exec_wait.as_millis();
        self.exec_fail(
            poll,
            index,
            format!("no exec slot of runtime {name} within {wait} ms"),
        );
        true
    }

    pub(super) fn exec_reap(&mut self, poll: &mut Poll) {
        let running: Vec<usize> = self
            .conns
            .iter()
            .enumerate()
            .filter(|(_, conn)| {
                matches!(
                    conn.role(),
                    Some(Role::Exec(Session {
                        stage: Stage::Running(_),
                        ..
                    }))
                )
            })
            .map(|(index, _)| index)
            .collect();
        for index in running {
            self.pump_exec(poll, index);
        }
    }

    fn running_helpers(&self) -> impl Iterator<Item = &crate::runtime::exec::Helper> {
        self.conns.iter().filter_map(|conn| match conn.role() {
            Some(Role::Exec(Session {
                stage: Stage::Running(running),
                ..
            })) => Some(&running.helper),
            _ => None,
        })
    }

    pub(super) fn exec_shutdown(&mut self) {
        for helper in self.running_helpers() {
            helper.signal(Signal::Term);
        }
    }

    pub(crate) fn kill_helpers(&mut self) {
        self.leaving.kill_all();
    }

    pub(super) fn exec_down(&mut self, poll: &mut Poll, name: &RuntimeName) {
        let (queued, running): (Vec<usize>, Vec<usize>) = self
            .conns
            .iter()
            .enumerate()
            .filter(|(_, conn)| conn.runs_exec(name))
            .map(|(index, _)| index)
            .partition(|index| {
                matches!(
                    self.conns.get(*index).and_then(Conn::role),
                    Some(Role::Exec(Session {
                        stage: Stage::Queued { .. },
                        ..
                    }))
                )
            });
        for index in queued.into_iter().chain(running) {
            self.exec_fail(poll, index, format!("runtime {name} went down"));
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
