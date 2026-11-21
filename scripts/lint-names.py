import pathlib
import re
import subprocess
import sys

errors = 0
def report(path, text, offset, message):
    global errors
    print(f"{path}:{text.count(chr(10), 0, offset) + 1}: {message}")
    errors += 1

# Names of the removed tmux-based kido must not come back.
# Kido.app keeps its own KIDO_ knobs, in app/ and in the two app docs.
app_knob = re.compile(r'KIDO_(VISUAL|STRESS|APP_|DEMO_|PRODUCT_NAME$|VSYNC_MEASURE$|MTC_VERIFY$|SHM_H$)')
app_scope = ('app/', 'docs/design-app.md', 'docs/known-issues-app.md')
gates = [
    re.compile(p) for p in (
        r'kido-pi', r'kido-tmux', r'share/kido', r'\bdune\b', r'install-tmux-fork', r'test_e2e',
        r'\bgo test\b', r'\.mli?\b', r'verify-ko', r'make flake', r'lib_tmux', r'rfc/kido-server',
        r'lib/[a-z_]+\.ml',
    )
]
# Whole-tree exemptions: a directory ends in /, anything else names one file.
gate_exempt = (
    'website/', 'third_party/', 'ko_server/testdata/', 'bench/streams/',
    'app/design/',  # historical mockups, kept as drawn
    'scripts/lint.sh', 'scripts/lint-names.py', 'app/VisualTests/PaletteTests.swift',  # the gate's own patterns; snapshot test data
)
gate_statements = {}
prefilter = r'KIDO_|kido-|share/kido|dune|tmux|test_e2e|go test|\.ml|verify-ko|make flake|lib/|rfc/kido-server'
excluded = [f':(exclude){entry}' for entry in gate_exempt]
found = subprocess.run(['git', 'grep', '-I', '-n', '-i', '--untracked', '-E', prefilter, '--', '.', *excluded], capture_output=True, text=True)
if found.returncode not in (0, 1):
    raise RuntimeError(found.stderr)
for hit in found.stdout.splitlines():
    path, line, text = hit.split(':', 2)
    if len(sys.argv) > 1 and sys.argv[1] == 'docs' and not path.endswith('.md'):
        continue
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
