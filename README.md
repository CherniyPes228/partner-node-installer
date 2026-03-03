# Zero-Touch Installer (Partner Node)

This folder contains a Linux installer designed for one-line partner onboarding.

## One-Liner

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/partner-node-installer/main/scripts/install.sh | sudo bash -s -- \
  --partner-key <KEY> \
  --country US \
  --main-server http://<main-server-ip>:18080
```

Default binary URL already points to:
`http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.0`

If you host another build, override with `--binary-url`.

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

- `--partner-key` (required in non-interactive mode)
- `--country` (default `US`)
- `--main-server` (required in non-interactive mode)
- `--binary-url` (optional; default is test host URL above)
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
