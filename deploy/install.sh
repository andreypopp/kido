#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
. deploy/bin/deployment.sh
resolve 'deploy/install.sh [NAME]' "$@"
shift "$consumed"
[[ $# == 0 ]] || { echo 'usage: deploy/install.sh [NAME]' >&2; exit 124; }
[[ -e $folder/terraform.tfstate ]] || { echo "$folder has no terraform.tfstate; run deploy/bin/tofu first" >&2; exit 1; }
make build-linux LINUX_ARCHS=x86_64
make -C koa build
host=$(address)
arguments=$(python3 - "$folder/terraform.tfstate" <<'PY'
import json
import shlex
import sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)["outputs"]
print(" ".join(shlex.quote(v) for v in [data["ko_host"]["value"], *data["ssh_cidrs"]["value"]]))
PY
)
ssh_command
remote_shell=$(printf "'%s' " "${ssh[@]}")
"${ssh[@]}" "$host" 'cloud-init status --wait >/dev/null && mkdir -p ~/ko-install/linux ~/ko-install/koa ~/ko-install/deploy'
rsync -az --delete -e "$remote_shell" build/ko/share/ko/linux/x86_64/ "$host:ko-install/linux/"
rsync -az --delete -e "$remote_shell" build/koa/ "$host:ko-install/koa/"
rsync -az --delete --exclude /terraform --exclude /deployments --exclude /bin --exclude __pycache__ -e "$remote_shell" deploy/ "$host:ko-install/deploy/"
"${ssh[@]}" -t "$host" "sudo /home/me/ko-install/deploy/provision.sh $arguments"
