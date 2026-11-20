# Koa page snapshots on the host

Approved by the user on 2026-11-20; starts after the restructuring of
plans/koa-snapshots.md lands, because both change the same test files.

A `make` target renders the Koa page states headless on the host in
seconds and compares them with local baselines that are not committed.
The VM stays the committed reference and the final check; the host
check is for iteration only.

A spike (2026-11-20, scratch only) showed: an off-screen WKWebView in a
command-line process with activation policy `.prohibited` and an
unordered window never changed the frontmost app; five launches gave
byte-identical PNGs; four states (notice closed and expanded, light
and dark, 1920x1114 px) differed from the guest baselines in 0 pixels;
a capture took about 80 ms and a warm start about 0.4 s to readiness.
Four equal states do not prove that every state, or a later host macOS,
agrees with the guest.

Shape: move the page-driving code of `app/VisualTests/KoaWebviewTests.swift`
and the readiness fence and paint retry of `app/VisualTests/AppWindowCase.swift`
into code that both the XCTest class and the host runner use (clock,
focus, animation, theme, font and cell metrics, viewport, scale).
`verifySnapshot` takes a `snapshotDirectory`, so the host baselines live
in an ignored directory keyed by the host's macOS build. States that
need native keyboard routing, previews or app chrome stay VM-only.
