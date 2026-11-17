use std::fmt;
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone)]
pub(crate) enum Failure {
    Tls(String),
    Identity(String),
}

impl fmt::Display for Failure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Tls(error) | Self::Identity(error) => error.fmt(formatter),
        }
    }
}
impl std::error::Error for Failure {}

use boring::error::ErrorStack;
use boring::ex_data::Index;
use boring::ssl::{Ssl, SslAlert};
#[cfg(any(target_vendor = "apple", test))]
use boring::ssl::{
    SslConnector, SslConnectorBuilder, SslContextBuilder, SslInfoCallbackMode,
    SslInfoCallbackValue, SslMethod, SslMode, SslOptions, SslRef, SslSessionCacheMode, SslVersion,
};
#[cfg(target_vendor = "apple")]
use ko_sys::event::Wake;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Signing {
    NotStarted,
    Succeeded,
    Failed,
}

#[cfg(target_vendor = "apple")]
#[derive(Debug)]
enum Verify {
    NotStarted,
    Running,
    Done(Result<(), String>),
}

#[derive(Debug)]
struct State {
    signing: Signing,
    alert: Option<SslAlert>,
    #[cfg(target_vendor = "apple")]
    verify: Verify,
}

#[cfg(all(test, target_vendor = "apple"))]
#[derive(Debug)]
pub(crate) struct Gate {
    pub(crate) started: std::sync::mpsc::Sender<()>,
    pub(crate) release: Mutex<std::sync::mpsc::Receiver<()>>,
    pub(crate) done: std::sync::mpsc::Sender<()>,
}

#[derive(Debug)]
pub(crate) struct Connection {
    state: Arc<Mutex<State>>,
    #[cfg(target_vendor = "apple")]
    wake: Arc<Wake>,
    #[cfg(target_vendor = "apple")]
    host: String,
    #[cfg(all(test, target_vendor = "apple"))]
    gate: Option<Arc<Gate>>,
}

impl Connection {
    pub(crate) fn new(host: &str) -> std::io::Result<Self> {
        #[cfg(not(target_vendor = "apple"))]
        let _ = host;
        Ok(Self {
            state: Arc::new(Mutex::new(State {
                signing: Signing::NotStarted,
                alert: None,
                #[cfg(target_vendor = "apple")]
                verify: Verify::NotStarted,
            })),
            #[cfg(target_vendor = "apple")]
            wake: Arc::new(Wake::new()?),
            #[cfg(target_vendor = "apple")]
            host: host.to_owned(),
            #[cfg(all(test, target_vendor = "apple"))]
            gate: None,
        })
    }

    #[cfg(target_vendor = "apple")]
    pub(crate) fn wake(&self) -> Arc<Wake> {
        Arc::clone(&self.wake)
    }

    #[cfg(all(test, target_vendor = "apple"))]
    pub(crate) fn gate(&mut self, gate: Arc<Gate>) {
        self.gate = Some(gate);
    }

    pub(crate) fn failure(&self, text: &str, peer_alert: Option<u64>) -> Option<Failure> {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.signing == Signing::Failed
            || (state.signing == Signing::Succeeded
                && (matches!(peer_alert, Some(42 | 49 | 116))
                    || matches!(
                        state.alert,
                        Some(
                            SslAlert::BAD_CERTIFICATE
                                | SslAlert::CERTIFICATE_REQUIRED
                                | SslAlert::ACCESS_DENIED
                        )
                    )))
        {
            return Some(Failure::Identity(text.to_owned()));
        }
        #[cfg(target_vendor = "apple")]
        if let Verify::Done(Err(reason)) = &state.verify {
            return Some(Failure::Tls(reason.clone()));
        }
        None
    }
}

pub(crate) fn index() -> Result<Index<Ssl, Connection>, ErrorStack> {
    static INDEX: OnceLock<Result<Index<Ssl, Connection>, ErrorStack>> = OnceLock::new();
    INDEX.get_or_init(Ssl::new_ex_index).clone()
}

#[cfg(any(target_vendor = "apple", test))]
pub(crate) fn signing(ssl: &SslRef, result: Signing) {
    if let Ok(index) = index()
        && let Some(connection) = ssl.ex_data(index)
    {
        connection
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .signing = result;
    }
}

#[cfg(any(target_vendor = "apple", test))]
pub(crate) fn config(roots: Vec<Vec<u8>>) -> Result<SslConnectorBuilder, ErrorStack> {
    let mut builder = SslConnector::builder(SslMethod::tls())?;
    configure(&mut builder, roots)?;
    builder.set_alpn_protos(b"\x08http/1.1")?;
    Ok(builder)
}

#[cfg(any(target_vendor = "apple", test))]
pub(crate) fn configure(
    builder: &mut SslContextBuilder,
    roots: Vec<Vec<u8>>,
) -> Result<(), ErrorStack> {
    let index = index()?;
    builder.set_min_proto_version(Some(SslVersion::TLS1_3))?;
    builder.set_max_proto_version(Some(SslVersion::TLS1_3))?;
    builder.set_options(SslOptions::NO_TICKET);
    builder.set_session_cache_mode(SslSessionCacheMode::OFF);
    builder.set_mode(SslMode::ENABLE_PARTIAL_WRITE | SslMode::ACCEPT_MOVING_WRITE_BUFFER);
    builder.set_sigalgs_list("ecdsa_secp256r1_sha256")?;
    builder.set_info_callback(move |ssl, mode, value| {
        if mode == SslInfoCallbackMode::READ_ALERT
            && let SslInfoCallbackValue::Alert(alert) = value
            && let Some(connection) = ssl.ex_data(index)
        {
            connection
                .state
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .alert = Some(alert.alert());
        }
    });
    #[cfg(not(target_vendor = "apple"))]
    {
        builder.set_verify(boring::ssl::SslVerifyMode::PEER);
        builder.set_default_verify_paths()?;
        for root in roots {
            builder
                .cert_store_mut()
                .add_cert(boring::x509::X509::from_der(&root)?)?;
        }
    }
    #[cfg(target_vendor = "apple")]
    {
        use boring::ssl::{SslVerifyError, SslVerifyMode};
        let roots = Arc::new(roots);
        builder.set_custom_verify_callback(SslVerifyMode::PEER, move |ssl| {
            let connection = ssl
                .ex_data(index)
                .ok_or(SslVerifyError::Invalid(SslAlert::INTERNAL_ERROR))?;
            let mut state = connection
                .state
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            match &state.verify {
                Verify::Done(Ok(())) => return Ok(()),
                Verify::Done(Err(_)) => {
                    return Err(SslVerifyError::Invalid(SslAlert::BAD_CERTIFICATE));
                }
                Verify::Running => return Err(SslVerifyError::Retry),
                Verify::NotStarted => {}
            }
            let chain = ssl
                .peer_cert_chain()
                .ok_or(SslVerifyError::Invalid(SslAlert::BAD_CERTIFICATE))?
                .iter()
                .map(|cert| cert.to_der())
                .collect::<Result<Vec<_>, _>>()
                .map_err(|_| SslVerifyError::Invalid(SslAlert::BAD_CERTIFICATE))?;
            let ocsp = ssl.ocsp_status().map(<[u8]>::to_vec);
            let host = connection.host.clone();
            let roots = Arc::clone(&roots);
            let shared = Arc::clone(&connection.state);
            let wake = Arc::clone(&connection.wake);
            #[cfg(test)]
            let gate = connection.gate.clone();
            state.verify = Verify::Running;
            if let Err(error) = std::thread::Builder::new()
                .name("ko-trust".to_owned())
                .spawn(move || {
                    #[cfg(test)]
                    let released = gate.as_ref().map_or(Ok(()), |gate| {
                        gate.started.send(()).map_err(|error| error.to_string())?;
                        gate.release
                            .lock()
                            .unwrap_or_else(|error| error.into_inner())
                            .recv_timeout(std::time::Duration::from_secs(5))
                            .map_err(|error| error.to_string())
                    });
                    #[cfg(not(test))]
                    let released: Result<(), String> = Ok(());
                    let result =
                        released.and_then(|()| verify(&chain, &roots, &host, ocsp.as_deref()));
                    shared
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .verify = Verify::Done(result);
                    wake.wake();
                    #[cfg(test)]
                    if let Some(gate) = gate {
                        let _ = gate.done.send(());
                    }
                })
            {
                state.verify = Verify::Done(Err(error.to_string()));
                return Err(SslVerifyError::Invalid(SslAlert::INTERNAL_ERROR));
            }
            Err(SslVerifyError::Retry)
        });
    }
    Ok(())
}

#[cfg(target_vendor = "apple")]
fn verify(
    chain: &[Vec<u8>],
    roots: &[Vec<u8>],
    host: &str,
    ocsp: Option<&[u8]>,
) -> Result<(), String> {
    use security_framework::{
        certificate::SecCertificate, policy::SecPolicy, secure_transport::SslProtocolSide,
        trust::SecTrust,
    };
    let chain = chain
        .iter()
        .map(|der| SecCertificate::from_der(der).map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let roots = roots
        .iter()
        .map(|der| SecCertificate::from_der(der).map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let policy = SecPolicy::create_ssl(SslProtocolSide::SERVER, Some(host));
    let mut trust =
        SecTrust::create_with_certificates(&chain, &[policy]).map_err(|error| error.to_string())?;
    if !roots.is_empty() {
        trust
            .set_anchor_certificates(&roots)
            .map_err(|error| error.to_string())?;
        trust
            .set_trust_anchor_certificates_only(false)
            .map_err(|error| error.to_string())?;
    }
    if let Some(ocsp) = ocsp {
        trust
            .set_trust_ocsp_response(std::iter::once(ocsp))
            .map_err(|error| error.to_string())?;
    }
    trust
        .evaluate_with_error()
        .map_err(|error| error.to_string())
}
