# Decisions for P1.3 (2026-10-30)

The P1.3 manager applies these and then moves them into p1-mvp.md.
Delete this file when that is done.

1. Scrollback compression is always on, in two places:
   - `ko-pane`: after writes, read `ghostty_terminal_compression_activity`;
     when the token stays unchanged for an idle period, call
     `ghostty_terminal_compress(..., INCREMENTAL)` from the poll loop
     until it returns `COMPLETE`.
   - The client mirror (`ko_vt`/`ko_tui`): the same idle steps, and the
     snapshot decoder option that compresses history pages while it
     restores them.
   No option turns it off.
2. Scrollback limits follow Ghostty 1.4's names and defaults:
   - `--scrollback-bytes`, default 50 MB (50_000_000), replaces
     `--scrollback` and its 32 MiB default; maps to
     `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`.
   - `--scrollback-lines`, default unlimited; maps to
     `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`.
   - The first limit reached applies. The byte limit counts uncompressed
     pages, so compression lowers resident memory, not retained history.
   - The client mirror uses the same limits as the server's terminal
     (the mirrored-terminal contract); `/version` reports them.
3. P1.3 measures resident memory per pane and per client with
   compression against the p1-mvp.md section 6 targets.
