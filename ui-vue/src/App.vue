<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import {
  Activity,
  BadgeCheck,
  Cpu,
  Gauge,
  HardDrive,
  Network,
  RefreshCcw,
  Router,
  Server,
  Signal,
  TriangleAlert,
  Users,
  Waves,
  Wifi,
} from "lucide-vue-next"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Textarea } from "@/components/ui/textarea"

const overview = ref(null)
const loading = ref(false)
const refreshError = ref("")
const commandMessage = ref("")
const quickMessage = ref("")
const realtimeState = ref("connecting")
const realtimeNote = ref("Connecting live channel...")
const lastRealtimeAt = ref("")
const commandType = ref("self_check")
const timeoutSec = ref("120")
const extraParams = ref("")
const selectedNode = ref("all")
const selectedModem = ref("all")
const eventFeed = ref([])

let ws = null
let wsUrl = ""
let reconnectTimer = null
let refreshTimer = null
let fallbackTimer = null

const commandOptions = [
  { value: "self_check", label: "Self Check", note: "Checks node-agent, proxy, heartbeat, and modem inventory." },
  { value: "transport_self_check", label: "Transport Check", note: "Diagnoses transport to the main server and websocket session health." },
  { value: "reconcile_config", label: "Reconcile Config", note: "Rebuilds desired state, 3proxy config, and modem ports." },
  { value: "restart_proxy", label: "Restart Proxy", note: "Restarts local 3proxy on the selected node." },
  { value: "rotate_ip", label: "Rotate IP", note: "Rotates a specific HiLink modem or all ready modems on the selected node." },
  { value: "self_update", label: "Self Update", note: "Updates node-agent to the target version from the main server." },
]

const runbookChecks = [
  { label: "Agent service", command: "systemctl status partner-node --no-pager", expected: "active (running), heartbeat is flowing." },
  { label: "Local UI", command: "systemctl status partner-node-ui --no-pager", expected: "active (running), 127.0.0.1:19090 is listening." },
  { label: "3proxy", command: "systemctl status 3proxy --no-pager", expected: "active (running), config is current." },
  { label: "Observed egress", command: "curl --proxy socks5h://127.0.0.1:31001 http://api.ipify.org", expected: "The IP should match the observed IP shown in the UI." },
  { label: "Policy routing", command: "ip rule show && ip route show table 1101", expected: "Source-based routing for HiLink is active." },
  { label: "Recent logs", command: "journalctl -u partner-node -n 120 --no-pager", expected: "heartbeat, reconcile, commands, rotate_ip." },
]

const summary = computed(() => overview.value?.summary || {})
const nodes = computed(() => Array.isArray(overview.value?.nodes) ? overview.value.nodes : [])
const modems = computed(() => Array.isArray(overview.value?.modems) ? overview.value.modems : [])
const commandHistory = computed(() => Array.isArray(overview.value?.last_results) ? overview.value.last_results : [])
const activeNodeId = computed(() => selectedNode.value !== "all" ? selectedNode.value : (nodes.value[0]?.node_id || ""))
const filteredModems = computed(() => selectedNode.value === "all" ? modems.value : modems.value.filter((item) => item.node_id === selectedNode.value))
const lastResults = computed(() => commandHistory.value.slice(0, 12))

function bytesLabel(value) {
  const size = Number(value || 0)
  if (!Number.isFinite(size) || size <= 0) return "0 B"
  if (size < 1024) return `${size} B`
  if (size < 1024 ** 2) return `${(size / 1024).toFixed(1)} KB`
  if (size < 1024 ** 3) return `${(size / 1024 ** 2).toFixed(2)} MB`
  return `${(size / 1024 ** 3).toFixed(2)} GB`
}

function relativeTime(value) {
  if (!value) return "-"
  const ts = new Date(value).getTime()
  if (!Number.isFinite(ts)) return value
  const diffSec = Math.max(0, Math.floor((Date.now() - ts) / 1000))
  if (diffSec < 5) return "now"
  if (diffSec < 60) return `${diffSec}s`
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m`
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h`
  return `${Math.floor(diffSec / 86400)}d`
}

function tone(status) {
  const value = String(status || "").toLowerCase()
  if (["online", "ready", "success", "active", "running", "open"].includes(value)) return "default"
  if (["degraded", "busy", "warning", "pending", "connecting"].includes(value)) return "secondary"
  if (["error", "failed", "offline", "timeout", "closed", "disconnected"].includes(value)) return "destructive"
  return "outline"
}

function prettyPayload(value) {
  try {
    return JSON.stringify(value ?? {}, null, 2)
  } catch {
    return String(value ?? "")
  }
}

function pushEvent(type, payload = {}) {
  const next = { id: `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`, type, ts: new Date().toISOString(), payload }
  eventFeed.value = [next, ...eventFeed.value].slice(0, 18)
  lastRealtimeAt.value = next.ts
}

function clearReconnect() { if (reconnectTimer) { window.clearTimeout(reconnectTimer); reconnectTimer = null } }
function clearRefreshTimer() { if (refreshTimer) { window.clearTimeout(refreshTimer); refreshTimer = null } }
function scheduleRefresh(delay = 250) { clearRefreshTimer(); refreshTimer = window.setTimeout(() => loadOverview(false), delay) }

function closeRealtime() {
  clearReconnect()
  if (ws) {
    ws.onopen = null; ws.onmessage = null; ws.onclose = null; ws.onerror = null; ws.close(); ws = null
  }
}

function buildPartnerWsUrl() {
  const partnerKey = overview.value?.partner_key
  const mainServer = overview.value?.main_server
  if (!partnerKey || !mainServer) return ""
  try {
    const url = new URL(mainServer)
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
    url.pathname = "/ws/partner"
    url.searchParams.set("partner_key", partnerKey)
    return url.toString()
  } catch { return "" }
}

function connectRealtime() {
  const nextUrl = buildPartnerWsUrl()
  if (!nextUrl) { realtimeState.value = "offline"; realtimeNote.value = "Main server for realtime is not known yet."; return }
  if (ws && ws.readyState === WebSocket.OPEN && wsUrl === nextUrl) return
  closeRealtime(); wsUrl = nextUrl; realtimeState.value = "connecting"; realtimeNote.value = "Connecting websocket to the main server..."
  ws = new WebSocket(nextUrl)
  ws.onopen = () => { realtimeState.value = "active"; realtimeNote.value = "Live channel is active, the screen updates from events."; pushEvent("realtime.connected", { partner_key: overview.value?.partner_key || "" }) }
  ws.onmessage = (event) => { try { const data = JSON.parse(event.data); pushEvent(data.type || "event", data.payload || {}) } catch { pushEvent("event.raw", { text: String(event.data || "") }) } scheduleRefresh(120) }
  ws.onerror = () => { realtimeState.value = "warning"; realtimeNote.value = "Realtime channel reported an error, waiting to reconnect." }
  ws.onclose = () => { ws = null; realtimeState.value = "offline"; realtimeNote.value = "Realtime channel is offline, trying to recover."; clearReconnect(); reconnectTimer = window.setTimeout(() => connectRealtime(), 2500) }
}

async function loadOverview(showLoader = true) {
  if (showLoader) loading.value = true
  refreshError.value = ""
  try {
    const response = await fetch("/api/overview", { cache: "no-store" })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    overview.value = data
    if (selectedNode.value === "all" && data.nodes?.length === 1) selectedNode.value = data.nodes[0].node_id
    if (selectedNode.value !== "all" && !data.nodes?.some((item) => item.node_id === selectedNode.value)) selectedNode.value = data.nodes?.[0]?.node_id || "all"
    if (selectedModem.value !== "all" && !filteredModems.value.some((item) => item.id === selectedModem.value)) selectedModem.value = "all"
    connectRealtime()
  } catch (error) {
    refreshError.value = error instanceof Error ? error.message : "refresh failed"
  } finally { loading.value = false }
}

function buildCommandPayload(type) {
  const payload = { type, timeout_sec: Number(timeoutSec.value || 120), params: {} }
  if (activeNodeId.value) payload.node_id = activeNodeId.value
  if (extraParams.value.trim()) payload.params = JSON.parse(extraParams.value)
  if (type === "rotate_ip" && selectedModem.value !== "all") payload.params.modem_ids = [selectedModem.value]
  return payload
}

async function sendCommand(type = commandType.value, targetMessage = "command") {
  commandMessage.value = ""; quickMessage.value = ""
  try {
    const response = await fetch("/api/command", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(buildCommandPayload(type)) })
    if (!response.ok) throw new Error(await response.text())
    const result = await response.json()
    const message = `${targetMessage === "quick" ? "quick" : "command"}: ${type} queued (${result.command?.id || result.command_id || "-"})`
    if (targetMessage === "quick") quickMessage.value = message; else commandMessage.value = message
    scheduleRefresh(200)
  } catch (error) {
    const text = error instanceof Error ? error.message : "command failed"
    if (targetMessage === "quick") quickMessage.value = text; else commandMessage.value = text
  }
}

function quickAction(type) { sendCommand(type, "quick") }
watch(selectedNode, () => { if (!filteredModems.value.some((item) => item.id === selectedModem.value)) selectedModem.value = "all" })
onMounted(() => { loadOverview(); fallbackTimer = window.setInterval(() => { if (realtimeState.value !== "active") loadOverview(false) }, 15000) })
onBeforeUnmount(() => { closeRealtime(); clearRefreshTimer(); if (fallbackTimer) { window.clearInterval(fallbackTimer); fallbackTimer = null } })
</script>
<template>
  <main class="min-h-screen bg-background text-foreground">
    <section class="mx-auto flex max-w-[1560px] flex-col gap-6 px-4 py-5 sm:px-6 xl:px-8">
      <header class="glass-panel grid-noise overflow-hidden rounded-[32px] border border-border/70">
        <div class="flex flex-col gap-6 px-5 py-5 lg:flex-row lg:items-end lg:justify-between lg:px-7 lg:py-7">
          <div class="max-w-4xl space-y-3">
            <Badge variant="secondary" class="rounded-full px-3 py-1 text-[11px] uppercase tracking-[0.18em]">Partner Fleet Console</Badge>
            <div class="space-y-2">
              <h1 class="text-3xl font-semibold tracking-tight sm:text-4xl">Partner fleet console for all assigned nodes</h1>
              <p class="max-w-3xl text-sm leading-6 text-muted-foreground sm:text-base">
                This local admin panel shows the entire fleet for the current `partner_key`: nodes, modems, observed egress IP,
                traffic by modem, active clients, recent commands, and live events from the main server.
              </p>
            </div>
          </div>
          <div class="grid gap-3 sm:grid-cols-2 xl:min-w-[520px]">
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Partner Key</div><div class="mt-2 font-mono text-sm">{{ overview?.partner_key || "-" }}</div></div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Main Server</div><div class="mt-2 break-all font-mono text-sm">{{ overview?.main_server || "-" }}</div></div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4"><div class="flex items-center justify-between gap-3"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Realtime</div><Badge :variant="tone(realtimeState)" class="rounded-full capitalize">{{ realtimeState }}</Badge></div><div class="mt-2 text-sm text-muted-foreground">{{ realtimeNote }}</div></div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Last live event</div><div class="mt-2 text-sm font-medium">{{ lastRealtimeAt ? relativeTime(lastRealtimeAt) : "-" }}</div></div>
          </div>
        </div>
      </header>

      <div class="grid gap-4 xl:grid-cols-6">
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Server class="h-4 w-4" /> Nodes</CardDescription><CardTitle class="text-2xl">{{ summary.nodes_online || 0 }} / {{ summary.nodes_total || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Currently online, degraded/offline: <span class="font-medium text-foreground">{{ summary.nodes_degraded || 0 }}</span></CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><HardDrive class="h-4 w-4" /> Modems</CardDescription><CardTitle class="text-2xl">{{ summary.modems_ready || 0 }} / {{ summary.modems_total || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Ready modems currently in the pool.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Users class="h-4 w-4" /> Clients</CardDescription><CardTitle class="text-2xl">{{ summary.active_clients || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Active leases through the main server for this partner fleet.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Activity class="h-4 w-4" /> Sessions</CardDescription><CardTitle class="text-2xl">{{ summary.active_sessions || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Aggregate load across all partner modems.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Waves class="h-4 w-4" /> Traffic In</CardDescription><CardTitle class="text-2xl">{{ bytesLabel(summary.traffic_in_total) }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Inbound traffic from aggregated heartbeat data.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Gauge class="h-4 w-4" /> Traffic Out</CardDescription><CardTitle class="text-2xl">{{ bytesLabel(summary.traffic_out_total) }}</CardTitle></CardHeader><CardContent class="flex items-center justify-between gap-3 text-sm text-muted-foreground"><span>{{ loading ? "refresh..." : "snapshot synced" }}</span><Button variant="outline" size="sm" class="rounded-full" @click="loadOverview()"><RefreshCcw class="h-4 w-4" />Refresh</Button></CardContent></Card>
      </div>

      <div v-if="refreshError" class="rounded-[24px] border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">{{ refreshError }}</div>

      <Tabs default-value="nodes" class="space-y-4">
        <TabsList class="w-fit rounded-2xl bg-muted/60 p-1">
          <TabsTrigger value="nodes" class="rounded-xl px-4">Nodes</TabsTrigger>
          <TabsTrigger value="modems" class="rounded-xl px-4">Modems</TabsTrigger>
          <TabsTrigger value="commands" class="rounded-xl px-4">Commands</TabsTrigger>
          <TabsTrigger value="activity" class="rounded-xl px-4">Realtime</TabsTrigger>
          <TabsTrigger value="runbook" class="rounded-xl px-4">Runbook</TabsTrigger>
        </TabsList>

        <TabsContent value="nodes" class="space-y-4">
          <Card class="rounded-[28px] border-border/70 shadow-sm">
            <CardHeader class="border-b border-border/60 pb-5"><CardTitle class="text-2xl">All partner nodes</CardTitle><CardDescription>Operational snapshot per node: heartbeat, observed IP, traffic, ready pool, and status.</CardDescription></CardHeader>
            <CardContent class="p-4 sm:p-6">
              <div class="overflow-hidden rounded-[24px] border border-border/70">
                <Table><TableHeader><TableRow class="hover:bg-transparent"><TableHead>Node</TableHead><TableHead>Status</TableHead><TableHead>Country</TableHead><TableHead>Observed IP</TableHead><TableHead>Modems</TableHead><TableHead>Sessions</TableHead><TableHead>Traffic</TableHead><TableHead>Heartbeat</TableHead></TableRow></TableHeader><TableBody>
                  <TableRow v-for="node in nodes" :key="node.node_id"><TableCell><div class="font-medium">{{ node.node_id }}</div><div class="text-xs text-muted-foreground">{{ node.agent_version || "-" }}</div></TableCell><TableCell><Badge :variant="tone(node.node_status)" class="rounded-full capitalize">{{ node.node_status || "unknown" }}</Badge></TableCell><TableCell>{{ node.country || "-" }}</TableCell><TableCell class="font-mono text-xs">{{ node.external_ip || "-" }}</TableCell><TableCell>{{ Array.isArray(node.modems) ? node.modems.length : 0 }}</TableCell><TableCell>{{ node.active_sessions || 0 }}</TableCell><TableCell class="text-xs text-muted-foreground"><div>In: {{ bytesLabel(node.bytes_in_total) }}</div><div>Out: {{ bytesLabel(node.bytes_out_total) }}</div></TableCell><TableCell class="text-xs">{{ relativeTime(node.last_heartbeat_at) }}</TableCell></TableRow>
                  <TableRow v-if="!nodes.length"><TableCell colspan="8" class="py-10 text-center text-muted-foreground">No nodes have been registered yet.</TableCell></TableRow>
                </TableBody></Table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="modems" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.35fr)_minmax(360px,0.65fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm"><CardHeader class="border-b border-border/60 pb-5"><CardTitle class="text-2xl">Modem fleet</CardTitle><CardDescription>Observed egress IP, technology, signal, sessions, and traffic for each partner modem.</CardDescription></CardHeader><CardContent class="p-4 sm:p-6"><div class="overflow-hidden rounded-[24px] border border-border/70"><Table><TableHeader><TableRow class="hover:bg-transparent"><TableHead>Node / Modem</TableHead><TableHead>Status</TableHead><TableHead>Observed IP</TableHead><TableHead>Operator</TableHead><TableHead>Tech</TableHead><TableHead>Signal</TableHead><TableHead>Sessions</TableHead><TableHead>Traffic</TableHead></TableRow></TableHeader><TableBody><TableRow v-for="modem in modems" :key="`${modem.node_id}:${modem.id}`"><TableCell><div class="font-medium">{{ modem.id }}</div><div class="text-xs text-muted-foreground">{{ modem.node_id }} • port {{ modem.port || "-" }}</div></TableCell><TableCell><Badge :variant="tone(modem.state)" class="rounded-full capitalize">{{ modem.state || "unknown" }}</Badge></TableCell><TableCell class="font-mono text-xs">{{ modem.wan_ip || "-" }}</TableCell><TableCell>{{ modem.operator || "-" }}</TableCell><TableCell>{{ modem.technology || "-" }}</TableCell><TableCell><div class="flex items-center gap-2"><Signal class="h-4 w-4 text-muted-foreground" /><span>{{ modem.signal_strength ?? "-" }}</span></div></TableCell><TableCell>{{ modem.active_sessions || 0 }}</TableCell><TableCell class="text-xs text-muted-foreground"><div>In: {{ bytesLabel(modem.traffic_bytes_in) }}</div><div>Out: {{ bytesLabel(modem.traffic_bytes_out) }}</div></TableCell></TableRow><TableRow v-if="!modems.length"><TableCell colspan="8" class="py-10 text-center text-muted-foreground">No modems have been discovered yet.</TableCell></TableRow></TableBody></Table></div></CardContent></Card>
            <Card class="rounded-[28px] border-border/70 shadow-sm"><CardHeader class="border-b border-border/60 pb-5"><CardTitle class="text-2xl">Fleet summary</CardTitle><CardDescription>A quick health layer without opening the main admin.</CardDescription></CardHeader><CardContent class="space-y-3 p-4 sm:p-6"><div class="rounded-2xl border border-border/70 p-4"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Ready modems</div><div class="mt-2 text-2xl font-semibold">{{ summary.modems_ready || 0 }}</div></div><div class="rounded-2xl border border-border/70 p-4"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Node observed IP</div><div class="mt-2 font-mono text-sm">{{ overview?.external_ip || "-" }}</div></div><div class="rounded-2xl border border-border/70 p-4"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Last heartbeat</div><div class="mt-2 text-sm font-medium">{{ relativeTime(overview?.last_heartbeat_at) }}</div></div><div class="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-4 text-sm text-amber-100"><div class="flex items-center gap-2 font-medium text-amber-200"><TriangleAlert class="h-4 w-4" />Important check</div><div class="mt-2 leading-6">If a modem observed IP does not match what a client sees through the proxy, the issue is in local egress or policy routing, not in the main server.</div></div></CardContent></Card>
          </div>
        </TabsContent>

        <TabsContent value="commands" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.1fr)_minmax(360px,0.9fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Command center</CardTitle>
                <CardDescription>Send commands to the selected node or modem without opening the main admin panel.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-4 p-4 sm:p-6">
                <div class="grid gap-4 md:grid-cols-2">
                  <div class="space-y-2">
                    <Label for="node-select">Target node</Label>
                    <Select v-model="selectedNode">
                      <SelectTrigger id="node-select" class="rounded-2xl"><SelectValue placeholder="Choose node" /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="all">Auto / first online node</SelectItem>
                        <SelectItem v-for="node in nodes" :key="node.node_id" :value="node.node_id">{{ node.node_id }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div class="space-y-2">
                    <Label for="modem-select">Target modem</Label>
                    <Select v-model="selectedModem">
                      <SelectTrigger id="modem-select" class="rounded-2xl"><SelectValue placeholder="Choose modem" /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="all">All / no modem filter</SelectItem>
                        <SelectItem v-for="modem in filteredModems" :key="`${modem.node_id}:${modem.id}`" :value="modem.id">{{ modem.id }} • {{ modem.node_id }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                </div>

                <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_140px]">
                  <div class="space-y-2">
                    <Label for="command-type">Command</Label>
                    <Select v-model="commandType">
                      <SelectTrigger id="command-type" class="rounded-2xl"><SelectValue placeholder="Choose command" /></SelectTrigger>
                      <SelectContent>
                        <SelectItem v-for="item in commandOptions" :key="item.value" :value="item.value">{{ item.label }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div class="space-y-2">
                    <Label for="timeout-sec">Timeout, sec</Label>
                    <Input id="timeout-sec" v-model="timeoutSec" class="rounded-2xl" type="number" min="10" />
                  </div>
                </div>

                <div class="space-y-2">
                  <Label for="extra-params">Extra JSON params</Label>
                  <Textarea id="extra-params" v-model="extraParams" class="min-h-[120px] rounded-[24px] font-mono text-xs" placeholder='{"force": true}' />
                </div>

                <div class="flex flex-wrap gap-3">
                  <Button class="rounded-full" @click="sendCommand()"><Play class="mr-2 h-4 w-4" />Queue command</Button>
                  <Button variant="outline" class="rounded-full" @click="extraParams = '{}'">Reset JSON</Button>
                </div>

                <div v-if="commandMessage" class="rounded-2xl border border-border/70 bg-muted/50 px-4 py-3 text-sm">{{ commandMessage }}</div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Quick actions</CardTitle>
                <CardDescription>Most common operations for day-to-day support.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <Button variant="outline" class="h-auto w-full justify-start rounded-[24px] px-4 py-4 text-left" @click="quickAction('self_check')"><div><div class="font-medium">Self-check</div><div class="text-sm text-muted-foreground">Run diagnostics for tunnel, proxy, modems, and health.</div></div></Button>
                <Button variant="outline" class="h-auto w-full justify-start rounded-[24px] px-4 py-4 text-left" @click="quickAction('reconcile_config')"><div><div class="font-medium">Reconcile config</div><div class="text-sm text-muted-foreground">Rebuild partner node proxy config and re-apply desired state.</div></div></Button>
                <Button variant="outline" class="h-auto w-full justify-start rounded-[24px] px-4 py-4 text-left" @click="quickAction('rotate_ip')"><div><div class="font-medium">Rotate IP</div><div class="text-sm text-muted-foreground">Rotate selected modem IP through HiLink/API workflow.</div></div></Button>
                <Button variant="outline" class="h-auto w-full justify-start rounded-[24px] px-4 py-4 text-left" @click="quickAction('restart_proxy')"><div><div class="font-medium">Restart proxy</div><div class="text-sm text-muted-foreground">Restart local proxy layer on the selected node.</div></div></Button>
                <Button variant="outline" class="h-auto w-full justify-start rounded-[24px] px-4 py-4 text-left" @click="quickAction('self_update')"><div><div class="font-medium">Self-update</div><div class="text-sm text-muted-foreground">Ask the agent to update itself from the configured release source.</div></div></Button>
                <div v-if="quickMessage" class="rounded-2xl border border-border/70 bg-muted/50 px-4 py-3 text-sm">{{ quickMessage }}</div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="activity" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.15fr)_minmax(360px,0.85fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Live event feed</CardTitle>
                <CardDescription>Realtime stream from the main server: heartbeats, incidents, command results, and lease updates.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <div v-for="item in eventFeed" :key="item.id" class="rounded-[24px] border border-border/70 p-4">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <div class="font-medium">{{ item.type }}</div>
                      <div class="mt-1 text-xs text-muted-foreground">{{ relativeTime(item.ts) }}</div>
                    </div>
                    <Badge :variant="tone(item.type.includes('error') || item.type.includes('failed') ? 'offline' : 'online')" class="rounded-full capitalize">
                      {{ item.type.includes("incident") ? "incident" : "event" }}
                    </Badge>
                  </div>
                  <pre class="mt-3 overflow-x-auto rounded-2xl bg-muted/60 p-3 text-xs leading-5">{{ prettyPayload(item.payload) }}</pre>
                </div>
                <div v-if="!eventFeed.length" class="rounded-[24px] border border-dashed border-border/70 px-4 py-10 text-center text-sm text-muted-foreground">No realtime events have been received yet.</div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Last command results</CardTitle>
                <CardDescription>Recent command execution results received by the partner fleet.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <div v-for="result in lastResults" :key="result.command_id || result.id || JSON.stringify(result)" class="rounded-[24px] border border-border/70 p-4">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <div class="font-medium">{{ result.command_type || result.type || "command" }}</div>
                      <div class="mt-1 text-xs text-muted-foreground">{{ result.node_id || "-" }}<span v-if="result.modem_id"> • {{ result.modem_id }}</span></div>
                    </div>
                    <Badge :variant="tone(result.status || result.success ? 'online' : 'offline')" class="rounded-full capitalize">{{ result.status || (result.success ? "success" : "unknown") }}</Badge>
                  </div>
                  <div class="mt-3 text-sm text-muted-foreground">{{ result.message || result.result || "No details" }}</div>
                </div>
                <div v-if="!lastResults.length" class="rounded-[24px] border border-dashed border-border/70 px-4 py-10 text-center text-sm text-muted-foreground">No command results yet.</div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="runbook" class="space-y-4">
          <Card class="rounded-[28px] border-border/70 shadow-sm">
            <CardHeader class="border-b border-border/60 pb-5">
              <CardTitle class="text-2xl">Partner runbook</CardTitle>
              <CardDescription>Fast checks for support and field diagnostics before escalation to the main admin.</CardDescription>
            </CardHeader>
            <CardContent class="grid gap-4 p-4 sm:p-6 xl:grid-cols-3">
              <div v-for="item in runbookChecks" :key="item.label" class="rounded-[24px] border border-border/70 p-4">
                <div class="font-medium">{{ item.label }}</div>
                <div class="mt-3 rounded-2xl bg-muted/60 px-3 py-2 font-mono text-xs">{{ item.command }}</div>
                <div class="mt-3 text-sm leading-6 text-muted-foreground">{{ item.expected }}</div>
              </div>
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </section>
  </main>
</template>
