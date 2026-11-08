#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    ko_pane_wire::fuzz::webview(data);
});
