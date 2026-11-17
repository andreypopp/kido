pub(crate) mod h3;

use std::io;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::os::fd::AsFd;
use std::time::{Duration, Instant};

use boring::ssl::SslRef;
#[cfg(target_vendor = "apple")]
use ko_sys::event::Wake;
use ko_sys::event::{Due, Interest, Poll, Ready, Timer, Token};
#[cfg(target_vendor = "apple")]
use std::sync::Arc;

use crate::endpoint::{HostName, tls};

const VALIDATION: Duration = Duration::from_secs(5);

fn validation_failed() -> io::Error {
    io::Error::new(
        io::ErrorKind::ConnectionReset,
        "QUIC path validation failed",
    )
}

#[cfg(any(target_vendor = "apple", test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Migration {
    Moved,
    Rejoin,
}

#[derive(Debug)]
pub(crate) struct IdleTimeout;

impl std::fmt::Display for IdleTimeout {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("QUIC idle timeout")
    }
}

impl std::error::Error for IdleTimeout {}

#[derive(Debug)]
struct Datagram {
    count: usize,
    info: quiche::SendInfo,
}

struct Driver {
    connection: quiche::Connection,
    socket: UdpSocket,
    local: SocketAddr,
    peer: SocketAddr,
    output: [u8; 1350],
    token: Token,
    timeout: Timer,
    pacing: Timer,
    keep: Timer,
    validation: Timer,
    keep_alive: Duration,
    keep_due: Option<Instant>,
    pending: Option<Datagram>,
    #[cfg(test)]
    block_send: bool,
    #[cfg(target_vendor = "apple")]
    wake: Arc<Wake>,
    #[cfg(target_vendor = "apple")]
    trust: Token,
}

pub(crate) fn route(peer: SocketAddr) -> io::Result<IpAddr> {
    let probe = UdpSocket::bind(if peer.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    })?;
    probe.connect(peer)?;
    Ok(probe.local_addr()?.ip())
}

fn bind(peer: SocketAddr) -> io::Result<(UdpSocket, SocketAddr)> {
    let socket = UdpSocket::bind(SocketAddr::new(route(peer)?, 0))?;
    socket.set_nonblocking(true)?;
    let local = socket.local_addr()?;
    Ok((socket, local))
}

impl std::fmt::Debug for Driver {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Driver")
            .field("socket", &self.socket)
            .field("pending", &self.pending)
            .field("established", &self.connection.is_established())
            .finish_non_exhaustive()
    }
}

impl Driver {
    fn start(
        host: &HostName,
        peer: SocketAddr,
        config: &std::sync::Mutex<quiche::Config>,
        poll: &mut Poll,
        keep_alive: Duration,
    ) -> io::Result<Self> {
        if keep_alive.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "zero QUIC keep-alive",
            ));
        }
        let (socket, local) = bind(peer)?;
        let mut cid = [0; quiche::MAX_CONN_ID_LEN];
        boring::rand::rand_bytes(&mut cid).map_err(io::Error::other)?;
        let mut connection = {
            let mut config = config.lock().unwrap_or_else(|error| error.into_inner());
            quiche::connect(
                Some(host.as_str()),
                &quiche::ConnectionId::from_ref(&cid),
                local,
                peer,
                &mut config,
            )
            .map_err(io::Error::other)?
        };
        let state = tls::Connection::new(host.as_str())?;
        #[cfg(target_vendor = "apple")]
        let wake = state.wake();
        let ssl: &mut SslRef = connection.as_mut();
        ssl.set_ex_data(tls::index().map_err(io::Error::other)?, state);
        let mut driver = Self {
            connection,
            token: poll.watch(socket.as_fd(), Interest::Read),
            socket,
            local,
            peer,
            output: [0; 1350],
            timeout: poll.timer(),
            pacing: poll.timer(),
            keep: poll.timer(),
            validation: poll.timer(),
            keep_alive,
            keep_due: None,
            pending: None,
            #[cfg(test)]
            block_send: false,
            #[cfg(target_vendor = "apple")]
            trust: poll.watch(wake.fd(), Interest::Read),
            #[cfg(target_vendor = "apple")]
            wake,
        };
        if let Err(error) = driver.flush(poll) {
            driver.detach(poll);
            return Err(error);
        }
        Ok(driver)
    }

    #[cfg(any(target_vendor = "apple", test))]
    fn migrate(&mut self, poll: &mut Poll) -> io::Result<Migration> {
        if self.connection.timeout().is_some_and(|left| left.is_zero()) {
            self.connection.on_timeout();
        }
        if !self.connection.is_established()
            || self.connection.is_closed()
            || self.connection.is_draining()
        {
            return Ok(Migration::Rejoin);
        }
        let (socket, local) = bind(self.peer)?;
        match self
            .connection
            .migrate(local, self.peer)
            .and_then(|_| self.connection.probe_path(local, self.peer))
        {
            Ok(_) => {}
            Err(quiche::Error::OutOfIdentifiers) => return Ok(Migration::Rejoin),
            Err(error) => return Err(self.error(error)),
        }
        poll.unwatch(self.token);
        self.token = poll.watch(socket.as_fd(), Interest::Read);
        self.socket = socket;
        self.local = local;
        self.pending = None;
        poll.start(self.validation, VALIDATION, None)?;
        self.flush(poll).map(|()| Migration::Moved)
    }

    fn paths(&mut self, poll: &mut Poll) -> io::Result<()> {
        while let Some(event) = self.connection.path_event_next() {
            match event {
                quiche::PathEvent::FailedValidation(local, _) if local == self.local => {
                    return Err(validation_failed());
                }
                quiche::PathEvent::Validated(local, _) if local == self.local => {
                    poll.stop(self.validation);
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn error(&mut self, error: quiche::Error) -> io::Error {
        let alert = self
            .connection
            .peer_error()
            .filter(|error| !error.is_app)
            .and_then(|error| error.error_code.checked_sub(0x100))
            .filter(|alert| u8::try_from(*alert).is_ok());
        let ssl: &mut SslRef = self.connection.as_mut();
        if let Ok(index) = tls::index()
            && let Some(state) = ssl.ex_data(index)
            && let Some(failure) = state.failure(&error.to_string(), alert)
        {
            return io::Error::other(failure);
        }
        if matches!(error, quiche::Error::TlsFail) || alert.is_some() {
            return io::Error::other(tls::Failure::Tls(error.to_string()));
        }
        if self.connection.is_established() && self.connection.is_timed_out() {
            return io::Error::new(io::ErrorKind::TimedOut, IdleTimeout);
        }
        if self.connection.is_closed() || self.connection.is_draining() {
            return io::ErrorKind::ConnectionReset.into();
        }
        io::Error::other(error)
    }

    fn ready(&mut self, poll: &mut Poll, ready: Ready) -> io::Result<bool> {
        #[cfg(target_vendor = "apple")]
        if ready.token == self.trust {
            self.wake.drain();
            return self.flush(poll).map(|()| true);
        }
        if ready.token != self.token {
            return Ok(false);
        }
        if ready.read {
            let mut bytes = [0; 65535];
            for _ in 0..32 {
                let (count, from) = match self.socket.recv_from(&mut bytes) {
                    Ok(received) => received,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error),
                };
                if count == 0 {
                    continue;
                }
                let info = quiche::RecvInfo {
                    from,
                    to: self.local,
                };
                match self.connection.recv(&mut bytes[..count], info) {
                    Ok(_) | Err(quiche::Error::Done) => {}
                    Err(error) => return Err(self.error(error)),
                }
            }
        }
        self.flush(poll).map(|()| true)
    }

    fn due(&mut self, poll: &mut Poll, due: Due) -> io::Result<bool> {
        if !poll.current(due) {
            return Ok(false);
        }
        if due.timer == self.validation {
            return Err(validation_failed());
        }
        if due.timer != self.timeout && due.timer != self.keep && due.timer != self.pacing {
            return Ok(false);
        }
        self.flush(poll).map(|()| true)
    }

    fn flush(&mut self, poll: &mut Poll) -> io::Result<()> {
        if self.connection.timeout().is_some_and(|left| left.is_zero()) {
            self.connection.on_timeout();
        }
        if self.connection.is_closed() || self.connection.is_draining() {
            self.pending = None;
            return Err(self.error(quiche::Error::Done));
        }
        self.paths(poll)?;
        if self.connection.is_established() {
            let now = Instant::now();
            if self.keep_due.is_some_and(|due| due <= now) {
                match self.connection.send_ack_eliciting() {
                    Ok(()) | Err(quiche::Error::Done) => {}
                    Err(error) => return Err(self.error(error)),
                }
                self.keep_due = Some(now + self.keep_alive);
            }
            let due = *self.keep_due.get_or_insert(now + self.keep_alive);
            poll.start(self.keep, due.saturating_duration_since(now), None)?;
        }
        poll.stop(self.pacing);
        poll.interest(self.token, Interest::Read);
        let mut exhausted = true;
        for _ in 0..32 {
            if self.pending.is_none() {
                match self.connection.send_on_path(
                    &mut self.output,
                    Some(self.local),
                    Some(self.peer),
                ) {
                    Ok((count, info)) => {
                        self.pending = Some(Datagram { count, info });
                    }
                    Err(quiche::Error::Done) => {
                        exhausted = false;
                        break;
                    }
                    Err(error) => return Err(self.error(error)),
                }
            }
            let Some(packet) = &self.pending else { break };
            if packet.info.at > Instant::now() {
                poll.start(
                    self.pacing,
                    packet.info.at.saturating_duration_since(Instant::now()),
                    None,
                )?;
                break;
            }
            #[cfg(test)]
            let sent = if self.block_send {
                Err(io::ErrorKind::WouldBlock.into())
            } else {
                self.socket
                    .send_to(&self.output[..packet.count], packet.info.to)
            };
            #[cfg(not(test))]
            let sent = self
                .socket
                .send_to(&self.output[..packet.count], packet.info.to);
            match sent {
                Ok(count) if count == packet.count => self.pending = None,
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "partial QUIC datagram",
                    ));
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    poll.interest(self.token, Interest::ReadWrite);
                    break;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        if exhausted && self.pending.is_none() {
            poll.start(self.pacing, Duration::ZERO, None)?;
        }
        if let Some(timeout) = self.connection.timeout() {
            poll.start(self.timeout, timeout, None)?;
        } else {
            poll.stop(self.timeout);
        }
        if self.connection.is_established() {
            while self.connection.scids_left() > 0 {
                let mut cid = [0; quiche::MAX_CONN_ID_LEN];
                let mut reset = [0; 16];
                boring::rand::rand_bytes(&mut cid).map_err(io::Error::other)?;
                boring::rand::rand_bytes(&mut reset).map_err(io::Error::other)?;
                self.connection
                    .new_scid(
                        &quiche::ConnectionId::from_ref(&cid),
                        u128::from_be_bytes(reset),
                        false,
                    )
                    .map_err(io::Error::other)?;
            }
        }
        if self.connection.is_closed() || self.connection.is_draining() {
            return Err(self.error(quiche::Error::Done));
        }
        Ok(())
    }

    fn connection(&mut self) -> &mut quiche::Connection {
        &mut self.connection
    }

    fn detach(self, poll: &mut Poll) {
        poll.unwatch(self.token);
        #[cfg(target_vendor = "apple")]
        poll.unwatch(self.trust);
        for timer in [self.timeout, self.pacing, self.keep, self.validation] {
            poll.free(timer);
        }
    }
}

#[cfg(test)]
pub(crate) mod tests;
