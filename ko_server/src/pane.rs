use std::io;
use std::path::PathBuf;

use ko_pane_wire::frame::Size;
use ko_sys::clock::Mono;
use ko_sys::event::Token;

use crate::config::Config;
use crate::delivery::Stamps;
use crate::ids::{PaneId, PaneToken};
use crate::inbox::Inbox;
use crate::model::PaneModel;
use crate::pane_proc::{Input, Io, Launch, PaneProc};
use crate::protocol::{Close, Variable};
use crate::runtime::RuntimeKey;
use crate::telemetry::Telemetry;
use crate::vars::Vars;

#[derive(Debug)]
pub(crate) struct Program {
    pub(crate) argv: Vec<Vec<u8>>,
    pub(crate) record: Vec<Vec<u8>>,
    pub(crate) cwd: PathBuf,
    pub(crate) env: Vec<Variable>,
}

#[derive(Debug)]
pub(crate) struct Birth {
    pub(crate) webview_supported: bool,
    pub(crate) vars: Vars,
    pub(crate) parent: Option<PaneId>,
    pub(crate) close: Close,
    pub(crate) runtime: Option<RuntimeKey>,
    pub(crate) program: Program,
}

#[derive(Debug)]
enum Membership {
    Born {
        key: RuntimeKey,
    },
    Visit {
        key: RuntimeKey,
        token: PaneToken,
        conn: Token,
    },
}

#[derive(Debug)]
pub(crate) struct Pane {
    id: PaneId,
    started: Mono,
    proc: PaneProc,
    command: Vec<Vec<u8>>,
    size: Size,
    focused: bool,
    telemetry: Telemetry,
    vars: Vars,
    parent: Option<PaneId>,
    close: Close,
    membership: Option<Membership>,
    token: PaneToken,
    model: PaneModel,
    inbox: Inbox,
    webview: crate::webview::PaneWebview,
}

impl Pane {
    pub(crate) fn spawn(
        config: &Config,
        launch: &Launch<'_>,
        birth: Birth,
        token: PaneToken,
        stamps: &mut Stamps,
        io: &mut Io<'_>,
    ) -> io::Result<Pane> {
        Ok(Pane {
            id: launch.id,
            started: Mono::now(),
            proc: PaneProc::spawn(config, launch, stamps, io)?,
            command: birth.program.record,
            size: launch.size,
            focused: false,
            telemetry: Telemetry::default(),
            vars: birth.vars,
            parent: birth.parent,
            close: birth.close,
            membership: birth.runtime.map(|key| Membership::Born { key }),
            token,
            model: PaneModel::default(),
            inbox: Inbox::default(),
            webview: crate::webview::PaneWebview::default(),
        })
    }

    pub(crate) fn id(&self) -> PaneId {
        self.id
    }

    pub(crate) fn started(&self) -> Mono {
        self.started
    }

    pub(crate) fn proc(&self) -> &PaneProc {
        &self.proc
    }

    pub(crate) fn proc_mut(&mut self) -> &mut PaneProc {
        &mut self.proc
    }

    pub(crate) fn telemetry(&self) -> &Telemetry {
        &self.telemetry
    }

    pub(crate) fn telemetry_mut(&mut self) -> &mut Telemetry {
        &mut self.telemetry
    }

    pub(crate) fn vars(&self) -> &Vars {
        &self.vars
    }

    pub(crate) fn parent(&self) -> Option<PaneId> {
        self.parent
    }

    pub(crate) fn set_close(&mut self, close: Close) {
        self.close = close;
    }

    pub(crate) fn close(&self) -> Close {
        self.close
    }

    pub(crate) fn runtime(&self) -> Option<&RuntimeKey> {
        self.membership.as_ref().map(|membership| match membership {
            Membership::Born { key } | Membership::Visit { key, .. } => key,
        })
    }

    pub(crate) fn begin_visit(&mut self, key: RuntimeKey, token: PaneToken, conn: Token) -> bool {
        if self.membership.is_some() {
            return false;
        }
        self.membership = Some(Membership::Visit { key, token, conn });
        true
    }

    pub(crate) fn visit_conn(&self) -> Option<Token> {
        match &self.membership {
            Some(Membership::Visit { conn, .. }) => Some(*conn),
            _ => None,
        }
    }

    pub(crate) fn end_visit(&mut self) -> Option<(RuntimeKey, Token)> {
        let Some(Membership::Visit { key, conn, .. }) = &self.membership else {
            return None;
        };
        let ended = (key.clone(), *conn);
        self.membership = None;
        Some(ended)
    }

    pub(crate) fn runtime_token(&self) -> Option<&PaneToken> {
        match self.membership.as_ref()? {
            Membership::Born { .. } => Some(&self.token),
            Membership::Visit { token, .. } => Some(token),
        }
    }

    pub(crate) fn token(&self) -> &PaneToken {
        &self.token
    }

    pub(crate) fn webview(&self) -> &crate::webview::PaneWebview {
        &self.webview
    }
    pub(crate) fn webview_mut(&mut self) -> &mut crate::webview::PaneWebview {
        &mut self.webview
    }

    pub(crate) fn inbox(&self) -> &Inbox {
        &self.inbox
    }

    pub(crate) fn inbox_mut(&mut self) -> &mut Inbox {
        &mut self.inbox
    }

    pub(crate) fn vars_mut(&mut self) -> &mut Vars {
        &mut self.vars
    }

    pub(crate) fn model(&self) -> &PaneModel {
        &self.model
    }

    pub(crate) fn model_mut(&mut self) -> &mut PaneModel {
        &mut self.model
    }

    pub(crate) fn parts_mut(&mut self) -> (&mut Telemetry, &mut PaneModel) {
        (&mut self.telemetry, &mut self.model)
    }

    pub(crate) fn command(&self) -> &[Vec<u8>] {
        &self.command
    }

    pub(crate) fn resize(&mut self, size: Size, io: &mut Io<'_>) {
        if self.size != size {
            self.size = size;
            self.proc.resize(size, io);
        }
    }

    #[cfg(test)]
    pub(crate) fn focused(&self) -> bool {
        self.focused
    }

    pub(crate) fn focus(&mut self, focused: bool, io: &mut Io<'_>) {
        if self.focused != focused {
            self.focused = focused;
            let _ = self.proc.input(Input::Focus(focused), io);
        }
    }
}
