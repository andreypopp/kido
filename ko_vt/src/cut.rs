const HEADER: usize = 10;
// Tag.ready and Tag.kitty_image_payload in src/terminal/snapshot/record.zig; the C API does not
// export the record tags.
const READY: u16 = 5;
const KITTY_PAYLOAD: u16 = 9;

#[derive(Debug)]
pub(crate) struct Cut {
    header: [u8; HEADER],
    have: usize,
    left: usize,
    tag: u16,
    envelope: bool,
    screen: bool,
    done: bool,
}

impl Cut {
    pub(crate) fn new(screen: bool) -> Cut {
        Cut {
            header: [0; HEADER],
            have: 0,
            left: 0,
            tag: 0,
            envelope: false,
            screen,
            done: false,
        }
    }

    pub(crate) fn done(&self) -> bool {
        self.done
    }

    fn keep(&self) -> bool {
        self.tag != KITTY_PAYLOAD
    }

    pub(crate) fn feed<E>(
        &mut self,
        mut bytes: &[u8],
        emit: &mut impl FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), E> {
        while !bytes.is_empty() && !self.done {
            if self.left == 0 {
                let take = (HEADER - self.have).min(bytes.len());
                let (taken, rest) = bytes.split_at(take);
                if let Some(slot) = self.header.get_mut(self.have..self.have + take) {
                    slot.copy_from_slice(taken);
                }
                self.have += take;
                bytes = rest;
                if self.have < HEADER {
                    continue;
                }
                self.have = 0;
                if self.envelope {
                    let [t0, t1, l0, l1, l2, l3, ..] = self.header;
                    self.tag = u16::from_le_bytes([t0, t1]);
                    self.left = u32::from_le_bytes([l0, l1, l2, l3]) as usize;
                } else {
                    self.envelope = true;
                    self.tag = 0;
                    self.left = 0;
                }
                if self.keep() {
                    emit(&self.header)?;
                }
                if self.screen && self.tag == READY {
                    self.done = true;
                    return Ok(());
                }
            }
            let (taken, rest) = bytes.split_at(self.left.min(bytes.len()));
            if !taken.is_empty() && self.keep() {
                emit(taken)?;
            }
            bytes = rest;
            self.left -= taken.len();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(tag: u16, payload: &[u8]) -> Vec<u8> {
        let [t0, t1] = tag.to_le_bytes();
        let [l0, l1, l2, l3] = u32::try_from(payload.len()).unwrap().to_le_bytes();
        let mut bytes = vec![t0, t1, l0, l1, l2, l3, 0, 0, 0, 0];
        bytes.extend_from_slice(payload);
        bytes
    }

    fn stream() -> Vec<u8> {
        [
            vec![7; HEADER],
            record(2, b"abc"),
            record(KITTY_PAYLOAD, b"image"),
            record(3, b""),
            record(READY, b""),
            record(4, b"after ready"),
        ]
        .concat()
    }

    fn cut(screen: bool, chunk: usize) -> (Vec<u8>, bool) {
        let mut cut = Cut::new(screen);
        let mut out = Vec::new();
        for piece in stream().chunks(chunk) {
            cut.feed::<()>(piece, &mut |bytes| {
                out.extend_from_slice(bytes);
                Ok(())
            })
            .unwrap();
        }
        (out, cut.done())
    }

    #[test]
    fn image_payloads_are_dropped_and_a_screen_stops_after_the_ready_header_however_it_arrives() {
        let kept = [
            vec![7; HEADER],
            record(2, b"abc"),
            record(3, b""),
            record(READY, b""),
        ]
        .concat();
        let full = [kept.clone(), record(4, b"after ready")].concat();
        for chunk in [1, 3, 10, 11, 4096] {
            assert_eq!(
                cut(true, chunk),
                (kept.clone(), true),
                "screen, chunks of {chunk}"
            );
            assert_eq!(
                cut(false, chunk),
                (full.clone(), false),
                "full, chunks of {chunk}"
            );
        }
    }

    #[test]
    fn an_emit_error_stops_the_feed() {
        let mut cut = Cut::new(false);
        let mut calls = 0;
        let result = cut.feed(&stream(), &mut |_| {
            calls += 1;
            if calls == 2 { Err("stopped") } else { Ok(()) }
        });
        assert_eq!((result, calls), (Err("stopped"), 2));
    }
}
