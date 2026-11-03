use ko_pane_wire::frame::{ClipboardLocation, Contents, Req};

#[derive(Debug, Default)]
pub(crate) struct Reads {
    open: Vec<(Req, ClipboardLocation)>,
    next: u64,
}

impl Reads {
    pub(crate) fn open(&mut self, location: ClipboardLocation) -> Req {
        let req = Req::of_serial(self.next);
        self.next = self.next.wrapping_add(1);
        self.open.push((req, location));
        req
    }

    pub(crate) fn answer(&mut self, req: Req, contents: Option<Contents<'_>>) -> Option<Vec<u8>> {
        let at = self.open.iter().position(|(open, _)| open.same(req))?;
        let (_, location) = self.open.swap_remove(at);
        let text = contents
            .and_then(|contents| contents.text())
            .unwrap_or_default();
        Some(location.osc52(text).into_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ko_pane_wire::frame::ContentsBuf;

    #[test]
    fn an_answer_closes_its_read_and_text_is_the_first_text_entry() {
        let mut reads = Reads::default();
        let first = reads.open(ClipboardLocation::Primary);
        let second = reads.open(ClipboardLocation::Standard);
        let contents =
            ContentsBuf::new([(&b"image/png"[..], &b"x"[..]), (b"text/plain", b"hi")].into_iter())
                .unwrap();
        assert_eq!(
            reads.answer(second, Some(contents.view())),
            Some(b"\x1b]52;c;aGk=\x1b\\".to_vec())
        );
        assert_eq!(reads.answer(second, None), None);
        assert_eq!(
            reads.answer(first, None),
            Some(b"\x1b]52;p;\x1b\\".to_vec())
        );
    }
}
