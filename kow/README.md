# ko workspaces

This did provides a single python script `kow` (stands for ko workspaces) which
helps bootstraping remote ko installations which:

- use Caddy to expose ko via HTTP3/QUIC + mTLS for configuration
- provide scripts for pairing Kido.app and iOS clients
- are built on Debain 13 with unattended upgrades on and only expose 22 (for ssh) and 442 (for HTTPS) ports

Run `./kow` to get started.
