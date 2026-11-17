use std::ffi::{CStr, c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;
use std::sync::Arc;

use rustls::pki_types::CertificateDer;
use rustls::sign::{CertifiedKey, Signer, SigningKey};
use rustls::{SignatureAlgorithm, SignatureScheme};

use super::{Code, slice_of, text_of};
use crate::endpoint::{self, HostName, Tls};

pub(super) const KO_ENDPOINT_UNIX: c_int = 1;
pub(super) const KO_ENDPOINT_TLS: c_int = 2;

#[allow(non_camel_case_types)]
pub(super) type ko_sign_fn =
    unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut u8, usize) -> usize;

#[repr(C)]
#[derive(Debug)]
pub struct Endpoint {
    pub(super) kind: c_int,
    pub(super) socket: *const c_char,
    pub(super) host: *const c_char,
    pub(super) port: u16,
    pub(super) identity: *const Identity,
}

#[repr(C)]
#[derive(Debug)]
pub(super) struct Identity {
    pub(super) certificate: *const u8,
    pub(super) certificate_len: usize,
    pub(super) sign: Option<ko_sign_fn>,
    pub(super) user: *mut c_void,
}

#[derive(Debug)]
struct External {
    user: *mut c_void,
    sign: ko_sign_fn,
}

// SAFETY: ko_client.h requires `sign` to accept calls from any thread, also at once,
// and `user` to stay valid until the close of the handle that owns this value.
unsafe impl Send for External {}
// SAFETY: ko_client.h requires `sign` to accept calls from any thread, also at once,
// and `user` to stay valid until the close of the handle that owns this value.
unsafe impl Sync for External {}

impl Signer for External {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        let mut out = [0u8; 72];
        // SAFETY: both buffers are valid for their lengths for the call; `sign` writes at
        // most `capacity` bytes and keeps neither pointer.
        let count = unsafe {
            (self.sign)(
                self.user,
                message.as_ptr(),
                message.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        match out.get(..count).filter(|bytes| !bytes.is_empty()) {
            Some(bytes) => Ok(bytes.to_vec()),
            None => Err(rustls::Error::Other(rustls::OtherError(Arc::new(
                crate::wire::stream::IdentitySigningFailed,
            )))),
        }
    }

    fn scheme(&self) -> SignatureScheme {
        SignatureScheme::ECDSA_NISTP256_SHA256
    }
}

#[derive(Debug)]
struct Key(Arc<External>);

impl SigningKey for Key {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        offered
            .contains(&SignatureScheme::ECDSA_NISTP256_SHA256)
            .then(|| Box::new(Key(Arc::clone(&self.0))) as Box<dyn Signer>)
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        SignatureAlgorithm::ECDSA
    }
}

impl Signer for Key {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        self.0.sign(message)
    }

    fn scheme(&self) -> SignatureScheme {
        self.0.scheme()
    }
}

pub(super) unsafe fn endpoint(
    raw: *const Endpoint,
    roots: Vec<CertificateDer<'static>>,
) -> Result<endpoint::Endpoint, Code> {
    // SAFETY: ko_client.h requires the endpoint and its active fields to be readable.
    let raw = unsafe { raw.as_ref() }.ok_or(Code::Argument)?;
    let scope = ();
    match raw.kind {
        KO_ENDPOINT_UNIX => {
            if raw.socket.is_null() {
                return Err(Code::Argument);
            }
            // SAFETY: the active socket is NUL-terminated and readable by contract.
            let socket = unsafe { CStr::from_ptr(raw.socket) }.to_bytes();
            if socket.is_empty() {
                return Err(Code::Argument);
            }
            Ok(endpoint::Endpoint::Unix(
                std::ffi::OsStr::from_bytes(socket).into(),
            ))
        }
        KO_ENDPOINT_TLS => {
            if raw.port == 0 {
                return Err(Code::Argument);
            }
            // SAFETY: the active host is NUL-terminated and readable by contract.
            let host = unsafe { text_of(raw.host, &scope) }.ok_or(Code::Argument)?;
            let host = HostName::try_from(host.to_owned()).map_err(|_| Code::Argument)?;
            // SAFETY: the active identity is readable by contract.
            let identity = unsafe { raw.identity.as_ref() }.ok_or(Code::Argument)?;
            let sign = identity.sign.ok_or(Code::Argument)?;
            if identity.certificate_len == 0 {
                return Err(Code::Argument);
            }
            // SAFETY: the certificate is readable for certificate_len bytes by contract.
            let certificate =
                unsafe { slice_of(identity.certificate, identity.certificate_len, &scope) }
                    .ok_or(Code::Argument)?
                    .to_vec();
            let key = CertifiedKey::new(
                vec![CertificateDer::from(certificate)],
                Arc::new(Key(Arc::new(External {
                    user: identity.user,
                    sign,
                }))),
            );
            let config = endpoint::config(Arc::new(key), roots).map_err(|_| Code::Argument)?;
            Ok(endpoint::Endpoint::Tls(Arc::new(Tls::new(
                host, raw.port, config,
            ))))
        }
        _ => Err(Code::Argument),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn count(
        user: *mut c_void,
        _: *const u8,
        _: usize,
        _: *mut u8,
        _: usize,
    ) -> usize {
        user.addr()
    }

    #[test]
    fn signer_refuses_invalid_counts() {
        for count_value in [0, 73] {
            let signer = External {
                user: std::ptr::without_provenance_mut(count_value),
                sign: count,
            };
            assert!(signer.sign(b"message").is_err());
        }
    }

    #[test]
    fn decoder_refuses_invalid_active_fields() {
        let certificate = [0];
        let mut identity = Identity {
            certificate: certificate.as_ptr(),
            certificate_len: 1,
            sign: None,
            user: std::ptr::null_mut(),
        };
        let mut raw = Endpoint {
            kind: 3,
            socket: std::ptr::null(),
            host: c"localhost".as_ptr(),
            port: 443,
            identity: &identity,
        };
        let decode = |raw| {
            // SAFETY: each non-null field points to readable test storage.
            unsafe { endpoint(raw, Vec::new()) }.unwrap_err()
        };
        assert_eq!(decode(std::ptr::null()), Code::Argument);
        assert_eq!(decode(&raw), Code::Argument);
        raw.kind = 1;
        assert_eq!(decode(&raw), Code::Argument);
        raw.socket = c"".as_ptr();
        assert_eq!(decode(&raw), Code::Argument);
        raw.socket = c"/tmp/socket".as_ptr();
        raw.kind = 2;
        raw.host = c"host:443".as_ptr();
        assert_eq!(decode(&raw), Code::Argument);
        raw.host = c"localhost".as_ptr();
        raw.port = 0;
        assert_eq!(decode(&raw), Code::Argument);
        raw.port = 443;
        raw.identity = std::ptr::null();
        assert_eq!(decode(&raw), Code::Argument);
        raw.identity = &identity;
        assert_eq!(decode(&raw), Code::Argument);
        identity.sign = Some(count);
        identity.certificate = std::ptr::null();
        raw.identity = &identity;
        assert_eq!(decode(&raw), Code::Argument);
    }
}
