use ko_vt_sys as sys;

pub fn clusters(text: &str) -> Vec<(&str, u8)> {
    let points: Vec<(usize, u32)> = text
        .char_indices()
        .map(|(at, c)| (at, u32::from(c)))
        .collect();
    let codepoints: Vec<u32> = points.iter().map(|(_, c)| *c).collect();
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(rest) = codepoints.get(from..).filter(|rest| !rest.is_empty()) {
        let mut width = 0u8;
        // SAFETY: rest holds rest.len() initialized codepoints, and width is writable.
        let used =
            unsafe { sys::ghostty_unicode_grapheme_width(rest.as_ptr(), rest.len(), &mut width) }
                .max(1);
        let start = points.get(from).map_or(text.len(), |(at, _)| *at);
        from += used;
        let end = points.get(from).map_or(text.len(), |(at, _)| *at);
        out.push((text.get(start..end).unwrap_or_default(), width));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clusters_carry_their_display_width() {
        assert_eq!(
            clusters("a界e\u{301}"),
            [("a", 1), ("界", 2), ("e\u{301}", 1)]
        );
    }
}
