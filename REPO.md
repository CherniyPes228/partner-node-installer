# Partner Node Installer Repo

This repository is intentionally separate from the main `partner-node` codebase.
It contains only the public zero-touch onboarding installer for partner Linux nodes.

## Structure
- `scripts/install.sh` - one-line installer entrypoint
- `README.md` - usage and parameters

## One-liner (example)
```bash
curl -fsSL https://raw.githubusercontent.com/<org>/partner-node-installer/main/scripts/install.sh | sudo bash -s -- \
  --partner-key <KEY> \
  --country US \
  --main-server https://main.example.com
```
