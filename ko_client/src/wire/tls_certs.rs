use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_ASN1_SIGNING, EcdsaKeyPair, KeyPair};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug)]
pub(crate) struct Certificate {
    pub(crate) der: Vec<u8>,
    pub(crate) key: Vec<u8>,
    signer: EcdsaKeyPair,
    subject: Vec<u8>,
}

#[derive(Debug)]
pub(crate) struct Fixtures {
    pub(crate) root: Certificate,
    pub(crate) server: Certificate,
    pub(crate) client: Certificate,
    pub(crate) other_client: Certificate,
    pub(crate) other_root: Certificate,
}

fn der(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut output = vec![tag];
    if body.len() < 128 {
        output.push(body.len() as u8);
    } else {
        let length = body.len().to_be_bytes();
        let length = &length[length.iter().position(|byte| *byte != 0).unwrap()..];
        output.push(0x80 | length.len() as u8);
        output.extend(length);
    }
    output.extend(body);
    output
}

fn oid(bytes: &[u8]) -> Vec<u8> {
    der(6, bytes)
}
fn sequence(parts: &[Vec<u8>]) -> Vec<u8> {
    der(0x30, &parts.concat())
}

fn time(seconds: u64) -> Vec<u8> {
    let days = (seconds / 86400) as i64 + 719468;
    let era = days / 146097;
    let day = days - era * 146097;
    let year = (day - day / 1460 + day / 36524 - day / 146096) / 365;
    let ordinal = day - (365 * year + year / 4 - year / 100);
    let month = (5 * ordinal + 2) / 153;
    let date = ordinal - (153 * month + 2) / 5 + 1;
    let month = month + if month < 10 { 3 } else { -9 };
    let year = year + era * 400 + i64::from(month <= 2);
    der(
        0x17,
        format!(
            "{:02}{month:02}{date:02}{:02}{:02}{:02}Z",
            year % 100,
            seconds / 3600 % 24,
            seconds / 60 % 60,
            seconds % 60
        )
        .as_bytes(),
    )
}

fn extension(id: &[u8], critical: bool, value: Vec<u8>) -> Vec<u8> {
    let mut fields = vec![oid(id)];
    if critical {
        fields.push(der(1, &[0xff]));
    }
    fields.push(der(4, &value));
    sequence(&fields)
}

impl Certificate {
    fn new(name: &str, issuer: Option<&Self>, serial: u8, server: bool) -> Self {
        let random = SystemRandom::new();
        let key = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &random).unwrap();
        let signer =
            EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, key.as_ref(), &random)
                .unwrap();
        let subject = sequence(&[der(
            0x31,
            &sequence(&[oid(&[0x55, 4, 3]), der(0x0c, name.as_bytes())]),
        )]);
        let issuer_name = issuer.map_or(&subject, |issuer| &issuer.subject);
        let algorithm = sequence(&[oid(&[0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2])]);
        let public = sequence(&[
            sequence(&[
                oid(&[0x2a, 0x86, 0x48, 0xce, 0x3d, 2, 1]),
                oid(&[0x2a, 0x86, 0x48, 0xce, 0x3d, 3, 1, 7]),
            ]),
            der(3, &[&[0][..], signer.public_key().as_ref()].concat()),
        ]);
        let root = issuer.is_none();
        let mut extensions = vec![
            extension(
                &[0x55, 0x1d, 0x13],
                true,
                sequence(&if root { vec![der(1, &[0xff])] } else { vec![] }),
            ),
            extension(
                &[0x55, 0x1d, 0x0f],
                true,
                der(3, if root { &[1, 6] } else { &[7, 0x80] }),
            ),
        ];
        if !root {
            extensions.push(extension(
                &[0x55, 0x1d, 0x25],
                false,
                sequence(&[oid(&[0x2b, 6, 1, 5, 5, 7, 3, if server { 1 } else { 2 }])]),
            ));
        }
        if server {
            extensions.push(extension(
                &[0x55, 0x1d, 0x11],
                false,
                sequence(&[der(0x82, b"localhost")]),
            ));
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let tbs = sequence(&[
            der(0xa0, &der(2, &[2])),
            der(2, &[serial]),
            algorithm.clone(),
            issuer_name.clone(),
            sequence(&[time(now - 3600), time(now + 7 * 86400)]),
            subject.clone(),
            public,
            der(0xa3, &sequence(&extensions)),
        ]);
        let signature = issuer
            .map_or(&signer, |issuer| &issuer.signer)
            .sign(&random, &tbs)
            .unwrap();
        let certificate = sequence(&[
            tbs,
            algorithm,
            der(3, &[&[0][..], signature.as_ref()].concat()),
        ]);
        Self {
            der: certificate,
            key: key.as_ref().to_vec(),
            signer,
            subject,
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
