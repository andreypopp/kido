#![deny(clippy::indexing_slicing, clippy::arithmetic_side_effects)]

use crate::http;
use crate::ids::ClientId;
use crate::protocol::RequestTarget;
use ko_pane_wire::ring::{SLICE_HEADER, SLICE_MAX};
use miniz_oxide::inflate::TINFLStatus;
use miniz_oxide::inflate::core::{DecompressorOxide, decompress, inflate_flags};
use std::io::{self, Cursor};
use tungstenite::protocol::frame::FrameHeader;
use tungstenite::protocol::frame::coding::OpCode;

pub const RECORD_HEADER: usize = 9;
pub const OUTPUT: u8 = 1;
pub const SNAPSHOT: u8 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BadRecord {
    Short,
    Kind(u8),
    Inflate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed<'a> {
    Output { offset: u64, data: &'a [u8] },
    Snapshot { offset: u64, slice: Vec<u8> },
}

pub fn parse_record(payload: &[u8]) -> Result<Parsed<'_>, BadRecord> {
    let (Some(&kind), Some(offset), Some(body)) = (
        payload.first(),
        payload
            .get(1..RECORD_HEADER)
            .and_then(|bytes| bytes.try_into().ok())
            .map(u64::from_le_bytes),
        payload.get(RECORD_HEADER..),
    ) else {
        return Err(BadRecord::Short);
    };
    match kind {
        OUTPUT => Ok(Parsed::Output { offset, data: body }),
        SNAPSHOT => {
            let (header, packed) = body
                .split_at_checked(SLICE_HEADER)
                .ok_or(BadRecord::Short)?;
            let slice = inflate(header, packed, SLICE_MAX).ok_or(BadRecord::Inflate)?;
            Ok(Parsed::Snapshot { offset, slice })
        }
        other => Err(BadRecord::Kind(other)),
    }
}

pub fn upgrade_request(
    method: &str,
    target: &RequestTarget,
    client: Option<ClientId>,
    headers: &[(&str, &str)],
) -> (Vec<u8>, String) {
    let key = tungstenite::handshake::client::generate_key();
    let mut extra = vec![
        ("Upgrade", "websocket"),
        ("Connection", "Upgrade"),
        ("Sec-WebSocket-Version", "13"),
        ("Sec-WebSocket-Key", key.as_str()),
    ];
    extra.extend_from_slice(headers);
    (http::call(method, target, client, &extra, b""), key)
}

pub fn accepted(response: &http::Response, key: &str) -> io::Result<()> {
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    if response.status == 101
        && response.header("sec-websocket-accept") == Some(&accept)
        && !response.headers.iter().any(|(name, value)| {
            name.eq_ignore_ascii_case("sec-websocket-extensions") && !value.trim().is_empty()
        })
    {
        Ok(())
    } else {
        Err(refused(response))
    }
}

pub fn refused(response: &http::Response) -> io::Error {
    io::Error::other(format!(
        "WebSocket upgrade failed: {} {}",
        response.status, response.reason
    ))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub opcode: u8,
    pub header: usize,
    pub length: usize,
}

pub fn parse_frame(buffer: &[u8]) -> Option<Frame> {
    let mut cursor = Cursor::new(buffer);
    let (header, length) = FrameHeader::parse(&mut cursor).ok()??;
    Some(Frame {
        opcode: u8::from(header.opcode),
        header: usize::try_from(cursor.position()).ok()?,
        length: usize::try_from(length).ok()?,
    })
}

pub fn masked(opcode: u8, fin: bool, payload: &[u8], key: [u8; 4], lie: i64) -> Vec<u8> {
    let declared = i64::try_from(payload.len())
        .unwrap_or(0)
        .saturating_add(lie);
    let header = FrameHeader {
        is_final: fin,
        opcode: OpCode::from(opcode),
        mask: Some(key),
        ..FrameHeader::default()
    };
    let mut frame = Vec::new();
    let _ = header.format(u64::try_from(declared).unwrap_or(0), &mut frame);
    frame.extend(
        payload
            .iter()
            .zip(key.iter().cycle())
            .map(|(byte, mask)| byte ^ mask),
    );
    frame
}

fn inflate(prefix: &[u8], packed: &[u8], limit: usize) -> Option<Vec<u8>> {
    let start = prefix.len();
    let cap = start.saturating_add(limit);
    let mut out = vec![0; start.saturating_add(packed.len().saturating_mul(8).min(limit))];
    out.get_mut(..start)?.copy_from_slice(prefix);
    let mut state = Box::<DecompressorOxide>::default();
    let mut input = packed;
    let mut at = 0usize;
    loop {
        let (status, taken, written) = decompress(
            &mut state,
            input,
            out.get_mut(start..)?,
            at,
            inflate_flags::TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF,
        );
        at = at.saturating_add(written);
        input = input.get(taken..)?;
        match status {
            TINFLStatus::Done if input.is_empty() => {
                out.truncate(start.saturating_add(at));
                return Some(out);
            }
            TINFLStatus::HasMoreOutput if out.len() < cap => {
                out.resize(out.len().saturating_mul(2).max(64).min(cap), 0);
            }
            _ => return None,
        }
    }
}
