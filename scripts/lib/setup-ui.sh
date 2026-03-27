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
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

MAIN_SERVER = os.environ.get("MAIN_SERVER", "").rstrip("/")
PARTNER_KEY = os.environ.get("PARTNER_KEY", "")
LISTEN_ADDR = os.environ.get("UI_LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("UI_PORT", "19090"))
ROOT_DIR = os.path.dirname(__file__)
SPEEDTEST_URL = os.environ.get("PARTNER_SPEEDTEST_URL", "http://speedtest.tele2.net/1MB.zip")
SPEEDTEST_BYTES = int(os.environ.get("PARTNER_SPEEDTEST_BYTES", "2000000"))

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


def normalize_target_url(raw_url, bytes_count):
    raw_url = str(raw_url or "").strip() or SPEEDTEST_URL
    parsed = urllib.parse.urlparse(raw_url)
    if parsed.scheme not in ("http", "https"):
        raise RuntimeError("target_url must use http or https")
    if not parsed.netloc:
        raise RuntimeError("target_url host is required")
    if parsed.netloc == "speed.cloudflare.com" and parsed.path == "/__down" and "bytes=" not in parsed.query:
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        query["bytes"] = [str(int(bytes_count))]
        parsed = parsed._replace(query=urllib.parse.urlencode(query, doseq=True))
    return urllib.parse.urlunparse(parsed)


def perform_local_speedtest(node_id, modem_id, bytes_count, target_url):
    qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
    overview = json_request(f"{MAIN_SERVER}/api/partner/overview?{qs}")
    modems = overview.get("modems", []) if isinstance(overview, dict) else []
    chosen = None
    for modem in modems:
        if str(modem.get("id", "")).strip() != modem_id:
            continue
        if node_id and str(modem.get("node_id", "")).strip() != node_id:
            continue
        chosen = modem
        break
    if not chosen:
        raise RuntimeError("modem not found")

    proxy_port = int(chosen.get("port") or 0)
    if proxy_port <= 0:
        raise RuntimeError("modem port is not available")

    target_url = normalize_target_url(target_url, bytes_count)
    started = time.time()
    result = subprocess.run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--output",
            "/dev/null",
            "--proxy",
            f"socks5h://127.0.0.1:{proxy_port}",
            "--connect-timeout",
            "10",
            "--max-time",
            "40",
            "--write-out",
            '{"speed_download":%{speed_download},"time_total":%{time_total},"size_download":%{size_download},"remote_ip":"%{remote_ip}","url_effective":"%{url_effective}"}',
            target_url,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "speedtest failed").strip())

    payload = json.loads((result.stdout or "").strip() or "{}")
    speed_download = float(payload.get("speed_download") or 0.0)
    time_total = float(payload.get("time_total") or 0.0)
    size_download = int(float(payload.get("size_download") or 0))
    mbps = round((speed_download * 8) / 1_000_000, 2) if speed_download > 0 else 0.0
    return {
        "mode": "local_modem",
        "node_id": str(chosen.get("node_id") or ""),
        "modem_id": str(chosen.get("id") or ""),
        "proxy_host": "127.0.0.1",
        "proxy_port": proxy_port,
        "target_url": payload.get("url_effective") or target_url,
        "remote_ip": payload.get("remote_ip") or "",
        "bytes_requested": int(bytes_count),
        "bytes_received": size_download,
        "duration_ms": int(time_total * 1000),
        "download_mbps": mbps,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


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

        if self.path.startswith("/api/modem-billing"):
            try:
                qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
                data = json_request(f"{MAIN_SERVER}/api/partner/modem-billing?{qs}")
                self._send_json(200, data)
            except urllib.error.HTTPError as err:
                self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
            except Exception as err:
                self._send_text(502, str(err))
            return

        if self.path.startswith("/api/speedtest-template"):
            self._send_json(200, {
                "target_url": SPEEDTEST_URL,
                "bytes_default": SPEEDTEST_BYTES,
            })
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
        if self.path == "/api/speedtest":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                req = json.loads(raw.decode("utf-8"))
                modem_id = str(req.get("modem_id", "")).strip()
                node_id = str(req.get("node_id", "")).strip()
                bytes_count = int(req.get("bytes") or SPEEDTEST_BYTES)
                target_url = str(req.get("target_url") or SPEEDTEST_URL).strip()
                if not modem_id:
                    self._send_text(400, "modem_id is required")
                    return
                data = perform_local_speedtest(node_id, modem_id, bytes_count, target_url)
                self._send_json(200, data)
            except urllib.error.HTTPError as err:
                self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
            except Exception as err:
                self._send_text(400, str(err))
            return

        if self.path == "/api/modem-billing":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                req = json.loads(raw.decode("utf-8"))
                req["partner_key"] = PARTNER_KEY
                data = json_request(f"{MAIN_SERVER}/api/partner/modem-billing", method="POST", payload=req)
                self._send_json(200, data)
            except urllib.error.HTTPError as err:
                self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
            except Exception as err:
                self._send_text(400, str(err))
            return

        if self.path == "/api/sim-check":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                req = json.loads(raw.decode("utf-8"))
                req["partner_key"] = PARTNER_KEY
                data = json_request(f"{MAIN_SERVER}/api/partner/sim-check", method="POST", payload=req)
                self._send_json(200, data)
            except urllib.error.HTTPError as err:
                self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
            except Exception as err:
                self._send_text(400, str(err))
            return

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
