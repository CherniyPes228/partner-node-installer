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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Textarea } from "@/components/ui/textarea"

const overview = ref(null)
const loading = ref(false)
const refreshError = ref("")
const commandMessage = ref("")
const quickMessage = ref("")
const realtimeState = ref("connecting")
const realtimeNote = ref("Подключаем live-канал…")
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
  { value: "self_check", label: "Self Check", note: "Проверка node-agent, proxy, heartbeat и modem inventory." },
  { value: "transport_self_check", label: "Transport Check", note: "Диагностика транспорта до main server и websocket-сессии." },
  { value: "reconcile_config", label: "Reconcile Config", note: "Пересборка desired state, 3proxy и портов модемов." },
  { value: "restart_proxy", label: "Restart Proxy", note: "Локальный перезапуск 3proxy на выбранной ноде." },
  { value: "rotate_ip", label: "Rotate IP", note: "Ротация конкретного HiLink-модема или всех ready модемов на ноде." },
  { value: "self_update", label: "Self Update", note: "Обновление node-agent до целевой версии main server." },
]

const runbookChecks = [
  { label: "Сервис агента", command: "systemctl status partner-node --no-pager", expected: "active (running), heartbeat идёт." },
  { label: "Локальная UI", command: "systemctl status partner-node-ui --no-pager", expected: "active (running), 127.0.0.1:19090 слушает." },
  { label: "3proxy", command: "systemctl status 3proxy --no-pager", expected: "active (running), конфиг актуален." },
  { label: "Observed egress", command: "curl --proxy socks5h://127.0.0.1:31001 http://api.ipify.org", expected: "IP должен совпадать с observed IP в UI." },
  { label: "Policy routing", command: "ip rule show && ip route show table 1101", expected: "source-based routing для HiLink активен." },
  { label: "Последние логи", command: "journalctl -u partner-node -n 120 --no-pager", expected: "heartbeat, reconcile, команды, rotate_ip." },
]

const summary = computed(() => overview.value?.summary || {})
const nodes = computed(() => Array.isArray(overview.value?.nodes) ? overview.value.nodes : [])
const modems = computed(() => Array.isArray(overview.value?.modems) ? overview.value.modems : [])
const commandHistory = computed(() => Array.isArray(overview.value?.last_results) ? overview.value.last_results : [])
const selectedCommandNote = computed(() => commandOptions.find((item) => item.value === commandType.value)?.note || "")
const activeNodeId = computed(() => {
  if (selectedNode.value !== "all") return selectedNode.value
  return nodes.value[0]?.node_id || ""
})
const filteredModems = computed(() => {
  if (selectedNode.value === "all") return modems.value
  return modems.value.filter((item) => item.node_id === selectedNode.value)
})
const readyModems = computed(() => filteredModems.value.filter((item) => String(item.state || "").toLowerCase() === "ready"))
const activeResults = computed(() => commandHistory.value.slice(0, 12))

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
  if (diffSec < 5) return "сейчас"
  if (diffSec < 60) return `${diffSec} сек`
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)} мин`
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)} ч`
  return `${Math.floor(diffSec / 86400)} д`
}

function tone(status) {
  const value = String(status || "").toLowerCase()
  if (["online", "ready", "success", "active", "running", "open"].includes(value)) return "default"
  if (["degraded", "busy", "warning", "pending", "connecting"].includes(value)) return "secondary"
  if (["error", "failed", "offline", "timeout", "closed", "disconnected"].includes(value)) return "destructive"
  return "outline"
}

function pushEvent(type, payload = {}) {
  const next = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    type,
    ts: new Date().toISOString(),
    payload,
  }
  eventFeed.value = [next, ...eventFeed.value].slice(0, 18)
  lastRealtimeAt.value = next.ts
}

function clearReconnect() {
  if (reconnectTimer) {
    window.clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
}

function clearRefreshTimer() {
  if (refreshTimer) {
    window.clearTimeout(refreshTimer)
    refreshTimer = null
  }
}

function scheduleRefresh(delay = 250) {
  clearRefreshTimer()
  refreshTimer = window.setTimeout(() => {
    loadOverview(false)
  }, delay)
}

function closeRealtime() {
  clearReconnect()
  if (ws) {
    ws.onopen = null
    ws.onmessage = null
    ws.onclose = null
    ws.onerror = null
    ws.close()
    ws = null
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
  } catch {
    return ""
  }
}

function connectRealtime() {
  const nextUrl = buildPartnerWsUrl()
  if (!nextUrl) {
    realtimeState.value = "offline"
    realtimeNote.value = "Main server для realtime пока неизвестен."
    return
  }
  if (ws && ws.readyState === WebSocket.OPEN && wsUrl === nextUrl) {
    return
  }

  closeRealtime()
  wsUrl = nextUrl
  realtimeState.value = "connecting"
  realtimeNote.value = "Подключаем websocket main server…"

  ws = new WebSocket(nextUrl)
  ws.onopen = () => {
    realtimeState.value = "active"
    realtimeNote.value = "Live-канал активен, экран обновляется по событиям."
    pushEvent("realtime.connected", { partner_key: overview.value?.partner_key || "" })
  }
  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data)
      pushEvent(data.type || "event", data.payload || {})
    } catch {
      pushEvent("event.raw", { text: String(event.data || "") })
    }
    scheduleRefresh(120)
  }
  ws.onerror = () => {
    realtimeState.value = "warning"
    realtimeNote.value = "Realtime канал дал ошибку, ждём переподключение."
  }
  ws.onclose = () => {
    ws = null
    realtimeState.value = "offline"
    realtimeNote.value = "Realtime канал отключён, пробуем восстановиться."
    clearReconnect()
    reconnectTimer = window.setTimeout(() => {
      connectRealtime()
    }, 2500)
  }
}

async function loadOverview(showLoader = true) {
  if (showLoader) loading.value = true
  refreshError.value = ""
  try {
    const response = await fetch("/api/overview", { cache: "no-store" })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    overview.value = data
    if (selectedNode.value === "all" && data.nodes?.length === 1) {
      selectedNode.value = data.nodes[0].node_id
    }
    if (selectedNode.value !== "all" && !data.nodes?.some((item) => item.node_id === selectedNode.value)) {
      selectedNode.value = data.nodes?.[0]?.node_id || "all"
    }
    if (selectedModem.value !== "all" && !filteredModems.value.some((item) => item.id === selectedModem.value)) {
      selectedModem.value = "all"
    }
    connectRealtime()
  } catch (error) {
    refreshError.value = error instanceof Error ? error.message : "refresh failed"
  } finally {
    loading.value = false
  }
}

function buildCommandPayload(type) {
  const payload = {
    type,
    timeout_sec: Number(timeoutSec.value || 120),
    params: {},
  }
  if (activeNodeId.value) payload.node_id = activeNodeId.value
  if (extraParams.value.trim()) payload.params = JSON.parse(extraParams.value)
  if (type === "rotate_ip" && selectedModem.value !== "all") {
    payload.params.modem_ids = [selectedModem.value]
  }
  return payload
}

async function sendCommand(type = commandType.value, targetMessage = "command") {
  commandMessage.value = ""
  quickMessage.value = ""
  try {
    const payload = buildCommandPayload(type)
    const response = await fetch("/api/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
    if (!response.ok) throw new Error(await response.text())
    const result = await response.json()
    const message = `${targetMessage === "quick" ? "quick" : "command"}: ${type} queued (${result.command?.id || result.command_id || "-"})`
    if (targetMessage === "quick") quickMessage.value = message
    else commandMessage.value = message
    scheduleRefresh(200)
  } catch (error) {
    const text = error instanceof Error ? error.message : "command failed"
    if (targetMessage === "quick") quickMessage.value = text
    else commandMessage.value = text
  }
}

function quickAction(type) {
  sendCommand(type, "quick")
}

watch(selectedNode, () => {
  if (!filteredModems.value.some((item) => item.id === selectedModem.value)) {
    selectedModem.value = "all"
  }
})

onMounted(() => {
  loadOverview()
  fallbackTimer = window.setInterval(() => {
    if (realtimeState.value !== "active") {
      loadOverview(false)
    }
  }, 15000)
})

onBeforeUnmount(() => {
  closeRealtime()
  clearRefreshTimer()
  if (fallbackTimer) {
    window.clearInterval(fallbackTimer)
    fallbackTimer = null
  }
})
</script>

<template>
  <main class="min-h-screen bg-background text-foreground">
    <section class="mx-auto flex max-w-[1560px] flex-col gap-6 px-4 py-5 sm:px-6 xl:px-8">
      <header class="glass-panel grid-noise overflow-hidden rounded-[32px] border border-border/70">
        <div class="flex flex-col gap-6 px-5 py-5 lg:flex-row lg:items-end lg:justify-between lg:px-7 lg:py-7">
          <div class="max-w-4xl space-y-3">
            <Badge variant="secondary" class="rounded-full px-3 py-1 text-[11px] uppercase tracking-[0.18em]">
              Partner Fleet Console
            </Badge>
            <div class="space-y-2">
              <h1 class="text-3xl font-semibold tracking-tight sm:text-4xl">Пульт партнёра по всем своим нодам</h1>
              <p class="max-w-3xl text-sm leading-6 text-muted-foreground sm:text-base">
                Локальная админка теперь показывает не одну машину, а весь флот по `partner_key`: ноды, модемы, observed egress IP,
                трафик по модемам, активных клиентов, последние команды и live-события из main server.
              </p>
            </div>
          </div>

          <div class="grid gap-3 sm:grid-cols-2 xl:min-w-[520px]">
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4">
              <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Partner Key</div>
              <div class="mt-2 font-mono text-sm">{{ overview?.partner_key || "-" }}</div>
            </div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4">
              <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Main Server</div>
              <div class="mt-2 break-all font-mono text-sm">{{ overview?.main_server || "-" }}</div>
            </div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4">
              <div class="flex items-center justify-between gap-3">
                <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Realtime</div>
                <Badge :variant="tone(realtimeState)" class="rounded-full capitalize">{{ realtimeState }}</Badge>
              </div>
              <div class="mt-2 text-sm text-muted-foreground">{{ realtimeNote }}</div>
            </div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4">
              <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Последний live event</div>
              <div class="mt-2 text-sm font-medium">{{ lastRealtimeAt ? relativeTime(lastRealtimeAt) : "-" }}</div>
            </div>
          </div>
        </div>
      </header>

      <div class="grid gap-4 xl:grid-cols-6">
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Server class="h-4 w-4" /> Ноды</CardDescription>
            <CardTitle class="text-2xl">{{ summary.nodes_online || 0 }} / {{ summary.nodes_total || 0 }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Online сейчас, degraded/offline: <span class="font-medium text-foreground">{{ summary.nodes_degraded || 0 }}</span>
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><HardDrive class="h-4 w-4" /> Модемы</CardDescription>
            <CardTitle class="text-2xl">{{ summary.modems_ready || 0 }} / {{ summary.modems_total || 0 }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Ready модемов в пуле прямо сейчас.
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Users class="h-4 w-4" /> Клиенты</CardDescription>
            <CardTitle class="text-2xl">{{ summary.active_clients || 0 }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Активных lease через main server на партнёрский флот.
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Activity class="h-4 w-4" /> Сессии</CardDescription>
            <CardTitle class="text-2xl">{{ summary.active_sessions || 0 }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Суммарная нагрузка по всем модемам партнёра.
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Waves class="h-4 w-4" /> Traffic In</CardDescription>
            <CardTitle class="text-2xl">{{ bytesLabel(summary.traffic_in_total) }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Входящий трафик по heartbeat aggregate.
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Gauge class="h-4 w-4" /> Traffic Out</CardDescription>
            <CardTitle class="text-2xl">{{ bytesLabel(summary.traffic_out_total) }}</CardTitle>
          </CardHeader>
          <CardContent class="flex items-center justify-between gap-3 text-sm text-muted-foreground">
            <span>{{ loading ? "refresh..." : "snapshot synced" }}</span>
            <Button variant="outline" size="sm" class="rounded-full" @click="loadOverview()">
              <RefreshCcw class="h-4 w-4" />
              Refresh
            </Button>
          </CardContent>
        </Card>
      </div>

      <div v-if="refreshError" class="rounded-[24px] border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
        {{ refreshError }}
      </div>

      <Tabs default-value="nodes" class="space-y-4">
        <TabsList class="w-fit rounded-2xl bg-muted/60 p-1">
          <TabsTrigger value="nodes" class="rounded-xl px-4">Ноды</TabsTrigger>
          <TabsTrigger value="modems" class="rounded-xl px-4">Модемы</TabsTrigger>
          <TabsTrigger value="commands" class="rounded-xl px-4">Команды</TabsTrigger>
          <TabsTrigger value="activity" class="rounded-xl px-4">Realtime</TabsTrigger>
          <TabsTrigger value="runbook" class="rounded-xl px-4">Runbook</TabsTrigger>
        </TabsList>

        <TabsContent value="nodes" class="space-y-4">
          <Card class="rounded-[28px] border-border/70 shadow-sm">
            <CardHeader class="border-b border-border/60 pb-5">
              <CardTitle class="text-2xl">Все ноды партнёра</CardTitle>
              <CardDescription>Операционный snapshot по каждой ноде: heartbeat, observed IP, трафик, ready pool и статус.</CardDescription>
            </CardHeader>
            <CardContent class="p-4 sm:p-6">
              <div class="overflow-hidden rounded-[24px] border border-border/70">
                <Table>
                  <TableHeader>
                    <TableRow class="hover:bg-transparent">
                      <TableHead>Нода</TableHead>
                      <TableHead>Статус</TableHead>
                      <TableHead>Страна</TableHead>
                      <TableHead>Observed IP</TableHead>
                      <TableHead>Modems</TableHead>
                      <TableHead>Sessions</TableHead>
                      <TableHead>Traffic</TableHead>
                      <TableHead>Heartbeat</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    <TableRow v-for="node in nodes" :key="node.node_id">
                      <TableCell>
                        <div class="font-medium">{{ node.node_id }}</div>
                        <div class="text-xs text-muted-foreground">{{ node.agent_version || "-" }}</div>
                      </TableCell>
                      <TableCell>
                        <Badge :variant="tone(node.node_status)" class="rounded-full capitalize">{{ node.node_status || "unknown" }}</Badge>
                      </TableCell>
                      <TableCell>{{ node.country || "-" }}</TableCell>
                      <TableCell class="font-mono text-xs">{{ node.external_ip || "-" }}</TableCell>
                      <TableCell>{{ Array.isArray(node.modems) ? node.modems.length : 0 }}</TableCell>
                      <TableCell>{{ node.active_sessions || 0 }}</TableCell>
                      <TableCell class="text-xs text-muted-foreground">
                        <div>In: {{ bytesLabel(node.bytes_in_total) }}</div>
                        <div>Out: {{ bytesLabel(node.bytes_out_total) }}</div>
                      </TableCell>
                      <TableCell class="text-xs">{{ relativeTime(node.last_heartbeat_at) }}</TableCell>
                    </TableRow>
                    <TableRow v-if="!nodes.length">
                      <TableCell colspan="8" class="py-10 text-center text-muted-foreground">Ноды ещё не зарегистрированы.</TableCell>
                    </TableRow>
                  </TableBody>
                </Table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="modems" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.35fr)_minmax(360px,0.65fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Флот модемов</CardTitle>
                <CardDescription>Observed egress IP, технология, сигнал, сессии и трафик по каждому модему партнёра.</CardDescription>
              </CardHeader>
              <CardContent class="p-4 sm:p-6">
                <div class="overflow-hidden rounded-[24px] border border-border/70">
                  <Table>
                    <TableHeader>
                      <TableRow class="hover:bg-transparent">
                        <TableHead>Нода / Модем</TableHead>
                        <TableHead>Статус</TableHead>
                        <TableHead>Observed IP</TableHead>
                        <TableHead>Оператор</TableHead>
                        <TableHead>Tech</TableHead>
                        <TableHead>Signal</TableHead>
                        <TableHead>Sessions</TableHead>
                        <TableHead>Traffic</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      <TableRow v-for="modem in modems" :key="`${modem.node_id}:${modem.id}`">
                        <TableCell>
                          <div class="font-medium">{{ modem.id }}</div>
                          <div class="text-xs text-muted-foreground">{{ modem.node_id }} • port {{ modem.port || "-" }}</div>
                        </TableCell>
                        <TableCell>
                          <Badge :variant="tone(modem.state)" class="rounded-full capitalize">{{ modem.state || "unknown" }}</Badge>
                        </TableCell>
                        <TableCell class="font-mono text-xs">{{ modem.wan_ip || "-" }}</TableCell>
                        <TableCell>{{ modem.operator || "-" }}</TableCell>
                        <TableCell>{{ modem.technology || "-" }}</TableCell>
                        <TableCell>
                          <div class="flex items-center gap-2">
                            <Signal class="h-4 w-4 text-muted-foreground" />
                            <span>{{ modem.signal_strength ?? "-" }}</span>
                          </div>
                        </TableCell>
                        <TableCell>{{ modem.active_sessions || 0 }}</TableCell>
                        <TableCell class="text-xs text-muted-foreground">
                          <div>In: {{ bytesLabel(modem.traffic_bytes_in) }}</div>
                          <div>Out: {{ bytesLabel(modem.traffic_bytes_out) }}</div>
                        </TableCell>
                      </TableRow>
                      <TableRow v-if="!modems.length">
                        <TableCell colspan="8" class="py-10 text-center text-muted-foreground">Модемы пока не обнаружены.</TableCell>
                      </TableRow>
                    </TableBody>
                  </Table>
                </div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Сводка по флоту</CardTitle>
                <CardDescription>Быстрый health-слой без перехода в main admin.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Готовых модемов</div>
                  <div class="mt-2 text-2xl font-semibold">{{ summary.modems_ready || 0 }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Observed IP ноды</div>
                  <div class="mt-2 font-mono text-sm">{{ overview?.external_ip || "-" }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Последний heartbeat</div>
                  <div class="mt-2 text-sm font-medium">{{ relativeTime(overview?.last_heartbeat_at) }}</div>
                </div>
                <div class="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-4 text-sm text-amber-100">
                  <div class="flex items-center gap-2 font-medium text-amber-200">
                    <TriangleAlert class="h-4 w-4" />
                    Важная сверка
                  </div>
                  <div class="mt-2 leading-6">
                    Если `observed IP` модема не совпадает с тем, что видит клиент через прокси, значит проблема в локальном egress или
                    policy routing, а не в main server.
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="commands" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(380px,0.7fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Command Center</CardTitle>
                <CardDescription>Поддержка и штатные операции по конкретной ноде и выбранному модему.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-5 p-4 sm:p-6">
                <div class="grid gap-4 md:grid-cols-2">
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Нода</div>
                    <Select v-model="selectedNode">
                      <SelectTrigger class="rounded-2xl">
                        <SelectValue placeholder="Выбери ноду" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="all">первая доступная</SelectItem>
                        <SelectItem v-for="node in nodes" :key="node.node_id" :value="node.node_id">
                          {{ node.node_id }}
                        </SelectItem>
                      </SelectContent>
                    </Select>
                  </div>

                  <div class="space-y-2">
                    <div class="text-sm font-medium">Команда</div>
                    <Select v-model="commandType">
                      <SelectTrigger class="rounded-2xl">
                        <SelectValue placeholder="Выбери команду" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem v-for="option in commandOptions" :key="option.value" :value="option.value">
                          {{ option.label }}
                        </SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                </div>

                <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_160px]">
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Модем</div>
                    <Select v-model="selectedModem">
                      <SelectTrigger class="rounded-2xl">
                        <SelectValue placeholder="Выбери модем" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="all">все ready на ноде</SelectItem>
                        <SelectItem v-for="modem in readyModems" :key="`${modem.node_id}:${modem.id}`" :value="modem.id">
                          {{ modem.id }} • {{ modem.node_id }}
                        </SelectItem>
                      </SelectContent>
                    </Select>
                  </div>

                  <div class="space-y-2">
                    <div class="text-sm font-medium">Timeout, sec</div>
                    <Input v-model="timeoutSec" class="rounded-2xl" />
                  </div>
                </div>

                <div class="space-y-2">
                  <div class="text-sm font-medium">Дополнительные params JSON</div>
                  <Textarea
                    v-model="extraParams"
                    class="rounded-[22px] font-mono text-xs"
                    placeholder='{"reason":"manual","force":true}'
                  />
                </div>

                <div class="rounded-[22px] border border-border/70 bg-muted/30 p-4 text-sm text-muted-foreground">
                  {{ selectedCommandNote }}
                </div>

                <div class="flex flex-wrap gap-3">
                  <Button class="rounded-full" @click="sendCommand()">Отправить команду</Button>
                  <Button variant="outline" class="rounded-full" @click="extraParams = ''">Очистить params</Button>
                </div>

                <div class="rounded-[22px] border border-border/70 bg-card p-4 text-sm">
                  {{ commandMessage || "Статус постановки команды в очередь появится здесь." }}
                </div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Быстрые действия</CardTitle>
                <CardDescription>Частые support-операции без main admin.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <Button class="w-full justify-start rounded-full" @click="quickAction('self_check')">
                  <BadgeCheck class="mr-2 h-4 w-4" />
                  Self Check
                </Button>
                <Button variant="outline" class="w-full justify-start rounded-full" @click="quickAction('transport_self_check')">
                  <Network class="mr-2 h-4 w-4" />
                  Transport Check
                </Button>
                <Button variant="outline" class="w-full justify-start rounded-full" @click="quickAction('reconcile_config')">
                  <Cpu class="mr-2 h-4 w-4" />
                  Reconcile Config
                </Button>
                <Button variant="outline" class="w-full justify-start rounded-full" @click="quickAction('restart_proxy')">
                  <Router class="mr-2 h-4 w-4" />
                  Restart Proxy
                </Button>
                <Button variant="outline" class="w-full justify-start rounded-full" @click="quickAction('self_update')">
                  <RefreshCcw class="mr-2 h-4 w-4" />
                  Self Update
                </Button>
                <div class="rounded-[22px] border border-border/70 bg-muted/30 p-4 text-sm text-muted-foreground">
                  {{ quickMessage || "Последний quick action и ошибки будут показаны здесь." }}
                </div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="activity" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(380px,0.72fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Последние результаты команд</CardTitle>
                <CardDescription>Что main server уже получил обратно от node-agent по всему партнёрскому флоту.</CardDescription>
              </CardHeader>
              <CardContent class="p-4 sm:p-6">
                <div class="overflow-hidden rounded-[24px] border border-border/70">
                  <Table>
                    <TableHeader>
                      <TableRow class="hover:bg-transparent">
                        <TableHead>Command ID</TableHead>
                        <TableHead>Нода</TableHead>
                        <TableHead>Статус</TableHead>
                        <TableHead>Сообщение</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      <TableRow v-for="result in activeResults" :key="result.command_id">
                        <TableCell class="font-mono text-xs">{{ result.command_id || "-" }}</TableCell>
                        <TableCell>{{ result.node_id || "-" }}</TableCell>
                        <TableCell>
                          <Badge :variant="tone(result.status)" class="rounded-full capitalize">{{ result.status || "unknown" }}</Badge>
                        </TableCell>
                        <TableCell>{{ result.message || "-" }}</TableCell>
                      </TableRow>
                      <TableRow v-if="!activeResults.length">
                        <TableCell colspan="4" class="py-10 text-center text-muted-foreground">Команд ещё не было или main server не вернул результаты.</TableCell>
                      </TableRow>
                    </TableBody>
                  </Table>
                </div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Live event feed</CardTitle>
                <CardDescription>Поток websocket-событий по partner_key с автоподтяжкой snapshot.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <div
                  v-for="event in eventFeed"
                  :key="event.id"
                  class="rounded-2xl border border-border/70 bg-card/80 p-4"
                >
                  <div class="flex items-center justify-between gap-3">
                    <div class="font-medium">{{ event.type }}</div>
                    <div class="text-xs text-muted-foreground">{{ relativeTime(event.ts) }}</div>
                  </div>
                  <div class="mt-2 text-xs leading-5 text-muted-foreground">
                    {{ JSON.stringify(event.payload) }}
                  </div>
                </div>
                <div v-if="!eventFeed.length" class="rounded-2xl border border-border/70 p-4 text-sm text-muted-foreground">
                  Ждём первые realtime-события от `ws/partner`.
                </div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="runbook" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-2">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Локальные команды</CardTitle>
                <CardDescription>Что запускать на Linux, если надо диагностировать руками.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <div v-for="item in runbookChecks" :key="item.label" class="rounded-2xl border border-border/70 p-4">
                  <div class="font-medium">{{ item.label }}</div>
                  <div class="mt-2 rounded-xl bg-muted/50 px-3 py-2 font-mono text-xs">{{ item.command }}</div>
                  <div class="mt-2 text-sm text-muted-foreground">{{ item.expected }}</div>
                </div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Что здесь теперь видно</CardTitle>
                <CardDescription>Ключевые operational-поля без похода в main admin.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6 text-sm text-muted-foreground">
                <div class="rounded-2xl border border-border/70 p-4">Весь флот по `partner_key`, а не только текущая Linux-машина.</div>
                <div class="rounded-2xl border border-border/70 p-4">Observed egress IP по модемам, чтобы сверять то, что реально видит интернет.</div>
                <div class="rounded-2xl border border-border/70 p-4">Realtime websocket-канал и live event feed вместо слепого опроса каждые 6 секунд.</div>
                <div class="rounded-2xl border border-border/70 p-4">Активные клиенты, сессии и aggregate traffic по партнёрскому флоту.</div>
                <div class="rounded-2xl border border-border/70 p-4">Команды по конкретной ноде и конкретному модему из одного экрана.</div>
                <div class="rounded-2xl border border-violet-500/30 bg-violet-500/10 p-4 text-violet-100">
                  <div class="flex items-center gap-2 font-medium text-violet-200">
                    <Wifi class="h-4 w-4" />
                    Realtime режим
                  </div>
                  <div class="mt-2 leading-6">
                    Основной апдейт идёт по `ws/partner`. Если websocket временно упал, UI держит редкий safety refresh, чтобы не застыть насмерть.
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>
      </Tabs>
    </section>
  </main>
</template>
