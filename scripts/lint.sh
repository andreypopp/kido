#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ''|--update-prompts|--update-schemas) ;;
  *) echo "usage: scripts/lint.sh [--update-prompts|--update-schemas]" >&2; exit 1 ;;
esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failed=0
# A negative pid or a process group reaches kill(2) only through ko_sys::pid and signal_child.
signal_pattern='\bkillpg\b|\bkill[[:space:]]*\([[:space:]]*-'
signals=$( {
  grep -rnE "$signal_pattern" bench --include='*.c' --include='*.h' --include='*.py'
  grep -rnE '\bos\.kill' bench --include='*.py' \
    | grep -vE '^bench/client\.py:[0-9]+:    os\.kill\(pid, sig\)$'
  grep -rnE '\blibc::kill(pg)?\b|\bkillpg\b|nix::sys::signal|Command::new\([[:space:]]*"kill"' ko ko_* fuzz --include='*.rs' \
    | grep -vE '^ko_sys/src/pid\.rs:'
} || true)
if [[ -n "$signals" ]]; then
  echo "$signals" | sed 's/$/: signals must go through ko_sys::pid or signal_child/'
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
def lexical(text):
    pattern = r'"(?:\\[\s\S]|[^"\\])*"|\'(?:\\[\s\S]|[^\'\\])*\'|`(?:\\[\s\S]|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/'
    comments = []
    def mask(match):
        token = match.group()
        if token.startswith(('//', '/*')):
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

core = ['share/pi/ko-pi.ts']
for path in candidates(r'(^|[^a-zA-Z_])(as|any)([^a-zA-Z_]|$)|!', core):
    text = pathlib.Path(path).read_text()
    code, _ = lexical(text)
    for match in re.finditer(r'\bas\b(?!\s+const\b)|\bany\b|(?<=[\w)\]])!(?!=)', code):
        report(path, text, match.start(), 'TS hygiene: assertion or any')

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
for path in candidates('[Pp]reviously|[Nn]o longer|[Uu]sed to|[Ff]ormerly|[Aa]s of now|[Ss]ince this fix', glob.glob('share/pi/*.ts')):
    text = pathlib.Path(path).read_text()
    _, comments = lexical(text)
    for offset, comment in comments:
        for match in re.finditer(history, comment, re.I):
            report(path, text, offset + match.start(), 'comment history: ' + match.group())

# A backticked ko crate path or file in the docs must exist: `ko_x::a::b` names a crate directory
# whose sources mention each segment, `ko_x/src/y.rs` a path in the tree.
crate_code = {}
for path in ['AGENTS.md', *glob.glob('docs/*.md'), 'share/pi/README.md']:
    text = pathlib.Path(path).read_text()
    for match in re.finditer(r'`(ko(?:_[a-z0-9]+)*)((?:::[A-Za-z_]\w*)+)', text):
        crate, segments = match.group(1), match.group(2).split('::')[1:]
        if not pathlib.Path(crate).is_dir():
            report(path, text, match.start(), f'stale reference {match.group(0)[1:]}: no crate {crate}')
            continue
        if crate not in crate_code:
            crate_code[crate] = ''.join(p.read_text() for p in pathlib.Path(crate).rglob('*.rs'))
        for segment in segments:
            if not re.search(r'\b' + re.escape(segment) + r'\b', crate_code[crate]):
                report(path, text, match.start(), f'stale reference {match.group(0)[1:]}: {segment} not in {crate}')
    for match in re.finditer(r'`(ko(?:_[a-z0-9]+)*/[\w./-]*[\w/])`', text):
        if not pathlib.Path(match.group(1)).exists():
            report(path, text, match.start(), f'stale reference {match.group(1)}: no such path')

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
# Names of the removed tmux-based kido must not come back.
# Kido.app keeps its own KIDO_ knobs, in app/ and in the two app docs.
app_knob = re.compile(r'KIDO_(VISUAL|STRESS|APP_|DEMO_|PRODUCT_NAME$|VSYNC_MEASURE$|MTC_VERIFY$|SHM_H$)')
app_scope = ('app/', 'docs/design-app.md', 'docs/known-issues-app.md')
gates = [
    re.compile(p) for p in (
        r'kido-pi', r'kido-tmux', r'share/kido', r'\bdune\b', r'(?i)\btmux\b', r'install-tmux-fork', r'test_e2e',
        r'\bgo test\b', r'\.mli?\b', r'verify-ko', r'make flake', r'make e2e(?![\w-])', r'lib_tmux', r'rfc/kido-server',
        r'lib/[a-z_]+\.ml',
    )
]
# Whole-tree exemptions: a directory ends in /, anything else names one file.
gate_exempt = (
    'website/', 'third_party/', 'ko_server/testdata/', 'bench/streams/',
    'app/design/',  # historical mockups, kept as drawn
    'scripts/lint.sh', 'app/VisualTests/PaletteTests.swift',  # the gate's own patterns; snapshot test data
)
# Exact statements, as the sleep tables above: a real tmux passthrough form in a fuzz sample.
gate_statements = {
    'ko_server/src/harness.rs': {'"tmux;\\x1b\\x1b[0m",': 1},
}
prefilter = r'KIDO_|kido-|share/kido|dune|tmux|test_e2e|go test|\.ml|verify-ko|make flake|make e2e|lib/|rfc/kido-server'
excluded = [f':(exclude){entry}' for entry in gate_exempt]
found = subprocess.run(['git', 'grep', '-I', '-n', '-i', '--untracked', '-E', prefilter, '--', '.', *excluded], capture_output=True, text=True)
if found.returncode not in (0, 1):
    raise RuntimeError(found.stderr)
for hit in found.stdout.splitlines():
    path, line, text = hit.split(':', 2)
    names = {m.group() for m in re.finditer(r'KIDO_[A-Z_]+', text) if not (path.startswith(app_scope) and app_knob.match(m.group()))}
    for pattern in gates:
        names.update(m.group() for m in pattern.finditer(text))
    allowed = gate_statements.get(path, {})
    if names and allowed.get(text.strip(), 0) > 0:
        allowed[text.strip()] -= 1
        continue
    if names:
        print(f"{path}:{line}: removed name " + ', '.join(sorted(names)))
        errors += 1
for path, statements in gate_statements.items():
    for statement, left in statements.items():
        if left:
            report(path, '', 0, f'stale gate allowance {statement!r} ({left} unused)')
raise SystemExit(1 if errors else 0)
PY
node_flags=()
make --no-print-directory build-ko >&2
build/ko/bin/ko api-schema > "$scratch/openapi.json"
if [[ "${1:-}" == --update-schemas ]]; then
  cp "$scratch/openapi.json" share/ko/openapi.json
elif ! diff -u share/ko/openapi.json "$scratch/openapi.json"; then
  echo 'share/ko/openapi.json:1: OpenAPI snapshot differs; regenerate: scripts/lint.sh --update-schemas'
  failed=1
fi
build/ko/bin/ko api-schema --client > "$scratch/client-model.json"
if [[ "${1:-}" == --update-schemas ]]; then
  cp "$scratch/client-model.json" share/ko/client-model.json
elif ! diff -u share/ko/client-model.json "$scratch/client-model.json"; then
  echo 'share/ko/client-model.json:1: client model schema differs; regenerate: scripts/lint.sh --update-schemas'
  failed=1
fi
build/ko/bin/ko api-schema --runtimes > "$scratch/runtimes-schema.json"
if [[ "${1:-}" == --update-schemas ]]; then
  cp "$scratch/runtimes-schema.json" share/ko/runtimes-schema.json
elif ! diff -u share/ko/runtimes-schema.json "$scratch/runtimes-schema.json"; then
  echo 'share/ko/runtimes-schema.json:1: runtime configuration schema differs; regenerate: scripts/lint.sh --update-schemas'
  failed=1
fi
printf 'const probe: number = 1;\n' > "$scratch/probe.ts"
if command -v node >/dev/null 2>&1 && node "$scratch/probe.ts" >/dev/null 2>&1; then
  :
elif command -v node >/dev/null 2>&1 && node --experimental-strip-types "$scratch/probe.ts" >/dev/null 2>&1; then
  node_flags=(--experimental-strip-types)
else
  echo 'lint: SKIP prompt and ko-api.d.ts snapshots (node cannot run TypeScript)'
  exit "$failed"
fi
if [ ! -d share/pi/node_modules ] || [ share/pi/package-lock.json -nt share/pi/node_modules ]; then
  (cd share/pi && npm install --silent && touch node_modules)
fi
share/pi/node_modules/.bin/openapi-typescript "$scratch/openapi.json" --default-non-nullable false -o "$scratch/ko-api.d.ts" >/dev/null
if [[ "${1:-}" == --update-schemas ]]; then
  cp "$scratch/ko-api.d.ts" share/pi/ko-api.d.ts
elif ! diff -u share/pi/ko-api.d.ts "$scratch/ko-api.d.ts"; then
  echo 'share/pi/ko-api.d.ts:1: generated types differ; regenerate: scripts/lint.sh --update-schemas'
  failed=1
fi
fixture=share/pi/testdata/ko-prompts.txt
if ! node ${node_flags[@]+"${node_flags[@]}"} scripts/dump-prompts.ts > "$scratch/prompts.txt"; then
  echo 'scripts/dump-prompts.ts:1: prompt dump failed' >&2
  exit 1
fi
if [[ "${1:-}" == --update-prompts ]]; then
  cp "$scratch/prompts.txt" "$fixture"
elif ! diff -u "$fixture" "$scratch/prompts.txt"; then
  echo "$fixture:1: prompt snapshot differs; regenerate: scripts/lint.sh --update-prompts"
  failed=1
fi
if [[ "$failed" == 0 ]]; then echo 'lint: PASS'; fi
exit "$failed"
