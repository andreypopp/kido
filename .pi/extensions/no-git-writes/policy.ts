import { lstatSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";

function tokens(command: string, home: string): string[] {
  const result: string[] = [];
  let word = "";
  let inWord = false;
  let quote = "";
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (ch === "\\" && quote !== "'") {
      inWord = true;
      const next = command[++i];
      if (next !== undefined && next !== "\n") word += next;
    } else if (quote) {
      if (ch === quote) quote = "";
      else word += ch;
    } else if (ch === "'" || ch === '"') {
      inWord = true;
      quote = ch;
    } else if (ch === "#" && !word) {
      while (i < command.length && command[i] !== "\n") i++;
      result.push(";");
    } else if (ch !== undefined && /[\s;&|()<>`]/.test(ch)) {
      if (word) result.push(word);
      word = "";
      inWord = false;
      if (!/[ \t\r]/.test(ch)) result.push(";");
    } else {
      const expanded = inWord ? undefined : /^(?:~|\$HOME|\$\{HOME\})(?=\/)/.exec(command.slice(i))?.[0];
      inWord = true;
      if (expanded) {
        word += home;
        i += expanded.length - 1;
      } else {
        word += ch;
      }
    }
  }
  if (word) result.push(word);
  return result;
}

function physicalPath(path: string): string {
  let existing = path;
  const rest: string[] = [];
  for (;;) {
    try {
      lstatSync(existing);
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    rest.unshift(basename(existing));
    existing = dirname(existing);
  }
  return resolve(realpathSync(existing), ...rest);
}

function worktreeAllowed(path: string, home: string): boolean {
  if (!isAbsolute(path)) return false;
  try {
    const real = physicalPath(path);
    return real.startsWith(`${physicalPath("/tmp")}${sep}`) ||
      (dirname(real) === physicalPath(join(home, "Workspace")) && /^kido-./.test(basename(real)));
  } catch {
    return false;
  }
}

const worktreeFlags = ["--detach", "-f", "--force", "-q", "--quiet", "--no-checkout", "--checkout"];

function gitWrite(args: string[], home: string): boolean {
  let i = 0;
  while (args[i]?.startsWith("-")) {
    const option = args[i++];
    if (["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"].includes(option ?? "")) i++;
  }
  const subcommand = args[i++];
  const rest = args.slice(i);
  if (subcommand === "stash") return !["list", "show"].includes(rest[0] ?? "");
  if (subcommand === "branch") {
    return rest.some((arg) => /^-[^-]*[dDmMcC]/.test(arg) || /^--(?:delete|move|copy|edit-description|set-upstream-to|unset-upstream)(?:=|$)/.test(arg)) ||
      (rest.length > 0 && !rest[0]?.startsWith("-"));
  }
  if (subcommand === "worktree") {
    if (rest[0] === "prune" || rest[0] === "list") return false;
    if (rest[0] !== "add") return true;
    const add = rest.slice(1);
    const path = add.find((arg) => !arg.startsWith("-"));
    return !add.includes("--detach") || add.some((arg) => arg.startsWith("-") && !worktreeFlags.includes(arg)) ||
      path === undefined || !worktreeAllowed(path, home);
  }
  return ["commit", "push", "add", "rm", "mv", "reset", "checkout", "switch", "restore", "rebase", "merge", "cherry-pick", "revert", "tag", "clean", "am", "apply", "update-index"].includes(subcommand ?? "");
}

function runs(command: string, home: string, hit: (executable: string, args: string[]) => boolean): boolean {
  const words = tokens(command, home);
  for (let start = 0; start < words.length;) {
    const end = words.indexOf(";", start);
    const args = words.slice(start, end < 0 ? undefined : end);
    let i = 0;
    while (args[i]) {
      const arg = args[i] ?? "";
      if (["-u", "--unset", "-C", "--chdir"].includes(arg)) i += 2;
      else if (/^[\w]+=.*/.test(arg) || ["env", "command", "exec", "sudo", "!", "then", "do", "if"].includes(arg) || arg.startsWith("-")) i++;
      else break;
    }
    const executable = basename(args[i] ?? "");
    if (hit(executable, args.slice(i + 1))) return true;
    if (["bash", "sh", "zsh", "eval"].includes(executable)) {
      const script = executable === "eval" ? args.slice(i + 1).join(" ") : args[args.indexOf("-c", i + 1) + 1];
      if (script && script !== args[0] && runs(script, home, hit)) return true;
    }
    for (const arg of args) {
      if ((arg.includes("$(") || arg.includes("`")) && runs(arg.replace(/\$\(/g, ";"), home, hit)) return true;
    }
    if (end < 0) break;
    start = end + 1;
  }
  return false;
}

export function blocksGitWrite(command: string, parentSession: string | undefined, home = homedir()): boolean {
  return !!parentSession && runs(command, home, (executable, args) => executable === "git" && gitWrite(args, home));
}

export function blocksSleep(command: string, home = homedir()): boolean {
  return runs(command, home, (executable) => executable === "sleep");
}

export function blocksSignal(command: string, home = homedir()): boolean {
  return runs(command, home, (executable) => ["pkill", "killall", "kill"].includes(executable));
}

export const parentSession = (env: NodeJS.ProcessEnv): string | undefined =>
  env.KO_AGENT_PARENT_SESSION || undefined;
