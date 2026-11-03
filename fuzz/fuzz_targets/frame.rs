#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| assert!(ko_pane_wire::frame::check_sizes(data)));
