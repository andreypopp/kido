#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ''|--update-prompts) ;;
  *) echo "usage: scripts/lint.sh [--update-prompts]" >&2; exit 1 ;;
esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failed=0
# A negative pid or a process group reaches kill(2) only through ko_sys::pid, signal_child and the Go signal helpers.
signal_pattern='\bUnix(Labels)?\.kill\b|\bkillpg\b|\bkill[[:space:]]*\([[:space:]]*-|syscall\.Kill|unix\.Kill|os\.FindProcess'
signals=$( {
  grep -rnE "$signal_pattern" bench test_e2e \
      --include='*.c' --include='*.h' --include='*.go' --include='*.py' \
    | grep -vE '^test_e2e/signal_test\.go:'
  grep -rnE '\bos\.kill' bench --include='*.py' \
    | grep -vE '^bench/client\.py:[0-9]+:    os\.kill\(pid, sig\)$'
  grep -rnE '\blibc::kill(pg)?\b|\bkillpg\b|nix::sys::signal|Command::new\([[:space:]]*"kill"' ko ko_* fuzz --include='*.rs' \
    | grep -vE '^ko_sys/src/pid\.rs:'
} || true)
if [[ -n "$signals" ]]; then
  echo "$signals" | sed 's/$/: signals must go through ko_sys::pid, signal_child or the signal_test.go helpers/'
  failed=1
fi
# The ring header's atomics are sequentially consistent; only the loom model's acquire/release
# twin, which shows the lost wakeup without them, uses another ordering.
orderings=$(grep -rnoE 'Ordering::[A-Za-z]+' ko_pane ko_pane_wire ko_server --include='*.rs' \
  | grep -vE '^ko_pane_wire/src/ring/model\.rs:|:Ordering::SeqCst$' || true)
if [[ -n "$orderings" ]]; then
  echo "$orderings" | sed 's/$/: ko_pane, ko_pane_wire and ko_server use only Ordering::SeqCst/'
  failed=1
fi
python3 - <<'PY' || failed=1
import glob
import pathlib
import re
import subprocess
import tomllib

revision = subprocess.check_output(['git', 'ls-files', '-s', 'third_party/tmux'], text=True).split()[1]
contract = pathlib.Path('share/rpc/contract.md').read_text()
if f'fork revision: {revision}\n' not in contract:
    print('share/rpc/contract.md: fork revision differs from third_party/tmux gitlink')
    raise SystemExit(1)

zig = re.search(r'^release=(\S+)$', pathlib.Path('scripts/install-zig.sh').read_text(), re.M).group(1)
zon = pathlib.Path('third_party/ghostty/build.zig.zon').read_text()
if f'.minimum_zig_version = "{zig}"' not in zon:
    print('scripts/install-zig.sh: zig release differs from third_party/ghostty minimum_zig_version')
    raise SystemExit(1)

locked = {package['name'] for package in tomllib.loads(pathlib.Path('Cargo.lock').read_text())['package']}
listed = set(pathlib.Path('scripts/crates.txt').read_text().split())
for name in sorted(locked - listed):
    print(f'Cargo.lock: package {name} is not in scripts/crates.txt')
for name in sorted(listed - locked):
    print(f'scripts/crates.txt: {name} is not in Cargo.lock')
verus_crates = re.search(r'^crates_version=(\S+)$', pathlib.Path('scripts/verus.sh').read_text(), re.M).group(1)
workspace = tomllib.loads(pathlib.Path('Cargo.toml').read_text())['workspace']['dependencies']
for name in ('vstd', 'verus_state_machines_macros'):
    if workspace.get(name) != f'={verus_crates}':
        print(f'Cargo.toml: {name} is not pinned to ={verus_crates}, the crates version of scripts/verus.sh')
        raise SystemExit(1)
headers = subprocess.check_output(['scripts/bindgen.sh', '--print-hash'], text=True).strip()
if f'// ghostty headers sha256: {headers}\n' not in pathlib.Path('ko_vt_sys/src/bindings.rs').read_text():
    print('ko_vt_sys/src/bindings.rs: header hash differs from third_party/ghostty/include; regenerate: make bindgen')
    raise SystemExit(1)
if locked != listed:
    raise SystemExit(1)

errors = 0
def report(path, text, offset, message):
    global errors
    print(f"{path}:{text.count(chr(10), 0, offset) + 1}: {message}")
    errors += 1

def candidates(pattern, paths):
    if not paths:
        return set()
    result = subprocess.run(['git', 'grep', '--no-index', '-l', '-E', pattern, '--', *paths], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr)
    return set(result.stdout.splitlines())

# Mask literals before looking for comments, and comments before looking for code.
def lexical(text, ocaml=False):
    pattern = (r"\{[a-z_]*\|[\s\S]*?\|[a-z_]*\}|'(?:\\[\s\S]|[^'\\])'|\"(?:\\[\s\S]|[^\"\\])*\"|\(\*[\s\S]*?\*\)" if ocaml else
               r'"(?:\\[\s\S]|[^"\\])*"|\'(?:\\[\s\S]|[^\'\\])*\'|`(?:\\[\s\S]|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/')
    comments = []
    def mask(match):
        token = match.group()
        if token.startswith('(*' if ocaml else ('//', '/*')):
            comments.append((match.start(), token))
        return re.sub(r'[^\n]', ' ', token)
    return re.sub(pattern, mask, text), comments

# A glob or named import of libc's kill makes a bare kill( call; only ko_sys::pid signals.
for path in glob.glob('ko/**/*.rs', recursive=True) + glob.glob('ko_*/**/*.rs', recursive=True):
    if path == 'ko_sys/src/pid.rs':
        continue
    text = pathlib.Path(path).read_text()
    code, _ = lexical(text)
    if re.search(r'\buse\s+libc::(\*|kill(?:pg)?\b|\{[^}]*(\*|\bkill(?:pg)?\b))', code):
        for match in re.finditer(r'(?<![\w:])kill(?:pg)?\s*\(', code):
            report(path, text, match.start(), 'signals must go through ko_sys::pid')

core = ['share/pi/kido-pi.ts', 'share/pi/ko-pi.ts']
for path in candidates(r'(^|[^a-zA-Z_])(as|any)([^a-zA-Z_]|$)|!', core):
    text = pathlib.Path(path).read_text()
    code, _ = lexical(text)
    for match in re.finditer(r'\bas\b(?!\s+const\b)|\bany\b|(?<=[\w)\]])!(?!=)', code):
        report(path, text, match.start(), 'TS hygiene: assertion or any')

sources = sum((glob.glob(pattern, recursive=True) for pattern in [
    'lib/**/*.ml', 'lib/**/*.mli', 'lib_tmux/**/*.ml', 'lib_tmux/**/*.mli',
    'bin/*.ml', 'bin/*.mli', 'share/pi/*.ts', 'test_e2e/*.go']), [])
for path in candidates('Mosaic|Matrix', [p for p in sources if p.startswith(('lib/', 'lib_tmux/'))]):
    text = pathlib.Path(path).read_text()
    for match in re.finditer(r'\b(?:Mosaic|Matrix)\w*', text):
        report(path, text, match.start(), 'TUI dependency outside bin/kido_sidebar')
text = pathlib.Path('lib/dune').read_text()
for match in re.finditer(r'\b(?:mosaic|matrix(?:\.text)?)\b', text):
    report('lib/dune', text, match.start(), 'TUI library dependency')

fuzz_allowed = {
    'ko_e2e/tests/e2e/config.rs': {
        'b"KO_FUZZ_SECONDS=abc".to_vec(),': 1,
        'b"KO_FUZZ_SEED=abc".to_vec(),': 1,
    },
}
for path in glob.glob('ko/**/*.rs', recursive=True) + glob.glob('ko_*/**/*.rs', recursive=True):
    text = pathlib.Path(path).read_text()
    allowed = fuzz_allowed.get(path, {})
    for match in re.finditer(r'^.*KO_FUZZ_\w+.*$', text, re.M):
        statement = match.group().strip()
        if allowed.get(statement, 0) > 0:
            allowed[statement] -= 1
        else:
            report(path, text, match.start(), 'fuzz variables are read in fuzz/ only')
for path, statements in fuzz_allowed.items():
    for statement, left in statements.items():
        if left:
            report(path, '', 0, f'stale KO_FUZZ_ allowance {statement!r} ({left} unused)')

history = r'\b(previously|no longer|(?<!be )used to|formerly|as of now|since this fix)\b'
for path in candidates('[Pp]reviously|[Nn]o longer|[Uu]sed to|[Ff]ormerly|[Aa]s of now|[Ss]ince this fix', sources):
    text = pathlib.Path(path).read_text()
    _, comments = lexical(text, path.endswith(('.ml', '.mli')))
    for offset, comment in comments:
        for match in re.finditer(history, comment, re.I):
            report(path, text, offset + match.start(), 'comment history: ' + match.group())

without_interface = {'lib/sh.ml', 'lib/test_support.ml', 'lib/test_fixture.ml', 'lib/view_fixture.ml', 'lib/state_fixture.ml', 'lib_tmux/program_status.ml', 'lib/tmux_vars.ml'}
for path in (p for p in set(glob.glob('lib/*.ml') + glob.glob('lib_tmux/*.ml') + glob.glob('bin/*.ml')) - without_interface if not pathlib.Path(p + 'i').exists()):
    text = pathlib.Path(path).read_text()
    code, _ = lexical(text, True)
    match = re.search(r'^let\b', code, re.M)
    if match:
        report(path, text, match.start(), 'missing .mli')

for path in ['AGENTS.md', *glob.glob('docs/*.md'), 'share/pi/README.md']:
    text = pathlib.Path(path).read_text()
    for match in re.finditer(r'`((?:[A-Z][\w]*\.){1,2}[A-Za-z_][\w]*)`', text):
        parts = match.group(1).split('.')
        if parts[0] == 'Tmux':
            module = 'lib_tmux/program_status.ml' if parts[1] == 'Program_status' else 'lib_tmux/tmux.ml'
            symbols = parts[2:] if parts[1] in {'Client', 'Program_status'} else parts[1:]
        elif parts[0] == 'Kido_sidebar':
            module = 'bin/kido_sidebar.ml'
            symbols = parts[1:]
        else:
            module = 'lib/' + parts[0].lower() + '.ml'
            symbols = parts[1:]
        if not pathlib.Path(module).exists():
            continue
        code, _ = lexical(pathlib.Path(module).read_text(), True)
        for symbol in symbols:
            if not re.search(r'\b' + re.escape(symbol) + r'\b', code):
                report(path, text, match.start(), f'stale reference {match.group(1)} ({module})')

# Existing bounded timing probes and whole-second timestamp tests; exact statements,
# not entire files, so a new sleep in any of these files still fails.
sleeps = {
    'test_e2e/conn_test.go': {'time.Sleep(20 * time.Millisecond)': 1},
    'test_e2e/launch_test.go': {'time.Sleep(100 * time.Millisecond)': 1},
    'test_e2e/leak_check_test.go': {'time.Sleep(50 * time.Millisecond)': 2},
    'test_e2e/reap_test.go': {'time.Sleep(100 * time.Millisecond)': 1},
    'test_e2e/render_test.go': {'time.Sleep(1200 * time.Millisecond)': 2},
    'test_e2e/ssh_prime_test.go': {'time.Sleep(100 * time.Millisecond)': 1},
    'test_e2e/standalone_test.go': {'time.Sleep(60 * time.Millisecond)': 2},
    'test_e2e/switch_session_test.go': {'time.Sleep(time.Until(time.Now().Truncate(time.Second).Add(time.Second)) + 50*time.Millisecond)': 1},
    'test_e2e/watchdog_test.go': {'time.Sleep(110 * time.Second)': 1, 'time.Sleep(200 * time.Millisecond)': 2},
}
for path in candidates(r'time\.Sleep', glob.glob('test_e2e/*.go')):
    if path == 'test_e2e/harness_test.go':
        continue
    text = pathlib.Path(path).read_text()
    for match in re.finditer(r'^.*time\.Sleep.*$', text, re.M):
        statement = match.group().strip().split('//')[0].rstrip()
        allowed = sleeps.get(path, {})
        if allowed.get(statement, 0) == 0:
            report(path, text, match.start(), 'time.Sleep outside harness/allowlist')
        else:
            allowed[statement] -= 1
# ko_e2e waits for events; its one fixed wait is the idle measurement, and harness.rs holds the poll tick.
rust_sleeps = {
    'ko_e2e/tests/e2e/idle.rs': {'std::thread::sleep(Duration::from_secs(2));': 1},
    'ko_e2e/tests/e2e/wait.rs': {'std::thread::sleep(Duration::from_secs(2));': 1},
}
for path in candidates(r'thread::(sleep|park_timeout)', glob.glob('ko_e2e/tests/e2e/*.rs')):
    if path == 'ko_e2e/tests/e2e/harness.rs':
        continue
    text = pathlib.Path(path).read_text()
    for match in re.finditer(r'^.*thread::(sleep|park_timeout).*$', text, re.M):
        statement = match.group().strip().split('//')[0].rstrip()
        allowed = rust_sleeps.get(path, {})
        if allowed.get(statement, 0) == 0:
            report(path, text, match.start(), 'thread::sleep outside the allowlist')
        else:
            allowed[statement] -= 1
for path, statements in rust_sleeps.items():
    for statement, left in statements.items():
        if left:
            report(path, '', 0, f'stale thread::sleep allowance {statement!r} ({left} unused)')
for path, statements in sleeps.items():
    for statement, left in statements.items():
        if left:
            report(path, '', 0, f'stale time.Sleep allowance {statement!r} ({left} unused)')

for path in candidates('kill-server', glob.glob('test_e2e/*.go') + glob.glob('scripts/*')):
    text = pathlib.Path(path).read_text()
    for match in re.finditer(r'^.*kill-server.*$', text, re.M):
        line = match.group().strip()
        if line.startswith(('//', '#')) or path == 'scripts/lint.sh':
            continue
        # kido's own subcommand resolves its private server, not tmux's default socket.
        if line == 'r.kido("kill-server")':
            continue
        if not re.search(r'(?:["\s])-([SL])(?:["\s])', line):
            report(path, text, match.start(), 'kill-server without explicit -S/-L')
raise SystemExit(1 if errors else 0)
PY
node_flags=()
printf 'const probe: number = 1;\n' > "$scratch/probe.ts"
if command -v node >/dev/null 2>&1 && node "$scratch/probe.ts" >/dev/null 2>&1; then
  :
elif command -v node >/dev/null 2>&1 && node --experimental-strip-types "$scratch/probe.ts" >/dev/null 2>&1; then
  node_flags=(--experimental-strip-types)
else
  echo 'lint: SKIP prompt snapshot (node cannot run TypeScript)'
  exit "$failed"
fi
for extension in kido-pi ko-pi; do
  fixture=share/pi/testdata/prompts.txt
  [[ "$extension" == ko-pi ]] && fixture=share/pi/testdata/ko-prompts.txt
  if ! node "${node_flags[@]}" scripts/dump-prompts.ts "$extension" > "$scratch/prompts.txt"; then
    echo 'scripts/dump-prompts.ts:1: prompt dump failed' >&2
    exit 1
  fi
  if [[ "${1:-}" == --update-prompts ]]; then
    cp "$scratch/prompts.txt" "$fixture"
  elif ! diff -u "$fixture" "$scratch/prompts.txt"; then
    echo "$fixture:1: prompt snapshot differs; regenerate: scripts/lint.sh --update-prompts"
    failed=1
  fi
done
if [[ "$failed" == 0 ]]; then echo 'lint: PASS'; fi
exit "$failed"
