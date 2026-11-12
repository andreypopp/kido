# koa only: the work that remains

koa is Kido's one pi harness, and its agent extension is
`share/koa/koa-agent.ts` (design-koa.md, design.md "The harness
extension"). Units 1 and 2 are on `main`: the `ko-pi` command and the
terminal paths are gone, `share/pi/` moved into `share/koa/`, and the
session entries, the task variable, the jobs symbol and the job log
directory are named `koa`. This plan keeps only the work that is not
done; it is deleted when the last item is done.

## Unit 3: release

A Kido.app release first, because the bundled harness changed, then
`scripts/release.sh` with a minor bump of ko, because the command
`ko-pi` is removed; the script does not detect a shim's removal, so
the version is the user's. The release note tells the user:

- to restart every terminal pi pane as `koa`: `ko-pi` is gone, and a
  running one fails at its next `/reload`;
- that a session written before the rename lists no recorded child
  or peer, has no reports for `read_report`, and cannot restart an
  ended child by name; a live child still lists through its row.

After that ko release, remove the `share/pi/` fallback for the old
prompt snapshot in `scripts/release.sh`.

This is the `/release` sequence, not a unit of code. The user has
not authorised it yet.

## The hygiene of the moved suite

`scripts/lint.sh` forbids `as`, `any` and `!` in `share/koa/*.ts`,
and exempts `koa-agent-*.test.ts`, `koa-agent-fixture.ts`,
`koa-webview-sdk.test.ts` and `agents.test.ts` by name (the `core`
list; about 320 sites at the move). Clean them to the rule and drop the
exemption.

## One extension

Merge `koa-sessions.ts` into `koa-agent.ts`. Today they are two
extensions: `koa-sessions.ts` owns fd 3 and is loaded again on a
folder switch, and the agent extension claims one copy for each
process. A merge must keep both behaviours.
