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

if [[ -z "${MAIN_SERVER}" || -z "${PARTNER_KEY}" ]]; then
  log_err "MAIN_SERVER and PARTNER_KEY must be set"
  exit 1
fi

mkdir -p "${UI_DIR}"

cat > "${UI_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Partner Node Local Console</title>
  <style>
    :root {
      --bg: #0b1220;
      --panel: #111a2e;
      --panel-2: #0f1729;
      --text: #e7edf7;
      --muted: #9fb0c9;
      --ok: #22c55e;
      --warn: #f59e0b;
      --err: #ef4444;
      --brand: #4f46e5;
      --line: #22304d;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", "Noto Sans", Arial, sans-serif;
      color: var(--text);
      background:
        radial-gradient(1200px 500px at -10% -20%, #1d2b56 0%, transparent 60%),
        radial-gradient(800px 420px at 120% -20%, #2d1846 0%, transparent 55%),
        var(--bg);
    }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 20px; }
    .head {
      display: flex; justify-content: space-between; align-items: center; gap: 12px;
      padding: 16px 18px; border: 1px solid var(--line); border-radius: 18px;
      background: linear-gradient(180deg, rgba(255,255,255,.03), rgba(255,255,255,.01));
    }
    .title { font-size: 20px; font-weight: 700; letter-spacing: .2px; }
    .meta { color: var(--muted); font-size: 13px; }
    .badge {
      display: inline-flex; align-items: center; gap: 6px;
      border: 1px solid var(--line); border-radius: 999px; padding: 6px 10px;
      color: var(--muted); font-size: 12px;
    }
    .grid {
      margin-top: 14px;
      display: grid; grid-template-columns: repeat(12, minmax(0, 1fr)); gap: 12px;
    }
    .card {
      border: 1px solid var(--line); border-radius: 16px; background: var(--panel);
      overflow: hidden;
    }
    .card-h {
      display: flex; justify-content: space-between; align-items: center;
      padding: 12px 14px; border-bottom: 1px solid var(--line); background: var(--panel-2);
      font-size: 14px; font-weight: 600;
    }
    .card-b { padding: 14px; }
    .kpi { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
    .k {
      border: 1px solid var(--line); border-radius: 12px; padding: 10px; background: #0e1628;
    }
    .k .l { color: var(--muted); font-size: 12px; margin-bottom: 6px; }
    .k .v { font-size: 22px; font-weight: 700; }
    .ok { color: var(--ok); }
    .warn { color: var(--warn); }
    .err { color: var(--err); }
    table { width: 100%; border-collapse: collapse; }
    th, td {
      border-bottom: 1px solid var(--line);
      text-align: left; padding: 9px 8px; font-size: 13px; vertical-align: top;
    }
    th { color: var(--muted); font-weight: 600; }
    .row-actions { display: flex; flex-wrap: wrap; gap: 8px; }
    input, select, textarea, button {
      width: 100%; border-radius: 10px; border: 1px solid var(--line);
      background: #0d1527; color: var(--text); padding: 9px 10px; font-size: 13px;
    }
    textarea { min-height: 90px; resize: vertical; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    button { cursor: pointer; background: #12203d; }
    button:hover { background: #172a52; }
    .btn-primary { background: linear-gradient(180deg, #4f46e5, #4338ca); border-color: #3730a3; }
    .btn-primary:hover { filter: brightness(1.06); }
    .form-grid { display: grid; grid-template-columns: repeat(12, minmax(0, 1fr)); gap: 10px; }
    .col-3 { grid-column: span 3; } .col-4 { grid-column: span 4; } .col-6 { grid-column: span 6; } .col-12 { grid-column: span 12; }
    .msg {
      margin-top: 8px; border: 1px solid var(--line); border-radius: 10px; padding: 10px;
      background: #0d1527; font-size: 13px;
    }
    .muted { color: var(--muted); }
    .small { font-size: 12px; }
    .pill {
      display: inline-flex; align-items: center; border-radius: 999px; padding: 3px 8px;
      border: 1px solid var(--line); font-size: 12px;
    }
    @media (max-width: 960px) {
      .kpi { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .col-3, .col-4, .col-6 { grid-column: span 12; }
      .grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="head">
      <div>
        <div class="title">Partner Node Local Console</div>
        <div class="meta" id="metaLine">Loading...</div>
      </div>
      <div class="badge"><span id="refreshState">auto refresh 6s</span></div>
    </div>

    <div class="grid">
      <div class="card" style="grid-column: span 12;">
        <div class="card-h">Node Health Snapshot</div>
        <div class="card-b">
          <div class="kpi">
            <div class="k"><div class="l">Nodes</div><div class="v" id="kNodes">0</div></div>
            <div class="k"><div class="l">Modems</div><div class="v" id="kModems">0</div></div>
            <div class="k"><div class="l">Ready Modems</div><div class="v ok" id="kReady">0</div></div>
            <div class="k"><div class="l">External IP</div><div class="v small" id="kIp">-</div></div>
          </div>
        </div>
      </div>

      <div class="card" style="grid-column: span 8;">
        <div class="card-h">Modems (Current Node Context)</div>
        <div class="card-b" style="padding-top: 0;">
          <table>
            <thead>
              <tr>
                <th>Modem</th>
                <th>State</th>
                <th>Operator</th>
                <th>WAN IP</th>
                <th>Signal</th>
                <th>Rotation</th>
              </tr>
            </thead>
            <tbody id="modemsBody"></tbody>
          </table>
        </div>
      </div>

      <div class="card" style="grid-column: span 4;">
        <div class="card-h">Quick Actions</div>
        <div class="card-b">
          <div class="row-actions">
            <button onclick="quick('self_check')">Self Check</button>
            <button onclick="quick('transport_self_check')">Transport Check</button>
            <button onclick="quick('reconcile_config')">Reconcile</button>
            <button onclick="quick('restart_proxy')">Restart Proxy</button>
          </div>
          <div class="msg muted small" id="quickMsg">No actions yet.</div>
        </div>
      </div>

      <div class="card" style="grid-column: span 12;">
        <div class="card-h">Command Center (Node / Modem)</div>
        <div class="card-b">
          <div class="form-grid">
            <div class="col-3">
              <label class="small muted">Command</label>
              <select id="cmdType">
                <option value="self_check">self_check</option>
                <option value="transport_self_check">transport_self_check</option>
                <option value="reconcile_config">reconcile_config</option>
                <option value="restart_proxy">restart_proxy</option>
                <option value="rotate_ip">rotate_ip</option>
              </select>
            </div>
            <div class="col-3">
              <label class="small muted">Target Modem</label>
              <select id="modemPick">
                <option value="">auto</option>
              </select>
            </div>
            <div class="col-3">
              <label class="small muted">Timeout (sec)</label>
              <input id="timeout" type="number" min="5" value="120" />
            </div>
            <div class="col-3">
              <label class="small muted">&nbsp;</label>
              <button class="btn-primary" onclick="sendCommand()">Send Command</button>
            </div>
            <div class="col-12">
              <label class="small muted">Extra Params JSON (optional)</label>
              <textarea id="params" placeholder='{"reason":"manual"}'></textarea>
            </div>
          </div>
          <div class="msg" id="cmdMsg">No command sent yet.</div>
        </div>
      </div>

      <div class="card" style="grid-column: span 12;">
        <div class="card-h">Recent Command Results</div>
        <div class="card-b" style="padding-top: 0;">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Type</th>
                <th>Status</th>
                <th>Message</th>
                <th>Updated</th>
              </tr>
            </thead>
            <tbody id="resultsBody"></tbody>
          </table>
        </div>
      </div>
    </div>
  </div>

  <script>
    let lastOverview = {};

    function el(id){ return document.getElementById(id); }
    function esc(v){ return String(v ?? '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m])); }
    function stateCls(s){
      const x = String(s || '').toLowerCase();
      if (['ready','online','success','active'].includes(x)) return 'ok';
      if (['degraded','busy','rotating','warning'].includes(x)) return 'warn';
      if (['offline','error','failed'].includes(x)) return 'err';
      return 'muted';
    }
    function getNodes(data){
      if (Array.isArray(data.nodes)) return data.nodes;
      const uniq = new Map();
      (data.modems || []).forEach(m => {
        if (m.node_id || m.nodeId) {
          const id = m.node_id || m.nodeId;
          if (!uniq.has(id)) uniq.set(id, { id, status: m.node_status || 'unknown' });
        }
      });
      return [...uniq.values()];
    }
    function getModems(data){
      return Array.isArray(data.modems) ? data.modems : [];
    }

    function renderOverview(data){
      lastOverview = data || {};
      const nodes = getNodes(data);
      const modems = getModems(data);
      const ready = modems.filter(m => String(m.state || '').toLowerCase() === 'ready').length;
      el('kNodes').textContent = nodes.length;
      el('kModems').textContent = modems.length;
      el('kReady').textContent = ready;
      el('kIp').textContent = data.external_ip || data.public_ip || '-';
      el('metaLine').textContent = `partner=${data.partner_key || '-'} | main=${data.main_server || '-'} | fetched=${new Date().toLocaleTimeString()}`;

      el('modemsBody').innerHTML = modems.map(m => `
        <tr>
          <td>${esc(m.id || m.modem_id || '-')}</td>
          <td><span class="pill ${stateCls(m.state)}">${esc(m.state || 'unknown')}</span></td>
          <td>${esc(m.operator || '-')}</td>
          <td>${esc(m.wan_ip || m.external_ip || '-')}</td>
          <td>${esc(m.signal ?? '-')}</td>
          <td>${esc(m.rotation_mode || '-')}</td>
        </tr>`).join('') || `<tr><td colspan="6" class="muted">No modems yet</td></tr>`;

      const pick = el('modemPick');
      const current = pick.value;
      pick.innerHTML = `<option value="">auto</option>` + modems.map(m => {
        const id = m.id || m.modem_id || '';
        return `<option value="${esc(id)}">${esc(id)} ${m.state ? `(${esc(m.state)})` : ''}</option>`;
      }).join('');
      if ([...pick.options].some(o => o.value === current)) pick.value = current;

      const results = Array.isArray(data.last_results) ? data.last_results : [];
      el('resultsBody').innerHTML = results.slice(0, 12).map(r => `
        <tr>
          <td>${esc(r.command_id || '-')}</td>
          <td>${esc(r.type || '-')}</td>
          <td><span class="pill ${stateCls(r.status)}">${esc(r.status || 'unknown')}</span></td>
          <td>${esc(r.message || '')}</td>
          <td>${esc(r.updated_at || r.finished_at || '-')}</td>
        </tr>`).join('') || `<tr><td colspan="5" class="muted">No command results yet</td></tr>`;
    }

    async function refresh(){
      try {
        const r = await fetch('/api/overview', { cache: 'no-store' });
        if (!r.ok) throw new Error(await r.text());
        const d = await r.json();
        renderOverview(d);
      } catch (e) {
        el('quickMsg').textContent = `refresh error: ${String(e.message || e)}`;
      }
    }

    async function postCommand(payload){
      const r = await fetch('/api/command', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (!r.ok) throw new Error(await r.text());
      return r.json();
    }

    async function quick(type){
      try {
        const payload = { type, timeout_sec: 120, params: {} };
        const modemId = el('modemPick').value;
        if (modemId && type === 'rotate_ip') payload.params.modem_id = modemId;
        const res = await postCommand(payload);
        const id = res?.command?.id || '-';
        el('quickMsg').textContent = `[pending] ${type} queued (id=${id})`;
        await refresh();
      } catch (e) {
        el('quickMsg').textContent = `action failed: ${String(e.message || e)}`;
      }
    }

    async function sendCommand(){
      try {
        const type = el('cmdType').value;
        const timeout_sec = Number(el('timeout').value || 120);
        let params = {};
        const raw = el('params').value.trim();
        if (raw) params = JSON.parse(raw);
        const modemId = el('modemPick').value;
        if (modemId && type === 'rotate_ip' && !params.modem_id) params.modem_id = modemId;
        const res = await postCommand({ type, timeout_sec, params });
        const id = res?.command?.id || '-';
        el('cmdMsg').textContent = `[pending] ${type} queued (id=${id})`;
        await refresh();
      } catch (e) {
        el('cmdMsg').textContent = `command failed: ${String(e.message || e)}`;
      }
    }

    refresh();
    setInterval(refresh, 6000);
  </script>
</body>
</html>
HTML

cat > "${UI_DIR}/server.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

MAIN_SERVER = os.environ.get("MAIN_SERVER", "").rstrip("/")
PARTNER_KEY = os.environ.get("PARTNER_KEY", "")
LISTEN_ADDR = os.environ.get("UI_LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("UI_PORT", "19090"))
INDEX_PATH = os.path.join(os.path.dirname(__file__), "index.html")

ALLOWED = {
    "self_check",
    "rotate_ip",
    "restart_proxy",
    "reconcile_config",
    "transport_self_check",
}


def json_request(url, method="GET", payload=None):
    body = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, method=method, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = resp.read()
        return json.loads(data.decode("utf-8"))


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

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(INDEX_PATH, "rb") as f:
                html = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return

        if self.path == "/api/overview":
            try:
                qs = urllib.parse.urlencode({"partner_key": PARTNER_KEY})
                data = json_request(f"{MAIN_SERVER}/api/partner/overview?{qs}")
                if isinstance(data, dict):
                    data.setdefault("partner_key", PARTNER_KEY)
                    data.setdefault("main_server", MAIN_SERVER)
                self._send_json(200, data)
            except urllib.error.HTTPError as e:
                self._send_text(e.code, e.read().decode("utf-8", errors="ignore"))
            except Exception as e:
                self._send_text(502, str(e))
            return

        if self.path == "/healthz":
            self._send_text(200, "ok")
            return

        self._send_text(404, "not found")

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
                "type": cmd_type,
                "timeout_sec": int(req.get("timeout_sec", 120)),
                "params": req.get("params", {}),
            }
            data = json_request(f"{MAIN_SERVER}/api/partner/command", method="POST", payload=payload)
            self._send_json(200, data)
        except urllib.error.HTTPError as e:
            self._send_text(e.code, e.read().decode("utf-8", errors="ignore"))
        except Exception as e:
            self._send_text(400, str(e))

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

