# A ko server behind HTTPS with mTLS

Status: design, not started. Base: `origin/main` 8ce43b39d.

Kido.app on macOS reaches a ko server on a DigitalOcean droplet
through Caddy, over HTTPS with mutual TLS. Each device has its own
self-signed certificate, which the server pins after a pairing with a
QR code. iOS is out of scope; the design keeps it possible.

Phase 1 is TLS over TCP. Phase 2 is HTTP/3 over QUIC, for roaming.

## 1. Goals

- A Mac with Kido.app and no SSH access attaches to the sessions of
  the droplet's ko server, with the same model, views and reconnect
  as an SSH remote window.
- A device gets access only through a pairing that the operator
  starts on the server. A device loses access through one command.
- The droplet comes from one `terraform apply` and one provisioning
  script, hardened, with ko and Caddy as systemd services.
- ko changes little: one flag. Caddy has no plugin. The server has
  no database, no private CA and no new Rust program.

Non-goals: iOS, a `ko https://HOST` terminal client (section 9,
Q2), certificate expiry and renewal, more than one user for each
server, a pairing from one device to another device.

## 2. Threat model

**What a certificate is worth.** The droplet has one user, `me`,
with sudo without a password. A pinned certificate with its key is a
shell as `me`, and so root on the droplet. Each part below is judged
against this.

| Attacker | Result | Defence |
|---|---|---|
| The network, no key | Nothing | Caddy refuses the handshake of a certificate that is not in the folder (`mode require` with the leaf verifier). ko has no TCP listener. |
| The network, between the Mac and the droplet | Nothing | The client checks the server certificate (WebPKI) and the server name. |
| A request with SNI of `enroll.` and `Host` of the ko host | Nothing | Caddy answers 421 with no option set (spike 1). |
| A browser on the user's Mac | Nothing | The key is not in a browser's reach, and ko refuses every request with an `Origin` header (docs/protocol.md, section 1). This rule stays. |
| A stolen or copied Mac disk | Nothing without the Secure Enclave of that Mac | The key is a Secure Enclave key. Its blob on disk works only in that enclave. |
| Malware as the Mac user | It can sign while it runs on that Mac; it cannot copy the key | Out of reach of this design. Revoke the device. |
| Someone who reads the QR code within 120 s | A device certificate | The token is single-use: the operator sees the name and the fingerprint of the device that used it, and the legitimate device fails. The operator revokes. |
| A fault in the pairing script | Root | `ko-pair` runs as root and reads a request from the network. It runs only while a pairing is open (120 s at most), behind Caddy's size limit, and parses with the Python standard library and `python3-cryptography`. This is the accepted cost of one small script. |
| A local process on the droplet that is not `me` or Caddy | Nothing | ko's socket accepts two uids (the peer credentials). Caddy's admin endpoint is a unix socket of mode 0600, not `localhost:2019`. |
| A pane | It is `me`, and so root: it can pair a device | None. `sudo` in a pane is the user's own. |

**Revocation.** These facts are from Caddy's source
(`modules/caddytls/connpolicy.go`); spike 1 confirms them on the
installed version:

- A connection policy with client authentication sets
  `SessionTicketsDisabled` (seen in v2.9.1 to v2.11.9). So TLS has no
  session resumption on the ko host: every connection is a full
  handshake with a client signature, and a revoked certificate cannot
  resume. The cost is in section 4.6.
- From v2.11.3 the verifiers run in `VerifyConnection`, on every
  connection; v2.11.3 gave the leaf verifier no certificate bytes,
  which v2.11.4 fixed (commit 6c675e29f87c). The provisioning
  requires Caddy 2.11.4 or later.
- `mode require` with the leaf verifier checks the handshake
  signature and that the certificate is in the folder. It does not
  check the EKU or the validity dates of a pinned certificate
  (spike 1). So the profile checks belong to `ko-pair` (4.3).
- The folder loader reads the `*.pem` files when the configuration is
  provisioned. A removed file has no effect until a reload or a
  restart.
- `reverse_proxy` closes its upgraded streams (WebSockets) when its
  configuration is unloaded (`stream_close_delay` is 0 by default).

The rule: a revocation removes the certificate and then **restarts**
Caddy. After the restart, the only Caddy process is one that read the
folder after the removal, and no connection of the old process
exists. This holds by construction and needs no probe with the
revoked key. Every other device reconnects (section 4.6). A pairing
restarts Caddy in the same way.

**What a revocation does not do.** A process that the device started
in a pane continues, and the device was root. A revocation closes
the door; it does not clean the house. After a loss, the operator
revokes and then checks the droplet, or builds it again with
Terraform. `deploy/README.md` says this.

**Certificates do not expire.** `notAfter` is `99991231235959Z`
(RFC 5280, "no well-defined expiration"). Go does not check the
validity dates of a client certificate under `RequireAnyClientCert`.
The one control is the revocation.

## 3. Architecture

```
Kido.app (macOS)                          Droplet (Debian 13)
+--------------------------+              +----------------------------------------+
| Swift: identity store,   |   TLS 1.3    | Caddy (uid caddy, sandbox)             |
|  Secure Enclave key,     |   mTLS       |  ko host:  client_auth require + leaf  |
|  pairing UI              |  ---------\  |            folder -> DIR/socket        |
| ko_client (Rust):        |  ---------/  |  enroll.:  no client auth              |
|  rustls over TCP,        |   HTTP/1.1   |            -> 127.0.0.1:<pair port>    |
|  sign callback -> Swift  |   WebSocket  +----------------------------------------+
+--------------------------+              | ko server --allow-uid <caddy> (uid me) |
                                          |  DIR/socket: uid me or uid caddy       |
        POST enroll. (server auth only)   +----------------------------------------+
        ------------------------------->  | sudo ko-pair (Python, root)            |
                                          |  runs only while a pairing is open     |
                                          | /var/lib/ko-devices/<fp>.pem           |
                                          +----------------------------------------+
```

| Part | Where | New or extended |
|---|---|---|
| A second uid on the socket | `ko`, `ko_server`, `ko_wire::local` | extends the admission and the directory rule |
| Static Linux server | `Makefile` | extends `build-linux` with `ko-pane` |
| Droplet, pairing, revocation | new directory `deploy/` | new; Terraform, shell, Python |
| TLS transport | `ko_client` (`wire`, `connect`, `api`, `ffi`) | extends the socket path to an endpoint |
| Identity and sign callback | `ko_client::ffi`, `ko_client.h` | new unsafe code |
| Remote kind, identity store, pairing | `app/` | extends `Host` |

## 4. The parts and their rules

### 4.1 A second uid on ko's socket

**Rule.** `ko server --allow-uid UID` lets one more uid connect to
`DIR/socket`. A connection of that uid is a host connection, as one
of the server's own uid: a request without pane headers is the user.
One uid is enough; the flag does not repeat. A server that the
launcher starts never has it.

**The model.** `Origin` (`ko_server/src/server.rs:33`) names whose
authority a connection has. A proxied device has the user's
authority, so `Origin` gets no variant, and no match on it changes:
`router.rs:138`, `:179`, `:249`, `:286`, `:302`;
`state/pane_ops.rs:136`; `state/runtime_ops.rs:20`, `:126`;
`state/visit_ops.rs:246`; `state/prompt.rs:141`; `state.rs:476`,
`:512`. The refusal of an `Origin` header (`router.rs:223`) stays
and also covers the proxied path, because Caddy passes the header.

The one change is the admission, `Verified::admit_from`
(`server.rs:49`): the `Origin::Host` arm admits the server's own uid
or the allowed uid. The value is `Config.allow_uid: Option<u32>`
(`ko_server/src/config.rs`), which the host `Listener` holds and
passes; a runtime listener has none. No second listener, no `Peer`
type and no configuration key exist.

**What must change in ko's directory rules.** Caddy must reach the
socket file, and two rules stop it today:

- `ko_wire::local::socket` (`local.rs:66`) refuses a directory with
  any group or other bit (`mode & 0o077`), for the server and for
  every `ko` command. The rule becomes: refuse group read, group
  write and every other bit (`mode & 0o067`). So 0700 and 0710 pass.
  Group search lets a member of the group open a name that it knows;
  it cannot list the directory. The rule is one for all, with no
  link to the flag, so a `ko` command in a pane needs no knowledge of
  it. The directory that ko creates stays 0700.
- The socket file has the mode of the server's umask, and a connect
  on Linux needs write permission. With `--allow-uid`, the server
  sets the socket's mode to 0660 after the bind. Without the flag
  nothing changes.

ko never changes an owner or a group. The deployment (4.4) makes
`DIR` as `/var/lib/ko`, mode 2710, owner `me`, group `ko-socket`,
with Caddy as the group's one member; the set-group-id bit gives the
socket that group. `KO_STATE_DIR=/var/lib/ko` is in `ko.service` and
in the login environment of `me`. The peer uid check is the gate; the
modes are the second layer. Two facts that the docs state: a member
of the group cannot read `DIR/log`, because the log is created with
mode 0600 and group search gives no read access to it; and a
runtime's listener checks no uid, so the allowed uid gets nothing on
a runtime's socket without the token of a live pane.

**What Caddy sends.** `X-Forwarded-*` headers, which ko ignores, and
the client's `Host`. A request head stays under ko's 16 KiB. Caddy
keeps upstream connections alive; ko supports keep-alive.

**Tests.** A second uid needs root, so the suite cannot connect as
one. What it tests without root:

- Unit, `ko_server`: the admission as a pure function of (peer uid,
  own uid, allowed uid): own passes; allowed passes; a third uid
  fails; with no allowed uid only own passes.
- Unit, `ko_wire::local`: 0700 and 0710 pass; 0750, 0720 and 0701
  are refused.
- e2e: `ko server --allow-uid <own uid>` on a 0710 directory: the
  socket's mode is 0660 and `ko api /version` answers; without the
  flag the socket keeps the umask's mode; `--allow-uid x` is a usage
  error (exit 124).
- The droplet smoke test (4.4), as root: `caddy` reaches the socket;
  `nobody` is refused (`sudo -u nobody curl --unix-socket`); `me`
  works. This is the only test of a real second uid.

### 4.2 The static Linux server

`make build-linux` builds only `ko` today, because the static build
served runtimes, where no server runs (docs/build.md, "The static
Linux ko"). The droplet's server needs `ko-pane`.

**Rule.** `build-linux` also builds `ko-pane` for each architecture
into `linux/<arch>/bin/`; `check-static` checks both files. The
droplet gets `linux/x86_64/` whole: `bin/ko`, `bin/ko-pane`,
`share/ko`.

**Risk.** A ko server on musl is not verified today: CI runs the
suite on glibc. The unit runs the e2e suite once against the musl
build in the `ci-like` container (`make ci-like`), on the host's
architecture, and reports the failures. x86_64 is cross-built and
gets only the smoke test on the droplet. The app bundle grows by one
`ko-pane` for each bundled architecture; if that is not wanted, the
target gets its own name (`build-linux-server`).

### 4.3 Pairing and the device folder

Pairing is Python in `deploy/`, not Rust: three scripts that run as
root through `sudo`, with the Debian packages `python3-cryptography`
and `qrencode`. No crate and no ko code is involved.

**The folder** is the one store: `/var/lib/ko-devices`, 0750
`root:caddy`.

- `<fp>.pem` is the certificate, in the script's own PEM encoding of
  the DER that it checked. `<fp>` is the lowercase hex SHA-256 of the
  DER. `<fp>.json` is the sidecar: `{name, enrolled (unix seconds)}`.
- A device exists when its `.pem` exists. A pairing writes the
  sidecar first and the `.pem` last; a revocation deletes the `.pem`
  first.
- Each file is written under a name that does not end in `.pem`,
  synced and renamed, under an `flock` on the folder. Caddy's loader
  reads only `*.pem`.

**`sudo ko-pair`** runs one pairing in the foreground:

1. It makes a token of 32 random bytes, prints `kido-pair:` and the
   payload as one line, and the same text as a QR code (`qrencode -t
   ansiutf8`, the text on stdin). It keeps only `SHA-256(token)`. The
   token goes to no disk, no log and no argument list.
2. It serves `POST /v1/enroll` on `127.0.0.1` (`http.server` of the
   standard library), behind Caddy's `enroll.` host, for at most
   120 s. Outside a pairing, Caddy answers 502 there.
3. On the first valid request it writes the device and runs `caddy
   validate`, because a `.pem` that Caddy cannot load stops Caddy's
   start (spike 1). If the validation fails, it removes the new
   files, answers 400 and exits nonzero; the old set stays in
   service. Else it answers 200, restarts Caddy and waits (10 s)
   until the unit is active and port 443 accepts. Only then it
   prints the device's name and fingerprint as paired and exits 0. A
   failed restart is a nonzero exit with the state that it left.
4. On expiry it prints that no device paired and exits 1.

The answer goes out before the restart, because it travels through
Caddy. The app waits for the activation (4.8).

**`sudo ko-revoke FP`** removes the device with that fingerprint (or
a unique prefix of 8 or more digits), restarts Caddy, waits as above
and prints success only then. **`sudo ko-devices`** lists name,
fingerprint and time.

**The request.** One POST with a JSON body of at most 8 KiB:

```
{ token: base64url(32 bytes),
  name: string, 1 to 64 characters, no controls,
  certificate: base64(DER),
  signature: base64(DER ECDSA signature) }
```

The signed message is `"kido-enroll-v1" ‖ 0x00 ‖ SHA-256(token) ‖
SHA-256(certificate DER)`, signed with the certificate's key (ECDSA
P-256, SHA-256). The prefix separates this use of the key from its
TLS signatures. The signature proves possession of the key without a
challenge round trip, and binds the proof to this token.

The checks, in this order:

1. The size limits and the JSON shape.
2. `SHA-256(token)` equals the kept hash (`hmac.compare_digest`).
   After 5 wrong tokens the pairing ends.
3. The certificate (`cryptography.x509`): one certificate, at most
   2 KiB; an ECDSA P-256 key; signed by its own key with
   ECDSA-SHA256; `CA:FALSE`; EKU `clientAuth`.
4. The signature over the message above.
5. Under the lock: write the device.

A request that passes check 2 ends the pairing whatever follows, so a
token works once. The answers are `200 {fingerprint}`, `400`, `403`
(one answer for a wrong, used or expired token) and `429`. The server
handles one request at a time, each with a 5 s deadline, and at most
30 in a pairing. It logs the result, the fingerprint and Caddy's
`X-Forwarded-For`, never the body.

No limit on new connections goes into nftables for port 443: a ko
client opens one connection for each view and each request.

**The payload:**

```
{ v: 1, enroll: "https://enroll.<domain>/v1/enroll",
  host: "<ko host name>", token: base64url }
```

**The certificate profile** (the app builds it, 4.8): version 3,
random 128-bit serial, ECDSA P-256, self-signed with SHA-256,
`CA:FALSE` (critical), key usage `digitalSignature`, EKU
`clientAuth`, SAN URI `urn:kido:install:<uuid>` with the install id,
`notBefore` 2026-01-01, `notAfter` 9999-12-31. The script does not
read the SAN.

**Tests** (`deploy/test.sh`, with `openssl` and `curl` against the
real scripts). The scripts read three settings from the environment,
which only the test sets: the folder, the port and the restart
command. The test runs `ko-pair` on a `/tmp` folder with a restart
command that records its call, reads the payload from its output,
makes a key and a certificate (`openssl ecparam`, `req -x509`), signs
(`openssl dgst -sign`) and posts with `curl`. It asserts: the files
and their modes; the exit code and the printed fingerprint; that the
restart ran after the write and before the success line; that a
second POST is refused; one failing case for each check (a wrong
token, a CA certificate, an RSA key, a signature over another token,
a signature by another key, an oversized body, expiry with a short
limit); that the token and the body are in no output; `ko-devices`
and `ko-revoke`. It also writes the fixed vector of the signed
message that the app's tests use (4.8). It needs
`python3-cryptography` and `qrencode`, so it runs in the Debian 13
container and on the droplet, not in `make verify` on macOS.

### 4.4 The droplet: `deploy/`

```
deploy/terraform/      main.tf, variables.tf, outputs.tf, versions.tf, .terraform.lock.hcl
deploy/provision.sh    runs on the droplet as root; safe to run again
deploy/install.sh      runs on the Mac: copies the build with rsync and runs provision.sh over SSH
deploy/files/          Caddyfile, ko.service, caddy drop-in, tmpfiles, nftables.conf,
                       sshd drop-in, unattended-upgrades, apparmor profile
deploy/ko-pair, ko-revoke, ko-devices     Python (4.3)
deploy/test.sh         the pairing tests (4.3)
deploy/smoke.sh        the server tests below, with openssl and curl
deploy/README.md       the operator's steps and the note of section 2
```

`scripts/checks.sh` gets a row for `deploy/` (the shell lint only);
a path without a row selects every check.

**Terraform** (the providers `digitalocean` and `cloudflare`,
versions pinned; state and `*.tfvars` are local and ignored by git).
The inputs: `DIGITALOCEAN_TOKEN`; `CLOUDFLARE_API_TOKEN`, a token
with only Zone, DNS, Edit on the one zone; the zone's id and name.

- `digitalocean_droplet`: Debian 13 x64, region and size as
  variables, the operator's SSH key, monitoring off, the droplet
  agent removed (the web console is a second way in), `user_data`
  that creates `me` with the key, locks root and installs `rsync`
  (the image has none, and `install.sh` needs it). A test VM gets its
  seed from the same user-data, so the two cannot differ.
- `digitalocean_firewall`: in: 22/tcp from `ssh_cidrs`, 443/tcp from
  all (phase 2 adds 443/udp). Port 80 by Q4. Out: all.
- `cloudflare_dns_record`: A (and AAAA when the droplet has IPv6)
  for `enroll.<domain>` and the ko host, each with `proxied =
  false` (DNS only). The reason: Cloudflare's proxy would end the
  TLS connection, so Caddy would never see the device certificate,
  and it would not pass the UDP of QUIC.
- ACME stays TLS-ALPN-01 on port 443. Caddy gets no Cloudflare
  plugin and no DNS token.

**Provisioning** (`provision.sh`; each step is idempotent):

- Packages: Caddy from Caddy's own apt repository, at or above the
  minimum version of section 2; `nftables`, `unattended-upgrades`,
  `apparmor-utils`, `python3-cryptography`, `qrencode`.
- Users: `me` (a login shell, the SSH key, sudo without a password);
  `caddy` (from the package); the group `ko-socket` with `caddy`.
- SSH: keys only, no root, no keyboard-interactive, `AllowUsers me`.
- nftables: default deny in; 22 from the SSH set, 443; loopback;
  established. The cloud firewall has the same rules; each covers a
  mistake in the other.
- unattended-upgrades: the security origin, automatic reboot in a
  window (04:00 local by default).
- ko: `/opt/ko/{bin,share}` from the static build. `ko.service` runs
  `ko server --allow-uid <id -u caddy>` as `me` with
  `KO_STATE_DIR=/var/lib/ko` and `Restart=always`; `tmpfiles.d` makes
  the directory (4.1). The unit has no sandbox: ko is the user's
  shell, and the user has sudo.
- Caddy: a drop-in with `ProtectSystem=strict`, `ProtectHome`,
  `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`,
  `CapabilityBoundingSet=CAP_NET_BIND_SERVICE`,
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`,
  `SystemCallFilter=@system-service`, `ReadWritePaths` for its data
  and log, `SupplementaryGroups=ko-socket`. An AppArmor profile for
  Caddy, set to enforce after the smoke test passes in complain mode.
- `/usr/local/sbin/ko-pair`, `ko-revoke`, `ko-devices`, and
  `/var/lib/ko-devices`.

**The Caddyfile** (this syntax passed `caddy validate` on 2.11.9):

```
{ admin unix//run/caddy/admin.sock|0600    # not localhost:2019
  auto_https disable_redirects        # port 80 is closed
  servers { protocols h1 h2 }         # phase 2 adds h3
  grace_period 3s }
enroll.<domain> {
  @enroll { method POST; path /v1/enroll }
  request_body { max_size 16KB }
  reverse_proxy @enroll 127.0.0.1:<pair port>
  respond 404 }
<ko host> {
  tls { client_auth { mode require
        verifier leaf { folder /var/lib/ko-devices } } }
  reverse_proxy unix//var/lib/ko/socket { flush_interval -1 } }
```

**Server tests** (`deploy/smoke.sh HOST`, run by the operator against
a new droplet, and by spike 1 against a Caddy in the container):

- `openssl s_client` without a certificate: the handshake fails.
- With a certificate that is not paired: fails.
- A full pairing with `sudo ko-pair`, `openssl` and `curl`; then
  `curl --cert`: `GET /version` is 200, and a WebSocket upgrade of
  `/client` succeeds.
- SNI `enroll.` with `Host:` of the ko host: 421.
- After `sudo ko-revoke`: the same certificate fails, and a WebSocket
  that was open has ended.
- `openssl s_client -reconnect`: no session is reused.
- The socket's uids (4.1): `caddy` and `me` pass, `nobody` is
  refused. `nobody` cannot read the admin socket or the device
  folder.
- A TCP scan of every port from outside, with a deadline, written in
  the script itself (Python's standard library; no `nmap`, so the
  Mac needs no install and the test has no skip): only 22 (from the
  SSH address) and 443 accept.
- `smoke.sh HOST [ADDRESS]`: with ADDRESS, every connection goes to
  that address and keeps the names of HOST as SNI and `Host` (a VM
  or a droplet before its DNS records exist). The script has no
  option that weakens the certificate check; a test CA comes from
  the caller's environment (`SSL_CERT_FILE`, `CURL_CA_BUNDLE`).

### 4.5 The TLS transport of `ko_client`

**Rule.** A client names its server by an endpoint, not by a socket
path. An endpoint is a unix socket or a TLS host. Everything above
the byte stream (the HTTP framing, the upgrade, the WebSocket, the
reconnect, the resume by offset, the `instance` gate, the watchdog)
is the same for both.

**The abstractions that change.** Today `ko_client::wire` works on
`UnixStream` and `&Path` directly: `open`, `exchange`, `fetch`,
`request`, `download`, `Interruptible`, `write_until`, `Link`,
`Connecting` (`wire/upgrade.rs`), and above them `api.rs`, `webview.rs`,
`ffi/engine.rs` (`shared.socket`), `ffi/images.rs`, `ffi/calls.rs`
and `ffi/webview.rs`. The change replaces both types:

```rust
// ko_client/src/endpoint.rs
pub enum Endpoint { Unix(PathBuf), Tls(Arc<Tls>) }
pub struct Tls { host: HostName, port: u16, config: Arc<rustls::ClientConfig> }

// ko_client/src/wire/stream.rs
pub(crate) enum Stream { Unix(UnixStream), Tls(Box<Secured>) }
struct Secured { socket: TcpStream, session: rustls::ClientConnection }
impl Stream { fd, read, write, interest, close }   // every caller matches through these
```

- `HostName` is a newtype that parses once: a DNS name, lower case,
  no port, no path. The `Host` header is that name for a TLS
  endpoint (`ko_wire/src/http.rs:403` and `:423` send `localhost`
  today; the caller passes the value).
- TLS 1.3 only, ALPN `http/1.1`, the one signature scheme
  `ecdsa_secp256r1_sha256`, no session storage (the server gives no
  tickets).
- **Poll interest.** The stream's interest is the caller's interest
  plus a write interest while rustls has bytes to write. Plaintext
  that rustls already holds is not visible to `poll`: after each
  read, the link drains the session's plaintext before it returns to
  the loop (the same class as `wire::buffered` for the upgrade).
- **The handshake** runs inside the same step function as the HTTP
  upgrade (`Connecting`), so it does not block the I/O thread of the
  ffi.
- **Name resolution.** `getaddrinfo` blocks. The engine resolves once
  for each dial of `/client`, on a short thread that wakes the loop
  through its `Wake`, and keeps the address list for the links and
  the requests of that connection. A dial tries each address with a
  5 s limit.
- **Trust.** The system trust store, through
  `rustls-platform-verifier` (decided): Security.framework on macOS
  and iOS, the system's certificate files on Linux. The function
  that builds the `rustls::ClientConfig` takes a list of extra
  roots and gives it to `Verifier::new_with_extra_roots`; the app
  and `ko` pass an empty list.
- **Failures.** A failure before a welcome gets one of these kinds,
  which the C ABI reports as codes:

| Cause | Kind | Reconnect |
|---|---|---|
| No route, refused, timeout, no name | no server (as today) | yes, with backoff |
| HTTP 502 from Caddy (ko is not running) | no server | yes |
| The server certificate is not valid | new: `tls` | no |
| A TLS alert after the client's certificate (`bad_certificate`, `certificate_required`, `access_denied`) | new: `identity` | no |
| A lost link | as today | yes |
| A close with code 1001 on `/client` | a lost link (below) | yes |

  In TLS 1.3 the server judges the client certificate after the
  client's handshake is complete, so the alert arrives with the
  first read. The upgrade step maps it.

**Close code 1001.** docs/protocol.md, section 1, says that only
1001 means the end of the server, and that a client detaches on it.
Behind Caddy that is no longer true: a Caddy restart (each pairing
and revocation) closes every WebSocket with 1001 while ko runs
(spike 1). The places that read the code:

- `ko_client/src/wire.rs:706` maps 1001 to `Next::Shutdown`.
- `ko_tui/src/client.rs:2005` is the one reader that acts on it: the
  terminal client quits. It has no TLS endpoint in phase 1.
- `ko_client/src/ffi/engine.rs:393` (`/client`) and `:691` (a view)
  handle `Shutdown` as `Closed`: an outage, and the engine dials
  again. `webview.rs:343`, `:607`, `api.rs:334` and
  `ko_tui/src/mirror.rs:424` also make no difference. The app's
  Swift reads no close code.

So Kido.app already reconnects after a 1001: the next dial gets the
same `instance` and the views resume, or a 502, which is "no
server". No code changes; unit 4 adds the test that pins it (the TLS
test server closes `/client` with 1001 and stays up; the engine
reports an outage, then a welcome that is not fresh). The rule for
the docs: on a TLS endpoint, 1001 is a lost link, because a proxy
can send it; the reconnect learns whether the server ended. A
terminal client for TLS (Q2) must follow the same rule (Q9).

**Crates** (for approval):

- `rustls` 0.23 without default features, with `ring` and `std`;
  with it `rustls-pki-types`, `rustls-webpki`, `ring`, `untrusted`,
  `subtle`, `zeroize`.
- `rustls-platform-verifier` 0.7. On Apple targets it brings
  `security-framework`, `security-framework-sys`, `core-foundation`
  and `core-foundation-sys`. On Linux it brings `rustls-native-certs`
  (with `openssl-probe`) and uses `rustls-webpki`. `Cargo.lock` and
  `scripts/crates.txt` list the packages of every target, so both
  sets are in the list.

`ring` has C and assembly, built by the `cc` crate. Spike 2 showed
that it links into the xcframework (macOS and both arm64 iOS slices)
with no duplicate symbol beside Zig's libghostty-vt, and that the
export checks pass. Two build changes are part of unit 4: for the
musl targets, `ring`'s `cc` build adds `--target=<arch>-unknown-linux-musl`,
which overrides zig's target, so the Makefile's zig compiler wrapper
drops that argument, and the archiver for those targets is `zig ar`
(spike 3: the host's `ar` indexes the ELF objects wrongly); and the
iOS builds need `DEVELOPER_DIR` exported. The unit confirms the export check again with the
Security crates of the platform verifier. `aws-lc-rs` needs cmake; a pure-Rust provider
is not production quality. Hand-written TLS is not an option.

**Tests** (`ko_client`, in-process, no network beyond loopback):

- A test server: `rustls::ServerConnection` on `127.0.0.1` in front
  of a real `ko_server` (the macOS dev-dependency) or a scripted
  peer, with fixtures in `ko_client/testdata/tls/` (a test root, a
  server leaf, two client leafs; made once with `openssl`). The
  client key is a software key through the `ring` provider. The
  test passes the test root as the extra root of its config, so the
  system store is never changed; the system's own roots stay
  trusted beside it, on macOS and on Linux.
- The cases: a request and an upgrade through TLS; a 32 MiB message;
  a slow peer (partial records) with the watchdog; a pinned client
  certificate is accepted and another gets the `identity` kind; a
  server certificate from another root gets the `tls` kind; a wrong
  name gets `tls`; the link ends in the middle of a view and the view
  resumes at its offset with the same `instance`; cancel during the
  handshake returns within the existing cancel limit.
- The existing unix tests stay and prove that the refactor changed
  nothing for a unix endpoint.

### 4.6 What phase 1 costs on the wire

ko opens one connection for each stream and each request
(docs/protocol.md, section 1). Behind Caddy with client
authentication, each is a TCP handshake plus a full TLS 1.3
handshake with one Secure Enclave signature: about two more round
trips than a channel of an SSH master, and no resumption. A Caddy
restart for a pairing or a revocation ends every connection of
every device. The client
reconnects and resumes the views by offset.

Unit 7 measures: the time of one request and of a window open (N
views) at 50, 150 and 300 ms RTT against the SSH remote; the time of
one signature; the outage that a Caddy restart causes; the
reconnect time across a network switch. A TCP connection that lost
its path gives no error, so the client sees it only through the 60 s
watchdog. If the measurement confirms that, the app tells the core
when the network path changed (`NWPathMonitor`), and the core drops
its TLS links and dials at once. That is one more exported function
(`ko_client_reconnect`), decided with the numbers. A keep-alive pool
for control requests is the other possible result. Phase 2 removes
the cost: one QUIC connection carries every stream.

### 4.7 The identity and the C ABI

**Rule.** The private key never enters Rust. `rustls` asks for a
signature through its `SigningKey` and `Signer` traits; the
implementation calls a C function pointer that Swift provides.
Where Swift keeps the key is Swift's fact alone.

**The C shape** (`ko_client.h`):

```c
/* Signs `message` with the P-256 key of the certificate: ECDSA over SHA-256(message), as an
 * ASN.1 DER signature of at most 72 bytes into `signature`. Returns its length, or 0 on a
 * failure. The core calls it on its I/O thread and on the thread of a blocking call, also on
 * two threads at once. It must not call ko_client and must not block on the main queue. */
typedef size_t (*ko_sign_fn)(void *user, const uint8_t *message, size_t message_len,
                             uint8_t *signature, size_t capacity);

typedef struct ko_identity {
    const uint8_t *certificate;   /* DER; copied before the call returns */
    size_t certificate_len;
    ko_sign_fn sign;
    void *user;                   /* kept: valid until ko_client_close returns, or until
                                     ko_client_probe returns */
} ko_identity;

typedef struct ko_endpoint {
    int kind;                     /* KO_ENDPOINT_UNIX, KO_ENDPOINT_TLS */
    const char *socket;           /* unix */
    const char *host;             /* tls */
    uint16_t port;
    const ko_identity *identity;  /* tls */
} ko_endpoint;
```

`ko_client_connect` and `ko_client_probe` take `const ko_endpoint *`
in place of `const char *socket`. No function is added in phase 1.
`ko_code` gets `KO_ERR_TLS` and `KO_ERR_IDENTITY`. The `user` rule is
the header's existing rule for `user` pointers; there is no release
callback.

**The new unsafe code, for approval** (in `ko_client::ffi`, a new
file `ffi/identity.rs`, which joins the list of modules that may hold
unsafe code in AGENTS.md and `scripts/lint.sh`):

```rust
struct External { user: *mut c_void, sign: ko_sign_fn }   // not Clone, not Copy
// SAFETY: ko_client.h requires `sign` to accept calls from any thread, also at once,
// and `user` to stay valid until the close of the handle that owns this value.
unsafe impl Send for External {}
unsafe impl Sync for External {}

impl rustls::sign::Signer for External {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        let mut out = [0u8; 72];
        // SAFETY: both buffers are valid for their lengths for the call; `sign` writes at
        // most `capacity` bytes and keeps neither pointer.
        let count = unsafe { (self.sign)(self.user, message.as_ptr(), message.len(),
                                         out.as_mut_ptr(), out.len()) };
        // 0 or more than 72 is a failure; else the first `count` bytes
    }
    fn scheme(&self) -> SignatureScheme { ECDSA_NISTP256_SHA256 }
}
impl rustls::sign::SigningKey for Identity { /* choose_scheme: only ECDSA_NISTP256_SHA256 */ }
```

That is one `unsafe impl` pair, one unsafe call, and the reads of the
two C structs at the edge (the existing pattern of `ffi.rs`).
`rustls` requires the trait objects; they are its interface, not an
abstraction of ko. The portable `Endpoint` takes the finished
`Arc<rustls::ClientConfig>`, so no unsafe code leaves `ffi`.

**The Swift side.** The sign function calls the key and returns the
DER signature. With CryptoKit that is
`SecureEnclave.P256.Signing.PrivateKey.signature(for:)` and
`derRepresentation`; with a `SecKey` it is `SecKeyCreateSignature`
with `ecdsaSignatureMessageX962SHA256`. Both sign SHA-256 of the
message, which is what TLS 1.3 needs. The plan prefers the CryptoKit
key, because Kido.app has no entitlements and its Debug, test and
visual builds are ad-hoc signed (docs/design-app.md, "Release
signing"): a `SecKey` in the Secure Enclave needs the data protection
keychain, which needs an entitlement and a provisioning profile; a
CryptoKit enclave key needs neither, and its `dataRepresentation` (a
blob that only this enclave can use) is a file. Spike 2 confirmed
this for an ad-hoc signature and an Apple Development identity, with
no entitlement and no prompt; the `SecKey` path is not needed. `swift-certificates` builds the
certificate from either (`Certificate.PrivateKey` has an initialiser
for `SecureEnclave.P256.Signing.PrivateKey` and for `SecKey`).

**The alternative: a software key.** Swift keeps a
`P256.Signing.PrivateKey` and gives its PKCS#8 bytes to the core once
(`ko_identity` gets `key`, `key_len` in place of `sign`, `user`); the
`ring` provider of `rustls` signs. This needs no callback and no new
`unsafe impl`. The cost is the point of the design: the key is bytes
in a file or a keychain item and in the process memory, so a copy of
the disk or one memory read is a shell on the server. The callback
plan needs it only if the callback is refused.

### 4.8 Kido.app

**The model.** `Host` (`app/App/Host.swift:28`) is `local` or
`remote(String)`, the SSH destination. It gets a third case for a TLS
server, with the validated host name. Every `switch` on `Host` and
every `case .remote` gets its decision:

| Site | TLS server |
|---|---|
| `clipboardKey` | `tls:<host>` |
| `imageFetches` | measured in unit 7; 4 until then |
| `label`, the window title prefix | by the UI design (4.9) |
| `WindowOwner` connect (`:545`) | its own sequence, below; no `SSH` |
| The mismatch sheet (`:622`) | the remote sheet; the text "on HOST" |
| `KO_ERR_NO_SERVER` recovery (`startRemoteServer`) | none: systemd owns the server |
| The agent publication | none: no SSH agent is forwarded |
| `recentHosts`, `kido-app://`, `RemoteIntent`, the palette's Connect mode | by the UI design |
| Upload, clipboard consent, webview panes | as an SSH remote: they use only the client |

**The identity store** (a new file, `app/App/Identity.swift`): one
identity for each server, in `~/Library/Application
Support/Kido/servers/<host>/`: `certificate.der` and `key` (the
enclave blob of 324 bytes, mode 0600). The key is always an enclave
key: the visual-test VM has a working enclave API too (spike 2), so
no software key exists in the app. Removing the directory forgets
the server. The enclave key is made with the access
`afterFirstUnlockThisDeviceOnly` and `privateKeyUsage`, with no user
presence, so it never shows a prompt. Signing while the screen is
locked is not tested yet; the user checks it once (Q6).

**Pairing** (Swift; the UI is 4.9):

1. Decode the payload; refuse another `v`, a URL that is not
   `https`, a host that is not a DNS name.
2. Make the key and the certificate (4.3 profile) with
   `swift-certificates` and `swift-crypto`.
3. Sign the message of 4.3 and send the POST with `URLSession` (no
   client certificate; the system's trust).
4. On 200, store the identity, then probe the ko host with
   `ko_client_probe` each second for at most 30 s, until it answers
   (Caddy restarts: first no server, then the answer).
5. Open the window.

A failed pairing deletes the new key.

**Connect** (no SSH layer): load the identity; `ko_client_probe`
within 20 s; a compatible server is dialled; a mismatch opens the
remote sheet. The engine does the reconnect. `KO_ERR_IDENTITY` and
`KO_ERR_TLS` stop it and show their banner.

**Packages.** `swift-certificates` and `swift-crypto` (approved)
enter `app/project.yml`.

**Tests.** `IdentityTests` (the certificate profile: parse the DER
back and assert each field; the signed message, checked against a
fixed vector that `deploy/test.sh` also uses, so the two sides
cannot agree on a wrong formula); the payload decode with each
refusal; the pairing against a local `URLProtocol` stub for each
answer; `Host` parsing; the connect sequence against the TLS test
server of 4.5 through `KoClientKit`. Visual snapshots for each state
of 4.9, recorded once at the end; the VM makes its own enclave key.

### 4.9 The UI

Owner: `@kido-app-design`. The plan does not design UI.

The answer of `@kido-app-design`, as received. Its points 2 (paste
only on macOS, no `kido-app://enroll` link) are recommendations for
the user; the rest follows existing patterns.

1. **Entry.** One new palette mode "Pair Server", reached from the
   root list item "Pair Server…" (after "Connect to Remote Host…"),
   from File > Pair Server… (no shortcut) and from the Connect mode's
   empty-input hint line "Paste a pairing code: Pair Server…" (a
   click switches the mode). No Dock menu item and no
   `kido-app://enroll` link: a token in a URL stays in logs, history
   and clipboard managers, and the paste is one step. The Connect
   mode stays as it is for SSH.
2. **Input.** Paste only on macOS; the QR scan is for iOS. The mode
   has one field "Pairing code" (the palette field, mode marker
   "Pair") and a second field "Device name", filled with the Mac's
   name (`Host.current().localizedName`). Return pairs. The field
   accepts the payload with surrounding whitespace, and with a
   `kido-pair:` prefix if the CLI prints one.
3. **States**, as the inline error line of the palette (the row that
   the Connect mode uses):
   - invalid: "Not a pairing code" (the input stays).
   - expired or used (the server's answer): "This code is used or
     expired. Run the pairing command again."
   - in progress: the field is inert, the gray spinner of Connect,
     the line "Pairing with HOST…" (HOST from the payload).
   - waiting for activation: "Waiting for HOST to activate…" (the
     app tries the connect for at most 30 s).
   - success: the palette closes and a new window opens on the
     server, as Connect does; the server goes to the recent list.
   - network failure: "Could not reach HOST: <OS message>" with a
     "Retry" button in the line. Retry sends the POST again only if
     the server did not get the token (the prompt-delivery rule:
     never send again after an uncertain send). After an uncertain
     send the line is "HOST may have paired this Mac; try Connect".
   - Escape at any state returns to the root; a POST in flight is
     not cancelled.
4. **Afterwards.** Enrolled servers are in the Connect mode's recent
   list with the SSH hosts, sorted by last use, each with a trailing
   muted kind word: "ssh" or "https" (no icon; the list is text).
   The window title is "HOST / Session": the host name of the
   payload, with no user part. The sidebar and the tabs do not
   change.
5. **Failures**, with the existing components:
   - The certificate is refused (not yet active, or revoked): the
     mismatch-style sheet, "HOST does not accept this Mac's
     certificate", with "Pair Again" (opens the Pair mode with HOST
     filled in; the old key stays until the new pairing succeeds)
     and "Close".
   - A TLS failure (the server's certificate is not valid): the
     sheet, "HOST's certificate is not valid: <reason>", with
     "Close" only. A Reconnect would fail in the same way; the fix
     is on the server.
   - Not reachable, or an outage: `RemoteFailure.banner` as for SSH,
     with Reconnect; the reconnect loop as today.
6. **Forget.** In the Connect mode, the context menu of the recent
   row: "Forget HOST…" (an SSH row has "Remove from Recents"). It
   opens the stock `NSAlert` "Forget HOST? This Mac's key and
   certificate for HOST are deleted. Pair again to connect.", with
   "Forget" (default) and "Cancel". Open windows on HOST stay until
   they are closed; their next reconnect shows the refused sheet.
7. **Snapshot states**, each in light and dark: the Pair mode empty;
   with a payload and a device name; invalid; expired; in progress;
   waiting; a network failure with Retry; an uncertain send; the
   Connect recent list with ssh and https rows; the refused sheet;
   the TLS sheet; the Forget alert; a window title "HOST / Session".

What this fixes in the rest of the plan:

- `KO_ERR_IDENTITY` maps to the refused sheet and `KO_ERR_TLS` to
  the TLS sheet; the core's text is the `<reason>`.
- "Pair Again" keeps the old identity until the new one is stored,
  so the identity store writes a new identity beside the old one and
  renames it into place (4.8).
- The pairing must know whether the server got the token. A failure
  before the request body is written is certain (Retry is allowed);
  a failure after it is an uncertain send. `ko-pair` ends the
  pairing on the first request with the right token, so a second
  POST would get 403 in any case.
- `ko-pair` prints the payload line with the `kido-pair:`
  prefix; the app accepts it with or without the prefix.

## 5. Phase 2: HTTP/3 and roaming

**Decision (the user's).** Phase 2 is HTTP/3 through Caddy. ko gets
no relay and no second TLS terminator. Spike 3 (section 6) showed
that this path works end to end.

**The rule.** One QUIC connection of a client carries each ko
connection (a request or a WebSocket) as one HTTP/3 request stream
with its own flow control. That keeps the rule "a flood on one never
delays another" and makes one handshake and one signature for a
window. A WebSocket is an RFC 9220 extended CONNECT, which Caddy
turns into an HTTP/1.1 upgrade toward ko's socket. ko does not
change.

**The client.** `quinn-proto` 0.11.19 is the QUIC state machine: it
has no runtime, and it uses rustls 0.23.46, the version of phase 1,
so the client configuration and the sign callback of 4.7 apply
unchanged (`QuicClientConfig::try_from`). ko writes the driver on
`ko_sys::event` and a client subset of HTTP/3: the control stream,
SETTINGS, HEADERS and DATA frames, QPACK with the static table and
literals (dynamic table size 0), Huffman decode, and the CONNECT of
RFC 9220. The spike's working sketch has 132 lines for the driver,
115 for the HTTP/3 frames and control stream, 504 for QPACK (370 of
them tables), 37 for RFC 9220 and 85 for the TLS adapter. The
estimate for production code stays 1500 to 2500 lines: strict
parsers, stream and frame state errors, limits, cancellation and
write back-pressure are not in the sketch.

The candidates that were not chosen: `quiche` 0.30.1 has its own
HTTP/3 with extended CONNECT, and an external key is possible
(`boring`'s `set_private_key_method`), but it needs cmake and
BoringSSL, a second TLS stack. `s2n-quic` 1.92 has no supported way
to drive it from a loop without futures.

**The facts that the units build on** (spike 3):

- Caddy needs `protocols h1 h2 h3` and UDP 443. `grace_period 3s`
  stays: the default grace has no limit, and an open HTTP/3 request
  then holds Caddy's shutdown.
- The CONNECT carries `Ko-Protocol` and `Ko-Vt`, as on TCP; without
  them ko answers 426.
- Client authentication is the same as on TCP: the same refusals,
  and revocation by restart. There are no tickets, so no resumption
  and no 0-RTT.
- A Caddy restart ends an HTTP/3 connection with `H3_NO_ERROR` and
  no WebSocket close frame (TCP gets 1001). The client treats the
  end of the QUIC connection as a lost link (4.5, "Close code 1001").
  ko's own stop still arrives as 1001.
- Caddy's QUIC idle timeout is 30 s and its server sends no
  keep-alive. ko's WebSocket ping every 30 s races that timeout, so
  the client sends a QUIC keep-alive well under 30 s; the droplet
  session chooses the value. A path that is silent for more than
  30 s (a sleep) ends the connection, and the reconnect of phase 1
  stays the answer.
- Only the client migrates. After a new local socket, the driver
  calls `Connection::local_address_changed()`; quic-go validates the
  new path. Both sides announce `active_connection_id_limit` 4, and
  Caddy has no option for migration. A NAT rebinding needs nothing
  from the client.

## 6. Spikes, before any unit

A spike is throwaway code outside the repository (`/tmp`). Its result
is a short section appended to this plan. A spike that needs a
download or a droplet asks the user first.

**Spike 1: Caddy leaf pinning** (a container, no droplet;
low risk, about 2 hours).

1. The exact Caddyfile syntax for `mode require` with the leaf
   verifier and a folder; the minimum version with
   `VerifyConnection`.
2. What `mode require` checks: no certificate, a certificate that is
   not pinned, a pinned certificate with a wrong key (the handshake
   signature), an expired pinned certificate, a pinned certificate
   without the EKU.
3. Restart: the time until Caddy serves again; what a broken `.pem`
   in the folder does to the start.
4. Resumption: `openssl s_client -reconnect` and `-sess_out/-sess_in`
   after a removal and a restart; TLS 1.2 and 1.3.
5. A restart against open WebSockets and keep-alive connections:
   all end, and how fast the client sees it.
6. `strict_sni_host`: SNI `enroll.` with the other `Host`.
7. ACME on a host with client authentication: does TLS-ALPN-01
   succeed (port 80 closed)? Tested against the Let's Encrypt staging
   endpoint on a droplet, or left for unit 3 if no droplet exists.
8. ko through Caddy: `ko`'s own streams (a view, an image download, a
   32 MiB message, a webview proxy route) through `reverse_proxy` to
   a unix socket; the response framing; the 502 when ko is down; the
   close code when ko stops.
9. The admin endpoint on a unix socket with a mode, and `systemctl
   restart` with it.

**Spike 2: a Secure Enclave key signs for rustls** (macOS; medium
risk, about 3 hours).

1. A Swift harness makes a CryptoKit enclave key and a certificate
   with `swift-certificates`, and a Rust static library with `rustls`
   and the callback of 4.7 completes a TLS 1.3 handshake with client
   authentication against `openssl s_server -Verify`.
2. Under each signing: ad-hoc, Personal Team, and inside the
   visual-test VM.
3. The blob in a file: a second process uses it; a copy on another
   Mac does not.
4. Signing while the screen is locked, with the chosen access; no
   prompt at any time.
5. The time of one signature, and of 8 at once on two threads.
6. `ring` in the xcframework: does the app's link accept it beside
   Zig's `compiler_rt` (the duplicate-symbol rule of docs/build.md,
   "The ko_client xcframework")? Does it build for the two iOS
   slices and for `x86_64-unknown-linux-musl` with zig?
7. If the CryptoKit key fails a point: the same with a `SecKey`, and
   the entitlement that it needs.

**Spike 1: results** (done; evidence in `/tmp/spike-caddy/`).

1. Caddy 2.11.9 from Caddy's Debian repository. The minimum is
   2.11.4 (section 2). The Caddyfile of 4.4 is the validated one.
2. No certificate, a certificate that is not pinned and a pinned
   certificate with a wrong key are refused. A pinned certificate
   that is expired, or has no `clientAuth` EKU, is accepted.
3. A restart serves again 20 ms after SIGTERM. A removed `.pem`
   stays accepted until the restart. A broken `.pem` makes `caddy
   validate` and `caddy run` exit 1.
4. No session is reused in TLS 1.2 or 1.3 with client
   authentication. After a removal and a restart, the certificate
   gets `bad certificate`. Revocation by restart is complete.
5. A restart ends every WebSocket and keep-alive connection within
   1.5 ms. The WebSockets get close code 1001 from Caddy (4.5).
6. SNI `enroll.` with the `Host` of the ko host gets 421, with no
   `strict_sni_host` in the configuration.
7. ACME TLS-ALPN-01 with client authentication and port 80 closed:
   not tested; it needs the droplet (unit 3, Q4).
8. ko through Caddy passes: `ko api`, a view upgrade with a binary
   snapshot, an RGBA image, a webview response, a WebSocket message
   of 32 MiB byte for byte. `Content-Length` is kept; the webview
   response is chunked. ko down gives 502; ko's stop reaches the
   client as 1001.
9. The admin endpoint on a unix socket of mode 0600 works. The
   systemd units and the sandbox are not tested (the container has
   no systemd); unit 3 tests them on the droplet.

**Spike 2: results** (done; the code is not in the repository).

1. Pass. A CryptoKit enclave P-256 key, a self-signed certificate
   from swift-certificates 1.21.1 with the profile of 4.3, and
   rustls 0.23.46 with the exact callback of 4.7 completed a TLS 1.3
   handshake with client authentication against OpenSSL 3.5.9
   `s_server -Verify 1 -verify_return_error -tls1_3`. The callback
   got 146 bytes and returned a DER signature of 71 bytes.
2. Signing kinds: ad-hoc works, with no entitlement and no prompt;
   an Apple Development identity works. The macOS 27.2.1 guest of
   the visual-test VM creates, uses and reloads enclave keys; the
   API works there, and its hardware isolation is not proven. A blob
   from the host fails in the VM (CryptoTokenKit -10), as expected.
3. The blob file (324 bytes) works from a second process. A copy on
   another Mac was not testable.
4. Access `afterFirstUnlockThisDeviceOnly` with `privateKeyUsage`
   and no user presence. Signing with the screen locked is not
   tested.
5. One signature takes about 5.1 ms on the host (about 1 ms in the
   VM); 8 signatures on 2 threads take about 37 ms. So a window with
   8 views pays about 40 ms of signatures on each connect.
6. `ring`: see 4.5 (the xcframework passes; musl needs the wrapper;
   iOS needs `DEVELOPER_DIR`).
7. The `SecKey` path was not needed.

**Spike 3: WebSockets over HTTP/3 through Caddy, migration, the
client** (done but for point 7; the results are below).

1. Does Caddy announce `SETTINGS_ENABLE_CONNECT_PROTOCOL` on HTTP/3,
   and does an RFC 9220 CONNECT with `:protocol: websocket` reach a
   unix-socket upstream as an HTTP/1.1 upgrade, with frames in both
   directions and the close code? Which Caddy version and options?
2. Client authentication on the QUIC listener: the same leaf
   verifier, the same revocation by restart.
3. Migration: a client that moves to another local address in the
   middle of a view (two interfaces, or two loopback addresses and a
   UDP relay). Does the stream continue, after how long, and what
   does quic-go need (the connection id count, the path validation)?
   A NAT rebinding (the port changes) as a separate case.
4. The idle timeout and keep-alive that Caddy uses, and what a sleep
   of 10 s, 60 s and 10 min does.
5. `quinn-proto` without tokio: the size of the driver on a plain
   UDP socket; its migration call for a new local socket; its
   `rustls` version against the one of phase 1.
6. The size of the hand-written HTTP/3 subset against a working
   exchange with Caddy; `quiche` as the comparison, with its build
   (cmake, iOS, musl) and the external-key question.
7. UDP 443 through the networks that the user uses, and the fall
   back to phase 1's TCP when it is blocked.
8. `s2n-quic`: is there a supported way to drive its core from a
   plain loop without futures, does its rustls provider take a
   client config with an external signing key, and does its client
   migrate? One hour at most; stop at the first "no".
9. A ko tunnel in place of HTTP/3 (a client and a relay on
   `quinn-proto`). Dropped by the user's decision.

**Where the spikes run** (section 9, Q6). Spike 1 and the HTTP/3
parts of spike 3 ran in a Debian 13 container through
Apple's `container`, so nothing is installed on the Mac (podman does
not exist on macOS). Spike 2 ran on the macOS host and in the
visual-test VM. Real roaming (spike 3, points 3, 4 and 7) and
ACME (spike 1, point 7) need a test droplet that lives for a short
time, with the Mac changing networks; the user runs that step.

**Spike 3: results** (done but for point 7; evidence in
`/tmp/spike3-caddy/REPORT.md` and
`/tmp/spike3-rust-evidence/RESULTS.md`; all numbers are from
loopback).

1. Pass. Caddy 2.11.9 (quic-go 0.63.0) with `protocols h1 h2 h3`
   announces `SETTINGS_ENABLE_CONNECT_PROTOCOL`. An RFC 9220 CONNECT
   reaches ko's unix socket as `GET /client` with an HTTP/1.1
   upgrade; the client gets 200. Messages pass in both directions,
   also a client message of 524 381 bytes and a server message of
   4 000 626 bytes. ko's stop arrives as close 1001. A Caddy restart
   ends the connection with `H3_NO_ERROR` and no close frame; with
   `grace_period 3s` it took 3.04 s.
2. Pass. No certificate gets `certificate required`, an unpinned
   certificate `bad certificate`, a pinned one 200. After a removal
   and a restart the certificate is refused. No connection was
   resumed and none used 0-RTT (`connpolicy.go:423` disables the
   tickets). SETTINGS can arrive before the TLS refusal, so they do
   not mean that the certificate was accepted.
3. Pass. The same `/client` WebSocket continues after the client
   moves from 127.0.0.1 to 127.0.0.2 (the path probe took 0.2 ms),
   and after a relay changes the source port without the client's
   knowledge. The server cannot start a migration.
4. Caddy's idle timeout is 30 s, and its server keep-alive is off.
   Without a client keep-alive a bare HTTP/3 connection closes after
   30.1 s; with one of 5 s it lives. A path that is dead for 10 s
   recovers; one that is dead for 60 s is closed after 30 s, with or
   without keep-alive. ko's WebSocket ping (30 s) and pong limit are
   a second clock: a QUIC ping does not answer them. The 10 min case
   was not run, because 30 s already decides it.
5. Pass. `quinn-proto` 0.11.19 builds on the repository's toolchain
   with no runtime and resolves rustls 0.23.46. The driver sketch on
   a plain UDP socket is 132 lines, without write back-pressure. A
   migration is a new socket and `Connection::local_address_changed()`.
   A custom `SigningKey` worked in the handshake with Caddy, with
   one signature (a software key; the enclave callback is spike 2).
6. Pass. The Rust sketch got 200 for the CONNECT from Caddy, decoded
   Huffman header values, and kept its stream across a new local
   address and port (the pong came 335 µs after the change). The
   first run got 426, because `Ko-Protocol` and `Ko-Vt` were absent.
   The line counts are in section 5. `quiche` did not build on the
   host (no cmake); its external-key call exists in the source and
   was not run.
7. Not run. It is the droplet session, below.
8. `s2n-quic` 1.92: stopped at the first "no". Its client needs a
   future and a task context; its core crates are documented as
   internal.
9. Dropped: the user chose HTTP/3 through Caddy.

One build fact for 4.5: the cross-build of `ring` for musl needs
`zig ar` as the archiver, because the host's `ar` indexes the ELF
objects wrongly.

**The droplet session** (run by the user, with a short-lived
droplet; it closes spike 3's point 7 and spike 1's point 7):

- UDP 443 from the user's networks (home Wi-Fi, a phone hotspot, an
  office or a café), and the time of the fall back to TCP where UDP
  is blocked.
- A real switch between Wi-Fi and cellular in the middle of a view,
  with the Rust client and the quic-go client: the time to resume,
  and that the stream is intact.
- A NAT rebinding on a real NAT, and the expiry of a NAT binding
  with a keep-alive of 10, 15 and 25 s.
- A sleep of the Mac for 10 s, 60 s and 10 min, and the wake.
- MTU and loss: path MTU discovery on cellular.
- ACME TLS-ALPN-01 with client authentication and port 80 closed.

## 7. The units, in order

Each unit is one manager's unit under AGENTS.md. Every unit adds and
breaks nothing, so each lands on `main` alone. Times are agent time
with reviews, not calendar time.

| # | Unit | Delivers | Needs | Risk | Time |
|---|---|---|---|---|---|
| S1 | Spike 1 | Done: results in section 6 | | | |
| S2 | Spike 2 | Done: results in section 6 | | | |
| 1 | Second uid | `--allow-uid`, the directory rule, the socket mode, docs, tests (4.1) | | low | 2 h |
| 2 | Static Linux server | `ko-pane` in `build-linux`, musl e2e run (4.2) | | medium | 3 h |
| 3 | `deploy/` | Terraform, provisioning, units, Caddyfile, `ko-pair`, `ko-revoke`, `ko-devices`, `test.sh`, `smoke.sh`, README (4.3, 4.4) | S1, 1, 2 | medium | 8 h, and one droplet session with the user |
| 4 | TLS transport | `Endpoint`, `Stream`, rustls, the resolver, the failure kinds, the 1001 test and its docs rule, tests (4.5) | crates | high | 12 h |
| 5 | Identity ABI | `ko_endpoint`, `ko_identity`, the signer, KoClientKit (4.7) | 4, S2, unsafe approval | medium | 4 h |
| 6 | Kido.app | The `Host` case, the identity store, pairing, connect, sheets, snapshots (4.8, 4.9) | 5, the request shape of 4.3 | high | 12 h |
| 7 | Measurement | The numbers of 4.6 in the docs; the decision on `ko_client_reconnect` and the request pool | 3, 6 | low | 3 h, and the user switches networks |
| S3 | Spike 3 | Done but for the droplet session: results in section 6 | | | a droplet session with the user |

Units 1, 2 and 4 are independent and can run at the same time. Unit
4 is the one that can break what works: it changes the wire layer
under every client. Its refactor to `Endpoint` and `Stream` lands
first with no TLS code and the existing tests unchanged; the TLS
case is its second commit.

**Tests that must fail first.** Unit 1: the e2e start on a 0710
directory (refused today). Unit 4: the upgrade through the TLS test
server. The other units add behaviour with tests that only pass.

**Docs** (each unit's manager writes them): docs/protocol.md,
section 1 ("There is no TLS", the allowed uid, the `Host` header);
docs/design-ko.md, 4.13 (`--allow-uid`, the directory rule) and 5
(the second remote transport); docs/design-app.md, "Remote hosts"
and "One ko client"; docs/build.md (the static server, `ring`);
docs/verification.md (the TLS test server, `deploy/test.sh`);
AGENTS.md (the unsafe list). When unit 7 is complete, this plan
becomes `docs/design-remote-tls.md` and is deleted.

### Phase 2 units (a draft)

Phase 2 starts after unit 7. Each unit adds a case and breaks
nothing: TCP stays the transport until unit P5.

| # | Unit | Scope | Test | Risk | Time |
|---|---|---|---|---|---|
| P1 | Caddy HTTP/3 in `deploy/` | `protocols h1 h2 h3`; UDP 443 in the cloud firewall and nftables; `grace_period` stays | `smoke.sh`: `curl --http3` with the paired certificate gets 200, without one it fails, after `ko-revoke` it fails; the scan allows UDP 443 | low | 2 h |
| P2 | The QUIC driver | `quinn-proto` on `ko_sys::event` in `ko_client`: the UDP socket, the timers, write back-pressure, the keep-alive, the same `ClientConfig` and signer as TCP | In process, against a `quinn-proto` server in the test: a handshake with a client certificate and one signature; a refused certificate gives the `identity` kind; a stream that the peer does not read does not stall another | high | 10 h |
| P3 | The HTTP/3 subset | Frames, the control stream, SETTINGS, QPACK with Huffman decode, the RFC 9220 CONNECT; readers of untrusted bytes, with the lints of AGENTS.md | Unit tests on the vectors of RFC 9204 and on bytes captured from Caddy; a fuzz target for the parsers with its corpus replay test | high | 10 h |
| P4 | The third stream case | `Stream` gets a QUIC case: one connection for each client carries every request and WebSocket; `Ko-Protocol` and `Ko-Vt` on the CONNECT; ko's WebSocket framing on the stream; the end of the connection is a lost link | The TLS cases of 4.5 again over HTTP/3, against a real Caddy in the Debian container (a gate as `KO_E2E_CONTAINER`): a view resumes at its offset after a Caddy restart | high | 12 h |
| P5 | Transport choice | QUIC first, TCP when no QUIC handshake completes within a limit; the result is kept for the endpoint while the process runs | UDP dropped in the test: the client is on TCP within the limit; UDP open: no TCP connection is made | medium | 6 h |
| P6 | Migration | The app's `NWPathMonitor` tells the core of a path change (one new exported function); the driver opens a new socket and calls `local_address_changed()`; a connection that is already dead goes to the reconnect | In process, two loopback addresses: a view continues with no new upgrade and no gap in its offsets | medium | 6 h |
| P7 | The app and the numbers | What a window shows for its transport, by `@kido-app-design`; the droplet session's numbers in the docs; the keep-alive value | Snapshots for each state that the design names | low | 4 h, and the droplet session |

P6's function replaces the `ko_client_reconnect` idea of 4.6 if
unit 7 did not already add it. A terminal client is not in this
list (Q2).

## 8. Approvals that the units need

- **Crates** (unit 4): `rustls`, `ring`, `rustls-webpki`,
  `rustls-pki-types`, `untrusted`, `subtle`, `zeroize`;
  `rustls-platform-verifier` with `security-framework`,
  `security-framework-sys`, `core-foundation`, `core-foundation-sys`
  (Apple) and `rustls-native-certs`, `openssl-probe` (Linux). The
  unit reports the exact list from `Cargo.lock`.
- **Unsafe:** the block of 4.7 (unit 5).
- **Routes:** none. ko gets no route.
- **Swift packages:** `swift-certificates`, `swift-crypto` (approved).
- **Phase 2:** the crate `quinn-proto` with its dependencies (unit
  P2; `bytes`, `rand`, `slab`, `rustc-hash`, `tinyvec` and the
  rustls crates of phase 1; the unit reports the exact list); one
  exported function for the path change (unit P6).
- **Spikes:** a droplet for unit 3 and the droplet session.

## 9. Open questions

Each has a recommendation; the plan above assumes it.

1. **Server certificate pinning.** The client trusts WebPKI for the
   ko host. A pin of the server's key in the payload (Caddy can keep
   its key across renewals) would remove the public CAs from the
   trust. *Recommend not in phase 1;* the payload's `v` allows it
   later.
2. **A terminal client for a TLS server** (`ko` on another machine,
   with a software key in a file). It would also give the e2e suite
   a real client for the whole path through Caddy. *Recommend
   later,* as its own unit after phase 1.
3. **One identity for each server, or one for the Mac.** *Recommend
   one for each server:* forgetting a server deletes its key, and two
   servers cannot link the device. The SAN's install id is then the
   one value that the Mac's certificates share; if that is not
   wanted, it becomes random for each identity.
4. **Port 80.** *Recommend closed,* if the droplet shows that
   TLS-ALPN-01 works with client authentication (spike 1 could not
   test it); else open for HTTP-01 only, without
   `disable_redirects`.
5. **`build-linux` grows by `ko-pane`**, also in the app bundle.
   *Recommend yes* (one target, one layout); a separate
   `build-linux-server` target if the bundle size matters.
6. **Where the spikes run.** *Recommend the proposal of section 6:*
   a Debian 13 container through Apple's `container` for Caddy, the
   pairing scripts and the HTTP/3 parts, and one short-lived test
   droplet for ACME and real roaming, which the user starts and
   destroys. Spike 2 is done. Two checks stay with the user, on real
   Macs: a signature while the screen is locked, and that a copied
   blob fails on another Mac.
7. **Paste only on macOS, and no `kido-app://enroll` link** (from
    `@kido-app-design`). *Recommend yes to both.*
8. **The directory rule changes for every ko** (4.1): a state
    directory of mode 0710 passes, on macOS too. *Recommend yes:*
    one rule with no link to the flag. The alternative keeps 0700
    for all and accepts 0710 only in a server with `--allow-uid`;
    then each `ko` command in a pane needs a second way to know it.
9. **Close code 1001 behind a proxy** (4.5). *Recommend:* on a TLS
    endpoint, 1001 is a lost link, and the reconnect finds out
    whether the server ended (a 502, or a welcome with another
    `instance`). Kido.app's engine already does this, so phase 1
    needs only a test and the docs. The alternative, a final
    "server stops" event on `/client` before the close, is a wire
    change for every client and is not needed until a terminal
    client has a TLS endpoint.
