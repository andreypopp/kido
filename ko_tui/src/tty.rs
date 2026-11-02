use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};

use ko_sys::fd;
use ko_sys::tty::{self, Saved};

#[derive(Debug)]
pub(crate) struct Tty {
    input: OwnedFd,
    output: OwnedFd,
    saved: Saved,
}

impl Tty {
    pub(crate) fn raw() -> io::Result<Tty> {
        let input = io::stdin().as_fd().try_clone_to_owned()?;
        let output = io::stdout().as_fd().try_clone_to_owned()?;
        let saved = tty::raw(input.as_fd())?;
        Ok(Tty {
            input,
            output,
            saved,
        })
    }

    pub(crate) fn input(&self) -> BorrowedFd<'_> {
        self.input.as_fd()
    }

    pub(crate) fn size(&self) -> (usize, usize) {
        let (cols, rows) = tty::size(self.output.as_fd()).unwrap_or((80, 24));
        (usize::from(cols), usize::from(rows))
    }

    pub(crate) fn read(&self, buffer: &mut [u8]) -> io::Result<Option<usize>> {
        match fd::read(self.input.as_fd(), buffer) {
            Ok(count) => Ok(Some(count)),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(error) => Err(error),
        }
    }

    pub(crate) fn write(&self, text: &str) -> io::Result<()> {
        let mut rest = text.as_bytes();
        while !rest.is_empty() {
            match fd::write(self.output.as_fd(), rest) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(count) => rest = rest.get(count..).unwrap_or_default(),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    fd::wait_writable(self.output.as_fd())?;
                }
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    pub(crate) fn flush_input(&self) {
        tty::flush_input(self.input.as_fd());
    }

    pub(crate) fn release(&self) {
        let _ = tty::restore(self.input.as_fd(), &self.saved);
    }

    pub(crate) fn acquire(&mut self) -> io::Result<()> {
        tty::raw(self.input.as_fd()).map(drop)
    }
}
