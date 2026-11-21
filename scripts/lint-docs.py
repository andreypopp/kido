import glob
import pathlib
import re

errors = 0
def report(path, text, offset, message):
    global errors
    print(f"{path}:{text.count(chr(10), 0, offset) + 1}: {message}")
    errors += 1

# A backticked ko crate path or file in the docs must exist: `ko_x::a::b` names a crate directory
# whose sources mention each segment, `ko_x/src/y.rs` a path in the tree.
crate_code = {}
for path in ['AGENTS.md', *glob.glob('docs/*.md')]:
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


raise SystemExit(1 if errors else 0)
