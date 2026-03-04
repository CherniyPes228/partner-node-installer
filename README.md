# Zero-Touch Installer (Partner Node)

This folder contains a Linux installer designed for one-line partner onboarding.

## One-Liner

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/partner-node-installer/main/scripts/install.sh | sudo bash -s -- \
  --partner-key <KEY> \
  --main-server http://<main-server-ip>:18080
```

Default binary URL already points to:
`http://chatmod-test.warforgalaxy.com/downloads/partner-node/node-agent-linux-amd64-v0.1.10`

If you host another build, override with `--binary-url`.

## What It Does

1. Validates root privileges.
2. Detects package manager (`apt`, `dnf`, `yum`).
3. Installs runtime dependencies (`wireguard-tools`, `modemmanager`, `3proxy`, etc.).
   On apt-based systems installer first tries official 3proxy GitHub `.deb`, then distro repo, then source build as fallback.
   You can override package source via `--threeproxy-package-url` (use `.rpm` for dnf/yum, `.deb` for apt).
4. Installs `node-agent` by downloading prebuilt binary.
5. Writes config to `/etc/partner-node/config.yaml`.
6. Ensures `/etc/3proxy/3proxy.conf` exists (creates default config if missing).
7. Installs systemd unit `/etc/systemd/system/partner-node.service`.
8. Enables and starts `partner-node`.

## Important Flags

- `--partner-key` (required in non-interactive mode)
- `--country` (optional; auto-detected from public IP, fallback `US`)
- `--main-server` (required in non-interactive mode)
- `--binary-url` (optional; default is test host URL above)
- `--threeproxy-package-url` (optional custom URL to 3proxy package)
  Default: `https://chatmod-test.warforgalaxy.com/downloads/partner-node/3proxy.deb`
- `--skip-firewall` (optional; disable installer firewall hardening)
- `--modem-rotation-method` (`auto`, `mmcli`, `api`, `api_reboot`; default `auto`)
- `--hilink-enabled` (default `true`)
- `--hilink-base-url` (optional; auto-detected if empty)
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
