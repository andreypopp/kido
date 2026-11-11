use std::collections::VecDeque;

use ko_pane_wire::frame::{self, MAX_CLIPBOARD};
use ko_wire::protocol::{ClipboardContent, ClipboardLocation, Text};

const MAX_PENDING: usize = 16;

pub(crate) fn write(location: ClipboardLocation, contents: &[ClipboardContent]) -> Option<String> {
    let pairs = contents
        .iter()
        .map(|content| (content.mime.as_bytes(), content.data.0.as_slice()));
    frame::first_text(pairs).map(|text| frame::ClipboardLocation::from(location).osc52(text))
}

pub(crate) fn answerable(mimes: &[String], list: bool) -> bool {
    !list && mimes.iter().any(|mime| mime == "text/plain")
}

#[derive(Debug, Default)]
pub(crate) struct Pending(VecDeque<(u64, ClipboardLocation)>);

impl Pending {
    pub(crate) fn ask(&mut self, id: u64, location: ClipboardLocation) -> String {
        if self.0.len() == MAX_PENDING {
            self.0.pop_front();
        }
        self.0.push_back((id, location));
        frame::ClipboardLocation::from(location).osc52_query()
    }

    pub(crate) fn answered(
        &mut self,
        location: ClipboardLocation,
        text: Vec<u8>,
    ) -> Option<(u64, Option<Vec<ClipboardContent>>)> {
        let at = self.0.iter().position(|(_, asked)| *asked == location)?;
        let (id, _) = self.0.remove(at)?;
        let contents = (text.len() <= MAX_CLIPBOARD).then(|| {
            vec![ClipboardContent {
                mime: "text/plain".to_owned(),
                data: Text(text),
            }]
        });
        Some((id, contents))
    }

    pub(crate) fn clear(&mut self) {
        self.0.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_of(contents: Option<Vec<ClipboardContent>>) -> Option<Vec<u8>> {
        contents.map(|contents| contents[0].data.0.clone())
    }

    #[test]
    fn a_write_carries_the_first_text_entry_to_the_named_clipboard() {
        let contents = [
            ClipboardContent {
                mime: "image/png".to_owned(),
                data: Text(b"x".to_vec()),
            },
            ClipboardContent {
                mime: "text/plain".to_owned(),
                data: Text(b"hi".to_vec()),
            },
        ];
        assert_eq!(
            write(ClipboardLocation::Primary, &contents),
            Some("\x1b]52;p;aGk=\x1b\\".to_owned())
        );
        assert_eq!(write(ClipboardLocation::Standard, &contents[..1]), None);
    }

    #[test]
    fn overlapping_reads_of_two_clipboards_get_their_own_answers() {
        let mut pending = Pending::default();
        assert_eq!(
            pending.ask(5, ClipboardLocation::Primary),
            "\x1b]52;p;?\x1b\\"
        );
        assert_eq!(
            pending.ask(6, ClipboardLocation::Standard),
            "\x1b]52;c;?\x1b\\"
        );
        pending.ask(7, ClipboardLocation::Standard);

        let (id, contents) = pending
            .answered(ClipboardLocation::Standard, b"std".to_vec())
            .unwrap();
        assert_eq!((id, text_of(contents)), (6, Some(b"std".to_vec())));
        let (id, contents) = pending
            .answered(ClipboardLocation::Primary, b"prim".to_vec())
            .unwrap();
        assert_eq!((id, text_of(contents)), (5, Some(b"prim".to_vec())));
        let (id, _) = pending
            .answered(ClipboardLocation::Standard, Vec::new())
            .unwrap();
        assert_eq!(id, 7);
        assert!(
            pending
                .answered(ClipboardLocation::Standard, Vec::new())
                .is_none()
        );
    }

    #[test]
    fn a_reply_over_the_limit_is_a_refusal_and_a_cleared_queue_answers_nothing() {
        let mut pending = Pending::default();
        pending.ask(1, ClipboardLocation::Standard);
        let big = vec![b'x'; MAX_CLIPBOARD + 1];
        assert_eq!(
            pending.answered(ClipboardLocation::Standard, big),
            Some((1, None))
        );
        pending.ask(2, ClipboardLocation::Standard);
        pending.clear();
        assert!(
            pending
                .answered(ClipboardLocation::Standard, Vec::new())
                .is_none()
        );
    }
}
