import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import kidoPi from "./kido-pi.ts";
import { createFakePi, fakeCtx, makeFixture, selfPane, startSessionCore, withEnv } from "./kido-pi-fixture.ts";

function makeRepo(repo: string): string {
  const common = join(repo, ".git");
  mkdirSync(join(common, "objects"), { recursive: true });
  mkdirSync(join(common, "refs"));
  writeFileSync(join(common, "HEAD"), "ref: refs/heads/main\n");
  return realpathSync(common);
}

test("project trust accepts a shared worktree repo only with the spawner's trusted root", async () => {
  const fx = makeFixture();
  try {
    const repo = join(fx.stateDir, "repo");
    const common = makeRepo(repo);
    const worktree = join(fx.stateDir, "worktree");
    mkdirSync(worktree);
    const gitdir = join(common, "worktrees", "child");
    mkdirSync(gitdir, { recursive: true });
    writeFileSync(join(gitdir, "HEAD"), "ref: refs/heads/main\n");
    writeFileSync(join(gitdir, "commondir"), "../..\n");
    writeFileSync(join(gitdir, "gitdir"), join(worktree, ".git"));
    writeFileSync(join(worktree, ".git"), `gitdir: ${gitdir}\n`);
    const s = createFakePi();
    kidoPi(s.pi as never);
    await withEnv({ KIDO_AGENT_TRUSTED_ROOT: common }, async () => {
      assert.deepEqual(await s.emit("project_trust", { cwd: worktree }), [{ trusted: "yes" }]);
      const unrelated = join(fx.stateDir, "unrelated");
      mkdirSync(unrelated);
      await withEnv({ GIT_DIR: common }, async () => {
        assert.deepEqual(await s.emit("project_trust", { cwd: unrelated }), [{ trusted: "undecided" }]);
      });
      const submodule = join(repo, "submodule");
      const moduleDir = join(common, "modules", "submodule");
      mkdirSync(join(moduleDir, "objects"), { recursive: true });
      mkdirSync(join(moduleDir, "refs"));
      writeFileSync(join(moduleDir, "HEAD"), "ref: refs/heads/main\n");
      mkdirSync(submodule);
      writeFileSync(join(submodule, ".git"), `gitdir: ${moduleDir}\n`);
      assert.deepEqual(await s.emit("project_trust", { cwd: submodule }), [{ trusted: "undecided" }]);
      assert.deepEqual(await s.emit("project_trust", { cwd: join(fx.stateDir, "missing") }), [{ trusted: "undecided" }]);
    });
    await withEnv({ KIDO_AGENT_TRUSTED_ROOT: undefined, KIDO_AGENT_PARENT_SESSION: undefined, KIDO_AGENT_DIR: undefined }, async () => {
      assert.deepEqual(await s.emit("project_trust", { cwd: worktree }), [{ trusted: "undecided" }]);
    });
  } finally { await fx.restore(); }
});

test("spawn_agent passes the trusted root only while its parent trusts the repo", async () => {
  const fx = makeFixture();
  try {
    fx.setPanes([selfPane()]);
    let trusted = true;
    const cwd = join(fx.stateDir, "repo");
    const root = makeRepo(cwd);
    const s = await startSessionCore(fx, kidoPi, (c) => ({ ...fakeCtx("self-session", c.ui), cwd, isProjectTrusted: () => trusted }));
    const spawn = s.tools.get("spawn_agent");
    await spawn.execute("c", { name: "trusted", task: "x" });
    assert.ok(fx.runCalls().at(-1)!.includes(`KIDO_AGENT_TRUSTED_ROOT=${root}`));
    trusted = false;
    await spawn.execute("c", { name: "untrusted", task: "x" });
    assert.equal(fx.runCalls().at(-1)!.some((arg) => arg.startsWith("KIDO_AGENT_TRUSTED_ROOT=")), false);
  } finally { await fx.restore(); }
});
