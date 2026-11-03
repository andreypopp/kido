const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn sextet(byte: u8) -> Option<u32> {
    BASE64
        .iter()
        .position(|&symbol| symbol == byte)
        .and_then(|index| u32::try_from(index).ok())
}

pub fn decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let last = bytes.len() / 4;
    for (index, quad) in bytes.chunks(4).enumerate() {
        let padding = quad.iter().rev().take_while(|&&byte| byte == b'=').count();
        if padding > 2 || (padding > 0 && index + 1 != last) {
            return None;
        }
        let mut word = 0;
        for &byte in &quad[..4 - padding] {
            word = word << 6 | sextet(byte)?;
        }
        word <<= 6 * padding;
        let [_, a, b, c] = word.to_be_bytes();
        out.extend_from_slice(&[a, b, c][..3 - padding]);
    }
    Some(out)
}

pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let mut word = [0; 4];
        word[1..=group.len()].copy_from_slice(group);
        let word = u32::from_be_bytes(word);
        for index in 0..4 {
            if index <= group.len() {
                let symbol = (word >> (18 - 6 * index)) & 63;
                out.push(char::from(BASE64[symbol as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}
