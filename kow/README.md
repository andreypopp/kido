# ko workspaces

This directory provides a single Python script `kow` (stands for ko workspaces)
which helps bootstrap remote ko installations which:

- use Caddy to expose ko via HTTP/3 (QUIC) + mTLS for configuration
- provide scripts for pairing Kido.app and iOS clients
- are built on Debian 13 with unattended upgrades on and only expose ports 22 (for SSH) and 443 (for HTTPS)

Run `./kow` to get started.
