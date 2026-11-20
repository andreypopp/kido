# Koa snapshot restructuring

Approved by the user on 2026-11-20: start after the threads widget-modes unit lands. The audit below (read-only, at de32ebe2f) is the starting design; the unit's planner checks it against the code at its base.

User constraints: keep every existing dark variant unless two baselines are byte-identical; snapshots stay cropped to the view under test; timing-dependent visual states are removed; geometry, presence and order facts go to `koa/koa-dom.test.ts`; recording happens only in the VM guest.

## Audit: 1. Inventory

Read-only audit at `de32ebe2f`; no tests or app runs.

`app/VisualTests/KoaWebviewTests.swift:73` defines **90 test methods**. The snapshot directory contains **498 PNGs, 47,261,477 bytes (45.1 MiB)**:
- 244 light, 245 dark, 9 without a theme suffix.
- 200 filenames contain “narrow”; this is not an exact width count: responsive tests use numeric widths, and `foot-narrow` also names a long-working state.
- Default widths: 980 and 470; responsive widths: 674/554/374/250/190, plus 420.

Per-method baseline counts, including shared ownership: **0×6, 1×1, 2×45, 4×8, 6×7, 7×1, 8×6, 10×6, 12×2, 14×2, 20×2, 22×1, 28×2, 50×1**. Normally each requested capture produces light+dark. Exceptions and aliases are at `app/VisualTests/KoaWebviewTests.swift:800`. Their sum is 500, not 498: narrow status shares idle’s two files; Dots has one stale dark-bare file and six current captures.

Top ten methods; names below omit `testKoaWebview`:
- ComposerFootResponsive **50** — `app/VisualTests/KoaWebviewTests.swift:380`
- BangWide/BangNarrow **28 each** — `app/VisualTests/KoaWebviewTests.swift:374`
- CommandsNarrow **22** — `app/VisualTests/KoaWebviewTests.swift:457`
- SessionsWide/SessionsNarrow **20 each** — `app/VisualTests/KoaWebviewTests.swift:645`
- AgentsWide/AgentsNarrow **14 each** — `app/VisualTests/KoaWebviewTests.swift:541`
- Controls **12** — `app/VisualTests/KoaWebviewTests.swift:497`
- CompletionNarrow **12** — `app/VisualTests/KoaWebviewTests.swift:641`

The four host methods have no PNG comparisons: `app/VisualTests/KoaHostTests.swift:22`.

## Audit: 2. What is duplicated

- **Footer:** five states across five widths, plus picker/long-model cases. Checks fit, hidden cells and picker bounds, but captures the whole page. Three cwd cases already alias working baselines. See `app/VisualTests/KoaWebviewTests.swift:1145`.
- **Bang:** mode styling, attachments, running/output/error/cancel/truncation. Four attachment/drop PNGs are byte-identical pairs across both themes and widths. Behaviour already has DOM coverage at `koa/koa-dom.test.ts:256`.
- **Sessions/completion/commands/controls:** popup, notice and composer presentation mixed with filtering, acceptance, cancellation and data changes. Much behaviour already exists at `koa/koa-dom.test.ts:333`, `koa/koa-dom.test.ts:437`, `koa/koa-dom.test.ts:487`.
- **Agents/views/jobs:** distinct card/header/output styles deserve images; navigation, node retention and padding assertions do not require full transcripts. Existing coverage includes `koa/koa-dom.test.ts:2070` and `koa/koa-dom.test.ts:2826`.
- **Markdown/media/questions/threads:** retain distinct visual treatments and wrapping; crop their component. Reply-pill presence/filtering already has coverage at `koa/koa-dom.test.ts:589`.
- **Reveal:** explicitly captures an intermediate animation phase. Remove that visual state; retain folded-code appearance. Timing/clip logic already has DOM tests at `koa/koa-dom.test.ts:3591`.

## Audit: 3. Proposal

**Reduce change exposure first, not merely file count.**

Extend the snapshot helper at `app/VisualTests/AppWindowCase.swift:347` to crop a checked selector rectangle, with padding for borders/shadows:

- Footer: `.field .foot`; composer states: `#composer`.
- Pickers: `#picker`, `.koa-complete`, `#session-picker`.
- Notices: `.nrow`; dialogs: `.dialog`.
- Cards/tools: `.agent-step`, `.job-step`, `.step`.
- View navigation: `#viewbar`; job output: `#jobv`.
- Markdown/media/questions: the relevant message or block, excluding unrelated reply headers.

Keep a small wide/narrow, light/dark integration set for page composition. Keep **every existing dark variant**, cropped, except duplicate baselines and the explicitly removed timing state. Restore deterministic coverage for stale dark-bare rather than silently deleting it.

Move geometry/presence/order assertions—including footer fit, dock spacing, queue order and pill alignment—into `koa/koa-dom.test.ts`; extend its geometry fixture where required, rather than asserting CSS layout through a fake that cannot model it.

Share the four identical bang/drop baselines. Remove two reveal-mid PNGs. Remove approximately 14 data/transition-only **light** captures where dark coverage remains. **Estimated total: 478 PNGs.** No giant contact sheets.

A reply-pill change should then affect **roughly 20–40 PNGs**: dedicated pill/thread examples plus composition anchors, not every footer, popup, notice or tool test. Cropping—not theme deletion—provides this reduction.

## Audit: 4. Cost and risks

Merge footer-state, thread, job and path methods into component families; retain all required state/theme comparisons. Target **35–45 fixture starts instead of 90**.

Without timings, estimate class execution at **8–20 minutes today versus 4–10 minutes after**, excluding build/VM queue time. Cropping alone will save inspection time, not halve execution time.

Effort: **2–4 engineering days**, plus one final guest recording/review. Risks: clipped shadows, lost composition checks, and fake geometry giving false confidence. Keep explicit composition anchors and reject empty/out-of-bounds crops. This follows the component-snapshot rule at `docs/design-app.md:3451`; recording remains guest-only per `docs/verification.md:65`.
