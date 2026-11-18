#!/bin/bash
set -euo pipefail
certificate=()
if [[ ${1:-} == --tls-cert ]]; then
    [[ $# -ge 3 ]] || { echo '--tls-cert needs a certificate and key' >&2; exit 1; }
    certificate=("$2" "$3")
    shift 3
fi
[[ $EUID == 0 && $# -ge 2 ]] || { echo 'usage: sudo provision.sh [--tls-cert CERT KEY] KO_HOST SSH_CIDR...' >&2; exit 1; }
base=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pair_port=8791
ko_changed=false
caddy_changed=false
nftables_changed=false
ssh_changed=false
install_changed() {
    local source=$1 target=$2 service=$3 mode=${4:-0644} temporary
    if ! cmp -s "$source" "$target"; then
        temporary=$(mktemp "$(dirname -- "$target")/.ko-install-XXXXXX")
        install -o root -g root -m "$mode" "$source" "$temporary"
        mv -f "$temporary" "$target"
        printf -v "${service}_changed" true
    fi
}
python3 - "$base/files" "$work" "$pair_port" "${certificate[0]:-}" "$@" <<'PY'
import ipaddress
from pathlib import Path
import re
import sys
source, target, port, certificate, host, *cidrs = sys.argv[1:]
enroll = "enroll." + host
for name in (host, enroll):
    if len(name) > 253 or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in name.split(".")):
        raise SystemExit("invalid DNS name")
networks = [ipaddress.ip_network(cidr, strict=False) for cidr in cidrs]
values = {"@HOST@": host, "@ENROLL@": enroll, "@PAIR_PORT@": port,
          "@SSH4@": ", ".join(str(n) for n in networks if n.version == 4),
          "@SSH6@": ", ".join(str(n) for n in networks if n.version == 6)}
for name in ("Caddyfile", "nftables.conf"):
    text = (Path(source) / name).read_text()
    for key, value in values.items():
        text = text.replace(key, value)
    if name == "Caddyfile" and certificate:
        tls = "tls /etc/caddy/ko-server.crt /etc/caddy/ko-server.key"
        text = text.replace(enroll + " {", enroll + " {\n\t" + tls, 1).replace("\ttls {", "\t" + tls + " {", 1)
    text = re.sub(r"^\s*elements = \{  \}\n", "", text, flags=re.MULTILINE)
    (Path(target) / name).write_text(text)
PY
export DEBIAN_FRONTEND=noninteractive
if [[ ! -s /etc/apt/sources.list.d/caddy-stable.list || ! -s /usr/share/keyrings/caddy-stable-archive-keyring.asc ]]; then
    python3 - <<'PY'
from pathlib import Path
import urllib.request
key = "/usr/share/keyrings/caddy-stable-archive-keyring.asc"
with urllib.request.urlopen("https://dl.cloudsmith.io/public/caddy/stable/gpg.key", timeout=30) as response:
    Path(key).write_bytes(response.read())
with urllib.request.urlopen("https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt", timeout=30) as response:
    repo = response.read().decode().replace("/usr/share/keyrings/caddy-stable-archive-keyring.gpg", key)
Path("/etc/apt/sources.list.d/caddy-stable.list").write_text(repo)
PY
fi
install -m 0644 "$base/files/nodesource.asc" /usr/share/keyrings/nodesource.asc
printf 'deb [signed-by=/usr/share/keyrings/nodesource.asc] https://deb.nodesource.com/node_24.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list
old_caddy=$(dpkg-query -W -f='${Version}' caddy 2>/dev/null || true)
apt-get update
apt-get install -y ca-certificates curl caddy nftables unattended-upgrades apparmor-utils python3-cryptography qrencode openssh-server sudo nodejs git fd-find
[[ $old_caddy == "$(dpkg-query -W -f='${Version}' caddy)" ]] || caddy_changed=true
version=$(caddy version | awk '{print $1}')
dpkg --compare-versions "${version#v}" ge 2.11.4 || { echo 'Caddy 2.11.4 or later is required' >&2; exit 1; }
id me >/dev/null
[[ -s /home/me/.ssh/authorized_keys ]] || { echo 'cloud-init must install the SSH key for me first' >&2; exit 1; }
usermod --shell /bin/bash me
printf 'me ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-ko-me
chmod 0440 /etc/sudoers.d/90-ko-me
visudo -cf /etc/sudoers.d/90-ko-me
passwd -l root
getent group ko-socket >/dev/null || groupadd --system ko-socket
if ! id -nG caddy | tr ' ' '\n' | grep -qx ko-socket; then
    usermod -a -G ko-socket caddy
    caddy_changed=true
fi
install -d -o root -g caddy -m 0750 /var/lib/ko-devices
install -d -o caddy -g caddy -m 0750 /var/log/caddy
[[ -d /etc/caddy/sites.d ]] || install -d -o root -g root -m 0755 /etc/caddy/sites.d
install -d /opt/ko/bin /opt/ko/share /etc/systemd/system/caddy.service.d
[[ -x $base/../linux/bin/ko && -x $base/../linux/bin/ko-pane ]] || { echo 'copy the Linux build beside deploy as linux/ first' >&2; exit 1; }
for binary in ko ko-pane; do
    install_changed "$base/../linux/bin/$binary" "/opt/ko/bin/$binary" ko 0755
done
if ! diff -qr "$base/../linux/share" /opt/ko/share >/dev/null; then
    share=$(mktemp -d /opt/ko/.share-XXXXXX)
    cp -a "$base/../linux/share/." "$share/"
    chown -R root:root "$share"
    mv /opt/ko/share "$share.old"
    mv "$share" /opt/ko/share
    rm -rf "$share.old"
    ko_changed=true
fi
/opt/ko/bin/ko server --help | grep -q -- '--allow-uid'
install_changed "$base/files/ko-tmpfiles.conf" /etc/tmpfiles.d/ko.conf ko
systemd-tmpfiles --create /etc/tmpfiles.d/ko.conf
python3 - "$base/files/ko.service" "$(id -u caddy)" > "$work/ko.service" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text().replace("@CADDY_UID@", sys.argv[2]), end="")
PY
install_changed "$work/ko.service" /etc/systemd/system/ko.service ko
printf 'export KO_STATE_DIR=/var/lib/ko\nexport PATH=/opt/ko/bin:$PATH\n' > /etc/profile.d/ko.sh
install -m 0755 "$base/ko-devices" /usr/local/sbin/ko-devices
ln -sfn ko-devices /usr/local/sbin/ko-revoke
ln -sfn ko-devices /usr/local/sbin/ko-pair
python3 - "$1" "$pair_port" > /etc/ko-pair.json <<'PY'
import json
import sys
print(json.dumps({"host": sys.argv[1], "port": int(sys.argv[2])}))
PY
chmod 0644 /etc/ko-pair.json
if [[ ${#certificate[@]} != 0 ]]; then
    install_changed "${certificate[0]}" /etc/caddy/ko-server.crt caddy
    install_changed "${certificate[1]}" /etc/caddy/ko-server.key caddy 0640
    chown root:caddy /etc/caddy/ko-server.key
fi
install_changed "$base/files/sysctl.conf" /etc/sysctl.d/60-ko-quic.conf caddy
sysctl -p /etc/sysctl.d/60-ko-quic.conf
install_changed "$work/Caddyfile" /etc/caddy/Caddyfile caddy
install_changed "$base/files/caddy.conf" /etc/systemd/system/caddy.service.d/ko.conf caddy
if [[ -f /etc/apparmor.d/caddy ]] && ! grep -q 'flags=(complain)' /etc/apparmor.d/caddy; then
    python3 - "$base/files/caddy.apparmor" > "$work/caddy.apparmor" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text().replace(" flags=(complain)", ""), end="")
PY
else
    cp "$base/files/caddy.apparmor" "$work/caddy.apparmor"
fi
install_changed "$work/caddy.apparmor" /etc/apparmor.d/caddy caddy
apparmor_parser -r /etc/apparmor.d/caddy
caddy validate --config /etc/caddy/Caddyfile
install_changed "$base/files/sshd.conf" /etc/ssh/sshd_config.d/00-ko.conf ssh
sshd -t
nft -c -f "$work/nftables.conf"
install_changed "$work/nftables.conf" /etc/nftables.conf nftables 0755
install -m 0644 "$base/files/unattended-upgrades" /etc/apt/apt.conf.d/52ko-unattended-upgrades
systemd-analyze verify /etc/systemd/system/ko.service /lib/systemd/system/caddy.service
systemctl daemon-reload
systemctl enable ko caddy nftables unattended-upgrades
for service in ko caddy nftables; do
    flag=${service}_changed
    if ! systemctl is-active --quiet "$service"; then
        systemctl start "$service"
    elif "${!flag}"; then
        systemctl restart "$service"
    fi
done
if ! systemctl is-active --quiet ssh; then
    systemctl start ssh
elif "$ssh_changed"; then
    systemctl reload ssh
fi
systemctl is-active --quiet ko caddy nftables
runuser -u me -- env -i HOME=/home/me PATH=/usr/local/bin:/usr/bin:/bin "$base/me.sh"
printf 'Provisioned %s; run deploy/smoke.sh before aa-enforce caddy.\n' "$1"
