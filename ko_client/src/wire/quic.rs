use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::os::fd::AsFd;
use std::time::{Duration, Instant};

use boring::ssl::{SslContextBuilder, SslRef};
#[cfg(target_vendor = "apple")]
use ko_sys::event::Wake;
use ko_sys::event::{Due, Interest, Poll, Ready, Timer, Token};
#[cfg(target_vendor = "apple")]
use std::sync::Arc;

use crate::endpoint::{HostName, tls};

#[derive(Debug)]
struct Datagram {
    count: usize,
    info: quiche::SendInfo,
}

struct Driver {
    connection: quiche::Connection,
    socket: UdpSocket,
    local: SocketAddr,
    output: [u8; 1350],
    token: Token,
    timeout: Timer,
    pacing: Timer,
    keep: Timer,
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
        context: SslContextBuilder,
        poll: &mut Poll,
        keep_alive: Duration,
    ) -> io::Result<Self> {
        if keep_alive.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "zero QUIC keep-alive",
            ));
        }
        let route = UdpSocket::bind(if peer.is_ipv4() {
            "0.0.0.0:0"
        } else {
            "[::]:0"
        })?;
        route.connect(peer)?;
        let socket = UdpSocket::bind(SocketAddr::new(route.local_addr()?.ip(), 0))?;
        socket.set_nonblocking(true)?;
        let local = socket.local_addr()?;
        let mut config =
            quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, context)
                .map_err(io::Error::other)?;
        config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .map_err(io::Error::other)?;
        config.set_initial_max_data(16 << 20);
        config.set_initial_max_stream_data_bidi_local(1 << 20);
        config.set_initial_max_stream_data_bidi_remote(1 << 20);
        config.set_initial_max_stream_data_uni(1 << 20);
        config.set_initial_max_streams_bidi(128);
        config.set_initial_max_streams_uni(16);
        config.set_active_connection_id_limit(4);
        let mut cid = [0; quiche::MAX_CONN_ID_LEN];
        boring::rand::rand_bytes(&mut cid).map_err(io::Error::other)?;
        let mut connection = quiche::connect(
            Some(host.as_str()),
            &quiche::ConnectionId::from_ref(&cid),
            local,
            peer,
            &mut config,
        )
        .map_err(io::Error::other)?;
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
            output: [0; 1350],
            timeout: poll.timer(),
            pacing: poll.timer(),
            keep: poll.timer(),
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

    fn error(&mut self, error: quiche::Error) -> io::Error {
        let alert = self
            .connection
            .peer_error()
            .filter(|error| !error.is_app)
            .and_then(|error| error.error_code.checked_sub(0x100));
        let ssl: &mut SslRef = self.connection.as_mut();
        if let Ok(index) = tls::index()
            && let Some(state) = ssl.ex_data(index)
            && let Some(failure) = state.failure(&error.to_string(), alert)
        {
            return io::Error::other(failure);
        }
        if matches!(error, quiche::Error::TlsFail) {
            return io::Error::other(tls::Failure::Tls(error.to_string()));
        }
        if self.connection.is_closed() || self.connection.is_draining() {
            return io::ErrorKind::ConnectionReset.into();
        }
        io::Error::other(error)
    }

    fn ready(&mut self, poll: &mut Poll, ready: Ready) -> io::Result<()> {
        #[cfg(target_vendor = "apple")]
        if ready.token == self.trust {
            self.wake.drain();
            return self.flush(poll);
        }
        if ready.token != self.token {
            return Ok(());
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
        self.flush(poll)
    }

    fn due(&mut self, poll: &mut Poll, due: Due) -> io::Result<()> {
        if !poll.current(due) {
            return Ok(());
        }
        if due.timer != self.timeout && due.timer != self.keep && due.timer != self.pacing {
            return Ok(());
        }
        self.flush(poll)
    }

    fn flush(&mut self, poll: &mut Poll) -> io::Result<()> {
        if self.connection.timeout().is_some_and(|left| left.is_zero()) {
            self.connection.on_timeout();
        }
        if self.connection.is_closed() || self.connection.is_draining() {
            self.pending = None;
            return Err(self.error(quiche::Error::Done));
        }
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
                match self.connection.send(&mut self.output) {
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
        for timer in [self.timeout, self.pacing, self.keep] {
            poll.free(timer);
        }
    }
}

#[cfg(test)]
mod tests;
