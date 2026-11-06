use std::time::Duration;

use ko_sys::clock::Mono;
use ko_sys::event::{Poll, Timer};

use crate::http::lossy;
use crate::pane::Pane;
use crate::pane_kind::{self, Kind, RemoteKind};
use crate::pane_status::{self, DEBOUNCE, Track};
use crate::protocol::{AgentState, Live, PaneStatus};

const TICK: Duration = Duration::from_millis(16);

#[derive(Debug)]
pub(crate) struct Model {
    tick: Timer,
}

#[derive(Debug, Default)]
pub(crate) struct PaneModel {
    track: Option<Track>,
    status: Option<PaneStatus>,
    dirty: bool,
    promotion: Option<Timer>,
}

impl PaneModel {
    pub(crate) fn status(&self) -> Option<&PaneStatus> {
        self.status.as_ref()
    }

    pub(crate) fn dirty(&self) -> bool {
        self.dirty
    }

    pub(crate) fn promotion(&self) -> Option<Timer> {
        self.promotion
    }

    pub(crate) fn take_promotion(&mut self) -> Option<Timer> {
        self.promotion.take()
    }
}

fn progress_of(state: AgentState) -> Option<u8> {
    match state {
        AgentState::Running { progress } | AgentState::Waiting { progress, .. } => progress,
        AgentState::Idle { .. } => None,
    }
}

fn caption(live: &Live) -> (Option<String>, Option<u8>) {
    live.agent()
        .or_else(|| live.shell().and_then(|shell| shell.report.as_ref()))
        .map_or((None, None), |agent| {
            (agent.msg.clone(), progress_of(agent.state))
        })
}

fn row_title(kind: &Kind, live: &Live, pane_title: &str, label: String) -> String {
    if let Some(title) = pane_kind::title(kind, pane_title) {
        return title;
    }
    let command = live.shell().and_then(|shell| shell.running_command());
    match (kind, live) {
        (
            Kind::Ssh {
                destination,
                pane: RemoteKind::Terminal,
            },
            Live::Ssh {
                pane: crate::protocol::Remote::Terminal { interactive, .. },
                ..
            },
        ) => match command.filter(|_| *interactive) {
            Some(command) => format!("ssh {destination}: {command}"),
            None => format!("ssh {destination}"),
        },
        (_, Live::Terminal(_)) => command.map_or(label, str::to_owned),
        _ => label,
    }
}

impl Model {
    pub(crate) fn new(poll: &mut Poll) -> Model {
        Model { tick: poll.timer() }
    }

    pub(crate) fn is_tick(&self, timer: Timer) -> bool {
        self.tick == timer
    }

    pub(crate) fn mark(&self, poll: &mut Poll, pane: &mut Pane) {
        pane.model_mut().dirty = true;
        self.arm(poll);
    }

    pub(crate) fn arm(&self, poll: &mut Poll) {
        if !poll.is_active(self.tick) {
            let _ = poll.start(self.tick, TICK, None);
        }
    }

    pub(crate) fn stop(&self, poll: &mut Poll) {
        poll.stop(self.tick);
    }
}

pub(crate) fn observe(pane: &mut Pane, poll: &mut Poll) -> Option<PaneStatus> {
    let now = Mono::now().nanos();
    let pane_title = lossy(pane.proc().title());
    let has_foreground = pane.status_foreground().is_some();
    let (telemetry, vars, model) = pane.parts_mut();
    model.dirty = false;
    let published = telemetry.records.published();
    let foreground = telemetry.foreground.as_ref().filter(|_| has_foreground);
    let kind = pane_kind::classify(foreground, vars, &published.records);
    let (track, live) = pane_status::observe(
        now,
        telemetry,
        &pane_title,
        &kind,
        &published,
        model.track.take(),
    );
    let label = pane_status::label(&track, foreground, &published.records);
    let pending = pane_status::pending(&track);
    model.track = Some(track);
    let (message, progress) = caption(&live);
    let mut next = PaneStatus {
        title: row_title(&kind, &live, &pane_title, label),
        kind: live,
        program_status: published,
        message,
        progress,
        since: now,
    };
    match pending {
        Some(observed) => {
            let remaining = observed.saturating_add(DEBOUNCE).saturating_sub(now).max(1);
            let timer = *model.promotion.get_or_insert_with(|| poll.timer());
            let _ = poll.start(timer, Duration::from_nanos(remaining), None);
        }
        None => {
            if let Some(timer) = model.promotion {
                poll.stop(timer);
            }
        }
    }
    if let Some(prev) = &model.status {
        let fresh = next.since;
        next.since = prev.since;
        if *prev == next {
            return None;
        }
        next.since = fresh;
    }
    model.status = Some(next.clone());
    Some(next)
}
