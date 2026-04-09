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
import re
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
MODEM_ALIAS_PREFIX = os.environ.get("MODEM_ALIAS_PREFIX", "172.31")
MODEM_ALIAS_PORT = int(os.environ.get("MODEM_ALIAS_PORT", "80"))
CONFIG_PATH = os.environ.get("PARTNER_NODE_CONFIG", "/etc/partner-node/config.yaml")
LOCAL_MODEM_REGISTRY_PATH = os.environ.get("PARTNER_NODE_MODEM_REGISTRY", "/var/lib/partner-node/modem_ordinal_registry.json")
TARGET_MAIN_VERSION = "22.200.15.00.00"
TARGET_WEBUI_VERSION = "17.100.13.113.03"
TARGET_WEBUI_LABEL = "17.100.13.01.03"

ALLOWED = {
    "self_check",
    "rotate_ip",
    "restart_proxy",
    "reconcile_config",
    "transport_self_check",
    "self_update",
    "flash_modem",
}


def json_request(url, method="GET", payload=None):
    body = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, method=method, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as resp:
        return json.loads(resp.read().decode("utf-8"))


def alias_host_for_ordinal(ordinal):
    try:
        ordinal = int(ordinal)
    except Exception:
        return ""
    if ordinal <= 0 or ordinal > 254:
        return ""
    return f"{MODEM_ALIAS_PREFIX}.{ordinal}.1"


def extract_alias_ordinal(host_header):
    host = str(host_header or "").strip().split(":", 1)[0]
    match = re.fullmatch(r"172\.31\.(\d{1,3})\.1", host)
    if not match:
        return None
    ordinal = int(match.group(1))
    if ordinal <= 0 or ordinal > 254:
        return None
    return ordinal


def ensure_alias_redirect():
    rule = [
        "iptables", "-t", "nat", "-C", "OUTPUT",
        "-d", "172.31.0.0/16", "-p", "tcp", "--dport", str(MODEM_ALIAS_PORT),
        "-j", "REDIRECT", "--to-ports", str(LISTEN_PORT),
    ]
    add_rule = [
        "iptables", "-t", "nat", "-A", "OUTPUT",
        "-d", "172.31.0.0/16", "-p", "tcp", "--dport", str(MODEM_ALIAS_PORT),
        "-j", "REDIRECT", "--to-ports", str(LISTEN_PORT),
    ]
    try:
        subprocess.run(rule, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        subprocess.run(add_rule, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ensure_alias_ip(alias_host):
    if not alias_host:
        return
    cidr = f"{alias_host}/32"
    current = subprocess.run(
        ["ip", "-o", "-4", "addr", "show", "dev", "lo"],
        capture_output=True,
        text=True,
        check=False,
    )
    if cidr in (current.stdout or ""):
        return
    subprocess.run(
        ["ip", "addr", "add", cidr, "dev", "lo"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def normalize_digits(raw):
    return "".join(ch for ch in str(raw or "") if ch.isdigit())


def modem_has_target(main_version, webui_version):
    main_version = str(main_version or "").strip()
    webui_version = str(webui_version or "").strip()
    if not main_version.startswith(TARGET_MAIN_VERSION):
        return False
    return webui_version.startswith(TARGET_WEBUI_VERSION) or TARGET_WEBUI_LABEL in webui_version


def load_local_modem_registry():
    try:
        with open(LOCAL_MODEM_REGISTRY_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        numbers = data.get("by_stable_key") if isinstance(data, dict) else {}
        flashed = data.get("flashed") if isinstance(data, dict) else {}
        return numbers if isinstance(numbers, dict) else {}, flashed if isinstance(flashed, dict) else {}
    except Exception:
        return {}, {}


def read_hilink_device_info(base_url):
    base_url = str(base_url or "").strip().rstrip("/")
    if not base_url:
        return None
    try:
        ses = subprocess.run(
            ["curl", "-fsS", "--max-time", "5", f"{base_url}/api/webserver/SesTokInfo"],
            capture_output=True,
            text=True,
            check=False,
        )
        if ses.returncode != 0:
            return None
        body = ses.stdout or ""
        ses_match = re.search(r"<SesInfo>(.*?)</SesInfo>", body, re.S)
        tok_match = re.search(r"<TokInfo>(.*?)</TokInfo>", body, re.S)
        if not ses_match or not tok_match:
            return None
        info = subprocess.run(
            [
                "curl", "-fsS", "--max-time", "5",
                "-H", f"Cookie: {ses_match.group(1).strip()}",
                "-H", f"__RequestVerificationToken: {tok_match.group(1).strip()}",
                f"{base_url}/api/device/information",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if info.returncode != 0:
            return None
        text = info.stdout or ""
        if "<error>" in text:
            return None
        fields = {}
        for tag, key in (
            ("DeviceName", "device_name"),
            ("SerialNumber", "serial_number"),
            ("Imei", "imei"),
            ("Iccid", "iccid"),
            ("HardwareVersion", "hardware_version"),
            ("SoftwareVersion", "software_version"),
            ("WebUIVersion", "webui_version"),
            ("ProductFamily", "product_family"),
        ):
            match = re.search(rf"<{tag}>(.*?)</{tag}>", text, re.S)
            if match:
                fields[key] = match.group(1).strip()
        fields["local_base_url"] = base_url
        return fields if fields else None
    except Exception:
        return None


def enrich_overview_with_local_modem_state(overview):
    if not isinstance(overview, dict):
        return overview

    by_stable_key, flashed = load_local_modem_registry()

    def enrich_modem(modem):
        if not isinstance(modem, dict):
            return modem

        candidates = []
        base = str(modem.get("local_base_url") or "").strip().rstrip("/")
        if base:
            candidates.append(base)
        candidates.extend(["http://192.168.8.1", "http://192.168.1.1"])

        info = None
        for candidate in candidates:
            info = read_hilink_device_info(candidate)
            if info:
                break

        if info:
            for field in ("imei", "serial_number", "device_name", "iccid", "hardware_version", "software_version", "webui_version", "product_family", "local_base_url"):
                if str(info.get(field) or "").strip():
                    modem[field] = info[field]

        imei = normalize_digits(modem.get("imei"))
        stable_key = f"imei:{imei}" if imei else ""
        local_number = int(by_stable_key.get(stable_key) or 0) if stable_key else 0
        local_flashed = bool(flashed.get(stable_key)) if stable_key else False

        if local_number > 0:
            modem["modem_number"] = local_number
            if int(modem.get("ordinal") or 0) <= 0:
                modem["ordinal"] = local_number

        if local_flashed:
            modem["provision_status"] = "ready"
            if not str(modem.get("provision_notes") or "").strip():
                modem["provision_notes"] = "known modem for this node"
            if modem_has_target(modem.get("software_version"), modem.get("webui_version")):
                modem["flash_status"] = "done"
                modem["flash_stage"] = "completed"
                number = int(modem.get("modem_number") or modem.get("ordinal") or 0)
                modem["flash_message"] = f"flashing completed; label this modem as #{number} for this node" if number > 0 else "flashing completed"
        return modem

    top_level = []
    for modem in overview.get("modems", []) or []:
        top_level.append(enrich_modem(modem))
    overview["modems"] = top_level

    modem_map = {}
    for modem in top_level:
        if isinstance(modem, dict):
            modem_map[f"{modem.get('node_id','')}:{modem.get('id','')}"] = modem

    for node in overview.get("nodes", []) or []:
        if not isinstance(node, dict):
            continue
        enriched = []
        node_id = str(node.get("node_id") or "")
        for modem in node.get("modems", []) or []:
            key = f"{node_id}:{modem.get('id','')}" if isinstance(modem, dict) else ""
            if key and key in modem_map:
                merged = dict(modem)
                merged.update(modem_map[key])
                enriched.append(merged)
            else:
                enriched.append(enrich_modem(modem))
        node["modems"] = enriched
    return overview


def reconcile_aliases(overview):
    ensure_alias_redirect()
    if not isinstance(overview, dict):
        return
    for modem in overview.get("modems", []) or []:
        if not isinstance(modem, dict):
            continue
        alias_host = alias_host_for_ordinal(modem.get("ordinal") or modem.get("modem_number"))
        if alias_host:
            ensure_alias_ip(alias_host)


def read_flash_settings():
    enabled = True
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            content = fh.read()
        match = re.search(r'(?ms)^modem:\n(?:(?:  .*\n)+?)  flash:\n(?:(?:    .*\n)+?)    auto_enabled:\s*(true|false)\s*$', content)
        if not match:
            match = re.search(r'(?m)^\s*auto_enabled:\s*(true|false)\s*$', content)
        if match:
            enabled = match.group(1).strip().lower() == "true"
    except Exception:
        enabled = True
    return {"auto_flash_enabled": enabled}


def write_flash_settings(auto_enabled):
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        content = fh.read()
    replacement = f"    auto_enabled: {'true' if auto_enabled else 'false'}"
    if re.search(r'(?m)^\s*auto_enabled:\s*(true|false)\s*$', content):
        updated = re.sub(r'(?m)^\s*auto_enabled:\s*(true|false)\s*$', replacement, content, count=1)
    elif "  flash:\n" in content:
        updated = content.replace("  flash:\n", f"  flash:\n{replacement}\n", 1)
    else:
        updated = content.rstrip() + f"\n  flash:\n    enabled: true\n{replacement}\n    script_path: \"/usr/local/sbin/partner-node-flash-e3372h.sh\"\n"
    with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
        fh.write(updated)
    subprocess.Popen(["systemctl", "restart", "partner-node"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"auto_flash_enabled": auto_enabled, "restarting_agent": True}


def fetch_overview():
    qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
    data = json_request(f"{MAIN_SERVER}/api/partner/overview?{qs}")
    if isinstance(data, dict):
        data.setdefault("partner_key", PARTNER_KEY)
        data.setdefault("main_server", MAIN_SERVER)
        enrich_overview_with_local_modem_state(data)
        reconcile_aliases(data)
    return data


def resolve_alias_target(ordinal):
    overview = fetch_overview()
    modems = overview.get("modems", []) if isinstance(overview, dict) else []
    for modem in modems:
        if not isinstance(modem, dict):
            continue
        if int(modem.get("ordinal") or modem.get("modem_number") or 0) != int(ordinal):
            continue
        base = str(modem.get("local_base_url") or "").strip().rstrip("/")
        if base:
            return modem, base
    return None, ""


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

    def _proxy_alias_request(self, ordinal):
        modem, upstream_base = resolve_alias_target(ordinal)
        if not upstream_base:
            self._send_text(404, f"modem alias #{ordinal} is not available")
            return

        body = None
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 0:
            body = self.rfile.read(length)

        upstream_url = upstream_base + self.path
        headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in {"host", "content-length", "connection"}:
                continue
            headers[key] = value
        headers["Host"] = urllib.parse.urlparse(upstream_base).netloc

        req = urllib.request.Request(upstream_url, data=body, method=self.command, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = resp.read()
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    lower = key.lower()
                    if lower in {"transfer-encoding", "connection", "content-length"}:
                        continue
                    if lower == "location" and value.startswith(upstream_base):
                        value = value.replace(upstream_base, f"http://{alias_host_for_ordinal(ordinal)}", 1)
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        except urllib.error.HTTPError as err:
            payload = err.read()
            self.send_response(err.code)
            for key, value in err.headers.items():
                lower = key.lower()
                if lower in {"transfer-encoding", "connection", "content-length"}:
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as err:
            self._send_text(502, str(err))

    def do_GET(self):
        alias_ordinal = extract_alias_ordinal(self.headers.get("Host", ""))
        if alias_ordinal is not None:
            self._proxy_alias_request(alias_ordinal)
            return

        if self.path == "/healthz":
            self._send_text(200, "ok")
            return

        if self.path == "/api/overview":
            try:
                data = fetch_overview()
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

        if self.path.startswith("/api/modem-registry"):
            try:
                qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
                data = json_request(f"{MAIN_SERVER}/api/partner/modem-registry?{qs}")
                self._send_json(200, data)
            except urllib.error.HTTPError as err:
                self._send_text(err.code, err.read().decode("utf-8", errors="ignore"))
            except Exception as err:
                self._send_text(502, str(err))
            return

        if self.path == "/api/flash-settings":
            try:
                self._send_json(200, read_flash_settings())
            except Exception as err:
                self._send_text(500, str(err))
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
        alias_ordinal = extract_alias_ordinal(self.headers.get("Host", ""))
        if alias_ordinal is not None:
            self._proxy_alias_request(alias_ordinal)
            return

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

        if self.path == "/api/modem-registry":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                req = json.loads(raw.decode("utf-8"))
                req["partner_key"] = PARTNER_KEY
                data = json_request(f"{MAIN_SERVER}/api/partner/modem-registry", method="POST", payload=req)
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

        if self.path == "/api/flash-settings":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length > 0 else b"{}"
                req = json.loads(raw.decode("utf-8"))
                auto_enabled = bool(req.get("auto_flash_enabled", True))
                self._send_json(200, write_flash_settings(auto_enabled))
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
    ensure_alias_redirect()
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
After=network-online.target partner-node.service
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
