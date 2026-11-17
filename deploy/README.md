# One remote ko server

Use a Debian 13 x64 DigitalOcean droplet and a Cloudflare DNS zone.
The Mac needs OpenTofu, Python 3, rsync, OpenSSH and OpenSSL. The
build needs the tools in `docs/build.md`. Use a dedicated DNS zone or
label set: this setup owns the ko host and `enroll.<ko host>`.

## Deployments

A deployment is one folder `deploy/deployments/NAME/` (mode 0700,
ignored by git). `deploy/bin/new NAME` makes it, and `deploy/bin/tofu
NAME` makes it on its first run. It holds:

- `id_ed25519`: the deployment's own SSH key pair, without a
  passphrase. Cloud-init gives its public half to `me`. Your own SSH
  keys and your SSH agent are never used.
- `ssh_host_ed25519_key`: the server's SSH host key, made on the Mac.
  Cloud-init installs it, so `known_hosts` is correct before the first
  connection. There is no trust on first use.
- `known_hosts`: that host key, under the name NAME (ssh's
  `HostKeyAlias`), so the server's address can change.
- `ssh_config`: the one SSH configuration of `deploy/bin/ssh`,
  `install.sh`, `rsync` and `smoke.sh`: user `me`, only this key, no
  agent, no agent forwarding, no password prompt, strict host key
  check. Use it with `ssh -F`.
- `terraform.tfvars`, `terraform.tfstate` and `.terraform/`: the
  OpenTofu input and state of this deployment.
- `address`, only for a host without a state, such as the local VM.

Keep the folder safe: its keys give root on the server. Delete it only
after `destroy`.

`deploy/bin/ssh [NAME] [COMMAND...]` connects as `me`. It takes the
address from the state's `ipv4` output, or from `address`. NAME is
optional when only one deployment exists.

## Install

1. Export `DIGITALOCEAN_TOKEN` and `CLOUDFLARE_API_TOKEN`. Give the
   Cloudflare token Zone DNS Edit access to this zone only. Do not put
   tokens in tfvars. Caddy gets no DNS token.
2. Run `deploy/bin/new NAME`, then create
   `deploy/deployments/NAME/terraform.tfvars`:

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
3. Run:

   ```sh
   deploy/bin/tofu NAME init
   deploy/bin/tofu NAME apply
   deploy/install.sh NAME
   ```

   `deploy/bin/tofu` runs `tofu` on `deploy/terraform` with the
   folder's state and tfvars, in the default workspace only. The install copies the x86_64 build as `me` and runs
   provisioning with sudo. You can run it again. Wait for DNS and for
   Caddy to obtain both server certificates. Port 80 stays closed;
   ACME must use TLS-ALPN-01 on port 443.
4. Run the smoke test. It needs a curl with HTTP/3 (`curl -V` lists
   `HTTP3`; the curl of macOS has none, Debian's has it), so run it
   in a Debian container that mounts the checkout at the same path:

   ```sh
   container run --rm --mount type=bind,source="$PWD",target="$PWD",readonly debian:13 \
     bash -c "apt-get update && apt-get install -y python3 curl openssl openssh-client &&
       $PWD/deploy/smoke.sh $PWD/deploy/deployments/NAME/ssh_config ko.example.net"
   ```

   It creates and revokes a test device. It checks TLS, HTTP/3, the
   WebSocket, socket access, all TCP ports (only 22 and 443 may
   accept a connection) and all UDP ports (only 443 may receive a
   datagram). The TCP scan takes about a minute, because the firewall
   drops the other ports. The UDP scan runs a root catcher on the
   server over SSH: it sees the datagrams that pass both firewalls.
   Check the Caddy journal for successful ACME issuance with port 80
   closed. This live check is required before use.
5. After the smoke test passes, run:

   ```sh
   deploy/bin/ssh NAME 'sudo aa-enforce caddy; sudo systemctl restart caddy'
   ```

   Check `sudo journalctl -k` for AppArmor denials. Provisioning starts
   the profile in complain mode and keeps an enforced profile enforced.

## Devices

Run `deploy/bin/ssh NAME -t sudo ko-pair`. It prints one line
`kido-pair: {...}` and the same text as a QR code. The line carries
the server's name, which Kido shows as the server's title: the
machine's hostname, or `--name NAME` (1 to 64 characters, no control
characters). Within 120
seconds, paste the line into Kido.app (Pair Server). The token works
once. Check the device name and fingerprint that `ko-pair` prints: if
they are not your device, someone else used the code; revoke it. Do
not share the line or the QR code.

Use `sudo ko-devices` to list devices. Use `sudo ko-revoke FP` to
revoke a full fingerprint or a unique prefix of at least eight hex
digits. Pairing and revocation restart Caddy. All devices reconnect.
A restart failure leaves the files in their reported state; correct
Caddy and restart it before you trust the result.

The device folder is `/var/lib/ko-devices`. The server state is
`/var/lib/ko`. The build is in `/opt/ko`. Login shells set `KO_STATE_DIR`
and add `/opt/ko/bin` to PATH. The ko host is in
`/etc/ko-pair.json`, with the pairing port; `ko-pair` derives the
enrollment host from it. The pairing listener uses
loopback port 8791 only.
The Caddy admin socket is `/run/caddy/admin.sock`, mode 0600.

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
  password. The private key in `deploy/deployments/NAME/` gives root:
  keep that folder off shared disks and backups that others read. A
  stolen key: remove it from `~me/.ssh/authorized_keys` through
  another session, or build the server again with a new deployment.
  `ssh_cidrs` restores a source limit when you want one.
- The server's SSH host private key is in the droplet's user-data.
  DigitalOcean keeps it, the account's API token can read it, and the
  metadata service serves it on the droplet. nftables refuses that
  service to every uid but root. The OpenTofu state in the folder
  holds it too.
- The software key in `testdata/` is public test data. Never pair it
  on a real server.

## Test locally

On a Debian 13 host, as root, install `python3-cryptography`, `qrencode`,
`openssl` and `curl`, then run `deploy/test.sh`. On a Mac with Apple's
container CLI:

```sh
container run --name u3-local-test \
  --mount type=bind,source="$PWD",target=/work,readonly debian:13 \
  bash -c 'apt-get update && apt-get install -y python3-cryptography qrencode openssl curl && /work/deploy/test.sh'
container delete u3-local-test
```

Tests use a private folder under `/tmp`. Only tests set
`KO_DEVICES_DIR`, `KO_PAIR_RESTART` and `KO_PAIR_SECONDS`.
Tests pass the ko host and port as `ko-pair [--name NAME] HOST PORT`.
The restart override replaces the complete restart and readiness check.
The pairing duration must be greater than zero and at most 120 seconds.

## Rehearse in a local VM

`kido-vm linux` (docs/build.md, "The Debian guest") runs Debian 13
arm64 with systemd on the Mac, from the same cloud-init as the
droplet, with the keys of a deployment folder. It needs no DNS: Caddy
cannot get ACME certificates there, so provisioning takes the server
certificate as an input: `provision.sh --tls-cert CERT KEY KO_HOST
SSH_CIDR...` installs the pair as `/etc/caddy/ko-server.crt` and
`.key` and gives both sites `tls` with it, on every run. Without the
option, the sites use ACME. Make one self-signed certificate with
`ko.vm.test` and `enroll.ko.vm.test` in its SAN.

```sh
make -C app vm && make build-linux LINUX_ARCHS=aarch64
deploy/bin/new vm
app/vm/.build/out/Products/Release/kido-vm linux install --deployment deploy/deployments/vm
app/vm/.build/out/Products/Release/kido-vm linux up   # writes deploy/deployments/vm/address
deploy/bin/ssh vm true                                 # no prompt: the host key is pinned
```

Copy `build/ko/share/ko/linux/aarch64/`, `deploy/` (without
`deployments/`) and the certificate to `~/ko-install` with rsync as
`install.sh` does (`-e "ssh -F deploy/deployments/vm/ssh_config"`),
then run `sudo provision.sh --tls-cert ... ko.vm.test 192.168.64.0/24
10.99.0.0/24`.

The smoke test needs a curl with HTTP/3, and Debian's curl has it.
Run the test in the guest, from a network namespace: its traffic to
the guest's address enters through a veth pair, so nftables applies
to it as to an outside client. Create the namespace after
provisioning: in the guest, a systemd reload with the namespace
present made `systemd-ssh-generator` crash in the vsock driver and
the next reload hang. For the test's SSH to the guest, copy
`ssh_config`, `id_ed25519` and `known_hosts` of
`deploy/deployments/vm` into the guest at the same absolute path
(owned by `me`, mode 0700), so the `ssh_config` works there, and
remove the copy afterwards. Do not copy the host key:

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
every connection goes; the names stay in SNI and `Host`. The smoke
test never turns off certificate checks. The VM has no cloud
firewall, so its port scans check only nftables. A container of
Apple's `container` cannot replace the namespace: it did not reach
the guest's address, on its default network or on one in the guest's
subnet.

## Remove

Revoke devices first if you must keep the server for inspection. To
remove the droplet, firewall, DNS records and registered SSH public key:

```sh
deploy/bin/tofu NAME destroy
```
