# Accepting contributions

The top-level session does the git work and coordinates subagents.
Agents for different PRs run in parallel.
The review and verify steps for one PR are independent.
They can run in parallel.

1. Check out each PR into a separate worktree.
   Replace `N` with the PR number.
   Run `git fetch origin pull/N/head`.
   Record the fetched head SHA.
   Run `git worktree add --detach "$(mktemp -d /tmp/kido-prN-XXXXXX)" <head sha>`.
   Run `git -C <worktree> submodule update --init third_party/tmux`.
   The e2e stage needs the fork source.
   Record the PR's base.
   Record how many commits the PR is behind main.

2. Assign the review to Fable (`claude-bridge/claude-fable-5-1`).
   Ask the reviewer to check correctness, style and functionality.
   Ask the reviewer to check the PR against the project values in
   AGENTS.md's "Code rules".
   Ask the reviewer to check that the PR follows the existing code
   standards: the AGENTS.md "OCaml" conventions, and the naming, idiom
   and layout of the code around the change.
   Ask the reviewer to check each added comment against the "No comments
   unless absolutely necessary" rule.
   Each comment that is not an external constraint, a workaround reason
   or an issue link is a finding.
   Require a verdict.
   Require a severity (`P1`, `P2` or `nit`) and `file:line` for each finding.

3. Run `make verify` in full in the PR's worktree.
   Rerun each failing test on main.
   Separate failures that the PR causes from pre-existing failures.
   Check that the PR's new tests fail without its change.

4. After the review and tests finish, run a simplify pass over the PR's diff.
   Use the simplify skill at `~/.pi/agent/skills/simplify/SKILL.md`.
   Check reuse, simplification, efficiency and altitude.
   Require the pass to report its findings.
   Do not let the pass commit to the contributor's branch.

5. Present a report for each PR to the user.
   Include:
   - what the PR does;
   - the review verdict and findings;
   - the test results;
   - the simplify findings;
   - a recommendation.

   The user decides whether to merge.
   Do not merge without the user's approval.
   Merge by squashing only: `gh pr merge N --squash`.
   Write the squash subject and body in the project's commit style.
   Do not comment on the PR without the user's approval.
   Do not push without the user's approval.

6. Remove each worktree with `rm -rf`.
   Then run `git worktree prune`.
   The submodule makes `git worktree remove` refuse.
