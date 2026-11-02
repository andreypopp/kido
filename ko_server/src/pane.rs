use std::io;

use ko_pane_wire::frame::Size;

use crate::config::Config;
use crate::delivery::Stamps;
use crate::ids::PaneId;
use crate::pane_proc::{Input, Io, Launch, PaneProc};

#[derive(Debug)]
pub(crate) struct Pane {
    id: PaneId,
    proc: PaneProc,
    command: Vec<Vec<u8>>,
    size: Size,
    focused: bool,
}

impl Pane {
    pub(crate) fn spawn(
        config: &Config,
        launch: &Launch<'_>,
        stamps: &mut Stamps,
        io: &mut Io<'_>,
    ) -> io::Result<Pane> {
        Ok(Pane {
            id: launch.id,
            proc: PaneProc::spawn(config, launch, stamps, io)?,
            command: launch.argv.to_vec(),
            size: launch.size,
            focused: false,
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
