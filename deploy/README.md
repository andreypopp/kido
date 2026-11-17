# One remote ko server

Use a Debian 13 x64 DigitalOcean droplet and a Cloudflare DNS zone.
The Mac needs OpenTofu, Python 3, rsync, OpenSSL and a curl with
HTTP/3 (`curl -V` lists `HTTP3`; the curl of macOS has none). The build
needs the tools in `docs/build.md`. Keep the SSH private key in your
SSH agent. Use a dedicated DNS zone or label set: this setup owns
`enroll.<domain>` and the ko host.

## Install

1. Export `DIGITALOCEAN_TOKEN` and `CLOUDFLARE_API_TOKEN`. Give the
   Cloudflare token Zone DNS Edit access to this zone only. Do not put
   tokens in tfvars. Caddy gets no DNS token.
2. Create `deploy/terraform/operator.tfvars`:

   ```hcl
   zone_id             = "YOUR_ZONE_ID"
   zone_name           = "example.net"
   ko_label            = "ko"
   region              = "fra1"
   size                = "s-1vcpu-1gb"
   ssh_public_key_path = "~/.ssh/id_ed25519.pub"
   ssh_cidrs           = ["YOUR_PUBLIC_IP/32"]
   ```

   Use `ssh_public_key` instead of `ssh_public_key_path` to supply key
   text. Include your IPv6 SSH CIDR if necessary. Keep the state safe.
3. Run:

   ```sh
   tofu -chdir=deploy/terraform init
   tofu -chdir=deploy/terraform apply -var-file=operator.tfvars
   deploy/install.sh
   ```

   Check the SSH host key before you accept it. The install copies the
   x86_64 build as `me` and runs provisioning with sudo. You can run it
   again. Wait for DNS and for Caddy to obtain both server certificates.
   Port 80 stays closed; ACME must use TLS-ALPN-01 on port 443.
4. Run `deploy/smoke.sh ko.example.net`. It creates and revokes a test
   device. It checks TLS, HTTP/3, the WebSocket, socket access, all
   TCP ports (only 22 and 443 may accept a connection) and all UDP
   ports (only 443 may receive a datagram). The TCP scan takes about
   a minute, because the firewall drops the other ports. The UDP scan
   runs a root catcher on the server over SSH: it sees the datagrams
   that pass both firewalls. Check the Caddy journal for successful ACME issuance with
   port 80 closed. This live check is required before use.
5. After the smoke test passes, run:

   ```sh
   ssh me@ko.example.net 'sudo aa-enforce caddy; sudo systemctl restart caddy'
   ```

   Check `sudo journalctl -k` for AppArmor denials. Provisioning starts
   the profile in complain mode and keeps an enforced profile enforced.

## Devices

Run `ssh -t me@ko.example.net sudo ko-pair`. It prints one line
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
and add `/opt/ko/bin` to PATH. Pairing host names are in
`/etc/ko-pair.json`, with the pairing port. The pairing listener uses
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
Tests pass the host, enrollment host and port as `ko-pair [--name NAME] HOST ENROLL PORT`.
The restart override replaces the complete restart and readiness check.
The pairing duration must be greater than zero and at most 120 seconds.

## Rehearse in a local VM

`kido-vm linux` (docs/build.md, "The Debian guest") runs Debian 13
arm64 with systemd on the Mac, from the same cloud-init as the
droplet. It needs no DNS: Caddy cannot get ACME certificates there, so
provisioning takes the server certificate as an input:
`provision.sh --tls-cert CERT KEY KO_HOST ENROLL_HOST SSH_CIDR...`
installs the pair as `/etc/caddy/ko-server.crt` and `.key` and gives
both sites `tls` with it, on every run. Without the option, the sites
use ACME. Make one self-signed certificate with both names in its SAN.

```sh
make -C app vm && make build-linux LINUX_ARCHS=aarch64
app/vm/.build/out/Products/Release/kido-vm linux install
app/vm/.build/out/Products/Release/kido-vm linux up   # prints the address
```

Copy `build/ko/share/ko/linux/aarch64/`, `deploy/` and the
certificate to `~/ko-install` with rsync as `install.sh` does, then
run `sudo provision.sh --tls-cert ... ko.vm.test enroll.vm.test
192.168.64.0/24 10.99.0.0/24`.

The smoke test needs a curl with HTTP/3, and Debian's curl has it.
Run the test in the guest, from a network namespace: its traffic to
the guest's address enters through a veth pair, so nftables applies
to it as to an outside client. Create the namespace after
provisioning: in the guest, a systemd reload with the namespace
present made `systemd-ssh-generator` crash in the vsock driver and
the next reload hang. Copy the VM's SSH key to `~/ko-install/key`
(mode 0600) for the test's SSH to the guest:

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
  KO_SMOKE_SSH="ssh -i $HOME/ko-install/key -o StrictHostKeyChecking=accept-new" \
  ~/ko-install/deploy/smoke.sh ko.vm.test 192.168.64.5
sudo ip netns delete ko-smoke   # also removes the veth pair
```

The optional ADDRESS is where every connection goes; the names stay
in SNI and `Host`. `KO_SMOKE_SSH` is the SSH command, for the VM's
key (`~/.local/state/kido-vm-linux/id_ed25519`). The smoke test never
turns off certificate checks. The VM has no cloud firewall, so its
port scans check only nftables. A container of Apple's `container`
cannot replace the namespace: it did not reach the guest's address,
on its default network or on one in the guest's subnet.

## Remove

Revoke devices first if you must keep the server for inspection. To
remove the droplet, firewall, DNS records and registered SSH public key:

```sh
tofu -chdir=deploy/terraform destroy -var-file=operator.tfvars
```
