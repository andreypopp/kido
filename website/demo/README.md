# Product video recordings

macOS, kitty, Swift, ffmpeg, Python 3 and authenticated pi are required. The demo uses the real pi agent/tools; it never fabricates output or sidebar state.

## Private build and recording

Build a matched kido + tmux fork into `output/prefix` with `./build.sh <fork-source-checkout>` (see its revision check). Nothing is installed into Homebrew or ~/.local. Recording defaults to this private prefix and the tmux scenario; `KIDO_DEMO_PREFIX` can select another private build, not an installed kido.

```sh
cd website/demo
./record.sh tmux --check
./record.sh tmux
./record.sh subagents
./record.sh async
./record.sh subagents --render-only
python3 -m unittest test_pipeline.py
```

## Scenarios

- **tmux / Interactive sidebar:** one session/window/pane, two visible splits, a new window and two more splits. Pane 1 runs `sleep 3; false`, pane 2 starts pi and receives `hello`, pane 3 takes focus. The sidebar zoom shows running → red error and pi → done, then returns to full view.
- **subagents:** the exact requested prompt asks A for the sum of two random 0–10 integers and B for twice that sum. B is launched first so A can address it safely. A runs the real `sum.py`, sends B the actual numbers/sum, and both use notify_parent. The camera zooms as children appear, returns to full once both exist, and holds the parent's numeric result. Evidence checks the actual arithmetic and tool/run records.
- **async / CI monitor:** pi launches `./ci-monitor.sh` with real async_bash, stream=true. The first line announces commit a22dfd; only after pi's reaction does an external, hidden runtime signal release the failure line. The agent reacts again. The monitor **continues running**, and the video ends with its live sidebar row, not a completion notice. It is bounded to five minutes after failure and is stopped during private-server cleanup. The release wait has a 90-second fallback. No signal command or path is displayed.

## Appearance and camera

1240×744 kitty window, font_size 22 PragmataPro Mono Liga, plain `$ ` prompt, brand palette, and identical #2a3a33 borders. The sidebar is 26 columns. There are no pre-populated api/web/infra sessions: every take starts with exactly one integrated shell. Actual README/source content fills the opening frame; that **first frame is the poster**.

Prompt zooms are 1.3–1.35×, bottom-right for the single-pane pi scenarios; sidebar zooms reach 1.45×, anchored to preserve its left edge. Cosine transitions take 0.8s. Per-scenario cuts smoothly accelerate only bounded waiting intervals, preserving the appearance/reaction milestones. The finish stays visible for at least two seconds. Desktop output is 1600×960, mobile 1080×1350. Mobile intentionally includes the sidebar and/or left part of the relevant pane rather than fitting a tiny full-width terminal.

## Files and review

`../public/media/{tmux,subagents,async}[-mobile].{mp4,webm,jpg}`: silent 30fps H.264/VP9 yuv420p and first-frame posters. Videos target 20–35 seconds.

Ignored `output/` retains each `<scenario>-source.mov`, `<scenario>-timeline.json`, `<scenario>/camera{,-mobile}.json`, agent evidence JSON and font diagnostics. `output/stills/<scenario>[-mobile]-{00,05,09,18,end}.jpg` contains review frames; extra event-specific stills can be extracted with ffmpeg. `--render-only` uses the retained capture and timeline without new agent calls.

## Isolation, focus, permissions and cleanup

Each take checks the Mac is unlocked before starting. If it is locked, stop and unlock it; do not work around the lock. ScreenCaptureKit preflights Screen Recording permission without requesting it. If denied, grant the app launching the script permission in **System Settings → Privacy & Security → Screen Recording**, then restart that app.

Capture targets only the new kitty process's exact window: no desktop region, audio, cursor or shadow. Kitty may stop repainting when occluded: leave the demo window focused during a take. The private remote-control socket raises only this instance before capture and at scenario milestones. Existing kitty windows are never addressed.

TMUX/TMUX_PANE/KIDO_AGENT_* are removed. Private TMUX_TMPDIR, KIDO_STATE_DIR, config, ZDOTDIR, pi sessions and socket live in `/tmp/kido-demo-*`. The socket is asserted to be under that runtime before every tmux operation. The temporary `~/src/greeter` directory must not already exist; it is owned by the take and removed afterward. HOME is preserved only for pi authentication. Personal extensions/context discovery are disabled.

All waits have deadlines. Cleanup closes only demo kitty, kills only the asserted private server, removes the owned project and stops the bounded, owned caffeinate process. Runtime logs are retained for debugging; output/build/cache files stay ignored.
