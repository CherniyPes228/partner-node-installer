# Zero-Touch Installer (Partner Node)

This folder contains a Linux installer designed for one-line partner onboarding.

## One-Liner

```bash
curl -fsSL https://install.example.com/partner-node/install.sh | sudo bash -s -- \
  --partner-key <KEY> \
  --country US \
  --main-server https://main.example.com \
  --install-mode binary \
  --binary-url https://downloads.example.com/partner-node/v0.1.0/node-agent-linux-amd64
```

## What It Does

1. Validates root privileges.
2. Detects package manager (`apt`, `dnf`, `yum`).
3. Installs runtime dependencies (`wireguard-tools`, `modemmanager`, `3proxy`, etc.).
4. Installs `node-agent`:
   - `binary` mode: downloads prebuilt binary.
   - `source` mode: clones repo and builds with Go.
5. Writes config to `/etc/partner-node/config.yaml`.
6. Installs systemd unit `/etc/systemd/system/partner-node.service`.
7. Enables and starts `partner-node`.

## Important Flags

- `--partner-key` (required)
- `--country` (default `US`)
- `--main-server` (default `https://main.example.com`)
- `--install-mode` (`binary` or `source`)
- `--binary-url` (recommended in `binary` mode)
- `--repo-url` and `--repo-ref` (for `source` mode)
- `--skip-start` (install only)

## Post-Install Checks

```bash
systemctl status partner-node
journalctl -u partner-node -f
```

## Notes

- The script is intended for Linux partner nodes.
- Provide real download URLs before production use.
- Keep installer and binaries behind HTTPS with integrity verification in production.

