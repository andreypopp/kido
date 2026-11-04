use std::io;
use std::path::PathBuf;

use ko_pane_wire::frame::Size;

use crate::config::Config;
use crate::delivery::Stamps;
use crate::ids::{PaneId, PaneToken, RunId, RuntimeName};
use crate::inbox::Inbox;
use crate::model::PaneModel;
use crate::pane_proc::{Input, Io, Launch, PaneProc};
use crate::protocol::{Close, Variable};
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
    pub(crate) vars: Vars,
    pub(crate) run: Option<RunId>,
    pub(crate) parent: Option<PaneId>,
    pub(crate) close: Close,
    pub(crate) runtime: Option<RuntimeName>,
    pub(crate) program: Program,
}

#[derive(Debug)]
pub(crate) struct Pane {
    id: PaneId,
    proc: PaneProc,
    command: Vec<Vec<u8>>,
    size: Size,
    focused: bool,
    telemetry: Telemetry,
    vars: Vars,
    run: Option<RunId>,
    parent: Option<PaneId>,
    close: Close,
    runtime: Option<RuntimeName>,
    token: PaneToken,
    model: PaneModel,
    inbox: Inbox,
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
            proc: PaneProc::spawn(config, launch, stamps, io)?,
            command: birth.program.record,
            size: launch.size,
            focused: false,
            telemetry: Telemetry {
                in_runtime: birth.runtime.is_some(),
                ..Telemetry::default()
            },
            vars: birth.vars,
            run: birth.run,
            parent: birth.parent,
            close: birth.close,
            runtime: birth.runtime,
            token,
            model: PaneModel::default(),
            inbox: Inbox::default(),
        })
    }

    pub(crate) fn id(&self) -> PaneId {
        self.id
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

    pub(crate) fn run(&self) -> Option<&RunId> {
        self.run.as_ref()
    }

    pub(crate) fn parent(&self) -> Option<PaneId> {
        self.parent
    }

    pub(crate) fn close(&self) -> Close {
        self.close
    }

    pub(crate) fn runtime(&self) -> Option<&RuntimeName> {
        self.runtime.as_ref()
    }

    pub(crate) fn token(&self) -> &PaneToken {
        &self.token
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

    pub(crate) fn parts_mut(&mut self) -> (&mut Telemetry, &Vars, &mut PaneModel) {
        (&mut self.telemetry, &self.vars, &mut self.model)
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
    pub(crate) fn size(&self) -> Size {
        self.size
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
