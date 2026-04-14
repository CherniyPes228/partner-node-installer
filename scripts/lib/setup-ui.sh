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
import sys
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
LOCAL_FLASH_JOB_PATH = os.environ.get("PARTNER_NODE_FLASH_JOB", "/var/lib/partner-node/flash_job_state.json")
NODE_CREDENTIALS_PATH = os.environ.get("PARTNER_NODE_CREDENTIALS", "/var/lib/partner-node/node_credentials")
TARGET_MAIN_VERSION = "22.200.15.00.00"
TARGET_WEBUI_VERSION = "17.100.13.113.03"
TARGET_WEBUI_LABEL = "17.100.13.01.03"
MAIN_SERVER_TIMEOUT = float(os.environ.get("PARTNER_MAIN_SERVER_TIMEOUT", "5"))
HILINK_PROBE_TIMEOUT = float(os.environ.get("PARTNER_HILINK_PROBE_TIMEOUT", "1.5"))
OVERVIEW_CACHE_TTL = float(os.environ.get("PARTNER_OVERVIEW_CACHE_TTL", "3"))

ALLOWED = {
    "self_check",
    "rotate_ip",
    "restart_proxy",
    "reconcile_config",
    "transport_self_check",
    "self_update",
    "flash_modem",
}

OVERVIEW_CACHE_LOCK = threading.Lock()
OVERVIEW_CACHE = {
    "data": {
        "partner_key": PARTNER_KEY,
        "main_server": MAIN_SERVER,
        "nodes": [],
        "modems": [],
        "modem_registry": [],
    },
    "updated_at": 0.0,
    "refreshing": False,
    "error": "",
}


def ui_log(message, **fields):
    parts = [f"[partner-node-ui] {message}"]
    for key, value in fields.items():
        parts.append(f"{key}={value}")
    try:
        print(" ".join(parts), file=sys.stderr, flush=True)
    except Exception:
        pass


def json_request(url, method="GET", payload=None, timeout=MAIN_SERVER_TIMEOUT):
    body = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, method=method, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
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


def load_local_flash_job():
    try:
        with open(LOCAL_FLASH_JOB_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return None
        job = data.get("current")
        if not isinstance(job, dict):
            return None
        return job
    except Exception:
        return None


def read_local_node_id():
    try:
        with open(NODE_CREDENTIALS_PATH, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("node_id="):
                    return line.split("=", 1)[1].strip()
    except Exception:
        return ""
    return ""


def local_service_active(service_name):
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service_name],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode == 0 and result.stdout.strip() == "active"
    except Exception:
        return False


def current_local_node_status():
    return "online" if local_service_active("partner-node") else "offline"


def local_hilink_base_candidates():
    candidates = []
    seen = set()

    def add(url):
        url = str(url or "").strip().rstrip("/")
        if not url or url in seen:
            return
        seen.add(url)
        candidates.append(url)

    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            content = fh.read()
        match = re.search(r'(?m)^\s*base_url:\s*"?(http://[0-9.]+(?::\d+)?)"?\s*$', content)
        if match:
            add(match.group(1))
    except Exception:
        pass

    for host in ("192.168.8.1", "192.168.1.1", "192.168.13.1", "192.168.3.1", "192.168.123.1"):
        add(f"http://{host}")
    return candidates


def detect_local_huawei_hilink_placeholder():
    recognized_products = ("14dc", "14db", "1505", "1506")
    product_id = ""
    try:
        lsusb = subprocess.run(
            ["lsusb"],
            capture_output=True,
            text=True,
            check=False,
        )
        usb_text = (lsusb.stdout or "").lower()
        for candidate in recognized_products:
            if f"12d1:{candidate}" in usb_text:
                product_id = candidate
                break
        if not product_id:
            return None
    except Exception:
        return None

    iface_name = ""
    iface_ip = ""
    try:
        ip_out = subprocess.run(
            ["ip", "-o", "-4", "addr", "show"],
            capture_output=True,
            text=True,
            check=False,
        )
        iface_name = ""
        iface_ip = ""
        for line in (ip_out.stdout or "").splitlines():
            line = line.strip()
            if not line or not line[0].isdigit():
                continue
            parts = line.split()
            if len(parts) < 4:
                continue
            name = parts[1]
            cidr = parts[3]
            ip = cidr.split("/", 1)[0].strip()
            if not name.startswith(("enx", "enp", "usb")):
                continue
            if ip.startswith("192.168.8.") or ip.startswith("192.168.1."):
                iface_name = name
                iface_ip = ip
                break
    except Exception:
        pass

    base_url = ""
    if iface_ip.startswith("192.168.8."):
        base_url = "http://192.168.8.1"
    elif iface_ip.startswith("192.168.1."):
        base_url = "http://192.168.1.1"
    return {
        "id": "hilink0",
        "ordinal": 0,
        "modem_number": 0,
        "usb_vendor_id": "12d1",
        "usb_product_id": product_id,
        "usb_mode": "hilink",
        "state": "detected",
        "wan_ip": "",
        "signal_strength": 0,
        "operator": "",
        "technology": "",
        "active_sessions": 0,
        "port": 31001,
        "client_eligible": True,
        "traffic_bytes_in": 0,
        "traffic_bytes_out": 0,
        "flash_status": "",
        "flash_stage": "",
        "flash_message": "",
        "provision_status": "requires_flash",
        "provision_notes": "huawei hilink modem detected; waiting for webui",
        "device_name": "E3372",
        "hardware_version": "",
        "software_version": "",
        "webui_version": "",
        "product_family": "LTE",
        "local_base_url": base_url,
        "local_interface": iface_name,
    }


def detect_local_live_modem(node_id, registry_by_node_imei, by_stable_key, flashed):
    for base_url in local_hilink_base_candidates():
        info = read_hilink_device_info(base_url)
        if not info:
            continue

        imei = normalize_digits(info.get("imei"))
        stable_key = f"imei:{imei}" if imei else ""
        registry_item = registry_by_node_imei.get(f"{node_id}:{imei}") if node_id and imei else None
        local_number = int(by_stable_key.get(stable_key) or 0) if stable_key else 0
        local_flashed = bool(flashed.get(stable_key)) if stable_key else False
        provision_status = "ready" if local_flashed else "requires_flash"
        provision_notes = "known modem for this node" if local_flashed or local_number > 0 else "new modem for this node"

        modem = {
            "id": "hilink0",
            "ordinal": 0,
            "modem_number": int(registry_item.get("modem_number") or 0) if registry_item else local_number,
            "local_modem_number": local_number,
            "known_to_node": bool(local_number > 0),
            "local_flashed": local_flashed,
            "node_id": node_id,
            "node_status": current_local_node_status(),
            "usb_vendor_id": "12d1",
            "usb_product_id": "14dc",
            "usb_mode": "hilink",
            "state": "ready",
            "wan_ip": "",
            "signal_strength": 0,
            "operator": "",
            "technology": "",
            "active_sessions": 0,
            "port": 31001,
            "client_eligible": True,
            "traffic_bytes_in": 0,
            "traffic_bytes_out": 0,
            "flash_status": "",
            "flash_stage": "",
            "flash_message": "",
            "provision_status": provision_status,
            "provision_notes": provision_notes,
            "last_seen_node_id": node_id,
            "last_seen_modem_id": "hilink0",
        }
        modem.update(info)
        if local_flashed and modem_has_target(modem.get("software_version"), modem.get("webui_version")):
            number = int(modem.get("modem_number") or modem.get("ordinal") or 0)
            modem["flash_status"] = "done"
            modem["flash_stage"] = "completed"
            modem["flash_message"] = f"flashing completed; label this modem as #{number} for this node" if number > 0 else "flashing completed"
        return modem
    placeholder = detect_local_huawei_hilink_placeholder()
    if not placeholder:
        return None
    ui_log(
        "local hilink placeholder detected",
        node_id=node_id or "",
        usb_product=placeholder.get("usb_product_id", ""),
        local_interface=placeholder.get("local_interface", ""),
        local_base_url=placeholder.get("local_base_url", ""),
    )
    placeholder["node_id"] = node_id
    placeholder["node_status"] = current_local_node_status()
    placeholder["last_seen_node_id"] = node_id
    placeholder["last_seen_modem_id"] = "hilink0"
    placeholder["known_to_node"] = False
    placeholder["local_flashed"] = False
    return placeholder


def finalize_overview_shape(overview):
    overview.setdefault("partner_key", PARTNER_KEY)
    overview.setdefault("main_server", MAIN_SERVER)
    overview.setdefault("nodes", [])
    overview.setdefault("modems", [])
    overview.setdefault("modem_registry", [])
    overview.setdefault("flash_job", {})
    nodes = overview.get("nodes") or []
    modems = overview.get("modems") or []
    if not modems:
        flattened = []
        seen = set()
        for node in nodes:
            if not isinstance(node, dict):
                continue
            for modem in node.get("modems", []) or []:
                if not isinstance(modem, dict):
                    continue
                key = (
                    str(modem.get("node_id") or node.get("node_id") or "").strip(),
                    normalize_digits(modem.get("imei")) or str(modem.get("id") or "").strip(),
                )
                if key in seen:
                    continue
                seen.add(key)
                flattened.append(modem)
        if flattened:
            modems = flattened
            overview["modems"] = flattened
    if nodes:
        best_node = None
        for node in nodes:
            if not isinstance(node, dict):
                continue
            if best_node is None:
                best_node = node
            if str(node.get("node_status") or "").strip() == "online":
                best_node = node
                break
        if isinstance(best_node, dict):
            overview["node_id"] = str(overview.get("node_id") or best_node.get("node_id") or "")
            overview["node_status"] = str(best_node.get("node_status") or best_node.get("state") or overview.get("node_status") or "")
            if str(best_node.get("last_heartbeat_at") or "").strip():
                overview["last_heartbeat_at"] = best_node.get("last_heartbeat_at")
    ready_count = 0
    requires_flash_count = 0
    offline_count = 0
    for modem in modems:
        if not isinstance(modem, dict):
            continue
        if str(modem.get("provision_status") or "").strip() == "ready":
            ready_count += 1
        elif str(modem.get("provision_status") or "").strip() == "requires_flash":
            requires_flash_count += 1
        if str(modem.get("state") or "").strip() == "offline":
            offline_count += 1
    overview["summary"] = {
        "nodes_total": len(nodes),
        "nodes_online": sum(1 for node in nodes if str(node.get("node_status") or "").strip() == "online"),
        "nodes_degraded": sum(1 for node in nodes if str(node.get("node_status") or "").strip() != "online"),
        "modems_total": len(modems),
        "modems_ready": ready_count,
        "modems_requires_flash": requires_flash_count,
        "modems_offline": offline_count,
    }
    return overview


def apply_local_flash_job(overview):
    if not isinstance(overview, dict):
        return overview

    job = load_local_flash_job()
    overview["flash_job"] = job or {}
    if not isinstance(job, dict):
        return overview

    job_status = str(job.get("status") or "").strip().lower()
    job_stage = str(job.get("stage") or "").strip().lower()
    if job_status in ("completed", "done", "success"):
        flash_status = "done"
    elif job_status == "failed":
        flash_status = "failed"
    elif job_status:
        flash_status = "running" if job_status not in ("queued",) else "queued"
    else:
        flash_status = ""
    flash_stage = job_stage or job_status
    flash_message = str(job.get("message") or job.get("error_message") or "").strip()
    job_modem_id = str(job.get("modem_id") or "").strip()
    job_imei = normalize_digits(job.get("imei"))

    def same_job_modem(modem):
        if not isinstance(modem, dict):
            return False
        modem_imei = normalize_digits(modem.get("imei"))
        modem_id = str(modem.get("id") or "").strip()
        if job_imei and modem_imei == job_imei:
            return True
        return bool(job_modem_id and modem_id == job_modem_id)

    for modem in overview.get("modems", []) or []:
        if not same_job_modem(modem):
            continue
        if flash_status:
            modem["flash_status"] = flash_status
        if flash_stage:
            modem["flash_stage"] = flash_stage
        if flash_message:
            modem["flash_message"] = flash_message
    for node in overview.get("nodes", []) or []:
        if not isinstance(node, dict):
            continue
        for modem in node.get("modems", []) or []:
            if not same_job_modem(modem):
                continue
            if flash_status:
                modem["flash_status"] = flash_status
            if flash_stage:
                modem["flash_stage"] = flash_stage
            if flash_message:
                modem["flash_message"] = flash_message
    return overview


def read_hilink_device_info(base_url):
    base_url = str(base_url or "").strip().rstrip("/")
    if not base_url:
        return None
    try:
        ses = subprocess.run(
            ["curl", "-fsS", "--max-time", str(HILINK_PROBE_TIMEOUT), f"{base_url}/api/webserver/SesTokInfo"],
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
                "curl", "-fsS", "--max-time", str(HILINK_PROBE_TIMEOUT),
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
    registry_items = overview.get("modem_registry", []) or []
    registry_by_node_imei = {}
    for item in registry_items:
        if not isinstance(item, dict):
            continue
        node_id = str(item.get("node_id") or item.get("last_seen_node_id") or "").strip()
        imei = normalize_digits(item.get("imei"))
        if node_id and imei:
            registry_by_node_imei[f"{node_id}:{imei}"] = item

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
        node_imei_key = f"{modem.get('node_id','')}:{imei}" if imei else ""
        registry_item = registry_by_node_imei.get(node_imei_key) if node_imei_key else None
        local_number = int(by_stable_key.get(stable_key) or 0) if stable_key else 0
        local_flashed = bool(flashed.get(stable_key)) if stable_key else False
        modem["known_to_node"] = bool(local_number > 0)
        modem["local_flashed"] = local_flashed

        if registry_item:
            registry_number = int(registry_item.get("modem_number") or 0)
            if registry_number > 0:
                modem["modem_number"] = registry_number
            for field in ("last_seen_node_id", "last_seen_modem_id"):
                if str(registry_item.get(field) or "").strip():
                    modem[field] = registry_item[field]

        if local_number > 0:
            modem["local_modem_number"] = local_number
            if int(modem.get("ordinal") or 0) <= 0:
                modem["ordinal"] = local_number

        if local_flashed:
            active_flash_status = str(modem.get("flash_status") or "").strip().lower()
            active_flash_stage = str(modem.get("flash_stage") or "").strip().lower()
            flash_still_running = active_flash_status in ("queued", "running") or active_flash_stage in ("queued", "verify")
            modem["provision_status"] = "ready"
            modem["client_eligible"] = True
            if not str(modem.get("provision_notes") or "").strip():
                modem["provision_notes"] = "known modem for this node"
            if not flash_still_running and modem_has_target(modem.get("software_version"), modem.get("webui_version")):
                modem["flash_status"] = "done"
                modem["flash_stage"] = "completed"
                number = int(modem.get("modem_number") or modem.get("ordinal") or 0)
                modem["flash_message"] = f"flashing completed; label this modem as #{number} for this node" if number > 0 else "flashing completed"
        elif local_number > 0:
            modem["provision_status"] = "requires_flash"
            modem["client_eligible"] = True
            if not str(modem.get("provision_notes") or "").strip():
                modem["provision_notes"] = "new modem assigned to this node; flash required"
        elif not str(modem.get("provision_status") or "").strip():
            modem["provision_status"] = "requires_flash"
        return modem

    top_level = []
    for modem in overview.get("modems", []) or []:
        top_level.append(enrich_modem(modem))
    overview["modems"] = top_level

    modem_map = {}
    active_registry_keys = set()
    for modem in top_level:
        if isinstance(modem, dict):
            modem_map[f"{modem.get('node_id','')}:{modem.get('id','')}"] = modem
            imei = normalize_digits(modem.get("imei"))
            if imei:
                active_registry_keys.add(f"{modem.get('node_id','')}:{imei}")

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
        node_id = str(node.get("node_id") or "")
        node["modems"] = enriched
    return overview


def inject_local_runtime_state(overview):
    if not isinstance(overview, dict):
        overview = {}

    node_id = read_local_node_id().strip()
    by_stable_key, flashed = load_local_modem_registry()
    registry_items = overview.get("modem_registry", []) or []
    registry_by_node_imei = {}
    for item in registry_items:
        if not isinstance(item, dict):
            continue
        item_node = str(item.get("node_id") or item.get("last_seen_node_id") or "").strip()
        item_imei = normalize_digits(item.get("imei"))
        if item_node and item_imei:
            registry_by_node_imei[f"{item_node}:{item_imei}"] = item

    if not node_id:
        for node in overview.get("nodes", []) or []:
            if isinstance(node, dict) and str(node.get("node_id") or "").strip():
                node_id = str(node.get("node_id") or "").strip()
                break

    local_status = current_local_node_status()
    local_modem = detect_local_live_modem(node_id, registry_by_node_imei, by_stable_key, flashed)

    nodes = overview.setdefault("nodes", [])
    modems = overview.setdefault("modems", [])
    node_entry = None
    if node_id:
        for node in nodes:
            if isinstance(node, dict) and str(node.get("node_id") or "").strip() == node_id:
                node_entry = node
                break
        if node_entry is None:
            node_entry = {
                "node_id": node_id,
                "node_status": local_status,
                "country": "",
                "external_ip": "",
                "modems": [],
                "active_sessions": 0,
                "bytes_in_total": 0,
                "bytes_out_total": 0,
                "last_heartbeat_at": "",
            }
            nodes.append(node_entry)
        else:
            node_entry["node_status"] = local_status
        overview["node_id"] = node_id
        overview["node_status"] = local_status
        if local_status == "online":
            overview["last_heartbeat_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if not local_modem:
        return finalize_overview_shape(overview)

    if not node_id:
        node_id = str(local_modem.get("node_id") or overview.get("node_id") or "local-node").strip()
        local_modem["node_id"] = node_id
        node_entry = {
            "node_id": node_id,
            "node_status": local_status,
            "country": "",
            "external_ip": "",
            "modems": [],
            "active_sessions": 0,
            "bytes_in_total": 0,
            "bytes_out_total": 0,
            "last_heartbeat_at": "",
        }
        nodes.append(node_entry)
        overview["node_id"] = node_id
        overview["node_status"] = local_status

    active_key = f"{node_id}:{normalize_digits(local_modem.get('imei')) or local_modem.get('id')}"

    def same_modem(item):
        if not isinstance(item, dict):
            return False
        item_node = str(item.get("node_id") or "").strip()
        item_imei = normalize_digits(item.get("imei"))
        item_id = str(item.get("id") or "").strip()
        if item_node != node_id:
            return False
        return active_key == f"{item_node}:{item_imei or item_id}"

    merged = False
    for idx, item in enumerate(modems):
        if same_modem(item):
            updated = dict(item)
            updated.update(local_modem)
            modems[idx] = updated
            local_modem = updated
            merged = True
            break
    if not merged:
        modems.append(local_modem)

    node_modems = node_entry.setdefault("modems", [])
    merged = False
    for idx, item in enumerate(node_modems):
        if same_modem(item):
            updated = dict(item)
            updated.update(local_modem)
            node_modems[idx] = updated
            merged = True
            break
    if not merged:
        node_modems.append(local_modem)

    return finalize_overview_shape(overview)


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
    now = time.time()
    with OVERVIEW_CACHE_LOCK:
        cached = dict(OVERVIEW_CACHE["data"]) if isinstance(OVERVIEW_CACHE["data"], dict) else {
            "partner_key": PARTNER_KEY,
            "main_server": MAIN_SERVER,
            "nodes": [],
            "modems": [],
            "modem_registry": [],
        }
        updated_at = float(OVERVIEW_CACHE.get("updated_at") or 0.0)
        refreshing = bool(OVERVIEW_CACHE.get("refreshing"))
    if isinstance(cached, dict):
        try:
            enrich_overview_with_local_modem_state(cached)
            inject_local_runtime_state(cached)
            apply_local_flash_job(cached)
            reconcile_aliases(cached)
        except Exception:
            pass
        cached = finalize_overview_shape(cached)
    if now - updated_at <= OVERVIEW_CACHE_TTL and cached:
        ui_log("overview cache hit", updated_at=int(updated_at), modem_count=len(cached.get("modems", []) or []))
        return cached
    if not refreshing:
        ui_log("overview cache stale; scheduling refresh", updated_at=int(updated_at), modem_count=len(cached.get("modems", []) or []))
        schedule_overview_refresh()
    return cached


def rebuild_overview_snapshot():
    qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
    try:
        data = json_request(f"{MAIN_SERVER}/api/partner/overview?{qs}", timeout=MAIN_SERVER_TIMEOUT)
    except Exception:
        data = {
            "partner_key": PARTNER_KEY,
            "main_server": MAIN_SERVER,
            "nodes": [],
            "modems": [],
            "modem_registry": [],
        }
    if isinstance(data, dict):
        data.setdefault("partner_key", PARTNER_KEY)
        data.setdefault("main_server", MAIN_SERVER)
        enrich_overview_with_local_modem_state(data)
        inject_local_runtime_state(data)
        apply_local_flash_job(data)
        reconcile_aliases(data)
    return data


def refresh_overview_cache():
    try:
        data = rebuild_overview_snapshot()
        error = ""
    except Exception as err:
        with OVERVIEW_CACHE_LOCK:
            OVERVIEW_CACHE["refreshing"] = False
            OVERVIEW_CACHE["error"] = str(err)
        ui_log("overview refresh failed", error=str(err))
        return

    with OVERVIEW_CACHE_LOCK:
        OVERVIEW_CACHE["data"] = data
        OVERVIEW_CACHE["updated_at"] = time.time()
        OVERVIEW_CACHE["refreshing"] = False
        OVERVIEW_CACHE["error"] = error
    ui_log("overview refresh complete", modem_count=len((data or {}).get("modems", []) or []), node_count=len((data or {}).get("nodes", []) or []))


def schedule_overview_refresh():
    with OVERVIEW_CACHE_LOCK:
        if OVERVIEW_CACHE["refreshing"]:
            return
        OVERVIEW_CACHE["refreshing"] = True
    threading.Thread(target=refresh_overview_cache, daemon=True).start()


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
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def _send_text(self, code, text):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

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
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

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
    schedule_overview_refresh()
    server = ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
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
