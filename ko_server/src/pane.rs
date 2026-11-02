use std::io;
use std::path::Path;

use ko_pane_wire::frame::Size;

use crate::config::Config;
use crate::delivery::Stamps;
use crate::ids::{ClientId, PaneId};
use crate::model::PaneModel;
use crate::pane_proc::{Io, PaneProc};
use crate::telemetry::Telemetry;
use crate::vars::Vars;

#[derive(Debug)]
pub(crate) struct Pane {
    id: PaneId,
    proc: PaneProc,
    command: Vec<Vec<u8>>,
    size: Size,
    sizer: Option<ClientId>,
    telemetry: Telemetry,
    vars: Vars,
    model: PaneModel,
}

impl Pane {
    pub(crate) fn spawn(
        config: &Config,
        id: PaneId,
        cwd: &Path,
        command: Vec<Vec<u8>>,
        env: &[Vec<u8>],
        stamps: &mut Stamps,
        io: &mut Io<'_>,
    ) -> io::Result<Pane> {
        Ok(Pane {
            id,
            proc: PaneProc::spawn(config, id, cwd, &command, env, stamps, io)?,
            command,
            size: Size::DEFAULT,
            sizer: None,
            telemetry: Telemetry::default(),
            vars: Vars::default(),
            model: PaneModel::default(),
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

    pub(crate) fn sizer(&self) -> Option<ClientId> {
        self.sizer
    }

    pub(crate) fn resize(&mut self, size: Size, io: &mut Io<'_>) {
        if self.size != size {
            self.size = size;
            self.proc.resize(size, io);
        }
    }

    pub(crate) fn claim(&mut self, client: ClientId, size: Size, io: &mut Io<'_>) {
        self.sizer = Some(client);
        self.resize(size, io);
    }
}
