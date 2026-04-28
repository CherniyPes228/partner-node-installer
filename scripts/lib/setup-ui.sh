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
PARTNER_NODE_UPDATE_PATH="${PARTNER_NODE_UPDATE_PATH:-/usr/local/sbin/partner-node-update.sh}"
PARTNER_NODE_UPDATE_LOG="${PARTNER_NODE_UPDATE_LOG:-/var/log/partner-node/update.log}"
PARTNER_NODE_UPDATE_URL="${PARTNER_NODE_UPDATE_URL:-https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/update.sh}"

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
import copy
import json
import mimetypes
import os
import re
import shlex
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
LOCAL_MODEM_USAGE_PATH = os.environ.get("PARTNER_NODE_MODEM_USAGE", "/var/lib/partner-node/modem_usage.json")
LOCAL_FLASH_JOB_PATH = os.environ.get("PARTNER_NODE_FLASH_JOB", "/var/lib/partner-node/flash_job_state.json")
LOCAL_FLASH_NOTICE_PATH = os.environ.get("PARTNER_NODE_FLASH_NOTICE", "/var/lib/partner-node/flash_notice_state.json")
NODE_CREDENTIALS_PATH = os.environ.get("PARTNER_NODE_CREDENTIALS", "/var/lib/partner-node/node_credentials")
UPDATE_HELPER_PATH = os.environ.get("PARTNER_NODE_UPDATE_PATH", "/usr/local/sbin/partner-node-update.sh")
UPDATE_HELPER_LOG = os.environ.get("PARTNER_NODE_UPDATE_LOG", "/var/log/partner-node/update.log")
UPDATE_SCRIPT_URL = os.environ.get("PARTNER_NODE_UPDATE_URL", "https://raw.githubusercontent.com/CherniyPes228/partner-node-installer/main/scripts/update.sh")
LOCAL_MODEM_STATE_PATHS = (
    LOCAL_MODEM_REGISTRY_PATH,
    LOCAL_FLASH_JOB_PATH,
    LOCAL_FLASH_NOTICE_PATH,
)
TARGET_MAIN_VERSION = "22.200.15.00.00"
TARGET_WEBUI_VERSION = "17.100.13.113.03"
TARGET_WEBUI_LABEL = "17.100.13.01.03"
MAIN_SERVER_TIMEOUT = float(os.environ.get("PARTNER_MAIN_SERVER_TIMEOUT", "5"))
HILINK_PROBE_TIMEOUT = float(os.environ.get("PARTNER_HILINK_PROBE_TIMEOUT", "1.5"))
HILINK_INFO_CACHE_TTL = float(os.environ.get("PARTNER_HILINK_INFO_CACHE_TTL", "15"))
HILINK_INFO_STALE_TTL = float(os.environ.get("PARTNER_HILINK_INFO_STALE_TTL", "30"))
OVERVIEW_CACHE_TTL = float(os.environ.get("PARTNER_OVERVIEW_CACHE_TTL", "3"))
CLIENT_SOCKET_TIMEOUT = float(os.environ.get("PARTNER_UI_CLIENT_TIMEOUT", "15"))
VERBOSE_UI_LOGS = os.environ.get("PARTNER_UI_VERBOSE_LOGS", "").strip().lower() in ("1", "true", "yes")
LOCAL_MODEM_PROBES_ENABLED = os.environ.get("PARTNER_UI_LOCAL_MODEM_PROBES", "").strip().lower() in ("1", "true", "yes")
LOCAL_HILINK_IFACE_PREFIXES = ("enx", "enp", "usb", "wwan", "eth")

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
HILINK_INFO_CACHE_LOCK = threading.Lock()
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
HILINK_INFO_CACHE = {}
LAST_ALIAS_SIGNATURE = ""


def ui_log(message, **fields):
    if not VERBOSE_UI_LOGS and message in (
        "overview cache hit",
        "overview cache stale; scheduling refresh",
        "overview refresh complete",
    ):
        return
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


def xml_tag_text(text, tag):
    match = re.search(rf"<{tag}>(.*?)</{tag}>", str(text or ""), re.I | re.S)
    return match.group(1).strip() if match else ""


def first_int_from_text(value):
    match = re.search(r"-?\d+", str(value or ""))
    if not match:
        return 0
    try:
        return int(match.group(0))
    except Exception:
        return 0


def signal_mode_to_label(value):
    raw = str(value or "").strip().lower()
    if raw in ("7", "lte", "4g"):
        return "lte"
    if raw in ("0", "wcdma", "umts", "3g"):
        return "wcdma"
    if raw in ("2", "gsm", "edge", "gprs", "2g"):
        return "gsm"
    return raw


def curl_fetch_text(url, cookie="", token=""):
    args = ["curl", "-fsS", "--max-time", str(HILINK_PROBE_TIMEOUT)]
    if cookie:
        args.extend(["-H", f"Cookie: {cookie}"])
    if token:
        args.extend(["-H", f"__RequestVerificationToken: {token}"])
    args.append(url)
    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return ""
    return result.stdout or ""


def merge_local_modem_snapshot(existing, incoming):
    updated = dict(existing if isinstance(existing, dict) else {})
    incoming = incoming if isinstance(incoming, dict) else {}
    for key, value in incoming.items():
        if isinstance(value, str):
            if value.strip() or not str(updated.get(key) or "").strip():
                updated[key] = value
            continue
        if isinstance(value, bool):
            updated[key] = value
            continue
        if isinstance(value, (int, float)):
            current = updated.get(key)
            try:
                current_num = int(current or 0)
            except Exception:
                current_num = 0
            try:
                next_num = int(value or 0)
            except Exception:
                next_num = 0
            if next_num != 0 or current_num == 0:
                updated[key] = value
            continue
        if value is not None:
            updated[key] = value
    return updated


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


def utc_now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def month_start_iso():
    return time.strftime("%Y-%m-01T00:00:00Z", time.gmtime())


def normalize_cycle_mode(value):
    value = str(value or "").strip().lower()
    return value if value == "rolling_30_days" else "day_of_month"


def normalize_plan_kind(value):
    value = str(value or "").strip().lower()
    return value if value == "unlimited" else "metered"


def parse_float_or_none(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except Exception:
        return None


def parse_int_or_none(value):
    if value is None or value == "":
        return None
    try:
        return int(value)
    except Exception:
        return None


def modem_usage_key(node_id, modem_id="", imei=""):
    node_id = str(node_id or "").strip()
    imei = normalize_digits(imei)
    modem_id = str(modem_id or "").strip()
    if node_id and imei:
        return f"{node_id}:imei:{imei}"
    if node_id and modem_id:
        return f"{node_id}:id:{modem_id}"
    return ""


def read_local_modem_usage_state():
    try:
        with open(LOCAL_MODEM_USAGE_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}
    modems = data.get("modems")
    if not isinstance(modems, dict):
        modems = {}
    data["version"] = 1
    data["modems"] = modems
    return data


def write_local_modem_usage_state(state):
    os.makedirs(os.path.dirname(LOCAL_MODEM_USAGE_PATH), exist_ok=True)
    tmp = f"{LOCAL_MODEM_USAGE_PATH}.tmp.{int(time.time() * 1000000)}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, LOCAL_MODEM_USAGE_PATH)


def live_modem_identity(modem):
    if not isinstance(modem, dict):
        return "", "", "", 0
    node_id = str(modem.get("node_id") or read_local_node_id() or "").strip()
    modem_id = str(modem.get("id") or modem.get("modem_id") or "").strip()
    imei = normalize_digits(modem.get("imei"))
    try:
        ordinal = int(modem.get("modem_number") or modem.get("ordinal") or 0)
    except Exception:
        ordinal = 0
    return node_id, modem_id, imei, ordinal


def find_live_modem(overview, node_id, modem_id):
    for modem in (overview.get("modems") or []):
        if not isinstance(modem, dict):
            continue
        if str(modem.get("node_id") or "").strip() == node_id and str(modem.get("id") or "").strip() == modem_id:
            return modem
    for node in (overview.get("nodes") or []):
        if not isinstance(node, dict) or str(node.get("node_id") or "").strip() != node_id:
            continue
        for modem in (node.get("modems") or []):
            if isinstance(modem, dict) and str(modem.get("id") or "").strip() == modem_id:
                item = dict(modem)
                item["node_id"] = node_id
                return item
    return {}


def ensure_usage_record(state, modem):
    node_id, modem_id, imei, ordinal = live_modem_identity(modem)
    key = modem_usage_key(node_id, modem_id, imei)
    if not key:
        return None
    records = state.setdefault("modems", {})
    record = records.get(key)
    if not isinstance(record, dict):
        record = {
            "key": key,
            "node_id": node_id,
            "modem_id": modem_id,
            "plan_kind": "metered",
            "cycle_mode": "day_of_month",
            "cycle_anchor_at": month_start_iso(),
            "cycle_start_at": month_start_iso(),
            "cycle_used_bytes": int(modem.get("cycle_used_bytes") or 0),
            "traffic_bytes_in": int(modem.get("traffic_bytes_in") or 0),
            "traffic_bytes_out": int(modem.get("traffic_bytes_out") or 0),
            "traffic_source": str(modem.get("traffic_source") or "").strip(),
            "quota_exhausted": bool(modem.get("quota_exhausted")),
            "updated_at": utc_now_iso(),
        }
        records[key] = record
    record["key"] = key
    record["node_id"] = node_id
    record["modem_id"] = modem_id
    record["modem_ordinal"] = ordinal
    if imei:
        record["imei"] = imei
    if str(modem.get("iccid") or "").strip():
        record["iccid"] = str(modem.get("iccid") or "").strip()
    if str(modem.get("local_interface") or "").strip():
        record["local_interface"] = str(modem.get("local_interface") or "").strip()
    record["plan_kind"] = normalize_plan_kind(record.get("plan_kind"))
    record["cycle_mode"] = normalize_cycle_mode(record.get("cycle_mode"))
    if not str(record.get("cycle_anchor_at") or "").strip():
        record["cycle_anchor_at"] = month_start_iso()
    if not str(record.get("cycle_start_at") or "").strip():
        record["cycle_start_at"] = record["cycle_anchor_at"]
    return record


def cycle_limit_bytes(record):
    if normalize_plan_kind(record.get("plan_kind")) == "unlimited":
        return 0
    limit = parse_float_or_none(record.get("traffic_limit_gb"))
    if not limit or limit <= 0:
        return 0
    return int(limit * 1024 * 1024 * 1024)


def apply_usage_record_to_modem(modem, record):
    if not isinstance(modem, dict) or not isinstance(record, dict):
        return modem
    source = str(record.get("traffic_source") or modem.get("traffic_source") or "").strip()
    if source == "interface_counters" and (
        str(modem.get("usb_mode") or "").strip().lower() == "hilink"
        or str(modem.get("local_base_url") or "").strip()
        or "hilink" in str(modem.get("id") or "").strip().lower()
    ):
        record["legacy_interface_cycle_used_bytes"] = int(record.get("legacy_interface_cycle_used_bytes") or record.get("cycle_used_bytes") or 0)
        record["cycle_used_bytes"] = 0
        record["traffic_bytes_in"] = 0
        record["traffic_bytes_out"] = 0
        record["proxy_client_bytes"] = 0
        record["traffic_source"] = "rebaseline_pending"
        record["quota_exhausted"] = False
        record["quota_block_reason"] = ""
    used = int(record.get("cycle_used_bytes") or 0)
    limit = cycle_limit_bytes(record)
    exhausted = bool(record.get("quota_exhausted")) or (limit > 0 and used >= limit)
    modem["traffic_bytes_in"] = int(record.get("traffic_bytes_in") or 0)
    modem["traffic_bytes_out"] = int(record.get("traffic_bytes_out") or 0)
    modem["cycle_used_bytes"] = used
    modem["proxy_client_bytes"] = int(record.get("proxy_client_bytes") or 0)
    modem["hilink_wan_bytes"] = int(record.get("hilink_wan_bytes") or 0)
    modem["local_interface_bytes"] = int(record.get("local_interface_bytes") or 0)
    modem["unattributed_wan_bytes"] = int(record.get("unattributed_wan_bytes") or 0)
    modem["legacy_interface_cycle_used_bytes"] = int(record.get("legacy_interface_cycle_used_bytes") or 0)
    modem["cycle_limit_bytes"] = limit
    modem["cycle_mode"] = normalize_cycle_mode(record.get("cycle_mode"))
    modem["cycle_start_at"] = record.get("cycle_start_at") or record.get("cycle_anchor_at") or ""
    modem["next_reset_at"] = record.get("next_reset_at") or ""
    modem["remaining_bytes"] = (limit - used) if limit > 0 else None
    modem["quota_exhausted"] = exhausted
    modem["quota_block_reason"] = record.get("quota_block_reason") or ("traffic quota exhausted" if exhausted else "")
    modem["traffic_source"] = record.get("traffic_source") or ""
    modem["traffic_sampled_at"] = record.get("last_hilink_sample_at") or record.get("last_counter_sample_at") or record.get("traffic_sampled_at") or ""
    if exhausted:
        modem["client_eligible"] = False
    return modem


def apply_local_usage_to_overview(overview):
    if not isinstance(overview, dict):
        return overview
    state = read_local_modem_usage_state()
    initial_usage_keys = set((state.get("modems") or {}).keys())
    for modem in overview.get("modems", []) or []:
        if not isinstance(modem, dict):
            continue
        record = ensure_usage_record(state, modem)
        if record:
            apply_usage_record_to_modem(modem, record)
    by_key = {}
    for modem in overview.get("modems", []) or []:
        if isinstance(modem, dict):
            node_id, modem_id, imei, _ = live_modem_identity(modem)
            for key in (modem_usage_key(node_id, modem_id, imei), f"{node_id}:{modem_id}"):
                if key:
                    by_key[key] = modem
    for node in overview.get("nodes", []) or []:
        if not isinstance(node, dict):
            continue
        node_id = str(node.get("node_id") or "").strip()
        for modem in node.get("modems", []) or []:
            if not isinstance(modem, dict):
                continue
            modem.setdefault("node_id", node_id)
            record = ensure_usage_record(state, modem)
            if record:
                apply_usage_record_to_modem(modem, record)
            key = modem_usage_key(node_id, modem.get("id"), modem.get("imei"))
            if key and key in by_key:
                by_key[key].update({k: v for k, v in modem.items() if k.startswith("cycle_") or k.startswith("quota_") or k in ("traffic_bytes_in", "traffic_bytes_out", "proxy_client_bytes", "hilink_wan_bytes", "local_interface_bytes", "unattributed_wan_bytes", "legacy_interface_cycle_used_bytes", "remaining_bytes", "client_eligible", "traffic_source", "traffic_sampled_at")})
    if set((state.get("modems") or {}).keys()) != initial_usage_keys:
        try:
            write_local_modem_usage_state(state)
        except Exception as err:
            ui_log("failed to persist local modem usage state", error=str(err))
    return overview


def build_local_modem_billing(overview):
    state = read_local_modem_usage_state()
    items = []
    for modem in overview.get("modems", []) or []:
        if not isinstance(modem, dict):
            continue
        record = ensure_usage_record(state, modem)
        if not record:
            continue
        used = int(record.get("cycle_used_bytes") or modem.get("cycle_used_bytes") or 0)
        limit = cycle_limit_bytes(record)
        remaining = (limit - used) if limit > 0 else None
        exhausted = bool(record.get("quota_exhausted")) or (limit > 0 and used >= limit)
        items.append({
            "key": record.get("key"),
            "node_id": record.get("node_id"),
            "modem_id": record.get("modem_id"),
            "modem_ordinal": int(record.get("modem_ordinal") or modem.get("modem_number") or modem.get("ordinal") or 0),
            "imei": record.get("imei") or normalize_digits(modem.get("imei")),
            "iccid": record.get("iccid") or modem.get("iccid") or "",
            "plan_kind": normalize_plan_kind(record.get("plan_kind")),
            "traffic_limit_gb": record.get("traffic_limit_gb"),
            "cycle_mode": normalize_cycle_mode(record.get("cycle_mode")),
            "auto_reset_day": record.get("auto_reset_day"),
            "cycle_anchor_at": record.get("cycle_anchor_at") or "",
            "last_manual_reset_at": record.get("last_manual_reset_at") or "",
            "notes": record.get("notes") or "",
            "cycle_start_at": record.get("cycle_start_at") or record.get("cycle_anchor_at") or "",
            "next_reset_at": record.get("next_reset_at") or "",
            "cycle_used_bytes": used,
            "cycle_limit_bytes": limit,
            "proxy_client_bytes": int(record.get("proxy_client_bytes") or 0),
            "hilink_wan_bytes": int(record.get("hilink_wan_bytes") or 0),
            "local_interface_bytes": int(record.get("local_interface_bytes") or 0),
            "unattributed_wan_bytes": int(record.get("unattributed_wan_bytes") or 0),
            "legacy_interface_cycle_used_bytes": int(record.get("legacy_interface_cycle_used_bytes") or 0),
            "remaining_bytes": remaining,
            "quota_exhausted": exhausted,
            "quota_block_reason": record.get("quota_block_reason") or ("traffic quota exhausted" if exhausted else ""),
            "traffic_source": record.get("traffic_source") or "",
            "traffic_sampled_at": record.get("last_hilink_sample_at") or record.get("last_counter_sample_at") or record.get("traffic_sampled_at") or "",
            "sim_needs_check": bool(modem.get("sim_needs_check")),
            "sim_quarantined": bool(modem.get("sim_quarantined")),
            "sim_check_status": modem.get("sim_check_status") or "",
            "sim_quarantine_note": modem.get("sim_quarantine_note") or "",
            "sim_degraded_events_24h": int(modem.get("sim_degraded_events_24h") or 0),
            "sim_last_checked_at": modem.get("sim_last_checked_at") or "",
        })
    try:
        write_local_modem_usage_state(state)
    except Exception as err:
        ui_log("failed to persist local modem billing state", error=str(err))
    items.sort(key=lambda item: (str(item.get("node_id") or ""), int(item.get("modem_ordinal") or 0), str(item.get("modem_id") or "")))
    return {"partner_key": PARTNER_KEY, "modems": items, "count": len(items), "source": "local_node"}


def update_local_modem_billing(req):
    overview = fetch_overview()
    state = read_local_modem_usage_state()
    node_id = str(req.get("node_id") or "").strip()
    modem_id = str(req.get("modem_id") or "").strip()
    live = find_live_modem(overview, node_id, modem_id)
    if not live:
        live = {"node_id": node_id, "id": modem_id}
    record = ensure_usage_record(state, live)
    if not record:
        raise ValueError("node_id and modem_id are required")

    plan_kind = normalize_plan_kind(req.get("plan_kind") or record.get("plan_kind"))
    record["plan_kind"] = plan_kind
    if plan_kind == "unlimited":
        record.pop("traffic_limit_gb", None)
    else:
        limit = parse_float_or_none(req.get("traffic_limit_gb"))
        if limit is None:
            record.pop("traffic_limit_gb", None)
        else:
            record["traffic_limit_gb"] = limit
    record["cycle_mode"] = normalize_cycle_mode(req.get("cycle_mode") or record.get("cycle_mode"))
    auto_reset_day = parse_int_or_none(req.get("auto_reset_day"))
    if auto_reset_day is None:
        record.pop("auto_reset_day", None)
    else:
        record["auto_reset_day"] = max(1, min(31, auto_reset_day))
    record["notes"] = str(req.get("notes") or "").strip()
    if req.get("manual_reset"):
        now = utc_now_iso()
        record["cycle_anchor_at"] = now
        record["cycle_start_at"] = now
        record["last_manual_reset_at"] = now
        record["cycle_used_bytes"] = 0
        record["traffic_bytes_in"] = 0
        record["traffic_bytes_out"] = 0
        record["proxy_client_bytes"] = 0
        record["unattributed_wan_bytes"] = 0
        record.pop("last_counter_sample_at", None)
        record.pop("last_rx_bytes", None)
        record.pop("last_tx_bytes", None)
        record.pop("last_hilink_sample_at", None)
        record.pop("last_hilink_wan_bytes_in", None)
        record.pop("last_hilink_wan_bytes_out", None)
    limit = cycle_limit_bytes(record)
    used = int(record.get("cycle_used_bytes") or 0)
    exhausted = limit > 0 and used >= limit
    record["quota_exhausted"] = exhausted
    record["quota_block_reason"] = "traffic quota exhausted" if exhausted else ""
    record["updated_at"] = utc_now_iso()
    write_local_modem_usage_state(state)

    mirror = dict(req)
    mirror["partner_key"] = PARTNER_KEY
    mirror["cycle_mode"] = record["cycle_mode"]
    try:
        json_request(f"{MAIN_SERVER}/api/partner/modem-billing", method="POST", payload=mirror)
    except Exception as err:
        ui_log("main modem billing mirror failed", error=str(err))
    return build_local_modem_billing(apply_local_usage_to_overview(overview))


def merge_local_registry_entries(overview):
    if not isinstance(overview, dict):
        return overview

    node_id = read_local_node_id().strip()
    if not node_id:
        node_id = str(overview.get("node_id") or "").strip()
    if not node_id:
        return overview

    by_stable_key, flashed = load_local_modem_registry()
    registry_items = overview.get("modem_registry")
    if not isinstance(registry_items, list):
        registry_items = []
        overview["modem_registry"] = registry_items

    existing = set()
    for item in registry_items:
        if not isinstance(item, dict):
            continue
        item_node = str(item.get("node_id") or item.get("last_seen_node_id") or "").strip()
        item_imei = normalize_digits(item.get("imei"))
        if item_node and item_imei:
            existing.add(f"{item_node}:{item_imei}")

    changed = False
    for stable_key, raw_number in by_stable_key.items():
        stable_key = str(stable_key or "").strip()
        if not stable_key.startswith("imei:"):
            continue
        imei = normalize_digits(stable_key.split(":", 1)[1])
        if not imei:
            continue
        registry_key = f"{node_id}:{imei}"
        if registry_key in existing:
            continue
        try:
            modem_number = int(raw_number or 0)
        except Exception:
            modem_number = 0
        is_ready = bool(flashed.get(stable_key))
        registry_items.append({
            "node_id": node_id,
            "imei": imei,
            "modem_number": modem_number,
            "provision_status": "ready" if is_ready else "requires_flash",
            "provision_notes": "known modem for this node" if is_ready else "new modem assigned to this node; flash required",
            "device_name": "E3372",
            "software_version": TARGET_MAIN_VERSION if is_ready else "",
            "webui_version": TARGET_WEBUI_LABEL if is_ready else "",
            "last_seen_node_id": node_id,
            "last_seen_modem_id": "",
            "last_seen_at": "",
        })
        existing.add(registry_key)
        changed = True

    if changed:
        registry_items.sort(key=lambda item: (
            str(item.get("node_id") or item.get("last_seen_node_id") or "").strip(),
            int(item.get("modem_number") or 0),
            normalize_digits(item.get("imei")),
        ))
    return overview


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


def load_local_flash_notice():
    try:
        with open(LOCAL_FLASH_NOTICE_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
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


def reset_overview_cache():
    with OVERVIEW_CACHE_LOCK:
        OVERVIEW_CACHE["data"] = {
            "partner_key": PARTNER_KEY,
            "main_server": MAIN_SERVER,
            "nodes": [],
            "modems": [],
            "modem_registry": [],
        }
        OVERVIEW_CACHE["updated_at"] = 0.0
        OVERVIEW_CACHE["refreshing"] = False
        OVERVIEW_CACHE["error"] = ""


def clear_local_modem_state_files():
    removed = []
    for path in LOCAL_MODEM_STATE_PATHS:
        path = str(path or "").strip()
        if not path:
            continue
        try:
            os.remove(path)
            removed.append(path)
        except FileNotFoundError:
            continue
        except Exception as err:
            raise RuntimeError(f"failed to remove {path}: {err}") from err
    return removed


def best_effort_reset_server_node_registry():
    node_id = read_local_node_id()
    if not PARTNER_KEY or not MAIN_SERVER or not node_id:
        return False
    try:
        json_request(
            f"{MAIN_SERVER}/api/partner/reset-node",
            method="POST",
            payload={"partner_key": PARTNER_KEY, "node_id": node_id},
        )
        return True
    except Exception as err:
        ui_log("server-side modem registry reset failed", node_id=node_id, error=str(err))
        return False


def run_systemctl(*args):
    result = subprocess.run(
        ["systemctl", *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=40,
    )
    if result.returncode != 0:
        stderr = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(f"failed to run systemctl {' '.join(args)}: {stderr or result.returncode}")


def restart_partner_node_service():
    run_systemctl("restart", "partner-node")


def stop_partner_node_service():
    run_systemctl("stop", "partner-node")


def start_partner_node_service():
    run_systemctl("start", "partner-node")


def reset_local_modem_state():
    stop_partner_node_service()
    removed = clear_local_modem_state_files()
    server_reset = best_effort_reset_server_node_registry()
    start_partner_node_service()
    reset_overview_cache()
    schedule_overview_refresh()
    return {
        "ok": True,
        "node_id": read_local_node_id(),
        "removed_files": removed,
        "server_registry_reset": server_reset,
        "restarted_service": "partner-node",
    }


def local_update_already_running():
    update_marker = str(UPDATE_SCRIPT_URL or "").strip() or "partner-node-installer/main/scripts/update.sh"
    try:
        result = subprocess.run(
            ["pgrep", "-af", update_marker],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        for line in (result.stdout or "").splitlines():
            line = line.strip()
            if not line:
                continue
            if update_marker in line:
                return True
    except Exception:
        return False
    return False


def start_local_update():
    update_url = str(UPDATE_SCRIPT_URL or "").strip()
    if not update_url:
        raise RuntimeError("update script url is empty")
    if local_update_already_running():
        return {
            "ok": True,
            "started": False,
            "already_running": True,
            "update_url": update_url,
            "log_path": UPDATE_HELPER_LOG,
            "message": "node update is already running",
        }

    log_path = str(UPDATE_HELPER_LOG or "").strip() or "/tmp/partner-node-update.log"
    log_dir = os.path.dirname(log_path)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    log_handle = open(log_path, "ab", buffering=0)
    command = f"exec curl -fsSL {shlex.quote(update_url)} | /bin/bash"
    subprocess.Popen(
        ["/bin/bash", "-lc", command],
        cwd="/",
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    reset_overview_cache()
    schedule_overview_refresh()
    return {
        "ok": True,
        "started": True,
        "already_running": False,
        "update_url": update_url,
        "log_path": log_path,
        "message": "node update started; partner services may restart for 10-30 seconds",
    }


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


def local_ipv4_interfaces():
    interfaces = []
    seen = set()
    try:
        ip_out = subprocess.run(
            ["ip", "-o", "-4", "addr", "show"],
            capture_output=True,
            text=True,
            check=False,
        )
        for line in (ip_out.stdout or "").splitlines():
            line = line.strip()
            if not line or not line[0].isdigit():
                continue
            parts = line.split()
            if len(parts) < 4:
                continue
            name = str(parts[1] or "").strip()
            cidr = str(parts[3] or "").strip()
            ip = cidr.split("/", 1)[0].strip()
            if not name.startswith(LOCAL_HILINK_IFACE_PREFIXES):
                continue
            octets = ip.split(".")
            if len(octets) != 4 or octets[0] != "192" or octets[1] != "168":
                continue
            key = (name, ip)
            if key in seen:
                continue
            seen.add(key)
            interfaces.append({
                "name": name,
                "ip": ip,
                "base_url": f"http://{octets[0]}.{octets[1]}.{octets[2]}.1",
            })
    except Exception:
        pass
    return interfaces


def local_hilink_runtime_candidates():
    candidates = []
    seen = set()

    def add(base_url, interface_name="", interface_ip=""):
        base_url = str(base_url or "").strip().rstrip("/")
        if not base_url or base_url in seen:
            return
        seen.add(base_url)
        candidates.append({
            "base_url": base_url,
            "local_interface": str(interface_name or "").strip(),
            "local_ip": str(interface_ip or "").strip(),
        })

    for iface in local_ipv4_interfaces():
        add(iface.get("base_url"), iface.get("name"), iface.get("ip"))

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


def local_hilink_base_candidates():
    return [item.get("base_url", "") for item in local_hilink_runtime_candidates()]


def detect_local_huawei_hilink_placeholders():
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
            return []
    except Exception:
        return []

    placeholders = []
    runtime_candidates = local_hilink_runtime_candidates()
    for candidate in runtime_candidates:
        iface_name = str(candidate.get("local_interface") or "").strip()
        iface_ip = str(candidate.get("local_ip") or "").strip()
        base_url = str(candidate.get("base_url") or "").strip().rstrip("/")
        modem_id = f"hilink-{iface_name}" if iface_name else "hilink0"
        placeholders.append({
            "id": modem_id,
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
            "port": 0,
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
            "local_ip": iface_ip,
        })

    if placeholders:
        return placeholders

    return [{
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
        "port": 0,
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
        "local_base_url": "",
        "local_interface": "",
        "local_ip": "",
    }]


def detect_local_live_modems(node_id, registry_by_node_imei, by_stable_key, flashed):
    modems = []
    seen = set()
    for candidate in local_hilink_runtime_candidates():
        base_url = str(candidate.get("base_url") or "").strip().rstrip("/")
        info = read_hilink_device_info(base_url)
        if not info:
            continue

        iface_name = str(candidate.get("local_interface") or info.get("local_interface") or "").strip()
        iface_ip = str(candidate.get("local_ip") or info.get("local_ip") or "").strip()
        modem_id = f"hilink-{iface_name}" if iface_name else "hilink0"
        imei = normalize_digits(info.get("imei"))
        stable_key = f"imei:{imei}" if imei else ""
        dedupe_key = f"{node_id}:{imei or modem_id}:{base_url}"
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)

        registry_item = registry_by_node_imei.get(f"{node_id}:{imei}") if node_id and imei else None
        local_number = int(by_stable_key.get(stable_key) or 0) if stable_key else 0
        local_flashed = bool(flashed.get(stable_key)) if stable_key else False
        modem_number = int(registry_item.get("modem_number") or 0) if registry_item else local_number
        provision_status = "ready" if local_flashed else "requires_flash"
        provision_notes = "known modem for this node" if local_flashed or local_number > 0 else "new modem for this node"

        modem = {
            "id": modem_id,
            "ordinal": modem_number if modem_number > 0 else 0,
            "modem_number": modem_number,
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
            "port": (31000 + modem_number) if modem_number > 0 else 0,
            "client_eligible": True,
            "traffic_bytes_in": 0,
            "traffic_bytes_out": 0,
            "flash_status": "",
            "flash_stage": "",
            "flash_message": "",
            "provision_status": provision_status,
            "provision_notes": provision_notes,
            "last_seen_node_id": node_id,
            "last_seen_modem_id": modem_id,
            "local_base_url": base_url,
            "local_interface": iface_name,
            "local_ip": iface_ip,
        }
        modem.update(info)
        if iface_name:
            modem["id"] = modem_id
            modem["last_seen_modem_id"] = modem_id
        modems.append(modem)

    if modems:
        return modems

    placeholders = detect_local_huawei_hilink_placeholders()
    for placeholder in placeholders:
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
        placeholder["last_seen_modem_id"] = placeholder.get("id") or "hilink0"
        placeholder["known_to_node"] = False
        placeholder["local_flashed"] = False
    return placeholders


def local_modem_hints_from_state(node_id, by_stable_key, flashed):
    hints = []
    notice = load_local_flash_notice()
    if isinstance(notice, dict):
        modem_id = str(notice.get("modem_id") or "").strip()
        imei = normalize_digits(notice.get("imei"))
        stable_key = f"imei:{imei}" if imei else ""
        ordinal = int(notice.get("ordinal") or 0)
        status = str(notice.get("status") or "").strip().lower()
        completed = status == "completed"
        local_flashed = completed or bool(flashed.get(stable_key)) if stable_key else completed
        if modem_id or imei or ordinal > 0:
            hints.append({
                "id": modem_id or (f"hilink-{ordinal}" if ordinal > 0 else "hilink0"),
                "ordinal": ordinal,
                "modem_number": ordinal,
                "local_modem_number": int(by_stable_key.get(stable_key) or ordinal or 0) if stable_key else ordinal,
                "known_to_node": bool(ordinal > 0 or stable_key in by_stable_key),
                "local_flashed": local_flashed,
                "node_id": node_id,
                "node_status": "online",
                "usb_vendor_id": "12d1",
                "usb_product_id": "",
                "usb_mode": "hilink",
                "state": "ready" if completed else "detected",
                "imei": imei,
                "wan_ip": "",
                "signal_strength": 0,
                "operator": "",
                "technology": "",
                "active_sessions": 0,
                "port": (31000 + ordinal) if ordinal > 0 else 0,
                "client_eligible": True,
                "traffic_bytes_in": 0,
                "traffic_bytes_out": 0,
                "flash_status": "done" if completed else status,
                "flash_stage": "completed" if completed else status,
                "flash_message": str(notice.get("message") or "").strip(),
                "provision_status": "ready" if local_flashed else "requires_flash",
                "provision_notes": str(notice.get("message") or "").strip() or "local modem state detected",
                "last_seen_node_id": node_id,
                "last_seen_modem_id": modem_id or "hilink0",
                "local_modem_detected": True,
            })
    return hints


def modem_identity_key(modem, fallback_node_id=""):
    if not isinstance(modem, dict):
        return ""
    node_id = str(modem.get("node_id") or fallback_node_id or "").strip()
    imei = normalize_digits(modem.get("imei"))
    if node_id and imei:
        return f"{node_id}:{imei}"
    modem_id = str(modem.get("id") or "").strip()
    if node_id and modem_id:
        return f"{node_id}:{modem_id}"
    if imei:
        return f"imei:{imei}"
    if modem_id:
        return f"id:{modem_id}"
    return ""


def modem_state_rank(value):
    state = str(value or "").strip().lower()
    if state == "ready":
        return 5
    if state == "degraded":
        return 4
    if state == "detected":
        return 3
    if state in ("queued", "running", "verify"):
        return 2
    if state == "offline":
        return 1
    return 0


def modem_runtime_score(modem):
    if not isinstance(modem, dict):
        return 0
    score = 0
    for field in ("wan_ip", "operator", "technology", "imei", "iccid", "local_base_url", "software_version", "webui_version"):
        if str(modem.get(field) or "").strip():
            score += 1
    for field in ("signal_strength", "port", "active_sessions", "traffic_bytes_in", "traffic_bytes_out", "ordinal", "modem_number"):
        try:
            if int(modem.get(field) or 0) != 0:
                score += 1
        except Exception:
            pass
    return score


def merge_modem_snapshots(current, candidate):
    preferred, secondary = current, candidate
    current_rank = modem_state_rank(current.get("state"))
    candidate_rank = modem_state_rank(candidate.get("state"))
    if candidate_rank > current_rank:
        preferred, secondary = candidate, current
    elif candidate_rank == current_rank:
        current_score = modem_runtime_score(current)
        candidate_score = modem_runtime_score(candidate)
        if candidate_score > current_score:
            preferred, secondary = candidate, current
        elif candidate_score == current_score:
            candidate_ordinal = int(candidate.get("ordinal") or 0)
            current_ordinal = int(current.get("ordinal") or 0)
            if candidate_ordinal > 0 and current_ordinal > 0 and candidate_ordinal < current_ordinal:
                preferred, secondary = candidate, current

    merged = dict(secondary or {})
    merged.update(preferred or {})
    for field in ("wan_ip", "operator", "technology", "imei", "iccid", "local_base_url", "software_version", "webui_version", "hardware_version", "device_name", "usb_mode"):
        if not str(merged.get(field) or "").strip() and str(secondary.get(field) or "").strip():
            merged[field] = secondary.get(field)
    for field in ("signal_strength", "port", "active_sessions", "traffic_bytes_in", "traffic_bytes_out", "ordinal", "modem_number"):
        try:
            if int(merged.get(field) or 0) == 0 and int(secondary.get(field) or 0) != 0:
                merged[field] = secondary.get(field)
        except Exception:
            pass
    return merged


def dedupe_modem_rows(modems, fallback_node_id=""):
    if not isinstance(modems, list) or not modems:
        return []
    deduped = []
    index_by_key = {}
    for modem in modems:
        if not isinstance(modem, dict):
            continue
        item = dict(modem)
        if fallback_node_id and not str(item.get("node_id") or "").strip():
            item["node_id"] = fallback_node_id
        key = modem_identity_key(item, fallback_node_id)
        if not key:
            deduped.append(item)
            continue
        if key in index_by_key:
            deduped[index_by_key[key]] = merge_modem_snapshots(deduped[index_by_key[key]], item)
            continue
        index_by_key[key] = len(deduped)
        deduped.append(item)
    return deduped


def finalize_overview_shape(overview):
    overview.setdefault("partner_key", PARTNER_KEY)
    overview.setdefault("main_server", MAIN_SERVER)
    overview.setdefault("nodes", [])
    overview.setdefault("modems", [])
    overview.setdefault("modem_registry", [])
    overview.setdefault("flash_job", {})
    overview.setdefault("flash_notice", {})
    nodes = overview.get("nodes") or []
    modems = overview.get("modems") or []
    for node in nodes:
        if not isinstance(node, dict):
            continue
        node_id = str(node.get("node_id") or "").strip()
        node["modems"] = dedupe_modem_rows(node.get("modems") or [], node_id)
    modems = dedupe_modem_rows(modems or [])
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
            modems = dedupe_modem_rows(flattened)
    overview["modems"] = modems
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
    notice = load_local_flash_notice()
    job_status = str((job or {}).get("status") or "").strip().lower()
    if job_status not in ("queued", "running"):
        job = None
    overview["flash_job"] = job or {}
    overview["flash_notice"] = notice or {}
    if isinstance(notice, dict) and notice:
        overview["local_modem_detected"] = True
        overview["local_modem_status"] = str(notice.get("status") or "").strip()
        overview["local_modem_message"] = str(notice.get("message") or "").strip()

    for modem in overview.get("modems", []) or []:
        if not isinstance(modem, dict):
            continue
        modem["flash_status"] = ""
        modem["flash_stage"] = ""
        modem["flash_message"] = ""
    for node in overview.get("nodes", []) or []:
        if not isinstance(node, dict):
            continue
        for modem in node.get("modems", []) or []:
            if not isinstance(modem, dict):
                continue
            modem["flash_status"] = ""
            modem["flash_stage"] = ""
            modem["flash_message"] = ""

    if not isinstance(job, dict):
        return overview

    job_status = str(job.get("status") or "").strip().lower()
    job_stage = str(job.get("stage") or "").strip().lower()
    flash_status = "running" if job_status not in ("queued",) else "queued"
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


def probe_hilink_device_info(base_url):
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
        cookie = ses_match.group(1).strip()
        token = tok_match.group(1).strip()
        text = curl_fetch_text(f"{base_url}/api/device/information", cookie, token)
        if not text:
            text = curl_fetch_text(f"{base_url}/api/device/information")
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
            ("WanIPAddress", "wan_ip"),
        ):
            value = xml_tag_text(text, tag)
            if value:
                fields[key] = value
        signal_text = curl_fetch_text(f"{base_url}/api/device/signal", cookie, token)
        if not signal_text or "<error>" in signal_text:
            signal_text = curl_fetch_text(f"{base_url}/api/device/signal")
        if signal_text and "<error>" not in signal_text:
            signal_strength = first_int_from_text(xml_tag_text(signal_text, "Rsrp"))
            if signal_strength == 0:
                signal_strength = first_int_from_text(xml_tag_text(signal_text, "Rssi"))
            if signal_strength != 0:
                fields["signal_strength"] = signal_strength
            mode = signal_mode_to_label(xml_tag_text(signal_text, "Mode"))
            if mode:
                fields["technology"] = mode
        operator_text = curl_fetch_text(f"{base_url}/operator.cgi", cookie, token)
        if not operator_text or "<error>" in operator_text:
            operator_text = curl_fetch_text(f"{base_url}/operator.cgi")
        operator = xml_tag_text(operator_text, "FullName")
        if operator:
            fields["operator"] = operator
        fields["local_base_url"] = base_url
        result = fields if fields else None
    except Exception:
        result = None
    return result


def schedule_hilink_info_refresh(base_url):
    base_url = str(base_url or "").strip().rstrip("/")
    if not base_url:
        return
    with HILINK_INFO_CACHE_LOCK:
        cached = HILINK_INFO_CACHE.get(base_url) or {}
        if cached.get("refreshing"):
            return
        cached["refreshing"] = True
        HILINK_INFO_CACHE[base_url] = cached

    def worker():
        result = probe_hilink_device_info(base_url)
        with HILINK_INFO_CACHE_LOCK:
            HILINK_INFO_CACHE[base_url] = {
                "ts": time.time(),
                "data": copy.deepcopy(result) if isinstance(result, dict) else None,
                "refreshing": False,
            }

    threading.Thread(target=worker, daemon=True).start()


def read_hilink_device_info(base_url):
    base_url = str(base_url or "").strip().rstrip("/")
    if not base_url:
        return None
    now = time.time()
    with HILINK_INFO_CACHE_LOCK:
        cached = HILINK_INFO_CACHE.get(base_url)
        if cached:
            data = cached.get("data")
            age = now - float(cached.get("ts") or 0.0)
            if age <= HILINK_INFO_CACHE_TTL and isinstance(data, dict):
                return copy.deepcopy(data)
            if age <= HILINK_INFO_STALE_TTL and isinstance(data, dict):
                if not cached.get("refreshing"):
                    cached["refreshing"] = True
                    HILINK_INFO_CACHE[base_url] = cached

                    def stale_worker():
                        result = probe_hilink_device_info(base_url)
                        with HILINK_INFO_CACHE_LOCK:
                            HILINK_INFO_CACHE[base_url] = {
                                "ts": time.time(),
                                "data": copy.deepcopy(result) if isinstance(result, dict) else None,
                                "refreshing": False,
                            }

                    threading.Thread(target=stale_worker, daemon=True).start()
                return copy.deepcopy(data)
    schedule_hilink_info_refresh(base_url)
    return None


def enrich_overview_with_local_modem_state(overview):
    if not isinstance(overview, dict):
        return overview

    merge_local_registry_entries(overview)
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
            for field in ("wan_ip", "operator", "technology", "local_interface", "local_ip"):
                if str(info.get(field) or "").strip():
                    modem[field] = info[field]
            for field in ("signal_strength", "active_sessions"):
                try:
                    value = int(info.get(field) or 0)
                except Exception:
                    value = 0
                if value != 0:
                    modem[field] = value

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
            modem["modem_number"] = local_number
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
            if not flash_still_running and str(modem.get("flash_status") or "").strip().lower() in ("done", "failed"):
                modem["flash_status"] = ""
                modem["flash_stage"] = ""
                modem["flash_message"] = ""
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
    modem_map_by_imei = {}
    for modem in top_level:
        if isinstance(modem, dict):
            modem_map[f"{modem.get('node_id','')}:{modem.get('id','')}"] = modem
            imei = normalize_digits(modem.get("imei"))
            if imei:
                modem_map_by_imei[f"{modem.get('node_id','')}:{imei}"] = modem

    for node in overview.get("nodes", []) or []:
        if not isinstance(node, dict):
            continue
        enriched = []
        node_id = str(node.get("node_id") or "")
        for modem in node.get("modems", []) or []:
            imei_key = f"{node_id}:{normalize_digits(modem.get('imei'))}" if isinstance(modem, dict) and normalize_digits(modem.get("imei")) else ""
            key = f"{node_id}:{modem.get('id','')}" if isinstance(modem, dict) else ""
            if imei_key and imei_key in modem_map_by_imei:
                merged = dict(modem)
                merged.update(modem_map_by_imei[imei_key])
                enriched.append(merged)
            elif key and key in modem_map:
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

    local_status = str(overview.get("node_status") or "").strip() or current_local_node_status()
    local_modems = local_modem_hints_from_state(node_id, by_stable_key, flashed)
    if LOCAL_MODEM_PROBES_ENABLED:
        local_modems.extend(detect_local_live_modems(node_id, registry_by_node_imei, by_stable_key, flashed))

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

    if not local_modems:
        return finalize_overview_shape(overview)

    if not node_id:
        node_id = str(local_modems[0].get("node_id") or overview.get("node_id") or "local-node").strip()
        for local_modem in local_modems:
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

    def same_modem(item, local_modem):
        if not isinstance(item, dict):
            return False
        item_node = str(item.get("node_id") or "").strip()
        local_imei = normalize_digits(local_modem.get("imei"))
        item_imei = normalize_digits(item.get("imei"))
        local_id = str(local_modem.get("id") or "").strip()
        item_id = str(item.get("id") or "").strip()
        local_base = str(local_modem.get("local_base_url") or "").strip().rstrip("/")
        item_base = str(item.get("local_base_url") or "").strip().rstrip("/")
        if item_node != node_id:
            return False
        if local_imei and item_imei:
            return local_imei == item_imei
        if local_base and item_base and local_base == item_base:
            return True
        if local_id and item_id and local_id == item_id:
            return True
        return False

    node_modems = node_entry.setdefault("modems", [])
    for local_modem in local_modems:
        merged = False
        for idx, item in enumerate(modems):
            if same_modem(item, local_modem):
                updated = merge_local_modem_snapshot(item, local_modem)
                modems[idx] = updated
                local_modem = updated
                merged = True
                break
        if not merged:
            modems.append(local_modem)

        merged = False
        for idx, item in enumerate(node_modems):
            if same_modem(item, local_modem):
                updated = merge_local_modem_snapshot(item, local_modem)
                node_modems[idx] = updated
                merged = True
                break
        if not merged:
            node_modems.append(local_modem)

    return finalize_overview_shape(overview)


def reconcile_aliases(overview):
    if not isinstance(overview, dict):
        return
    global LAST_ALIAS_SIGNATURE
    alias_hosts = []
    for modem in overview.get("modems", []) or []:
        if not isinstance(modem, dict):
            continue
        alias_host = alias_host_for_ordinal(modem.get("ordinal") or modem.get("modem_number"))
        if alias_host:
            alias_hosts.append(alias_host)
    alias_hosts = sorted(set(alias_hosts))
    signature = "|".join(alias_hosts)
    if signature == LAST_ALIAS_SIGNATURE:
        return
    ensure_alias_redirect()
    for alias_host in alias_hosts:
        ensure_alias_ip(alias_host)
    LAST_ALIAS_SIGNATURE = signature


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
        updated = content.rstrip() + f"\n  flash:\n    enabled: true\n{replacement}\n    script_path: \"/usr/local/sbin/partner-node-provision-hilink.sh\"\n"
    with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
        fh.write(updated)
    subprocess.Popen(["systemctl", "restart", "partner-node"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"auto_flash_enabled": auto_enabled, "restarting_agent": True}


def fetch_overview():
    now = time.time()
    with OVERVIEW_CACHE_LOCK:
        cached = copy.deepcopy(OVERVIEW_CACHE["data"]) if isinstance(OVERVIEW_CACHE["data"], dict) else {
            "partner_key": PARTNER_KEY,
            "main_server": MAIN_SERVER,
            "nodes": [],
            "modems": [],
            "modem_registry": [],
        }
        updated_at = float(OVERVIEW_CACHE.get("updated_at") or 0.0)
        refreshing = bool(OVERVIEW_CACHE.get("refreshing"))
    if isinstance(cached, dict):
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
        inject_local_runtime_state(data)
        apply_local_usage_to_overview(data)
        apply_local_flash_job(data)
        reconcile_aliases(data)
    return data


def refresh_overview_cache():
    data = None
    error = ""
    try:
        data = rebuild_overview_snapshot()
    except Exception as err:
        error = str(err)
        ui_log("overview refresh failed", error=str(err))
    finally:
        with OVERVIEW_CACHE_LOCK:
            if isinstance(data, dict):
                OVERVIEW_CACHE["data"] = data
                OVERVIEW_CACHE["updated_at"] = time.time()
            OVERVIEW_CACHE["refreshing"] = False
            OVERVIEW_CACHE["error"] = error
    if isinstance(data, dict):
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


class LocalUIHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        try:
            self.connection.settimeout(CLIENT_SOCKET_TIMEOUT)
        except Exception:
            pass

    def end_headers(self):
        self.send_header("Connection", "close")
        super().end_headers()
        self.close_connection = True

    def handle_one_request(self):
        started = time.time()
        try:
            super().handle_one_request()
        finally:
            elapsed_ms = int((time.time() - started) * 1000)
            if elapsed_ms > 2000:
                ui_log("slow ui request", path=getattr(self, "path", ""), duration_ms=elapsed_ms)

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
                data = build_local_modem_billing(fetch_overview())
                self._send_json(200, data)
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
                data = update_local_modem_billing(req)
                self._send_json(200, data)
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

        if self.path == "/api/local/reset-modems":
            try:
                self._send_json(200, reset_local_modem_state())
            except Exception as err:
                self._send_text(500, str(err))
            return

        if self.path == "/api/local/run-update":
            try:
                self._send_json(200, start_local_update())
            except Exception as err:
                self._send_text(500, str(err))
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
    server = LocalUIHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
    server.serve_forever()
PY

cat > "${UI_DIR}/ui.env" <<EOF
MAIN_SERVER="${MAIN_SERVER}"
PARTNER_KEY="${PARTNER_KEY}"
UI_LISTEN_ADDR="127.0.0.1"
UI_PORT="${UI_PORT}"
PARTNER_NODE_UPDATE_PATH="${PARTNER_NODE_UPDATE_PATH}"
PARTNER_NODE_UPDATE_LOG="${PARTNER_NODE_UPDATE_LOG}"
PARTNER_NODE_UPDATE_URL="${PARTNER_NODE_UPDATE_URL}"
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
