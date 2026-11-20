# kow: one remote ko server

`kow/kow` ("ko workspace") deploys and operates one ko server on a
Debian 13 x64 DigitalOcean droplet with a Cloudflare DNS zone. It is
one self-contained Python 3 script (3.12 or later, standard library
only) that embeds every file it needs: the OpenTofu configuration and
the whole payload that it installs on the server. Homebrew installs it
as `andreypopp/tap/kow` (docs/release.md, "kow").

The Mac needs OpenTofu, Python 3.12, rsync and OpenSSH. Use a
dedicated DNS zone or label set: this setup owns the ko host,
`enroll.<ko host>` and the wildcard `*.<ko host>`, each an A and an
AAAA record of the droplet, not proxied. Caddy serves only the ko host
and the enrollment host: another name under the wildcard gets no
certificate and fails TLS.

## Commands

    kow NAME init                  make the workspace folder ./NAME
    kow NAME deploy [OPTIONS]      tofu init, tofu apply, then install
    kow NAME install [OPTIONS]     copy ko, koa and the payload; provision
    kow NAME ssh [COMMAND...]      connect as me
    kow NAME pair [--name N]       sudo ko-pair, with a terminal
    kow NAME unpair FP             sudo ko-revoke FP
    kow NAME list-devices          sudo ko-devices
    kow NAME smoke [--host HOST] [ADDRESS]   the live smoke test

NAME is the path of the workspace folder, relative to the current
directory or absolute. Its last component is the deployment's name
and must be a DNS label. The commands take the server's address from
the folder's state (the `ipv4` output) or from its `address` file.

`install` and `deploy` take the ko and koa builds from their GitHub
releases by default: the `ko/<version>` asset
`ko-<version>-linux-x86_64.tar.gz` and the `koa/<version>` asset
`koa-<version>.tar.gz`. kow pins both versions with their SHA-256, and
refuses an archive with another digest. `--ko VERSION` and `--koa
VERSION` select another release; kow then takes the SHA-256 from the
release asset's published `digest` and refuses an asset without one.
`--checkout DIR`, or `KOW_CHECKOUT=DIR` in the environment, builds
both from a Kido checkout instead (`make build-linux
LINUX_ARCHS=x86_64` and `make -C koa build`); the flag wins over the
variable, and `--checkout` excludes `--ko` and `--koa`. kow never
reads a `.env` file and never detects a checkout on its own.

The hidden options are for tests and releases: `kow --extract DIR`
writes the server payload into DIR, `kow --test` runs the pairing test
and the artifact tests, `kow --test-provision` runs `provision.sh` in a
disposable container ("Test locally"), and `kow --pin` and `kow --check-pins` rewrite or
check the pinned releases (docs/release.md, "kow").

## The workspace folder

`kow NAME init` makes `./NAME` (mode 0700) and refuses an existing
folder. In the repository, keep workspaces in `kow/`, whose
`.gitignore` ignores everything but the script. The folder holds:

- `id_ed25519`: the deployment's own SSH key pair, without a
  passphrase. Cloud-init gives its public half to `me`. Your own SSH
  keys and your SSH agent are never used.
- `known_hosts`: the server's ed25519 host key, under the name NAME
  (ssh's `HostKeyAlias`), so the server's address can change. It is
  empty until the first connection, which accepts the key and pins
  it; every later connection refuses another key. After you build the
  server again, empty the file: the new server has a new key.
- `ssh_config`: the one SSH configuration of every kow command and of
  the smoke test: user `me`, only this key (an absolute
  `IdentityFile` and `UserKnownHostsFile` in the folder), no agent, no
  agent forwarding, no password prompt, strict host key check. Use it
  with `ssh -F`. kow adds `StrictHostKeyChecking=accept-new` only
  while `known_hosts` is empty.
- `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`,
  `cloud-init.yaml` and `.terraform.lock.hcl`: the OpenTofu
  configuration. kow runs `tofu` in the folder, so the state
  (`terraform.tfstate`) and `.terraform/` are there too, in the
  default workspace only.
- `terraform.tfvars`: the input, a template that you fill in.
- `address`, only for a host without a state, such as the local VM.

Keep the folder safe: its keys give root on the server. Delete it only
after `tofu destroy`.

## Install

1. Export `DIGITALOCEAN_TOKEN` and `CLOUDFLARE_API_TOKEN`. Give the
   Cloudflare token Zone DNS Edit access to this zone only. Do not put
   tokens in tfvars. Caddy gets no DNS token.
2. Run `kow NAME init`, then edit `NAME/terraform.tfvars`:

   ```hcl
   zone_id   = "YOUR_ZONE_ID"
   zone_name = "example.net"
   ko_label  = "ko"
   region    = "fra1"
   size      = "s-1vcpu-1gb"
   ```

   The ko host is `ko_label.zone_name`; the enrollment host is
   `enroll.` and the ko host. `ssh_cidrs` limits SSH to source
   networks; by default every address may connect (see "Threat
   model").
3. Run `kow NAME deploy`. The install copies ko and koa as `me` into
   `~/ko-install/linux/` and `~/ko-install/koa/`, writes the payload
   into `~/ko-install/deploy/`, and runs `provision.sh` with sudo. You
   can run `kow NAME install` again at any time ("Repeated installs"). Wait for DNS and for
   Caddy to obtain both server certificates. Port 80 stays closed;
   ACME must use TLS-ALPN-01 on port 443.
4. Run `kow NAME smoke`. It needs a curl with HTTP/3 (`curl -V` lists
   `HTTP3`): Homebrew's curl has it, the curl of macOS has none, and
   the test refuses to start without it. It creates and revokes a
   test device. It checks TLS, HTTP/3, the WebSocket, socket access,
   all TCP ports (only 22 and 443 may accept a connection) and all UDP
   ports (only 443 may receive a datagram). The TCP scan takes about a
   minute, because the firewall drops the other ports. The UDP scan
   runs a root catcher on the server over SSH: it sees the datagrams
   that pass both firewalls. Check the Caddy journal for successful
   ACME issuance with port 80 closed. This live check is required
   before use.
5. After the smoke test passes, run:

   ```sh
   kow NAME ssh 'sudo aa-enforce caddy; sudo systemctl restart caddy'
   ```

   Check `sudo journalctl -k` for AppArmor denials. Provisioning starts
   the profile in complain mode and keeps an enforced profile enforced.

## Repeated installs

A repeated `kow NAME install` with the same builds does no work that
is already in place. kow identifies each build: a release by its
version and archive SHA-256, a checkout build by a SHA-256 over its
paths, contents, modes and symlink targets. Provisioning records the
identity of the installed ko in `/opt/ko/.kow-source` and of koa in
`/opt/koa.kow-source`. Before it downloads or copies a build, kow
reads both files over SSH; on an exact match it neither downloads nor
copies that build, and `provision.sh` leaves it in place. A
mismatch, a missing file or a failed or unreadable answer takes the
full path. A `--checkout` install still runs both builds. Provisioning
removes an identity before it changes that build and writes it again
only after the services run, so a failed install never leaves an
identity that matches a mixed build.

`provision.sh` compares each file, symlink, account setting and
permission before it changes it. It runs `apt-get update` and
`apt-get install` only when a listed package is missing or an apt
source or key changed; package updates stay with unattended-upgrades.
Work that a change makes necessary (apt, or the restart of ko, Caddy,
nftables, ssh or systemd-resolved) has a marker in
`/var/lib/kow/pending/` from the change until it succeeds, so a run
that fails between the change and the restart leaves the work to the
next run. A repeated install still does the SSH query, the checksum
copy of the payload, the comparisons, the validations, the
tmpfiles, sysctl and AppArmor loads, `systemctl daemon-reload`,
`enable` and the status checks, and the checks of `me.sh`.

## Agents on the server

Provisioning gives `me` what a Koa pane needs, and no credentials:

- koa, installed in `/opt/koa`, separate from ko. Provisioning
  replaces it when the build changes. The service and login PATH
  include its `bin` directory, after `~/.local/bin`. A koa update
  applies to new panes without a ko restart.
- Node 24 from NodeSource's apt repository (Debian 13 has Node 20;
  koa needs 24). The payload's `files/nodesource.asc` is the
  repository's key, so apt checks it, and updates come through apt.
- pi and Claude Code, at the versions of the payload's
  `tools/package.json`, installed by `npm ci` from its lockfile into
  `~/.local/share/ko-tools`, with `pi` and `claude` in `~/.local/bin`.
  npm checks every package against the lockfile's hash; Claude Code's
  native binary is one of those packages. A changed lockfile installs
  again on the next run.
- Debian's `fd-find`, linked as `fd` in `~/.local/bin` (Debian names
  it `fdfind`), for Koa's @-file completion and pi's find tool.
- `~/.pi/agent/settings.json` from the payload's
  `files/pi-settings.json`, only when the file does not exist: later
  runs never touch it. It names the pi packages, each pinned to a
  commit or a version; pi installs them on its first start.

Log in once on the server, in a login shell (`kow NAME ssh`; a
command given to ssh runs without `~/.local/bin` on PATH): run
`claude` once for Claude Code's login, which pi-claude-bridge uses,
and `pi`, then `/login` for each provider that you use.

## Devices

Run `kow NAME pair`. It prints one line `kido-pair: {...}` and the
same text as a QR code. The line carries the server's name, which
Kido shows as the server's title: the machine's hostname, or `--name
NAME` (1 to 64 characters, no control characters). Within 120
seconds, paste the line into Kido.app (Pair Server). The token works
once. Check the device name and fingerprint that `ko-pair` prints: if
they are not your device, someone else used the code; revoke it. Do
not share the line or the QR code.

Use `kow NAME list-devices` to list devices. Use `kow NAME unpair FP`
to revoke a full fingerprint or a unique prefix of at least eight hex
digits. Pairing and revocation restart Caddy. All devices reconnect.
A restart failure leaves the files in their reported state; correct
Caddy and restart it before you trust the result.

The device folder is `/var/lib/ko-devices`. The server state is
`/var/lib/ko`. The build is in `/opt/ko`. Login shells set `KO_STATE_DIR`
and add the ko and koa commands to PATH. The ko host is in
`/etc/ko-pair.json`, with the pairing port; `ko-pair` derives the
enrollment host from it. The pairing listener uses loopback port 8791
only. The Caddy admin socket is `/run/caddy/admin.sock`, mode 0600.

The server's own sites go in `/etc/caddy/sites.d/NAME.caddy`, root-owned
files written with sudo; `kow NAME install` never changes that folder.
A site uses a name under `*.<ko host>`, which DNS already points at
the server, and keeps its files under `/etc/caddy`: Caddy's AppArmor
profile lets it read there, but not in `/srv` or a home folder. A
site that does not validate stops the next install at its `caddy
validate`. Such a site is public unless it adds `tls { client_auth
... }` like the ko host. `sudo systemctl reload caddy` applies it.

## Threat model

The design is in `plans/remote-mtls.md`, section 2. The facts that
the operator must know:

- A paired certificate and its key give root: the device is `me`,
  and `me` has sudo without a password.
- Caddy refuses a TLS handshake without a certificate from
  `/var/lib/ko-devices`. ko has no TCP listener; its socket accepts
  only `me` and `caddy`.
- The key of Kido.app is a Secure Enclave key. A copy of the Mac's
  disk does not give access. Malware that runs as the Mac user can
  sign while it runs; revoke that device.
- `ko-pair` runs as root and reads a request from the network, only
  while a pairing is open (120 s at most).
- Certificates do not expire. Revocation is the one control. It
  removes the certificate and restarts Caddy, which ends every open
  connection of every device.
- Revocation closes the door; it does not clean the house. Processes
  and changes that a lost device made stay. After a loss, revoke the
  device, then inspect the droplet or build it again with OpenTofu.
- SSH is open to every source address. It accepts only the
  deployment's own key, only for `me`, never root and never a
  password. The private key in the workspace folder gives root: keep
  that folder off shared disks and backups that others read. A
  stolen key: remove it from `~me/.ssh/authorized_keys` through
  another session, or build the server again with a new workspace.
  `ssh_cidrs` restores a source limit when you want one.
- The first SSH connection trusts the host key that it receives, so
  a man-in-the-middle on that one connection could impersonate the
  server. Every later connection is pinned to that key.
- The default install trusts the GitHub releases of ko and koa
  through the SHA-256 that kow pins; `--ko` and `--koa` trust the
  digest that GitHub publishes for the asset.
- The software key in KidoPairing's test fixture
  (`app/Packages/KidoPairing/Tests/KidoPairingTests/testdata`) is
  public test data. Never pair it on a real server.

## Test locally

`kow --test` extracts the payload into a temporary folder and runs
its `test.sh` against KidoPairing's fixture in the checkout, after the
unit tests of the artifact identities and the transfer choice. On a
Debian 13 host, as root, install `python3-cryptography`, `qrencode`,
`openssl` and `curl`, then run `kow/kow --test`. On a Mac with
Apple's container CLI:

```sh
container run --name kow-local-test \
  --mount type=bind,source="$PWD",target=/work,readonly debian:13 \
  bash -c 'apt-get update && apt-get install -y python3-cryptography qrencode openssl curl && python3 /work/kow/kow --test'
container delete kow-local-test
```

`kow --test-provision` changes the system it runs on, so it runs only
in a disposable Debian 13 container with `KOW_TEST_PROVISION=1`, and
needs `sudo` and `diffutils` too. It replaces apt, systemd, Caddy and
the other system commands with stubs that log their arguments, and
installs a fake ko and koa. It checks that a second identical run
writes no file, runs no apt or npm and starts or restarts no service,
and that a run which fails after a change completes the apt work and
the ko restart on the next run. It does not check real systemd
effects.

```sh
container run --rm --mount type=bind,source="$PWD",target=/work,readonly \
  -e KOW_TEST_PROVISION=1 debian:13 \
  bash -c 'apt-get update && apt-get install -y python3-cryptography qrencode openssl curl sudo diffutils && python3 /work/kow/kow --test-provision'
```

Tests use a private folder under `/tmp`. Only tests set
`KO_DEVICES_DIR`, `KO_PAIR_RESTART` and `KO_PAIR_SECONDS`.
Tests pass the ko host and port as `ko-pair [--name NAME] HOST PORT`.
The restart override replaces the complete restart and readiness check.
The pairing duration must be greater than zero and at most 120 seconds.

## Rehearse in a local VM

`kido-vm linux` (docs/build.md, "The Debian guest") runs Debian 13
arm64 with systemd on the Mac, from the same cloud-init as the
droplet (the workspace's `cloud-init.yaml`), with the key of a
workspace folder. It needs no DNS: Caddy cannot get ACME certificates
there, so provisioning takes the server certificate as an input:
`provision.sh --tls-cert CERT KEY KO_HOST SSH_CIDR...` installs the
pair as `/etc/caddy/ko-server.crt` and `.key` and gives both sites
`tls` with it, on every run. Without the option, the sites use ACME.
Make one self-signed certificate with `ko.vm.test` and
`enroll.ko.vm.test` in its SAN.

```sh
make -C app vm && make build-linux LINUX_ARCHS=aarch64
make -C koa build
kow/kow kow/vm init
app/vm/.build/out/Products/Release/kido-vm linux install --deployment kow/vm
app/vm/.build/out/Products/Release/kido-vm linux up   # writes kow/vm/address
kow/kow kow/vm ssh true                               # pins the host key; no prompt
```

`kow install` needs a state, so the rehearsal copies by hand: copy
`build/ko/share/ko/linux/aarch64/` to `~/ko-install/linux/`,
`build/koa/` to `~/ko-install/koa/`, the output of `kow/kow --extract
DIR` to `~/ko-install/deploy/`, and the certificate to `~/ko-install`,
with rsync (`-e "ssh -F kow/vm/ssh_config"`), then run `sudo
~/ko-install/deploy/provision.sh --tls-cert ... ko.vm.test
192.168.64.0/24 10.99.0.0/24`.

The smoke test needs a curl with HTTP/3, and Debian's curl has it.
Run the payload's `smoke.sh` in the guest, from a network namespace:
its traffic to the guest's address enters through a veth pair, so
nftables applies to it as to an outside client. Create the namespace
after provisioning: in the guest, a systemd reload with the namespace
present made `systemd-ssh-generator` crash in the vsock driver and
the next reload hang. For the test's SSH to the guest, copy
`ssh_config`, `id_ed25519` and `known_hosts` of the workspace into
the guest at the same absolute path (owned by `me`, mode 0700), so
the `ssh_config` works there, and remove the copy afterwards:

```sh
sudo ip netns add ko-smoke
sudo ip link add ko-smoke-h type veth peer name ko-smoke-c
sudo ip link set ko-smoke-c netns ko-smoke
sudo ip addr add 10.99.0.1/24 dev ko-smoke-h
sudo ip link set ko-smoke-h up
sudo ip netns exec ko-smoke ip addr add 10.99.0.2/24 dev ko-smoke-c
sudo ip netns exec ko-smoke ip link set ko-smoke-c up
sudo ip netns exec ko-smoke ip link set lo up
sudo ip netns exec ko-smoke ip route add default via 10.99.0.1
sudo ip netns exec ko-smoke sudo -u me env \
  SSL_CERT_FILE=$HOME/ko-install/server.crt CURL_CA_BUNDLE=$HOME/ko-install/server.crt \
  ~/ko-install/deploy/smoke.sh "$FOLDER/ssh_config" ko.vm.test 192.168.64.5
sudo ip netns delete ko-smoke   # also removes the veth pair
```

`smoke.sh SSH_CONFIG HOST [ADDRESS]`: the optional ADDRESS is where
every connection goes; the names stay in SNI and `Host`. `kow NAME
smoke [--host HOST] [ADDRESS]` runs the same script, with the host
from the state unless `--host` names it, and the folder's address
unless ADDRESS names another. The smoke test never turns off
certificate checks. The VM has no cloud firewall, so its port scans
check only nftables. A container of Apple's `container` cannot
replace the namespace: it did not reach the guest's address, on its
default network or on one in the guest's subnet.

## Remove

Revoke devices first if you must keep the server for inspection. To
remove the droplet, firewall, DNS records and registered SSH public
key, run `tofu destroy` in the workspace folder.
