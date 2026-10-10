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
python3 - <<'PY' || failed=1
import glob
import pathlib
import re
import subprocess

revision = subprocess.check_output(['git', 'ls-files', '-s', 'third_party/tmux'], text=True).split()[1]
contract = pathlib.Path('share/rpc/contract.md').read_text()
if f'fork revision: {revision}\n' not in contract:
    print('share/rpc/contract.md: fork revision differs from third_party/tmux gitlink')
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

core = ['share/pi/kido-status.ts', 'share/pi/kido-agents.ts']
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

history = r'\b(previously|no longer|(?<!be )used to|formerly|as of now|since this fix)\b'
for path in candidates('[Pp]reviously|[Nn]o longer|[Uu]sed to|[Ff]ormerly|[Aa]s of now|[Ss]ince this fix', sources):
    text = pathlib.Path(path).read_text()
    _, comments = lexical(text, path.endswith(('.ml', '.mli')))
    for offset, comment in comments:
        for match in re.finditer(history, comment, re.I):
            report(path, text, offset + match.start(), 'comment history: ' + match.group())

without_interface = {'lib/sh.ml', 'lib/test_support.ml', 'lib/test_fixture.ml', 'lib/view_fixture.ml', 'lib/tmux_pane_fixture.ml', 'lib_tmux/program_status.ml'}
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
    'test_e2e/async_bash_test.go': {'time.Sleep(100 * time.Millisecond)': 1},
    'test_e2e/async_ending_test.go': {'time.Sleep(1200 * time.Millisecond)': 2},
    'test_e2e/conn_test.go': {'time.Sleep(20 * time.Millisecond)': 1},
    'test_e2e/control_test.go': {'time.Sleep(10 * time.Millisecond)': 1},
    'test_e2e/launch_test.go': {'time.Sleep(100 * time.Millisecond)': 3},
    'test_e2e/leak_check_test.go': {'time.Sleep(50 * time.Millisecond)': 2},
    'test_e2e/reap_test.go': {'time.Sleep(100 * time.Millisecond)': 1, 'time.Sleep(1200 * time.Millisecond)': 1},
    'test_e2e/render_test.go': {'time.Sleep(1200 * time.Millisecond)': 2},
    'test_e2e/rpc_test.go': {'time.Sleep(100 * time.Millisecond)': 1},
    'test_e2e/snapshot_test.go': {'time.Sleep(200 * time.Millisecond)': 1},
    'test_e2e/ssh_prime_test.go': {'time.Sleep(100 * time.Millisecond)': 1},
    'test_e2e/stall_test.go': {'time.Sleep(6 * time.Second)': 1},
    'test_e2e/standalone_test.go': {'time.Sleep(60 * time.Millisecond)': 2, 'time.Sleep(time.Second)': 1},
    'test_e2e/stream_test.go': {'time.Sleep(300 * time.Millisecond)': 1},
    'test_e2e/switch_session_test.go': {'time.Sleep(time.Until(time.Now().Truncate(time.Second).Add(time.Second)) + 50*time.Millisecond)': 1},
    'test_e2e/watchdog_test.go': {'time.Sleep(100 * time.Millisecond)': 1, 'time.Sleep(110 * time.Second)': 2, 'time.Sleep(200 * time.Millisecond)': 3},
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
if ! node "${node_flags[@]}" scripts/dump-prompts.ts > "$scratch/prompts.txt"; then
  echo 'scripts/dump-prompts.ts:1: prompt dump failed' >&2
  exit 1
fi
fixture=share/pi/testdata/prompts.txt
if [[ "${1:-}" == --update-prompts ]]; then
  cp "$scratch/prompts.txt" "$fixture"
elif ! diff -u "$fixture" "$scratch/prompts.txt"; then
  echo "$fixture:1: prompt snapshot differs; regenerate: scripts/lint.sh --update-prompts"
  failed=1
fi
if [[ "$failed" == 0 ]]; then echo 'lint: PASS'; fi
exit "$failed"
