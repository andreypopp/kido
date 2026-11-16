#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
make build-linux LINUX_ARCHS=x86_64
outputs=$(mktemp)
trap 'rm -f "$outputs"' EXIT
tofu -chdir=deploy/terraform output -json > "$outputs"
readarray_compat=()
while IFS= read -r value; do readarray_compat+=("$value"); done < <(python3 - "$outputs" <<'PY'
import json
import shlex
import sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
print(data["ipv4"]["value"])
print(" ".join(shlex.quote(v) for v in [data["ko_host"]["value"], data["enroll_host"]["value"], *data["ssh_cidrs"]["value"]]))
PY
)
[[ ${#readarray_compat[@]} == 2 ]]
host=${readarray_compat[0]}
arguments=${readarray_compat[1]}
ssh "me@$host" 'cloud-init status --wait >/dev/null && mkdir -p ~/ko-install/linux ~/ko-install/deploy'
rsync -az --delete build/ko/share/ko/linux/x86_64/ "me@$host:ko-install/linux/"
rsync -az --delete --exclude terraform --exclude __pycache__ deploy/ "me@$host:ko-install/deploy/"
ssh -t "me@$host" "sudo /home/me/ko-install/deploy/provision.sh $arguments"
