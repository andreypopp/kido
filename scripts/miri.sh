#!/usr/bin/env bash
# Usage: scripts/miri.sh
# Miri on the modules that have no sockets, FFI or processes: the frame codec, the ring over heap memory
# (ko_sys/src/mapping/heap.rs), ids, the wire types and the HTTP head reader. conn.rs and pane_proc.rs
# run on unix sockets and a poll loop, which Miri cannot run.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/nightly.sh
skip_without_nightly miri miri --version
# -Zmiri-disable-isolation: the heap mapping holds /dev/null as its descriptor
export MIRIFLAGS="-Zmiri-disable-isolation -Zmiri-strict-provenance"
# the proptest tests are skipped: proptest reads its regression files and takes thousands of cases
status=0
boxed miri.sh 1500 make --no-print-directory nightly-cargo ARGS="miri test --locked -p ko_pane_wire -- \
  frame:: ring:: fuzz::tests::the_model --skip the_ring_agrees_with_a_list_of_records \
  --skip every_frame_size_in_a_stream_is_between_the_header_and_the_input" || status=1
boxed miri.sh 1500 make --no-print-directory nightly-cargo ARGS="miri test --locked -p ko_server -- \
  ids:: protocol:: http:: --skip decoders_return_a_value_or_a_decode_error --skip routes_return_a_route_nothing_or_invalid \
  --skip a_request_cut_into_pieces --skip a_head_of_n_bytes_parses_up_to_the_limit_and_is_too_large_above" || status=1
exit $status
