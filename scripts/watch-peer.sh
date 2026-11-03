#!/usr/bin/env bash
# Prints the id of another live run that starts scripts/$1 under the same parent as this run, if any.
set -euo pipefail
own=${KO_RUN_ID:-}
[[ -n $own ]] || exit 0
python3 - "$1" "$own" <<'PY'
import json, re, subprocess, sys

script, own = sys.argv[1:]

def runs(*args):
    try:
        out = subprocess.run(['ko', 'runs', '--json', *args], capture_output=True, text=True, check=True).stdout
        return json.loads(out)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return []

shown = runs(own)
parent = (shown[0] if isinstance(shown, list) and shown else shown).get('parent') if shown else None
if parent:
    for peer in runs('--parent', parent):
        if peer['id'] != own and any(re.search(r'(^|[\s/\'"])scripts/' + re.escape(script) + r'($|[\s;\'"&|])', arg) for arg in peer['argv']):
            print(peer['id'])
            break
PY
