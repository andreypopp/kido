import { basename, resolve, sep } from "node:path";

function tokens(command: string): string[] {
  const result: string[] = [];
  let word = "";
  let quote = "";
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (ch === "\\" && quote !== "'") {
      const next = command[++i];
      if (next !== undefined && next !== "\n") word += next;
    } else if (quote) {
      if (ch === quote) quote = "";
      else word += ch;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
    } else if (ch === "#" && !word) {
      while (i < command.length && command[i] !== "\n") i++;
      result.push(";");
    } else if (ch !== undefined && /[\s;&|()<>`]/.test(ch)) {
      if (word) result.push(word);
      word = "";
      if (!/[ \t\r]/.test(ch)) result.push(";");
    } else {
      word += ch;
    }
  }
  if (word) result.push(word);
  return result;
}

function gitWrite(args: string[]): boolean {
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
    return !add.includes("--detach") || add.some((arg) => ["-b", "-B", "--lock"].includes(arg)) ||
      path === undefined || !resolve(path).startsWith(`${resolve("/tmp")}${sep}`);
  }
  return ["commit", "push", "add", "rm", "mv", "reset", "checkout", "switch", "restore", "rebase", "merge", "cherry-pick", "revert", "tag", "clean", "am", "apply", "update-index"].includes(subcommand ?? "");
}

export function blocksGitWrite(command: string, parentSession: string | undefined): boolean {
  if (!parentSession) return false;
  const words = tokens(command);
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
    if (executable === "git" && gitWrite(args.slice(i + 1))) return true;
    if (["bash", "sh", "zsh", "eval"].includes(executable)) {
      const script = executable === "eval" ? args.slice(i + 1).join(" ") : args[args.indexOf("-c", i + 1) + 1];
      if (script && script !== args[0] && blocksGitWrite(script, parentSession)) return true;
    }
    for (const arg of args) {
      if ((arg.includes("$(") || arg.includes("`")) && blocksGitWrite(arg.replace(/\$\(/g, ";"), parentSession)) return true;
    }
    if (end < 0) break;
    start = end + 1;
  }
  return false;
}
