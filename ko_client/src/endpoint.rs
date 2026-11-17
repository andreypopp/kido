#[cfg(feature = "tls")]
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
#[cfg(feature = "tls")]
use std::sync::Arc;

#[cfg(feature = "tls")]
pub(crate) mod tls;
#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
pub(crate) use tls::config;

#[cfg(any(all(target_vendor = "apple", feature = "tls"), test))]
#[derive(Debug, Clone)]
pub(crate) enum Endpoint {
    Unix(PathBuf),
    #[cfg(feature = "tls")]
    Tls(Arc<Tls>),
}

#[cfg(feature = "tls")]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostName(String);

#[cfg(feature = "tls")]
impl TryFrom<String> for HostName {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty()
            || value.len() > 253
            || value.parse::<IpAddr>().is_ok()
            || !value.split('.').all(|label| {
                !label.is_empty()
                    && label.len() <= 63
                    && label
                        .as_bytes()
                        .first()
                        .is_some_and(u8::is_ascii_alphanumeric)
                    && label
                        .as_bytes()
                        .last()
                        .is_some_and(u8::is_ascii_alphanumeric)
                    && label
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            })
        {
            return Err("expected a DNS host name without an address, port or path");
        }
        Ok(Self(value.to_ascii_lowercase()))
    }
}

#[cfg(feature = "tls")]
#[derive(Debug)]
pub struct Tls {
    pub(crate) host: HostName,
    #[cfg(any(target_vendor = "apple", test))]
    pub(crate) port: u16,
    pub(crate) connector: boring::ssl::SslConnector,
}

#[cfg(all(feature = "tls", any(target_vendor = "apple", test)))]
impl Tls {
    pub(crate) fn new(host: HostName, port: u16, connector: boring::ssl::SslConnector) -> Self {
        Self {
            host,
            port,
            connector,
        }
    }
}

#[derive(Debug, Clone)]
pub enum Resolved {
    Unix(PathBuf),
    #[cfg(feature = "tls")]
    Tls {
        target: Arc<Tls>,
        addresses: Arc<[SocketAddr]>,
    },
}

#[cfg(any(all(target_vendor = "apple", feature = "tls"), test))]
impl Endpoint {
    #[cfg(any(all(target_vendor = "apple", feature = "tls"), test))]
    pub(crate) fn resolve(
        &self,
        cancel: Option<&ko_sys::event::Wake>,
        within: std::time::Duration,
    ) -> std::io::Result<Arc<Resolved>> {
        use ko_sys::fd::{self, Waited, Want};
        use std::net::ToSocketAddrs;
        match self {
            Self::Unix(path) => Ok(Arc::new(Resolved::Unix(path.clone()))),
            Self::Tls(target) => {
                let host = target.host.0.clone();
                let port = target.port;
                let wake = Arc::new(ko_sys::event::Wake::new()?);
                let worker = Arc::clone(&wake);
                let (send, receive) = std::sync::mpsc::channel();
                std::thread::Builder::new()
                    .name("ko-resolve".to_owned())
                    .spawn(move || {
                        let addresses = (host.as_str(), port)
                            .to_socket_addrs()
                            .map(|addresses| addresses.collect::<Vec<_>>());
                        let _ = send.send(addresses);
                        worker.wake();
                    })?;
                match fd::wait(
                    wake.fd(),
                    Want::Read,
                    cancel.map(ko_sys::event::Wake::fd),
                    Some(within),
                )? {
                    Waited::Cancelled => Err(crate::connect::cancelled_error()),
                    Waited::TimedOut => Err(std::io::ErrorKind::TimedOut.into()),
                    Waited::Ready => {
                        let addresses =
                            receive.try_recv().map_err(std::io::Error::other)?.map_err(
                                |error| std::io::Error::new(std::io::ErrorKind::NotFound, error),
                            )?;
                        if addresses.is_empty() {
                            return Err(std::io::ErrorKind::NotFound.into());
                        }
                        Ok(Arc::new(Resolved::Tls {
                            target: Arc::clone(target),
                            addresses: addresses.into(),
                        }))
                    }
                }
            }
        }
    }
}

#[cfg(feature = "tls")]
impl HostName {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_resolved_dial_keeps_its_target_and_addresses_together() {
        let within = std::time::Duration::from_secs(5);
        let unix = Endpoint::Unix(PathBuf::from("/tmp/test-socket"));
        assert!(
            matches!(unix.resolve(None, within).unwrap().as_ref(), Resolved::Unix(path) if path == &PathBuf::from("/tmp/test-socket"))
        );
        let fixtures = crate::wire::tests::tls::Fixtures::new();
        let Resolved::Tls { target, .. } =
            crate::wire::tests::tls::target(&fixtures, "127.0.0.1:443".parse().unwrap())
        else {
            panic!("TLS target");
        };
        let configured = Endpoint::Tls(Arc::clone(&target));
        let resolved = configured.resolve(None, within).unwrap();
        let Resolved::Tls {
            target: resolved_target,
            addresses,
        } = resolved.as_ref()
        else {
            panic!("TLS target");
        };
        assert!(Arc::ptr_eq(&target, resolved_target));
        assert!(!addresses.is_empty());
        assert!(
            addresses
                .iter()
                .all(|address| address.ip().is_loopback() && address.port() == 443)
        );
    }

    #[test]
    fn a_host_is_a_lowercase_dns_name_without_an_address_port_or_path() {
        assert_eq!(
            HostName::try_from("KO.Example".to_owned())
                .unwrap()
                .as_str(),
            "ko.example"
        );
        for invalid in [
            "",
            "127.0.0.1",
            "::1",
            "[::1]",
            "host:443",
            "host/path",
            "host\nname",
            "-host",
            "host-",
            "host..name",
            "host.",
            "höst",
        ] {
            assert!(
                HostName::try_from(invalid.to_owned()).is_err(),
                "{invalid:?}"
            );
        }
    }
}
