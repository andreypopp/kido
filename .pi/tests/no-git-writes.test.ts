import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { after, test } from "node:test";
import { blocksGitWrite, blocksSignal, blocksSleep, parentSession } from "../extensions/no-git-writes/policy.ts";

const allowed = [
  "git status", "git diff --cached", "git log -3", "git show HEAD", "git grep TODO",
  "git ls-files -s", "git rev-parse HEAD", "git fetch origin", "git stash list", "git stash show",
  "git branch", "git branch --list", "git branch --show-current", "git branch -a",
  "git worktree list", "git worktree prune", "git worktree add --detach /tmp/kido-isolation HEAD",
  "git -C . worktree add --detach '/tmp/kido isolation' HEAD",
  "env GIT_DIR=.git git -C . status && git diff", "echo 'git stash'", "printf '%s' 'git add .'",
  "# git stash\ngit status", "git log --grep='git commit'", "bash -c 'git status && git diff'",
  "echo \"$(git status)\"", "git diff | grep add", "(git status; git log)", "git st\\\natus",
];
const blocked = [
  ...["commit", "push", "add", "rm", "mv", "reset", "checkout", "switch", "restore", "stash", "rebase", "merge", "cherry-pick", "revert", "tag", "clean", "am", "update-index"].map((name) => `git ${name}`),
  "git restore --staged .", "git rm --cached file", "git apply --index patch", "git apply patch",
  "git branch -d topic", "git branch -D topic", "git branch -m new", "git branch --delete topic",
  "git branch topic", "git worktree add /tmp/new", "git worktree remove /tmp/new",
  "git worktree add --detach ./local", "git worktree add --detach /tmp/../repo",
  "git worktree add -b topic --detach /tmp/new", "git -C '/some dir' add .",
  "git -c core.editor=true --git-dir .git commit", "git --work-tree=. add .",
  "FOO=bar git add .", "env FOO=bar git stash", "env -u FOO git stash", "command git checkout .",
  "git status && git add .", "git stash list && git stash", "git diff; git reset --hard",
  "git status | git checkout .", "(git status; (git stash))", "git status\ngit push",
  "bash -c 'git stash list && git stash'", "env FOO=bar sh -c 'git add .'",
  "echo $(git add .)", "echo \"$(git add .)\"", "echo `git stash`", "eval 'git push'",
  "if true; then git stash; fi", "/usr/bin/git add .", "'git' 'add' .", "g\\it a\\dd .",
];

for (const command of allowed) {
  test(`allow: ${command}`, () => assert.equal(blocksGitWrite(command, "parent"), false));
}
for (const command of blocked) {
  test(`block: ${command}`, () => assert.equal(blocksGitWrite(command, "parent"), true));
}
test("top-level: every blocked command is allowed with no parent session", () => {
  for (const command of blocked) assert.equal(blocksGitWrite(command, undefined), false);
});
test("empty parent session is top-level", () => assert.equal(blocksGitWrite("git stash", ""), false));

test("KO_AGENT_PARENT_SESSION makes a spawned agent: git writes are blocked", () => {
  const session = parentSession({ KO_AGENT_PARENT_SESSION: "parent" });
  assert.equal(blocksGitWrite("git add .", session), true);
  assert.equal(blocksGitWrite("git status", session), false);
});
const root = realpathSync(mkdtempSync("/var/tmp/no-git-writes-"));
const tmpRoot = mkdtempSync("/tmp/no-git-writes-");
const home = `${root}/home`;
mkdirSync(`${home}/Workspace/kido-real`, { recursive: true });
mkdirSync(`${root}/outside`);
symlinkSync("/etc", `${home}/Workspace/kido-link`);
symlinkSync("/etc", `${home}/Workspace/kido-real/up`);
symlinkSync("kido-loop", `${home}/Workspace/kido-loop`);
symlinkSync(`${home}/Workspace/kido-real`, `${root}/outside/alias`);
symlinkSync(`${root}/outside`, `${tmpRoot}/out`);
symlinkSync(home, `${root}/linked-home`);
after(() => {
  rmSync(root, { recursive: true });
  rmSync(tmpRoot, { recursive: true });
});
const addWorktree = (path: string, homeDir = home) => blocksGitWrite(`git worktree add --detach ${path} HEAD`, "parent", homeDir);

test("worktree add --detach: kido-<name> directly in $HOME/Workspace and /tmp are allowed", () => {
  for (const path of [`${home}/Workspace/kido-x`, `${home}/Workspace/kido-x/`, `${home}/Workspace//kido-x`, `${home}/Workspace/./kido-x/.`,
    "~/Workspace/kido-x", "~/Workspace/kido-x/", "$HOME/Workspace/kido-x", "${HOME}/Workspace/kido-x", "~/Workspace//kido-x",
    `'${home}/Workspace/kido-y z'`, `${home}/Workspace/kido-x/../kido-y`, `${home}/Workspace/kido-real`,
    `${root}/outside/alias`, "/tmp/x", "/tmp/../tmp/x", "/tmp//x", `${tmpRoot}/x`]) {
    assert.equal(addWorktree(path), false, path);
  }
  assert.equal(addWorktree("~/Workspace/kido-x", `${root}/linked-home`), false);
  assert.equal(addWorktree(`${root}/linked-home/Workspace/kido-x`), false);
});
test("worktree add --detach: near misses, escapes, symlinks and relative paths are refused", () => {
  for (const path of [`${home}/Workspace/kido-`, `${home}/Workspace/kidox`, `${home}/Workspace/kido`, `${home}/Workspace/kido-x/sub`,
    `${home}/Workspace/kido-x/../../evil`, `${home}/Workspace/kido-x/..`, `${home}/Workspace/other`, `${home}/kido-x`,
    "~/Workspace/kido-", "~/Workspace/kidox", "~/Workspace/kido-x/../../evil", "$HOME/Workspace/../kido-x", "~user/Workspace/kido-x",
    "Workspace/kido-x", "./kido-x", "../kido-x", "kido-x",
    `${home}/Workspace/kido-link`, `${home}/Workspace/kido-link/x`, "~/Workspace/kido-link", `${home}/Workspace/kido-real/up/../x`,
    `${home}/Workspace/kido-real/up/x`, `${home}/Workspace/kido-loop`, `${home}/Workspace/kido-loop/x`,
    `${tmpRoot}/out/x`, `${tmpRoot}/out`, `${root}/outside/alias/x`,
    "/Users/nobody/Workspace/kido-x", "/tmp", "/tmpx/y"]) {
    assert.equal(addWorktree(path), true, path);
  }
});
test("worktree add: ~ and $HOME expand only when the shell would expand them", () => {
  for (const path of ["'~/Workspace/kido-x'", "'$HOME/Workspace/kido-x'", '"$HOME/Workspace/kido-x"', '"~/Workspace/kido-x"', "'${HOME}/Workspace/kido-x'",
    "\\~/Workspace/kido-x", "\\$HOME/Workspace/kido-x", "\\${HOME}/Workspace/kido-x", "''~/Workspace/kido-x", "x~/Workspace/kido-x"]) {
    assert.equal(addWorktree(path), true, path);
  }
});
test("worktree add: only value-less options are allowed", () => {
  const dir = `${home}/Workspace/kido-x`;
  for (const option of ["-f", "--force", "-q", "--quiet", "--no-checkout", "--checkout"]) {
    assert.equal(blocksGitWrite(`git worktree add --detach ${option} ${dir} HEAD`, "parent", home), false, option);
  }
  for (const command of [
    `git worktree add --detach --reason x ${dir}`, `git worktree add --detach --orphan ${dir}`, `git worktree add --detach --guess-remote ${dir}`,
    `git worktree add --detach -- ${dir}`, `git worktree add --detach --lock ${dir}`, `git worktree add --detach -b t ${dir}`,
    `git worktree add --detach -B t ${dir}`, `git worktree add ${dir}`, "git worktree add --detach",
  ]) assert.equal(blocksGitWrite(command, "parent", home), true, command);
});

test("neither variable set is a top-level session", () => {
  assert.equal(blocksGitWrite("git add .", parentSession({})), false);
  assert.equal(blocksGitWrite("git add .", parentSession({ KO_AGENT_PARENT_SESSION: "" })), false);
});

test("sleep is blocked, also inside a script, and other commands are not", () => {
  for (const command of ["sleep 5", "make test; sleep 240; tail log", "sh -c 'sleep 1'", "x=$(sleep 1)", "/bin/sleep 1"])
    assert.equal(blocksSleep(command), true, command);
  for (const command of ["tail -f log", "echo sleep", "grep sleep file", "make sleepy"])
    assert.equal(blocksSleep(command), false, command);
});

test("pkill, killall and kill are blocked, a mention of kill is not", () => {
  for (const command of ["pkill -f x", "killall node", "kill -9 123", "kill %1", "/bin/kill 5", "sh -c 'pkill x'"])
    assert.equal(blocksSignal(command), true, command);
  for (const command of ["grep kill file", "echo kill", "make killall-docs"])
    assert.equal(blocksSignal(command), false, command);
});
