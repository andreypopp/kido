import glob
import pathlib
import re
import os

os.chdir(pathlib.Path(__file__).resolve().parents[2])

errors = 0
def report(path, text, offset, message):
    global errors
    print(f"{path}:{text.count(chr(10), 0, offset) + 1}: {message}")
    errors += 1

# Mask literals before looking for comments, and comments before looking for code.
def lexical(text):
    pattern = r'"(?:\\[\s\S]|[^"\\])*"|\'(?:\\[\s\S]|[^\'\\])*\'|`(?:\\[\s\S]|[^`\\])*`|(?<=[(,=:\[!&|?{};])[ \t]*/(?![/*])(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\[\n])+/[a-z]*|//[^\n]*|/\*[\s\S]*?\*/'
    comments = []
    def mask(match):
        token = match.group()
        if token.startswith(('//', '/*')):
            comments.append((match.start(), token))
        return re.sub(r'[^\n]', ' ', token)
    return re.sub(pattern, mask, text), comments

ts_sources = glob.glob('webview/*.ts') + glob.glob('koa/*.ts') + glob.glob('koa/page/*.ts') + glob.glob('koa/visual/*.ts')
signal_sites = {'koa/koa-agent.ts': {'function': 'signalJob', 'count': 0}, 'koa/koa-child.ts': {'function': 'signalChild', 'count': 0}}
for path in ts_sources:
    text = pathlib.Path(path).read_text()
    code, _ = lexical(text)
    allowed = signal_sites.get(path)
    function = re.search(r'\bfunction\s+' + allowed['function'] + r'\s*\([^)]*\)[^{]*\{', code) if allowed else None
    start = end = -1
    if function:
        start = function.end()
        depth = 1
        end = start
        while end < len(code) and depth:
            depth += (code[end] == '{') - (code[end] == '}')
            end += 1
    for match in re.finditer(r'\bprocess\.kill\s*\(', code):
        if start <= match.start() < end:
            allowed['count'] += 1
        else:
            report(path, text, match.start(), 'process.kill must occur only in signalJob or signalChild')
for path, site in signal_sites.items():
    if site['count'] != 1:
        report(path, '', 0, 'expected exactly one process.kill call in ' + site['function'])

core = [path for path in ts_sources if path.startswith('koa/')]
for path in core:
    text = pathlib.Path(path).read_text()
    code, _ = lexical(text)
    for match in re.finditer(r'\bas\b(?!\s+const\b)|(?<![\w.])any\b|(?<=[\w)\]])!(?!=)', code):
        report(path, text, match.start(), 'TS hygiene: assertion or any')

history = r'\b(previously|no longer|(?<!be )used to|formerly|as of now|since this fix)\b'
for path in ts_sources:
    text = pathlib.Path(path).read_text()
    _, comments = lexical(text)
    for offset, comment in comments:
        for match in re.finditer(history, comment, re.I):
            report(path, text, offset + match.start(), 'comment history: ' + match.group())


raise SystemExit(1 if errors else 0)
