# koa: unfinished work

koa is built; docs/design-koa.md gives its design. This plan holds
only the work that is not done. The question controls in a reply
have their own plan, plans/koa-questions.md.

1. **A visible page's memory.** The stress report has no budget for
   the physical footprint of a visible page. Measure it, find what
   WebKit keeps for a long transcript, and find whether windowing old
   items (dropping their nodes and loading them again through
   `/items`) lowers it. Off the screen, one page of eight in the
   many-panes workload had a footprint of about 320 MiB, against
   about 100 MiB for the others. The result is a budget in
   `share/koa/stress/report.ts` and, if windowing helps, a page change.
2. **Session trees.** `/tree`, forks and clones from the page. pi's
   RPC has `fork`, `clone` and `switch_session`, which koa already
   follows with a rebuild; the page has no view to start them. Needs a
   mockup first.
3. **More built-in slash commands.** pi's RPC mode does not run its
   TUI's built-ins (`get_commands` excludes them), and koa handles
   only `/name`. Each further built-in (`/model`, `/thinking`,
   `/compact`, `/new`, `/resume`, `/session`, `/copy`, `/export`) is
   koa's own handler over an RPC command or a page action, and
   completion then lists it. Decide the set with the user.
