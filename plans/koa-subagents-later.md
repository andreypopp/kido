# After in-process subagents

In-process subagents are built (docs/design-subagents.md;
docs/design.md, "Decisions", 2026-11-13). These items stay, each its
own unit:

1. **`close: on_exit` and the linger grace go.** Their reason, a
   parent's ending notice that read a child's lingering screen, went
   with the child panes. koa's editor float can take the default
   `exit`; the sweep then loses its linger rule and the focus guard
   (docs/design.md, "Window lifecycle").
2. **Keys for the view hierarchy.** Today only the view bar, an
   `@name` link and the sidebar's record switch koa's view
   (docs/design-koa.md, "Views").
3. **The `--resume` picker in-process.** `koa-resume.ts` is still a
   child process, because it owns the terminal before the webview.
4. **The queue patch goes** when pi has a `clearQueue` that keeps
   custom messages (docs/design-koa.md, "The process").
