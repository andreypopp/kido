import assert from "node:assert/strict";
import { test } from "node:test";
import { blocksGitWrite } from "../extensions/no-git-writes/policy.ts";

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
  test(`top-level: ${command}`, () => assert.equal(blocksGitWrite(command, undefined), false));
}
test("empty parent session is top-level", () => assert.equal(blocksGitWrite("git stash", ""), false));
