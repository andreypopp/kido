# koa: open work

The implemented design is in
[docs/design-koa.md](../docs/design-koa.md). Each item below needs its
own unit and decision before implementation.

1. **Visible-page memory.** DOM windowing and the streaming-history
   relative budget are implemented. A general physical-footprint
   budget for visible WebKit pages is not. Measure the reported-only
   workloads and choose a budget in `koa/stress/report.ts`.
2. **Session tree UI.** The page has no tree navigation, fork or clone
   UI. Design a mockup before adding one. The existing SDK actions do
   not supply the page interaction.
3. **Additional built-ins.** `koa/koa-commands.ts` defines the supported
   commands. Each addition to that set is a product decision.
4. **View hierarchy keys.** The view bar, links and sidebar actions
   select views. Keyboard navigation of the hierarchy needs a design.
5. **Terminal resume picker.** Consider an in-process picker only
   with a design that preserves terminal ownership before the page
   starts and bounds cancellation and startup failure.
6. **Queue patch.** Remove the clearQueue patch only when the selected
   pi API preserves custom messages during user queue take-back.
7. **Runtime file completion.** Consider querying files in the runtime
   instead of on the host. This needs a latency and cancellation design;
   it is not scheduled.

The draft editor still observes a child pane's death under the
on-exit close policy. Removing that policy is not a completed cleanup:
it needs a replacement for that observation before the server's
linger rule can be considered for removal.
