use std::ffi::{CStr, c_char, c_int, c_void};
use std::os::unix::ffi::OsStrExt;
use std::sync::Arc;

use crate::endpoint::tls::{self, Signing};
use boring::ssl::{PrivateKeyMethod, PrivateKeyMethodError, SslRef, SslSignatureAlgorithm};
use boring::x509::X509;

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

impl PrivateKeyMethod for External {
    fn sign(
        &self,
        ssl: &mut SslRef,
        message: &[u8],
        algorithm: SslSignatureAlgorithm,
        output: &mut [u8],
    ) -> Result<usize, PrivateKeyMethodError> {
        tls::signing(ssl, Signing::Failed);
        if algorithm != SslSignatureAlgorithm::ECDSA_SECP256R1_SHA256 {
            return Err(PrivateKeyMethodError::FAILURE);
        }
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
        let bytes = out
            .get(..count)
            .filter(|bytes| !bytes.is_empty())
            .ok_or(PrivateKeyMethodError::FAILURE)?;
        let destination = output
            .get_mut(..count)
            .ok_or(PrivateKeyMethodError::FAILURE)?;
        destination.copy_from_slice(bytes);
        tls::signing(ssl, Signing::Succeeded);
        Ok(count)
    }

    fn decrypt(
        &self,
        _: &mut SslRef,
        _: &[u8],
        _: &mut [u8],
    ) -> Result<usize, PrivateKeyMethodError> {
        Err(PrivateKeyMethodError::FAILURE)
    }

    fn complete(&self, _: &mut SslRef, _: &mut [u8]) -> Result<usize, PrivateKeyMethodError> {
        Err(PrivateKeyMethodError::FAILURE)
    }
}

pub(super) unsafe fn endpoint(
    raw: *const Endpoint,
    roots: Vec<Vec<u8>>,
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
            let certificate = X509::from_der(&certificate).map_err(|_| Code::Argument)?;
            let mut config = endpoint::config(roots).map_err(|_| Code::Argument)?;
            config
                .set_certificate(&certificate)
                .map_err(|_| Code::Argument)?;
            config.set_private_key_method(External {
                user: identity.user,
                sign,
            });
            let config = config.build();
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
            let context = endpoint::config(Vec::new()).unwrap().build();
            let mut ssl = boring::ssl::Ssl::new(context.context()).unwrap();
            assert!(
                signer
                    .sign(
                        &mut ssl,
                        b"message",
                        SslSignatureAlgorithm::ECDSA_SECP256R1_SHA256,
                        &mut [0; 72]
                    )
                    .is_err()
            );
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
