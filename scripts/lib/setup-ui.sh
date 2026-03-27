#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Setup local partner UI on 127.0.0.1:<UI_PORT>
###############################################################################

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

UI_DIR="${UI_DIR:-/opt/partner-node-ui}"
UI_SERVICE_NAME="${UI_SERVICE_NAME:-partner-node-ui}"
UI_PORT="${UI_PORT:-19090}"
MAIN_SERVER="${MAIN_SERVER:-}"
PARTNER_KEY="${PARTNER_KEY:-}"
UI_ASSET_BASE="${UI_ASSET_BASE:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/ui-dist}"

if [[ -z "${MAIN_SERVER}" || -z "${PARTNER_KEY}" ]]; then
  log_err "MAIN_SERVER and PARTNER_KEY must be set"
  exit 1
fi

mkdir -p "${UI_DIR}/assets"

log_info "Downloading partner UI assets..."
curl -fsSL "${UI_ASSET_BASE}/index.html" -o "${UI_DIR}/index.html"
curl -fsSL "${UI_ASSET_BASE}/assets/partner-node-ui.js" -o "${UI_DIR}/assets/partner-node-ui.js"
curl -fsSL "${UI_ASSET_BASE}/assets/partner-node-ui.css" -o "${UI_DIR}/assets/partner-node-ui.css"

cat > "${UI_DIR}/server.py" <<'PY'
#!/usr/bin/env python3
import json
import mimetypes
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

MAIN_SERVER = os.environ.get("MAIN_SERVER", "").rstrip("/")
PARTNER_KEY = os.environ.get("PARTNER_KEY", "")
LISTEN_ADDR = os.environ.get("UI_LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("UI_PORT", "19090"))
ROOT_DIR = os.path.dirname(__file__)

ALLOWED = {
    "self_check",
    "rotate_ip",
    "restart_proxy",
    "reconcile_config",
    "transport_self_check",
    "self_update",
}


def json_request(url, method="GET", payload=None):
    body = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, method=method, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code, text):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, file_path):
        if not os.path.isfile(file_path):
            self._send_text(404, "not found")
            return
        ctype, _ = mimetypes.guess_type(file_path)
        if not ctype:
            ctype = "application/octet-stream"
        with open(file_path, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send_text(200, "ok")
            return

        if self.path == "/api/overview":
            try:
                qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
                data = json_request(f"{MAIN_SERVER}/api/partner/overview?{qs}")
                if isinstance(data, dict):
                    data.setdefault("partner_key", PARTNER_KEY)
                    data.setdefault("main_server", MAIN_SERVER)
                self._send_json(200, data)
            except urllib.error.HTTPError as err:
                self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
            except Exception as err:
                self._send_text(502, str(err))
            return

        if self.path.startswith("/assets/"):
            target = os.path.join(ROOT_DIR, self.path.lstrip("/"))
            self._serve_file(target)
            return

        if self.path in ("/", "/index.html"):
            self._serve_file(os.path.join(ROOT_DIR, "index.html"))
            return

        self._serve_file(os.path.join(ROOT_DIR, "index.html"))

    def do_POST(self):
        if self.path != "/api/command":
            self._send_text(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            req = json.loads(raw.decode("utf-8"))
            cmd_type = str(req.get("type", "")).strip()
            if cmd_type not in ALLOWED:
                self._send_text(403, "command not allowed")
                return
            payload = {
                "partner_key": PARTNER_KEY,
                "node_id": str(req.get("node_id", "")).strip(),
                "type": cmd_type,
                "timeout_sec": int(req.get("timeout_sec", 120)),
                "params": req.get("params", {}),
            }
            data = json_request(f"{MAIN_SERVER}/api/partner/command", method="POST", payload=payload)
            self._send_json(200, data)
        except urllib.error.HTTPError as err:
            self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
        except Exception as err:
            self._send_text(400, str(err))

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = HTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
    server.serve_forever()
PY

cat > "${UI_DIR}/ui.env" <<EOF
MAIN_SERVER="${MAIN_SERVER}"
PARTNER_KEY="${PARTNER_KEY}"
UI_LISTEN_ADDR="127.0.0.1"
UI_PORT="${UI_PORT}"
EOF

cat > "/etc/systemd/system/${UI_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Partner Node Local UI
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${UI_DIR}/ui.env
ExecStart=/usr/bin/python3 ${UI_DIR}/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

chmod 0755 "${UI_DIR}/server.py"
chmod 0644 "${UI_DIR}/index.html"
chmod 0644 "${UI_DIR}/assets/partner-node-ui.js"
chmod 0644 "${UI_DIR}/assets/partner-node-ui.css"
chmod 0600 "${UI_DIR}/ui.env"
chmod 0644 "/etc/systemd/system/${UI_SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable "${UI_SERVICE_NAME}"
systemctl restart "${UI_SERVICE_NAME}" || true

if systemctl is-active --quiet "${UI_SERVICE_NAME}"; then
  log_info "Partner UI is active: http://127.0.0.1:${UI_PORT}"
else
  log_warn "Partner UI is not active yet. Check: journalctl -u ${UI_SERVICE_NAME} -n 80 --no-pager"
fi
