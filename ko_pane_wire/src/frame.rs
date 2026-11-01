pub const MAX_DIMENSION: u16 = 4096;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants_match_the_c_ko_pane() {
        let header = include_str!("../../ko_pane/protocol.h");
        assert!(header.contains(&format!("#define KO_MAX_DIMENSION {MAX_DIMENSION}u\n")));
    }
}
