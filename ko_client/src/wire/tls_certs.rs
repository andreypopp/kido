use boring::asn1::Asn1Time;
use boring::bn::BigNum;
use boring::ec::{EcGroup, EcKey};
use boring::hash::MessageDigest;
use boring::nid::Nid;
use boring::pkey::{PKey, Private};
use boring::ssl::{PrivateKeyMethod, PrivateKeyMethodError, SslRef, SslSignatureAlgorithm};
use boring::x509::extension::{
    BasicConstraints, ExtendedKeyUsage, KeyUsage, SubjectAlternativeName,
};
use boring::x509::{X509, X509NameBuilder};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug)]
pub(crate) struct Key {
    pub(crate) key: PKey<boring::pkey::Private>,
    pub(crate) signatures: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}
impl PrivateKeyMethod for Key {
    fn sign(
        &self,
        ssl: &mut SslRef,
        input: &[u8],
        algorithm: SslSignatureAlgorithm,
        out: &mut [u8],
    ) -> Result<usize, PrivateKeyMethodError> {
        assert_eq!(algorithm, SslSignatureAlgorithm::ECDSA_SECP256R1_SHA256);
        let mut signer =
            boring::sign::Signer::new(boring::hash::MessageDigest::sha256(), &self.key).unwrap();
        signer.update(input).unwrap();
        let signature = signer.sign_to_vec().unwrap();
        out[..signature.len()].copy_from_slice(&signature);
        self.signatures
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        crate::endpoint::tls::signing(ssl, crate::endpoint::tls::Signing::Succeeded);
        Ok(signature.len())
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

#[derive(Debug)]
pub(crate) struct Certificate {
    pub(crate) der: Vec<u8>,
    pub(crate) key: Vec<u8>,
    signer: PKey<Private>,
    certificate: X509,
}

#[derive(Debug)]
pub(crate) struct Fixtures {
    pub(crate) root: Certificate,
    pub(crate) server: Certificate,
    pub(crate) client: Certificate,
    pub(crate) other_client: Certificate,
    pub(crate) other_root: Certificate,
}

pub(crate) fn server(config: &mut boring::ssl::SslContextBuilder, fixtures: &Fixtures) {
    config
        .set_min_proto_version(Some(boring::ssl::SslVersion::TLS1_3))
        .unwrap();
    config
        .set_max_proto_version(Some(boring::ssl::SslVersion::TLS1_3))
        .unwrap();
    config
        .cert_store_mut()
        .add_cert(X509::from_der(&fixtures.root.der).unwrap())
        .unwrap();
    let leaf = fixtures.client.der.clone();
    config.set_verify_callback(
        boring::ssl::SslVerifyMode::PEER | boring::ssl::SslVerifyMode::FAIL_IF_NO_PEER_CERT,
        move |valid, context| {
            if valid
                && context.error_depth() == 0
                && !context
                    .current_cert()
                    .is_some_and(|cert| cert.to_der().unwrap() == leaf)
            {
                context.set_error(Err(boring::x509::X509VerifyError::CERT_REJECTED));
                return false;
            }
            valid
        },
    );
    config
        .set_certificate(&X509::from_der(&fixtures.server.der).unwrap())
        .unwrap();
    config
        .set_private_key(&PKey::private_key_from_der(&fixtures.server.key).unwrap())
        .unwrap();
    config.set_options(boring::ssl::SslOptions::NO_TICKET);
}

impl Certificate {
    fn new(name: &str, issuer: Option<&Self>, serial: u32, server: bool) -> Self {
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap();
        let signer = PKey::from_ec_key(EcKey::generate(&group).unwrap()).unwrap();
        let mut subject = X509NameBuilder::new().unwrap();
        subject.append_entry_by_text("CN", name).unwrap();
        let subject = subject.build();
        let mut certificate = X509::builder().unwrap();
        certificate.set_version(2).unwrap();
        certificate
            .set_serial_number(&BigNum::from_u32(serial).unwrap().to_asn1_integer().unwrap())
            .unwrap();
        certificate.set_subject_name(&subject).unwrap();
        certificate
            .set_issuer_name(issuer.map_or(&*subject, |issuer| issuer.certificate.subject_name()))
            .unwrap();
        certificate.set_pubkey(&signer).unwrap();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        certificate
            .set_not_before(&Asn1Time::from_unix(now - 3600).unwrap())
            .unwrap();
        certificate
            .set_not_after(&Asn1Time::from_unix(now + 7 * 86400).unwrap())
            .unwrap();
        let root = issuer.is_none();
        let mut constraints = BasicConstraints::new();
        constraints.critical();
        if root {
            constraints.ca();
        }
        certificate
            .append_extension(&constraints.build().unwrap())
            .unwrap();
        let mut usage = KeyUsage::new();
        usage.critical();
        if root {
            usage.key_cert_sign().crl_sign();
        } else {
            usage.digital_signature();
        }
        certificate
            .append_extension(&usage.build().unwrap())
            .unwrap();
        if !root {
            let mut usage = ExtendedKeyUsage::new();
            if server {
                usage.server_auth();
            } else {
                usage.client_auth();
            }
            certificate
                .append_extension(&usage.build().unwrap())
                .unwrap();
        }
        if server {
            let san = SubjectAlternativeName::new()
                .dns("localhost")
                .build(
                    &certificate
                        .x509v3_context(issuer.map(|issuer| issuer.certificate.as_ref()), None),
                )
                .unwrap();
            certificate.append_extension(&san).unwrap();
        }
        certificate
            .sign(
                issuer.map_or(&signer, |issuer| &issuer.signer),
                MessageDigest::sha256(),
            )
            .unwrap();
        let certificate = certificate.build();
        Self {
            der: certificate.to_der().unwrap(),
            key: signer.private_key_to_der_pkcs8().unwrap(),
            signer,
            certificate,
        }
    }
}

impl Fixtures {
    pub(crate) fn new() -> Self {
        let root = Certificate::new("Kido test root", None, 1, false);
        let server = Certificate::new("localhost", Some(&root), 2, true);
        let client = Certificate::new("Kido test client", Some(&root), 3, false);
        let other_client = Certificate::new("Kido other client", Some(&root), 4, false);
        let other_root = Certificate::new("Kido other root", None, 5, false);
        Self {
            root,
            server,
            client,
            other_client,
            other_root,
        }
    }
}
