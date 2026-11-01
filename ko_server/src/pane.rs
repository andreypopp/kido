use std::io;
use std::path::Path;

use ko_pane_wire::frame::Size;

use crate::config::Config;
use crate::ids::{ClientId, PaneId};
use crate::pane_proc::{Io, PaneProc};

#[derive(Debug)]
pub(crate) struct Pane {
    id: PaneId,
    proc: PaneProc,
    command: Vec<Vec<u8>>,
    size: Size,
    sizer: Option<ClientId>,
}

impl Pane {
    pub(crate) fn spawn(
        config: &Config,
        id: PaneId,
        cwd: &Path,
        command: Vec<Vec<u8>>,
        env: &[Vec<u8>],
        io: &mut Io<'_>,
    ) -> io::Result<Pane> {
        Ok(Pane {
            id,
            proc: PaneProc::spawn(config, id, cwd, &command, env, io)?,
            command,
            size: Size::DEFAULT,
            sizer: None,
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
