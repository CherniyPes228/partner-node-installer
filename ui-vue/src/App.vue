<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import {
  Activity,
  BadgeCheck,
  Cpu,
  Gauge,
  HardDrive,
  Network,
  Play,
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
const realtimeState = ref("offline")
const realtimeNote = ref("Waiting for local node overview...")
const lastRealtimeAt = ref("")
const commandType = ref("self_check")
const timeoutSec = ref("120")
const extraParams = ref("")
const selectedNode = ref("all")
const selectedModem = ref("all")
const modemFleetScope = ref("current_node")
const activeTab = ref("nodes")
const eventFeed = ref([])
const localSpeedTest = ref(null)
const localSpeedTestLoading = ref(false)
const localSpeedTestError = ref("")
const modemBilling = ref([])
const modemRegistry = ref([])
const billingMessage = ref("")
const registryMessage = ref("")
const billingSaving = ref("")
const registrySaving = ref("")
const registryResetting = ref(false)
const simChecking = ref("")
const flashSettings = ref({ auto_flash_enabled: true })
const flashSettingsLoading = ref(false)
const flashSettingsSaving = ref(false)
const flashSettingsMessage = ref("")
const localUpdateRunning = ref(false)
const localUpdateMessage = ref("")
const flashOverlay = ref({
  open: false,
  status: "",
  stage: "",
  message: "",
  label: "",
  key: "",
  startedAt: 0,
})
const seenActiveFlashKeys = ref([])
const lastFlashOverlayDebugSignature = ref("")
const speedTestTarget = ref("http://speedtest.tele2.net/1MB.zip")
const speedTestCustomUrl = ref("")
const speedTestTargets = [
  { value: "http://speedtest.tele2.net/1MB.zip", label: "Tele2 1 MB (HTTP)" },
  { value: "http://proof.ovh.net/files/1Mb.dat", label: "OVH 1 MB (HTTP)" },
  { value: "http://cachefly.cachefly.net/1mb.test", label: "CacheFly 1 MB (HTTP)" },
  { value: "custom", label: "Custom URL" },
]

let ws = null
let wsUrl = ""
let reconnectTimer = null
let refreshTimer = null
let fallbackTimer = null
let localOverviewTimer = null
let billingTimer = null
let overviewRequestInFlight = false
let billingRequestInFlight = false

const commandOptions = [
  { value: "self_check", label: "Self Check", note: "Checks node-agent, proxy, heartbeat, and modem inventory." },
  { value: "transport_self_check", label: "Transport Check", note: "Diagnoses transport to the main server and websocket session health." },
  { value: "reconcile_config", label: "Reconcile Config", note: "Rebuilds desired state, 3proxy config, and modem ports." },
  { value: "restart_proxy", label: "Restart Proxy", note: "Restarts local 3proxy on the selected node." },
  { value: "rotate_ip", label: "Rotate IP", note: "Rotates a specific HiLink modem or all ready modems on the selected node." },
  { value: "flash_modem", label: "Flash Modem", note: "Runs the safe E3372h-153 flash workflow only for supported firmware baselines." },
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
const partnerBalance = computed(() => overview.value?.partner_balance || {})
const flashJob = computed(() => (overview.value && typeof overview.value.flash_job === "object" && overview.value.flash_job) ? overview.value.flash_job : null)
const flashNotice = computed(() => (overview.value && typeof overview.value.flash_notice === "object" && overview.value.flash_notice) ? overview.value.flash_notice : null)
const billingBySlot = computed(() => {
  const map = {}
  for (const item of modemBilling.value) {
    const nodeId = String(item?.node_id || "").trim()
    const slot = Number(item?.modem_ordinal || 0)
    if (nodeId && Number.isFinite(slot) && slot > 0) map[`${nodeId}:${slot}`] = item
  }
  return map
})
const registryByIMEI = computed(() => {
  const map = {}
  for (const item of modemRegistry.value) {
    if (item.node_id && item.imei) map[`${item.node_id}:${item.imei}`] = item
  }
  return map
})
const registryByModemKey = computed(() => {
  const map = {}
  for (const item of modemRegistry.value) {
    if (item.last_seen_node_id && item.last_seen_modem_id) map[`${item.last_seen_node_id}:${item.last_seen_modem_id}`] = item
  }
  return map
})
const registryBySlot = computed(() => {
  const map = {}
  for (const item of modemRegistry.value) {
    const nodeId = String(item?.node_id || item?.last_seen_node_id || "").trim()
    const slot = Number(item?.modem_number || 0)
    if (nodeId && Number.isFinite(slot) && slot > 0) map[`${nodeId}:${slot}`] = item
  }
  return map
})
const simCheckRequiredCount = computed(() => modemBilling.value.filter((item) => item.sim_needs_check || item.sim_quarantined).length)
const activeNodeId = computed(() => selectedNode.value !== "all" ? selectedNode.value : (nodes.value[0]?.node_id || ""))
const currentOverviewNodeId = computed(() => String(overview.value?.node_id || activeNodeId.value || "").trim())
const currentNodeRegistry = computed(() => {
  const nodeId = currentOverviewNodeId.value
  if (!nodeId) return []
  return modemRegistry.value.filter((item) => String(item?.node_id || "").trim() === nodeId)
})
const filteredModems = computed(() => selectedNode.value === "all" ? modems.value : modems.value.filter((item) => item.node_id === selectedNode.value))
const fleetModems = computed(() => {
  const scopeNodeId = currentOverviewNodeId.value
  const liveModems = modemFleetScope.value === "current_node" && scopeNodeId
    ? modems.value.filter((item) => String(item?.node_id || "").trim() === scopeNodeId)
    : modems.value
  const registryItems = modemFleetScope.value === "current_node"
    ? currentNodeRegistry.value
    : modemRegistry.value

  const liveByNodeImei = {}
  for (const modem of liveModems) {
    const nodeId = String(modem?.node_id || "").trim()
    const imei = String(modem?.imei || "").trim()
    if (nodeId && imei) liveByNodeImei[`${nodeId}:${imei}`] = modem
  }

  const rows = []
  const usedLiveKeys = new Set()
  const sortedRegistry = [...registryItems].sort((left, right) => {
    const leftNode = String(left?.node_id || left?.last_seen_node_id || "").trim()
    const rightNode = String(right?.node_id || right?.last_seen_node_id || "").trim()
    if (leftNode !== rightNode) return leftNode.localeCompare(rightNode)
    const leftNumber = Number(left?.modem_number || 0)
    const rightNumber = Number(right?.modem_number || 0)
    if (leftNumber > 0 && rightNumber > 0 && leftNumber !== rightNumber) return leftNumber - rightNumber
    const leftImei = String(left?.imei || "").trim()
    const rightImei = String(right?.imei || "").trim()
    return leftImei.localeCompare(rightImei)
  })

  for (const item of sortedRegistry) {
    const nodeId = String(item?.node_id || item?.last_seen_node_id || "").trim()
    const imei = String(item?.imei || "").trim()
    const modemId = String(item?.last_seen_modem_id || "").trim()
    const live = nodeId && imei ? liveByNodeImei[`${nodeId}:${imei}`] : null
    const stableNumber = Number(item?.modem_number || 0) || 0

    const row = {
      node_id: nodeId,
      id: modemId || (imei ? `imei-${imei}` : "unknown-modem"),
      imei,
      state: "offline",
      modem_number: stableNumber,
      ordinal: stableNumber,
      known_to_node: true,
      local_flashed: String(item?.provision_status || "").trim().toLowerCase() === "ready",
      provision_status: item?.provision_status || "",
      provision_notes: item?.provision_notes || "",
      device_name: item?.device_name || "",
      hardware_version: item?.hardware_version || "",
      software_version: item?.software_version || "",
      webui_version: item?.webui_version || "",
      local_base_url: "",
      client_eligible: true,
      signal_strength: 0,
      active_sessions: 0,
      traffic_bytes_in: 0,
      traffic_bytes_out: 0,
      last_seen_at: item?.last_seen_at || "",
      ...live,
      modem_number: stableNumber || Number(live?.modem_number || 0) || 0,
      ordinal: stableNumber || Number(live?.ordinal || 0) || 0,
      _fleet_key: registryFleetRowKey(item),
    }
    rows.push(row)
    if (live) usedLiveKeys.add(liveFleetRowKey(live))
  }

  const remainingLive = [...liveModems]
    .filter((modem) => !usedLiveKeys.has(liveFleetRowKey(modem)))
    .sort((left, right) => {
      const leftNode = String(left?.node_id || "").trim()
      const rightNode = String(right?.node_id || "").trim()
      if (leftNode !== rightNode) return leftNode.localeCompare(rightNode)
      const leftNumber = Number(localModemNumber(left) || 0)
      const rightNumber = Number(localModemNumber(right) || 0)
      if (leftNumber > 0 && rightNumber > 0 && leftNumber !== rightNumber) return leftNumber - rightNumber
      return liveFleetRowKey(left).localeCompare(liveFleetRowKey(right))
    })
    .map((modem) => ({
      ...modem,
      _fleet_key: liveFleetRowKey(modem),
    }))

  return [...rows, ...remainingLive]
})
const lastResults = computed(() => commandHistory.value.slice(0, 12))
const activeFlashModem = computed(() => modems.value.find((item) => ["queued", "running", "verify"].includes(String(item.flash_status || "").toLowerCase())))
const activeFlashNodeId = computed(() => String(flashJob.value?.node_id || activeFlashModem.value?.node_id || "").trim())
const TARGET_MAIN_VERSION = "22.200.15.00.00"
const TARGET_WEBUI_VERSION = "17.100.13.113.03"
const FLASH_DISMISS_STORAGE_KEY = "partner-node.flash.dismissed-job"

function loadDismissedFlashJobKey() {
  try {
    return String(window.localStorage.getItem(FLASH_DISMISS_STORAGE_KEY) || "").trim()
  } catch {
    return ""
  }
}

function storeDismissedFlashJobKey(value) {
  try {
    if (value) {
      window.localStorage.setItem(FLASH_DISMISS_STORAGE_KEY, value)
    } else {
      window.localStorage.removeItem(FLASH_DISMISS_STORAGE_KEY)
    }
  } catch {
  }
}

function currentFlashStorageKey(job) {
  if (!job || typeof job !== "object") return ""
  const status = String(job.status || "").trim().toLowerCase()
  if (!status) return ""
  const stableKey = String(job.stable_key || "").trim()
  const imei = String(job.imei || "").trim()
  const modemId = String(job.modem_id || "").trim()
  const subject = stableKey || (imei ? `imei:${imei}` : "") || (modemId ? `modem:${modemId}` : "")
  if (!subject) return ""
  if (isTerminalFlashJob(job)) {
    const message = String(job.message || "").trim()
    return `${subject}:${status}:${message}`
  }
  const jobId = String(job.job_id || "").trim()
  if (jobId) return `${subject}:${jobId}:${status}`
  return `${subject}:${status}`
}

function isActiveFlashJob(job) {
  const status = String(job?.status || "").trim().toLowerCase()
  return ["queued", "running"].includes(status)
}

function isTerminalFlashJob(job) {
  const status = String(job?.status || "").trim().toLowerCase()
  return ["completed", "done", "failed"].includes(status)
}

function flashJobTargetModem(job) {
  if (!job) return null
  const jobNodeId = String(job.node_id || "").trim()
  const stableKey = String(job.stable_key || "").trim()
  const stableImei = stableKey.startsWith("imei:") ? normalizeDigits(stableKey.slice(5)) : ""
  const jobImei = String(job.imei || "").trim()
  const normalizedJobImei = normalizeDigits(jobImei) || stableImei
  const jobModemId = String(job.modem_id || "").trim()
  const jobOrdinal = Number(job.ordinal || 0)
  const sameNode = (item) => !jobNodeId || String(item?.node_id || "").trim() === jobNodeId
  if (normalizedJobImei) {
    const byImei = modems.value.find((item) => sameNode(item) && normalizeDigits(item?.imei) === normalizedJobImei)
    if (byImei) return byImei
  }
  if (Number.isFinite(jobOrdinal) && jobOrdinal > 0) {
    const byOrdinal = modems.value.find((item) => sameNode(item) && Number(localModemNumber(item) || 0) === jobOrdinal)
    if (byOrdinal) return byOrdinal
  }
  if (jobModemId) {
    return modems.value.find((item) => sameNode(item) && String(item.id || "").trim() === jobModemId) || null
  }
  return null
}

function normalizeDigits(value) {
  return String(value || "").replace(/\D+/g, "")
}

function bytesLabel(value) {
  const size = Number(value || 0)
  if (!Number.isFinite(size) || size <= 0) return "0 B"
  if (size < 1024) return `${size} B`
  if (size < 1024 ** 2) return `${(size / 1024).toFixed(1)} KB`
  if (size < 1024 ** 3) return `${(size / 1024 ** 2).toFixed(2)} MB`
  return `${(size / 1024 ** 3).toFixed(2)} GB`
}

function localModemNumber(modem) {
  if (!modem) return "?"
  const imeiKey = modem.node_id && modem.imei ? `${modem.node_id}:${modem.imei}` : ""
  const imeiMapped = imeiKey ? registryByIMEI.value[imeiKey] : null
  const imeiMappedNumber = Number(imeiMapped?.modem_number || 0)
  if (Number.isFinite(imeiMappedNumber) && imeiMappedNumber > 0) return imeiMappedNumber
  const registryNumber = Number(modem.modem_number || 0)
  if (Number.isFinite(registryNumber) && registryNumber > 0) return registryNumber
  const ordinal = Number(modem.ordinal || 0)
  if (Number.isFinite(ordinal) && ordinal > 0) return ordinal
  const imei = String(modem.imei || "").trim()
  if (imei) return "?"
  const key = modem.node_id && modem.id ? `${modem.node_id}:${modem.id}` : ""
  const mapped = key ? registryByModemKey.value[key] : null
  const mappedNumber = Number(mapped?.modem_number || 0)
  if (Number.isFinite(mappedNumber) && mappedNumber > 0) return mappedNumber
  return "?"
}

function registryItemForModem(modem) {
  if (!modem) return null
  const nodeId = String(modem.node_id || "").trim()
  const imei = normalizeDigits(modem.imei)
  if (nodeId && imei && registryByIMEI.value[`${nodeId}:${imei}`]) return registryByIMEI.value[`${nodeId}:${imei}`]
  const slot = Number(localModemNumber(modem) || 0)
  if (nodeId && Number.isFinite(slot) && slot > 0) return registryBySlot.value[`${nodeId}:${slot}`] || null
  const modemId = String(modem.id || "").trim()
  if (nodeId && modemId) return registryByModemKey.value[`${nodeId}:${modemId}`] || null
  return null
}

function billingItemForModem(modem) {
  if (!modem) return null
  const nodeId = String(modem.node_id || "").trim()
  const slot = Number(localModemNumber(modem) || modem.ordinal || modem.modem_number || 0)
  if (nodeId && Number.isFinite(slot) && slot > 0) return billingBySlot.value[`${nodeId}:${slot}`] || null
  return null
}

function registryItemForBillingItem(item) {
  if (!item) return null
  const nodeId = String(item.node_id || "").trim()
  const slot = Number(item.modem_ordinal || 0)
  if (nodeId && Number.isFinite(slot) && slot > 0) return registryBySlot.value[`${nodeId}:${slot}`] || null
  const modemId = String(item.modem_id || "").trim()
  if (nodeId && modemId) return registryByModemKey.value[`${nodeId}:${modemId}`] || null
  return null
}

function liveModemForRegistryItem(item) {
  if (!item) return null
  const nodeId = String(item.node_id || item.last_seen_node_id || "").trim()
  const imei = normalizeDigits(item.imei)
  if (nodeId && imei) {
    const byImei = modems.value.find((modem) => String(modem?.node_id || "").trim() === nodeId && normalizeDigits(modem?.imei) === imei)
    if (byImei) return byImei
  }
  const slot = Number(item.modem_number || 0)
  if (nodeId && Number.isFinite(slot) && slot > 0) {
    const bySlot = modems.value.find((modem) => String(modem?.node_id || "").trim() === nodeId && Number(localModemNumber(modem) || 0) === slot)
    if (bySlot) return bySlot
  }
  return null
}

function registryFleetRowKey(item) {
  if (!item) return ""
  const nodeId = String(item.node_id || item.last_seen_node_id || "").trim()
  const imei = String(item.imei || "").trim()
  const modemNumber = Number(item.modem_number || 0)
  const modemId = String(item.last_seen_modem_id || item.id || "").trim()
  if (nodeId && imei) return `registry:${nodeId}:${imei}`
  if (nodeId && Number.isFinite(modemNumber) && modemNumber > 0) return `registry:${nodeId}:slot:${modemNumber}`
  if (nodeId && modemId) return `registry:${nodeId}:${modemId}`
  return `registry:${imei || modemId || "unknown"}`
}

function liveFleetRowKey(modem) {
  if (!modem) return ""
  const nodeId = String(modem.node_id || "").trim()
  const imei = String(modem.imei || "").trim()
  const modemId = String(modem.id || "").trim()
  if (nodeId && imei) return `live:${nodeId}:${imei}`
  if (nodeId && modemId) return `live:${nodeId}:${modemId}`
  return `live:${imei || modemId || "unknown"}`
}

function fleetRowKey(modem) {
  if (!modem) return ""
  return String(modem._fleet_key || "").trim() || liveFleetRowKey(modem)
}

function aliasUrlForModem(modem) {
  const base = String(modem?.local_base_url || "").trim()
  if (base) return base
  const number = Number(localModemNumber(modem))
  if (!Number.isFinite(number) || number <= 0) return ""
  return `http://192.168.${100 + number}.1`
}

function isTargetFlashed(modem) {
  return String(modem?.software_version || "").trim() === TARGET_MAIN_VERSION
    && String(modem?.webui_version || "").trim() === TARGET_WEBUI_VERSION
}

function isKnownNodeModem(modem) {
  if (!modem?.node_id || !modem?.imei) return false
  return Boolean(registryByIMEI.value[`${modem.node_id}:${modem.imei}`])
}

function canFlashLiveModem(modem) {
  if (!modem) return false
  if (["queued", "running", "verify"].includes(String(modem.flash_status || "").toLowerCase())) return false
  if (activeFlashNodeId.value && modem.node_id === activeFlashNodeId.value) return false
  if (modem.local_flashed === true) return false
  if (!String(modem.imei || "").trim()) return false
  if (modem.known_to_node === true && String(modem.provision_status || "").trim().toLowerCase() === "ready") return false
  if (isKnownNodeModem(modem) && String(modem.provision_status || "").trim().toLowerCase() === "ready") return false
  return ["detected", "ready"].includes(String(modem.state || "").trim().toLowerCase()) || modem.provision_status === "requires_flash"
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

function normalizedFlashOverlayStatus(status) {
  const normalized = String(status || "").trim().toLowerCase()
  if (["completed", "done", "success"].includes(normalized)) return "completed"
  if (normalized === "failed") return "failed"
  if (normalized) return "running"
  return "queued"
}

function flashStatusLabel(status) {
  const normalized = normalizedFlashOverlayStatus(status)
  if (normalized === "completed") return "Flashing finished"
  if (normalized === "failed") return "Flashing failed"
  return "Flashing in progress"
}

function flashOverlayBody(status, message) {
  const normalized = normalizedFlashOverlayStatus(status)
  if (normalized === "completed") {
    return message || "The modem is back on the HiLink network. Flashing completed successfully."
  }
  if (normalized === "failed") {
    return message || "Flashing failed. Reconnect the modem and try again."
  }
  return message || "The modem is being flashed. Watch the modem LEDs. It may disconnect and reconnect during the process. Do not unplug it."
}

function flashOverlayKeyForModem(modem) {
  if (!modem) return ""
  if (modem.node_id && modem.id) return `${modem.node_id}:${modem.id}`
  if (modem.node_id && modem.imei) return `${modem.node_id}:${modem.imei}`
  return modem.imei || modem.id || ""
}

function flashOverlayKeyForJob(job, target = null) {
  if (!job || typeof job !== "object") return target ? flashOverlayKeyForModem(target) : ""
  const nodeId = String(job.node_id || target?.node_id || "").trim()
  const stableKey = String(job.stable_key || "").trim()
  if (nodeId && stableKey) return `${nodeId}:${stableKey}`
  const imei = normalizeDigits(job.imei) || normalizeDigits(target?.imei)
  if (nodeId && imei) return `${nodeId}:imei:${imei}`
  const ordinal = Number(job.ordinal || 0)
  if (nodeId && Number.isFinite(ordinal) && ordinal > 0) return `${nodeId}:ordinal:${ordinal}`
  const modemId = String(job.modem_id || target?.id || "").trim()
  if (nodeId && modemId) return `${nodeId}:${modemId}`
  return target ? flashOverlayKeyForModem(target) : ""
}

function flashOverlayLabelForJob(job, target = null) {
  const explicitOrdinal = Number(job?.ordinal || 0)
  const targetOrdinal = Number(localModemNumber(target) || 0)
  const ordinal = Number.isFinite(explicitOrdinal) && explicitOrdinal > 0
    ? explicitOrdinal
    : (Number.isFinite(targetOrdinal) && targetOrdinal > 0 ? targetOrdinal : "?")
  const idLabel = String(job?.modem_id || target?.id || "modem").trim() || "modem"
  const nodeLabel = String(job?.node_id || target?.node_id || "").trim()
  return `#${ordinal} • ${idLabel}${nodeLabel ? ` • ${nodeLabel}` : ""}`
}

function rememberActiveFlashKey(key) {
  const normalized = String(key || "").trim()
  if (!normalized) return
  if (!seenActiveFlashKeys.value.includes(normalized)) {
    seenActiveFlashKeys.value = [...seenActiveFlashKeys.value, normalized]
  }
}

function forgetActiveFlashKey(key) {
  const normalized = String(key || "").trim()
  if (!normalized) return
  seenActiveFlashKeys.value = seenActiveFlashKeys.value.filter((item) => item !== normalized)
}

function hasSeenActiveFlashKey(key) {
  const normalized = String(key || "").trim()
  return normalized ? seenActiveFlashKeys.value.includes(normalized) : false
}

function debugFlashOverlay(reason, payload = {}) {
  try {
    const snapshot = {
      reason,
      overlay_open: Boolean(flashOverlay.value.open),
      overlay_key: String(flashOverlay.value.key || "").trim(),
      overlay_status: String(flashOverlay.value.status || "").trim(),
      overlay_stage: String(flashOverlay.value.stage || "").trim(),
      flash_job_modem_id: String(flashJob.value?.modem_id || "").trim(),
      flash_job_status: String(flashJob.value?.status || "").trim(),
      flash_job_stage: String(flashJob.value?.stage || "").trim(),
      flash_notice_modem_id: String(flashNotice.value?.modem_id || "").trim(),
      flash_notice_status: String(flashNotice.value?.status || "").trim(),
      ...payload,
    }
    const signature = JSON.stringify(snapshot)
    if (signature === lastFlashOverlayDebugSignature.value) return
    lastFlashOverlayDebugSignature.value = signature
    console.info("[partner-node][flash-overlay]", snapshot)
  } catch {
  }
}

function modemForOverlayKey(key) {
  const normalized = String(key || "").trim()
  if (!normalized) return null
  return modems.value.find((item) => {
    const primaryKey = flashOverlayKeyForModem(item)
    if (primaryKey && primaryKey === normalized) return true
    if (item.node_id && item.imei && `${item.node_id}:${item.imei}` === normalized) return true
    return false
  }) || null
}

function shouldPinRunningOverlay() {
  const overlayKey = String(flashOverlay.value.key || "").trim()
  const activeOverlayStatus = String(flashOverlay.value.status || "").trim().toLowerCase()
  const activeOverlayRunning = flashOverlay.value.open && !["completed", "done", "failed", "success"].includes(activeOverlayStatus)
  if (!activeOverlayRunning || !overlayKey) return false
  const target = modemForOverlayKey(overlayKey)
  if (target) {
    const flashStatus = String(target.flash_status || "").trim().toLowerCase()
    if (["queued", "running", "verify"].includes(flashStatus)) return true
    const provisionStatus = String(target.provision_status || "").trim().toLowerCase()
    if (["requires_flash", "pending"].includes(provisionStatus)) return true
    if (target.local_flashed !== true && !isTargetFlashed(target)) return true
  }
  const startedAt = Number(flashOverlay.value.startedAt || 0)
  if (!Number.isFinite(startedAt) || startedAt <= 0) return false
  return (Date.now() - startedAt) < 120000
}

function openFlashOverlay(label, status = "queued", stage = "queued", message = "Safe flash queued. Do not unplug or reconnect the modem until the process finishes.", key = "") {
  flashOverlay.value = { open: true, status, stage, message, label, key, startedAt: Date.now() }
  debugFlashOverlay("openFlashOverlay", { label, status, stage, key, message })
}

function closeFlashOverlay() {
  const noticeKey = currentFlashStorageKey(flashNotice.value)
  const overlayKey = String(flashOverlay.value.key || "").trim()
  const noticeTarget = flashJobTargetModem(flashNotice.value)
  const noticeOverlayKey = flashOverlayKeyForJob(flashNotice.value, noticeTarget)
  if (flashNotice.value && isTerminalFlashJob(flashNotice.value) && noticeKey && (!overlayKey || overlayKey === noticeOverlayKey)) {
    storeDismissedFlashJobKey(noticeKey)
  }
  forgetActiveFlashKey(overlayKey)
  debugFlashOverlay("closeFlashOverlay", { notice_key: noticeKey, notice_overlay_key: noticeOverlayKey, overlay_key: overlayKey })
  flashOverlay.value = { ...flashOverlay.value, open: false }
}

function syncFlashOverlayFromOverview() {
  const overlayKey = String(flashOverlay.value.key || "").trim()
  const activeOverlayStatus = String(flashOverlay.value.status || "").trim().toLowerCase()
  const activeOverlayRunning = flashOverlay.value.open && !["completed", "done", "failed", "success"].includes(activeOverlayStatus)
  const hasActiveJob = Boolean(flashJob.value && isActiveFlashJob(flashJob.value))
  const activeRunningModem = activeFlashModem.value
  const activeRunningKey = flashOverlayKeyForModem(activeRunningModem)
  const pinnedRunningOverlay = shouldPinRunningOverlay()

  if (flashJob.value) {
    const target = flashJobTargetModem(flashJob.value)
    const label = flashOverlayLabelForJob(flashJob.value, target)
    if (isActiveFlashJob(flashJob.value)) {
      const activeKey = flashOverlayKeyForJob(flashJob.value, target)
      rememberActiveFlashKey(activeKey)
      storeDismissedFlashJobKey("")
      debugFlashOverlay("sync:flashJob-active", { target_key: activeKey, target_id: flashJob.value.modem_id || target?.id || "", target_number: Number(flashJob.value.ordinal || 0) || localModemNumber(target), node_label: flashJob.value.node_id || target?.node_id || "" })
      flashOverlay.value = {
        open: true,
        status: flashJob.value.status || "running",
        stage: flashJob.value.stage || flashJob.value.status || "running",
        message: flashOverlayBody(flashJob.value.status, flashJob.value.message),
        label,
        key: activeKey,
        startedAt: flashOverlay.value.startedAt || Date.now(),
      }
      return
    }
  }

  if (!hasActiveJob && activeRunningModem && activeRunningKey) {
    rememberActiveFlashKey(activeRunningKey)
    storeDismissedFlashJobKey("")
    debugFlashOverlay("sync:activeRunningModem-fallback", {
      target_key: activeRunningKey,
      target_id: activeRunningModem.id,
      target_number: localModemNumber(activeRunningModem),
      target_provision_status: activeRunningModem.provision_status || "",
      target_flash_status: activeRunningModem.flash_status || "",
      target_flash_stage: activeRunningModem.flash_stage || "",
    })
    flashOverlay.value = {
      open: true,
      status: activeRunningModem.flash_status || "running",
      stage: activeRunningModem.flash_stage || activeRunningModem.flash_status || "running",
      message: flashOverlayBody(activeRunningModem.flash_status, activeRunningModem.flash_message || ""),
      label: `#${localModemNumber(activeRunningModem)} • ${activeRunningModem.id}${activeRunningModem.node_id ? ` • ${activeRunningModem.node_id}` : ""}`,
      key: activeRunningKey,
      startedAt: flashOverlay.value.startedAt || Date.now(),
    }
    return
  }

  if (activeOverlayRunning && !hasActiveJob && overlayKey && !pinnedRunningOverlay) {
    rememberActiveFlashKey(overlayKey)
    debugFlashOverlay("sync:close-stale-running-overlay", { overlay_key: overlayKey })
    flashOverlay.value = { ...flashOverlay.value, open: false }
  }

  if (flashNotice.value && isTerminalFlashJob(flashNotice.value)) {
    const target = flashJobTargetModem(flashNotice.value)
    const noticeOverlayKey = flashOverlayKeyForJob(flashNotice.value, target)
    if (!hasSeenActiveFlashKey(noticeOverlayKey) && (!overlayKey || overlayKey !== noticeOverlayKey)) {
      debugFlashOverlay("sync:ignore-terminal-notice-without-active-session", { notice_key: noticeOverlayKey })
      return
    }
    if (pinnedRunningOverlay && overlayKey && noticeOverlayKey && overlayKey !== noticeOverlayKey) {
      debugFlashOverlay("sync:ignore-terminal-notice-because-pinned-overlay", { notice_key: noticeOverlayKey, overlay_key: overlayKey })
      return
    }
    if (activeRunningKey && noticeOverlayKey && activeRunningKey !== noticeOverlayKey) {
      debugFlashOverlay("sync:ignore-terminal-notice-because-other-modem-running", { notice_key: noticeOverlayKey, active_running_key: activeRunningKey })
      return
    }
    if (hasActiveJob && activeOverlayRunning && overlayKey && noticeOverlayKey && overlayKey !== noticeOverlayKey) {
      debugFlashOverlay("sync:ignore-terminal-notice-because-active-job", { notice_key: noticeOverlayKey, overlay_key: overlayKey })
      return
    }
    if (!hasActiveJob && activeOverlayRunning && overlayKey && noticeOverlayKey && overlayKey !== noticeOverlayKey) {
      debugFlashOverlay("sync:close-running-overlay-before-terminal-notice", { notice_key: noticeOverlayKey, overlay_key: overlayKey })
      flashOverlay.value = { ...flashOverlay.value, open: false }
      return
    }
    const dismissedKey = loadDismissedFlashJobKey()
    const currentKey = currentFlashStorageKey(flashNotice.value)
    if (currentKey && currentKey === dismissedKey) {
      if (flashOverlay.value.open) {
        debugFlashOverlay("sync:close-dismissed-terminal-notice", { notice_key: noticeOverlayKey, dismissed_key: dismissedKey })
        flashOverlay.value = { ...flashOverlay.value, open: false }
      }
      return
    }
    const label = flashOverlayLabelForJob(flashNotice.value, target)
    flashOverlay.value = {
      open: true,
      status: flashNotice.value.status || "completed",
      stage: "",
      message: flashOverlayBody(flashNotice.value.status, flashNotice.value.message),
      label,
      key: noticeOverlayKey,
      startedAt: flashOverlay.value.startedAt || Date.now(),
    }
    debugFlashOverlay("sync:show-terminal-notice", {
      notice_key: noticeOverlayKey,
      target_id: flashNotice.value.modem_id || target?.id || "",
      target_number: Number(flashNotice.value.ordinal || 0) || localModemNumber(target),
      target_status: flashNotice.value.status || "completed",
      target_message: flashNotice.value.message || "",
    })
    forgetActiveFlashKey(noticeOverlayKey)
    return
  }
  if (flashOverlay.value.open && flashOverlay.value.key) {
    debugFlashOverlay("sync:close-no-source-left", { overlay_key: flashOverlay.value.key })
    flashOverlay.value = { ...flashOverlay.value, open: false }
  }
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
function scheduleRefresh(delay = 400) { clearRefreshTimer(); refreshTimer = window.setTimeout(() => loadOverview(false), delay) }

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
  if (!nextUrl) { realtimeState.value = "disconnected"; realtimeNote.value = "Main server for realtime is not known yet."; return }
  if (ws && ws.readyState === WebSocket.OPEN && wsUrl === nextUrl) return
  closeRealtime(); wsUrl = nextUrl; realtimeState.value = "connecting"; realtimeNote.value = "Connecting websocket to the main server..."
  ws = new WebSocket(nextUrl)
  ws.onopen = () => { realtimeState.value = "active"; realtimeNote.value = "Live channel is active, the screen updates from events."; pushEvent("realtime.connected", { partner_key: overview.value?.partner_key || "" }) }
  ws.onmessage = (event) => { try { const data = JSON.parse(event.data); pushEvent(data.type || "event", data.payload || {}) } catch { pushEvent("event.raw", { text: String(event.data || "") }) } scheduleRefresh(400) }
  ws.onerror = () => { realtimeState.value = "warning"; realtimeNote.value = "Realtime channel reported an error, waiting to reconnect." }
  ws.onclose = () => { ws = null; realtimeState.value = "fallback"; realtimeNote.value = "Realtime channel is reconnecting; local polling stays active."; clearReconnect(); reconnectTimer = window.setTimeout(() => connectRealtime(), 2500) }
}

async function loadOverview(showLoader = true) {
  if (overviewRequestInFlight) return
  overviewRequestInFlight = true
  if (showLoader) loading.value = true
  refreshError.value = ""
  try {
    const response = await fetch("/api/overview", { cache: "no-store" })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    overview.value = data
    modemRegistry.value = Array.isArray(data.modem_registry) ? data.modem_registry : []
    if (selectedNode.value === "all" && data.nodes?.length === 1) selectedNode.value = data.nodes[0].node_id
    if (selectedNode.value !== "all" && !data.nodes?.some((item) => item.node_id === selectedNode.value)) selectedNode.value = data.nodes?.[0]?.node_id || "all"
    if (selectedModem.value !== "all" && !filteredModems.value.some((item) => item.id === selectedModem.value)) selectedModem.value = "all"
    connectRealtime()
  } catch (error) {
    refreshError.value = error instanceof Error ? error.message : "refresh failed"
    if (realtimeState.value !== "active") {
      realtimeState.value = "fallback"
      realtimeNote.value = "Local overview request failed, retrying with periodic polling."
    }
  } finally {
    overviewRequestInFlight = false
    loading.value = false
  }
}

async function updateModemRegistry(modem, provisionStatus) {
  registrySaving.value = (modem.node_id && modem.imei) ? `${modem.node_id}:${modem.imei}` : (modem.imei || `${modem.node_id}:${modem.id}`)
  registryMessage.value = ""
  try {
    const response = await fetch("/api/modem-registry", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        node_id: modem.node_id || modem.last_seen_node_id || "",
        imei: modem.imei,
        provision_status: provisionStatus,
        notes: modem.provision_notes || modem.notes || "",
      }),
    })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    modemRegistry.value = Array.isArray(data.items) ? data.items : modemRegistry.value
    registryMessage.value = `updated ${modem.imei || modem.id}`
    await loadOverview(false)
  } catch (error) {
    registryMessage.value = error instanceof Error ? error.message : "registry update failed"
  } finally {
    registrySaving.value = ""
  }
}

async function loadModemBilling() {
  if (billingRequestInFlight) return
  billingRequestInFlight = true
  try {
    const response = await fetch("/api/modem-billing", { cache: "no-store" })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    modemBilling.value = Array.isArray(data.modems) ? data.modems : []
  } catch (error) {
    billingMessage.value = error instanceof Error ? error.message : "billing refresh failed"
  } finally {
    billingRequestInFlight = false
  }
}

async function loadFlashSettings() {
  flashSettingsLoading.value = true
  try {
    const response = await fetch("/api/flash-settings", { cache: "no-store" })
    if (!response.ok) throw new Error(await response.text())
    flashSettings.value = await response.json()
  } catch (error) {
    flashSettingsMessage.value = error instanceof Error ? error.message : "flash settings refresh failed"
  } finally {
    flashSettingsLoading.value = false
  }
}

async function toggleAutoFlash() {
  flashSettingsSaving.value = true
  flashSettingsMessage.value = ""
  const nextValue = !flashSettings.value.auto_flash_enabled
  try {
    const response = await fetch("/api/flash-settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ auto_flash_enabled: nextValue }),
    })
    if (!response.ok) throw new Error(await response.text())
    flashSettings.value = await response.json()
    flashSettingsMessage.value = nextValue
      ? "Auto-flash enabled. Agent is restarting."
      : "Auto-flash disabled. Agent is restarting."
    await loadOverview(false)
  } catch (error) {
    flashSettingsMessage.value = error instanceof Error ? error.message : "failed to update flash settings"
  } finally {
    flashSettingsSaving.value = false
  }
}

function buildCommandPayload(type) {
  const payload = { type, timeout_sec: Number(timeoutSec.value || 120), params: {} }
  if (activeNodeId.value) payload.node_id = activeNodeId.value
  if (extraParams.value.trim()) payload.params = JSON.parse(extraParams.value)
  if ((type === "rotate_ip" || type === "flash_modem") && selectedModem.value !== "all") {
    payload.params.modem_ids = [selectedModem.value]
    payload.params.modem_id = selectedModem.value
  }
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

async function runLocalSpeedTest() {
  if (selectedModem.value === "all") {
    localSpeedTestError.value = "Choose a modem first."
    return
  }
  const targetUrl = speedTestTarget.value === "custom" ? speedTestCustomUrl.value.trim() : speedTestTarget.value
  if (!targetUrl) {
    localSpeedTestError.value = "Choose a test service or enter a custom URL."
    return
  }
  localSpeedTestLoading.value = true
  localSpeedTestError.value = ""
  try {
    const response = await fetch("/api/speedtest", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        node_id: activeNodeId.value,
        modem_id: selectedModem.value,
        bytes: 2_000_000,
        target_url: targetUrl,
      }),
    })
    if (!response.ok) throw new Error(await response.text())
    localSpeedTest.value = await response.json()
  } catch (error) {
    localSpeedTestError.value = error instanceof Error ? error.message : "local speed test failed"
  } finally {
    localSpeedTestLoading.value = false
  }
}

async function saveBilling(modem) {
  billingSaving.value = `${modem.node_id}:${modem.modem_id}`
  billingMessage.value = ""
  try {
    const payload = {
      node_id: modem.node_id,
      modem_id: modem.modem_id,
      plan_kind: modem.plan_kind || "metered",
      traffic_limit_gb: modem.plan_kind === "unlimited" || modem.traffic_limit_gb === "" || modem.traffic_limit_gb == null ? null : Number(modem.traffic_limit_gb),
      auto_reset_day: modem.auto_reset_day === "" || modem.auto_reset_day == null ? null : Number(modem.auto_reset_day),
      notes: modem.notes || "",
    }
    const response = await fetch("/api/modem-billing", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    modemBilling.value = Array.isArray(data.modems) ? data.modems : modemBilling.value
    billingMessage.value = `saved ${modem.modem_id}`
  } catch (error) {
    billingMessage.value = error instanceof Error ? error.message : "billing save failed"
  } finally {
    billingSaving.value = ""
  }
}

async function resetBilling(modem) {
  billingSaving.value = `${modem.node_id}:${modem.modem_id}`
  billingMessage.value = ""
  try {
    const payload = {
      node_id: modem.node_id,
      modem_id: modem.modem_id,
      plan_kind: modem.plan_kind || "metered",
      traffic_limit_gb: modem.plan_kind === "unlimited" || modem.traffic_limit_gb === "" || modem.traffic_limit_gb == null ? null : Number(modem.traffic_limit_gb),
      auto_reset_day: modem.auto_reset_day === "" || modem.auto_reset_day == null ? null : Number(modem.auto_reset_day),
      notes: modem.notes || "",
      manual_reset: true,
    }
    const response = await fetch("/api/modem-billing", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    })
    if (!response.ok) throw new Error(await response.text())
    const data = await response.json()
    modemBilling.value = Array.isArray(data.modems) ? data.modems : modemBilling.value
    billingMessage.value = `reset ${modem.modem_id}`
  } catch (error) {
    billingMessage.value = error instanceof Error ? error.message : "billing reset failed"
  } finally {
    billingSaving.value = ""
  }
}

async function verifySim(modem) {
  simChecking.value = `${modem.node_id}:${modem.modem_id}`
  billingMessage.value = ""
  try {
    const response = await fetch("/api/sim-check", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        node_id: modem.node_id,
        modem_id: modem.modem_id,
        notes: modem.notes || "",
      }),
    })
    if (!response.ok) throw new Error(await response.text())
    await response.json()
    await loadOverview(false)
    billingMessage.value = `sim verified for ${modem.modem_id}`
  } catch (error) {
    billingMessage.value = error instanceof Error ? error.message : "sim check failed"
  } finally {
    simChecking.value = ""
  }
}

async function flashRegistryModem(item) {
  if (activeFlashNodeId.value && String(item?.node_id || "").trim() === activeFlashNodeId.value) {
    registryMessage.value = `another modem is already flashing on node ${activeFlashNodeId.value}`
    return
  }
  registrySaving.value = (item.node_id && item.imei) ? `${item.node_id}:${item.imei}` : (item.imei || `${item.last_seen_node_id}:${item.last_seen_modem_id}`)
  registryMessage.value = ""
  try {
    const targetModem = liveModemForRegistryItem(item)
    if (!targetModem) {
      throw new Error(`insert modem #${item.modem_number || "?"} so the node can target its current live slot`)
    }
    const overlayKey = flashOverlayKeyForModem(targetModem)
    rememberActiveFlashKey(overlayKey)
    debugFlashOverlay("action:flashRegistryModem", { overlay_key: overlayKey, modem_number: item.modem_number || "?", modem_id: targetModem.id })
    openFlashOverlay(`#${item.modem_number || localModemNumber(targetModem) || "?"} • ${targetModem.id}${targetModem.node_id ? ` • ${targetModem.node_id}` : ""}`, "queued", "queued", flashOverlayBody("running", ""), overlayKey)
    const response = await fetch("/api/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        node_id: targetModem.node_id || item.node_id || item.last_seen_node_id || "",
        type: "flash_modem",
        timeout_sec: 1800,
        params: {
          modem_id: targetModem.id || "",
          modem_ids: targetModem.id ? [targetModem.id] : [],
        },
      }),
    })
    if (!response.ok) throw new Error(await response.text())
    await response.json()
    registryMessage.value = `flash queued for modem #${item.modem_number}`
    await loadOverview(false)
  } catch (error) {
    flashOverlay.value = {
      ...flashOverlay.value,
      open: true,
      status: "failed",
      stage: "failed",
      message: error instanceof Error ? error.message : "flash command failed",
    }
    registryMessage.value = error instanceof Error ? error.message : "flash command failed"
  } finally {
    registrySaving.value = ""
  }
}

async function flashLiveModem(modem) {
  const key = modem.imei || `${modem.node_id}:${modem.id}`
  registrySaving.value = key
  registryMessage.value = ""
  try {
    const overlayKey = flashOverlayKeyForModem(modem)
    rememberActiveFlashKey(overlayKey)
    debugFlashOverlay("action:flashLiveModem", { overlay_key: overlayKey, modem_id: modem.id, modem_number: localModemNumber(modem) })
    openFlashOverlay(`#${localModemNumber(modem)} • ${modem.id}${modem.node_id ? ` • ${modem.node_id}` : ""}`, "queued", "queued", flashOverlayBody("running", ""), overlayKey)
    const response = await fetch("/api/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        node_id: modem.node_id || "",
        type: "flash_modem",
        timeout_sec: 1800,
        params: {
          modem_id: modem.id || "",
          modem_ids: modem.id ? [modem.id] : [],
        },
      }),
    })
    if (!response.ok) throw new Error(await response.text())
    await response.json()
    registryMessage.value = `flash queued for ${modem.id}`
    await loadOverview(false)
  } catch (error) {
    flashOverlay.value = {
      ...flashOverlay.value,
      open: true,
      status: "failed",
      stage: "failed",
      message: error instanceof Error ? error.message : "flash command failed",
    }
    registryMessage.value = error instanceof Error ? error.message : "flash command failed"
  } finally {
    registrySaving.value = ""
  }
}

async function resetLocalNodeModemState() {
  if (registryResetting.value) return
  if (isActiveFlashJob(flashJob.value)) {
    registryMessage.value = "stop the active flash job first"
    return
  }
  if (!window.confirm("Clear local modem memory on this node and restart partner-node? This also requests a node registry reset on the main server.")) return
  registryResetting.value = true
  registryMessage.value = ""
  try {
    const response = await fetch("/api/local/reset-modems", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    })
    if (!response.ok) throw new Error(await response.text())
    const result = await response.json()
    const removedCount = Array.isArray(result.removed_files) ? result.removed_files.length : 0
    const resetNote = result.server_registry_reset === true ? "server registry cleared" : "server registry reset skipped"
    registryMessage.value = `local modem state cleared (${removedCount} files), agent restarted, ${resetNote}`
    closeFlashOverlay()
    await new Promise((resolve) => window.setTimeout(resolve, 1500))
    await loadOverview(false)
    scheduleRefresh(3000)
  } catch (error) {
    registryMessage.value = error instanceof Error ? error.message : "failed to reset local modem state"
  } finally {
    registryResetting.value = false
  }
}

async function runLocalNodeUpdate() {
  if (localUpdateRunning.value) return
  if (isActiveFlashJob(flashJob.value)) {
    localUpdateMessage.value = "stop the active flash job first"
    return
  }
  if (!window.confirm("Run in-place update on this node now? The same partner key and installed config will be reused. partner-node and the local UI may restart for a short time.")) return
  localUpdateRunning.value = true
  localUpdateMessage.value = ""
  try {
    const response = await fetch("/api/local/run-update", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    })
    if (!response.ok) throw new Error(await response.text())
    const result = await response.json()
    localUpdateMessage.value = result?.message || "node update started"
    scheduleRefresh(5000)
    window.setTimeout(() => { loadOverview(false) }, 12000)
  } catch (error) {
    localUpdateMessage.value = error instanceof Error ? error.message : "failed to start node update"
  } finally {
    localUpdateRunning.value = false
  }
}

function quickAction(type) { sendCommand(type, "quick") }
watch(selectedNode, () => { if (!filteredModems.value.some((item) => item.id === selectedModem.value)) selectedModem.value = "all" })
watch(activeTab, (value) => {
  if (value === "modems") loadModemBilling()
})
watch([modems, overview], () => { syncFlashOverlayFromOverview() }, { deep: true })
onMounted(() => {
  loadOverview()
  loadFlashSettings()
  if (activeTab.value === "modems") loadModemBilling()
  localOverviewTimer = window.setInterval(() => {
    loadOverview(false)
  }, 4000)
  billingTimer = window.setInterval(() => {
    if (activeTab.value === "modems") loadModemBilling()
  }, 20000)
  fallbackTimer = window.setInterval(() => {
    if (realtimeState.value !== "active") loadOverview(false)
  }, 15000)
})
onBeforeUnmount(() => {
  closeRealtime()
  clearRefreshTimer()
  if (fallbackTimer) {
    window.clearInterval(fallbackTimer)
    fallbackTimer = null
  }
  if (localOverviewTimer) {
    window.clearInterval(localOverviewTimer)
    localOverviewTimer = null
  }
  if (billingTimer) {
    window.clearInterval(billingTimer)
    billingTimer = null
  }
})
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

      <div class="grid gap-4 xl:grid-cols-7">
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Server class="h-4 w-4" /> Nodes</CardDescription><CardTitle class="text-2xl">{{ summary.nodes_online || 0 }} / {{ summary.nodes_total || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Currently online, degraded/offline: <span class="font-medium text-foreground">{{ summary.nodes_degraded || 0 }}</span></CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><HardDrive class="h-4 w-4" /> Modems</CardDescription><CardTitle class="text-2xl">{{ summary.modems_ready || 0 }} / {{ summary.modems_total || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Ready modems currently in the pool.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Users class="h-4 w-4" /> Clients</CardDescription><CardTitle class="text-2xl">{{ summary.active_clients || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Active leases through the main server for this partner fleet.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Activity class="h-4 w-4" /> Sessions</CardDescription><CardTitle class="text-2xl">{{ summary.active_sessions || 0 }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Aggregate load across all partner modems.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Waves class="h-4 w-4" /> Traffic In</CardDescription><CardTitle class="text-2xl">{{ bytesLabel(summary.traffic_in_total) }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Inbound traffic from aggregated heartbeat data.</CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><Gauge class="h-4 w-4" /> Traffic Out</CardDescription><CardTitle class="text-2xl">{{ bytesLabel(summary.traffic_out_total) }}</CardTitle></CardHeader><CardContent class="flex items-center justify-between gap-3 text-sm text-muted-foreground"><span>{{ loading ? "refresh..." : "snapshot synced" }}</span><Button variant="outline" size="sm" class="rounded-full" @click="loadOverview()"><RefreshCcw class="h-4 w-4" />Refresh</Button></CardContent></Card>
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1"><CardHeader class="pb-3"><CardDescription class="flex items-center gap-2"><BadgeCheck class="h-4 w-4" /> Balance</CardDescription><CardTitle class="text-2xl">${{ Number(partnerBalance.balance_usd || 0).toFixed(2) }}</CardTitle></CardHeader><CardContent class="text-sm text-muted-foreground">Daily accrual balance for this partner.</CardContent></Card>
      </div>

      <div v-if="refreshError" class="rounded-[24px] border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">{{ refreshError }}</div>

      <Tabs v-model="activeTab" default-value="nodes" class="space-y-4">
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
          <Card class="rounded-[28px] border-border/70 shadow-sm"><CardHeader class="border-b border-border/60 pb-5"><div class="flex flex-wrap items-start justify-between gap-3"><div><CardTitle class="text-2xl">Modem fleet</CardTitle><CardDescription>Observed egress IP, node-local modem number, firmware baseline, SIM ICCID, and package usage.</CardDescription></div><div class="w-full max-w-[220px] space-y-2"><div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Scope</div><Select v-model="modemFleetScope"><SelectTrigger class="rounded-2xl"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="current_node">This node only</SelectItem><SelectItem value="all_nodes">All nodes</SelectItem></SelectContent></Select></div></div></CardHeader><CardContent class="p-4 sm:p-6"><div class="overflow-hidden rounded-[24px] border border-border/70"><Table><TableHeader><TableRow class="hover:bg-transparent"><TableHead>Node / Modem</TableHead><TableHead>Status</TableHead><TableHead>Observed IP</TableHead><TableHead>SIM</TableHead><TableHead>Operator</TableHead><TableHead>Tech</TableHead><TableHead>Signal</TableHead><TableHead>Sessions</TableHead><TableHead>Traffic</TableHead><TableHead>Plan</TableHead><TableHead>Action</TableHead></TableRow></TableHeader><TableBody><TableRow v-for="modem in fleetModems" :key="fleetRowKey(modem)"><TableCell><div class="font-medium">#{{ localModemNumber(modem) }} • {{ modem.id }}</div><div class="text-xs text-muted-foreground">{{ modem.node_id }} • port {{ modem.port || "-" }}</div><div v-if="aliasUrlForModem(modem)" class="text-xs text-muted-foreground"><a :href="aliasUrlForModem(modem)" class="underline underline-offset-4" target="_blank" rel="noreferrer">{{ aliasUrlForModem(modem) }}</a></div><div class="text-xs text-muted-foreground">{{ modem.imei || "IMEI pending" }}</div><div class="text-xs text-muted-foreground">{{ modem.usb_mode || "mode pending" }}<span v-if="modem.usb_vendor_id || modem.usb_product_id"> • {{ modem.usb_vendor_id || "----" }}:{{ modem.usb_product_id || "----" }}</span></div><div v-if="modem.usb_mode === 'charging'" class="mt-1 text-[11px] text-amber-600">Recovery required: unplug and reconnect before retrying flash.</div></TableCell><TableCell><div class="space-y-1"><Badge :variant="tone(modem.state)" class="rounded-full capitalize">{{ modem.state || "unknown" }}</Badge><Badge v-if="modem.provision_status" :variant="modem.provision_status === 'ready' ? 'secondary' : modem.provision_status === 'requires_flash' ? 'destructive' : 'outline'" class="rounded-full">{{ modem.provision_status }}</Badge><Badge v-if="modem.sim_needs_check || modem.sim_quarantined" variant="destructive" class="rounded-full">SIM check required</Badge></div><div v-if="modem.flash_message" class="mt-2 text-[11px] text-muted-foreground">{{ modem.flash_message }}</div></TableCell><TableCell class="font-mono text-xs">{{ modem.wan_ip || "-" }}</TableCell><TableCell class="text-xs"><div class="font-mono">{{ modem.iccid || "-" }}</div><div class="text-muted-foreground">{{ modem.client_eligible === false ? "blocked for clients" : "eligible" }}</div></TableCell><TableCell>{{ modem.operator || "-" }}</TableCell><TableCell>{{ modem.technology || "-" }}</TableCell><TableCell><div class="flex items-center gap-2"><Signal class="h-4 w-4 text-muted-foreground" /><span>{{ modem.signal_strength ?? "-" }}</span></div><div class="mt-1 text-[11px] text-muted-foreground">{{ modem.software_version || "-" }} / {{ modem.webui_version || "-" }}</div></TableCell><TableCell>{{ modem.active_sessions || 0 }}</TableCell><TableCell class="text-xs text-muted-foreground"><div>In: {{ bytesLabel(modem.traffic_bytes_in) }}</div><div>Out: {{ bytesLabel(modem.traffic_bytes_out) }}</div></TableCell><TableCell class="text-xs text-muted-foreground"><template v-if="billingItemForModem(modem)"><div>{{ billingItemForModem(modem).plan_kind === 'unlimited' ? 'Unlimited' : `${billingItemForModem(modem).traffic_limit_gb || '-'} GB` }}</div><div>Cycle: {{ bytesLabel(billingItemForModem(modem).cycle_used_bytes) }}</div></template><span v-else>-</span></TableCell><TableCell class="text-xs"><Button v-if="canFlashLiveModem(modem)" variant="destructive" size="sm" class="rounded-full" :disabled="registrySaving === ((modem.node_id && modem.imei) ? `${modem.node_id}:${modem.imei}` : (modem.imei || `${modem.node_id}:${modem.id}`))" @click="flashLiveModem(modem)">Flash now</Button><span v-else class="text-muted-foreground">-</span></TableCell></TableRow><TableRow v-if="!fleetModems.length"><TableCell colspan="11" class="py-10 text-center text-muted-foreground">{{ modemFleetScope === 'current_node' ? 'No modems discovered on this node yet.' : 'No modems have been discovered yet.' }}</TableCell></TableRow></TableBody></Table></div></CardContent></Card>
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(400px,0.8fr)]">
            <div class="space-y-4">
              <Card class="rounded-[28px] border-border/70 shadow-sm"><CardHeader class="border-b border-border/60 pb-5"><div class="flex flex-wrap items-start justify-between gap-3"><div><CardTitle class="text-2xl">Provisioning registry</CardTitle><CardDescription>Every modem gets a stable number by IMEI, so you can label the hardware and keep tracking it after moving to another USB port.</CardDescription></div><Button variant="destructive" class="rounded-full" :disabled="registryResetting || isActiveFlashJob(flashJob)" @click="resetLocalNodeModemState()">{{ registryResetting ? "Clearing..." : "Clear node memory" }}</Button></div></CardHeader><CardContent class="space-y-4 p-4 sm:p-6"><div v-if="registryMessage" class="rounded-xl border border-border/70 bg-muted/50 px-3 py-2 text-sm">{{ registryMessage }}</div><div class="rounded-xl border border-border/70 bg-muted/30 px-3 py-2 text-xs text-muted-foreground">This clears the local node modem registry, active flash state, and requests a server-side reset for this node. Use it before retesting the same modem as new hardware.</div><div v-for="item in currentNodeRegistry" :key="`${item.node_id}:${item.imei}`" class="rounded-[24px] border border-border/70 p-4 space-y-3"><div class="flex flex-wrap items-start justify-between gap-3"><div><div class="flex flex-wrap items-center gap-2"><div class="font-medium">Modem #{{ item.modem_number }}</div><Badge :variant="item.provision_status === 'ready' ? 'secondary' : item.provision_status === 'requires_flash' ? 'destructive' : 'outline'" class="rounded-full">{{ item.provision_status || "new" }}</Badge></div><div class="mt-1 font-mono text-xs text-muted-foreground">{{ item.imei }}</div><div class="mt-1 text-xs text-muted-foreground">{{ item.device_name || "-" }} • {{ item.hardware_version || "-" }}</div><div class="mt-1 text-xs text-muted-foreground">{{ item.software_version || "-" }} • {{ item.webui_version || "-" }}</div></div><div class="text-right text-xs text-muted-foreground"><div>{{ item.last_seen_node_id || "-" }} • {{ item.last_seen_modem_id || "-" }}</div><div>{{ relativeTime(item.last_seen_at) }}</div></div></div><div class="rounded-xl border border-border/70 bg-muted/30 px-3 py-2 text-xs text-muted-foreground">Safe flash is limited to supported E3372h-153 baselines from the approved firmware list. Unknown revisions stay blocked.</div><div class="flex flex-wrap gap-3"><Button variant="outline" class="rounded-full" :disabled="registrySaving === `${item.node_id}:${item.imei}`" @click="updateModemRegistry(item, 'ready')">Mark ready</Button><Button variant="secondary" class="rounded-full" :disabled="registrySaving === `${item.node_id}:${item.imei}`" @click="updateModemRegistry(item, 'requires_flash')">Needs flash</Button><Button v-if="item.provision_status === 'requires_flash'" variant="destructive" class="rounded-full" :disabled="registrySaving === `${item.node_id}:${item.imei}` || !item.last_seen_node_id || !item.last_seen_modem_id" @click="flashRegistryModem(item)">Flash now</Button></div></div><div v-if="!currentNodeRegistry.length" class="rounded-[24px] border border-dashed border-border/70 px-4 py-10 text-center text-sm text-muted-foreground">No provisioned modems yet. Plug them one by one to assign a stable modem number.</div></CardContent></Card>
              <Card class="rounded-[28px] border-border/70 shadow-sm"><CardHeader class="border-b border-border/60 pb-5"><CardTitle class="text-2xl">SIM package controls</CardTitle><CardDescription>Per-modem traffic package, SIM health status, auto reset day, and manual reset of the current billing cycle.</CardDescription></CardHeader><CardContent class="space-y-4 p-4 sm:p-6"><div v-if="simCheckRequiredCount" class="rounded-xl border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">{{ simCheckRequiredCount }} SIM card(s) are blocked from client traffic until you verify them on a healthy modem.</div><div v-if="billingMessage" class="rounded-xl border border-border/70 bg-muted/50 px-3 py-2 text-sm">{{ billingMessage }}</div><div v-for="item in modemBilling" :key="`${item.node_id}:${item.modem_ordinal || item.modem_id}`" class="rounded-[24px] border border-border/70 p-4 space-y-3"><div class="flex flex-wrap items-start justify-between gap-3"><div><div class="flex flex-wrap items-center gap-2"><div class="font-medium">#{{ localModemNumber({ node_id: item.node_id, id: item.modem_id, ordinal: item.modem_ordinal }) }} • {{ item.modem_id }}</div><Badge v-if="registryItemForBillingItem(item)?.provision_status" :variant="registryItemForBillingItem(item)?.provision_status === 'ready' ? 'secondary' : registryItemForBillingItem(item)?.provision_status === 'requires_flash' ? 'destructive' : 'outline'" class="rounded-full">{{ registryItemForBillingItem(item)?.provision_status }}</Badge><Badge v-if="item.sim_needs_check || item.sim_quarantined" variant="destructive" class="rounded-full">Blocked for clients</Badge><Badge v-else variant="secondary" class="rounded-full">SIM healthy</Badge></div><div class="text-xs text-muted-foreground">{{ item.node_id }} • ICCID {{ item.iccid || "-" }} • cycle used {{ bytesLabel(item.cycle_used_bytes) }}<span v-if="item.next_reset_at"> • next reset {{ relativeTime(item.next_reset_at) }}</span></div><div v-if="item.sim_quarantine_note" class="mt-1 text-xs text-destructive">{{ item.sim_quarantine_note }}</div></div><div class="text-right text-xs text-muted-foreground"><div>Started {{ relativeTime(item.cycle_start_at) }}</div><div v-if="item.remaining_bytes != null">Left {{ bytesLabel(item.remaining_bytes) }}</div><div v-if="item.sim_last_checked_at">Checked {{ relativeTime(item.sim_last_checked_at) }}</div></div></div><div class="grid gap-3 md:grid-cols-4"><div class="space-y-2"><div class="text-sm font-medium">Plan</div><Select v-model="item.plan_kind"><SelectTrigger class="rounded-2xl"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="metered">Metered</SelectItem><SelectItem value="unlimited">Unlimited</SelectItem></SelectContent></Select></div><div class="space-y-2"><div class="text-sm font-medium">Limit GB</div><Input v-model="item.traffic_limit_gb" :disabled="item.plan_kind === 'unlimited'" class="rounded-2xl" type="number" min="0" step="0.1" /></div><div class="space-y-2"><div class="text-sm font-medium">Auto reset day</div><Input v-model="item.auto_reset_day" class="rounded-2xl" type="number" min="1" max="28" placeholder="2" /></div><div class="space-y-2"><div class="text-sm font-medium">Notes</div><Input v-model="item.notes" class="rounded-2xl" placeholder="SIM tariff note" /></div></div><div class="grid gap-2 text-xs text-muted-foreground md:grid-cols-3"><div class="rounded-xl border border-border/70 p-3"><div class="font-medium text-foreground">ICCID</div><div class="mt-1 font-mono">{{ item.iccid || "-" }}</div></div><div class="rounded-xl border border-border/70 p-3"><div class="font-medium text-foreground">Degraded / 24h</div><div class="mt-1">{{ item.sim_degraded_events_24h || 0 }}</div></div><div class="rounded-xl border border-border/70 p-3"><div class="font-medium text-foreground">Client status</div><div class="mt-1">{{ item.sim_needs_check || item.sim_quarantined ? "blocked" : "eligible" }}</div></div></div><div class="flex flex-wrap gap-3"><Button class="rounded-full" :disabled="billingSaving === `${item.node_id}:${item.modem_id}`" @click="saveBilling(item)">{{ billingSaving === `${item.node_id}:${item.modem_id}` ? 'Saving...' : 'Save' }}</Button><Button variant="outline" class="rounded-full" :disabled="billingSaving === `${item.node_id}:${item.modem_id}`" @click="resetBilling(item)">Manual reset</Button><Button variant="secondary" class="rounded-full" :disabled="simChecking === `${item.node_id}:${item.modem_id}` || !(item.sim_needs_check || item.sim_quarantined)" @click="verifySim(item)">{{ simChecking === `${item.node_id}:${item.modem_id}` ? 'Checking...' : 'Verify SIM' }}</Button></div></div><div v-if="!modemBilling.length" class="rounded-[24px] border border-dashed border-border/70 px-4 py-10 text-center text-sm text-muted-foreground">No modem billing data yet.</div></CardContent></Card>
            </div>
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Fleet summary</CardTitle>
                <CardDescription>Health, speed, local proxy diagnostics, and flash controls.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Ready modems</div>
                  <div class="mt-2 text-2xl font-semibold">{{ summary.modems_ready || 0 }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Month accrual</div>
                  <div class="mt-2 text-2xl font-semibold">${{ Number(partnerBalance.current_month_earned_usd || 0).toFixed(2) }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Last heartbeat</div>
                  <div class="mt-2 text-sm font-medium">{{ relativeTime(overview?.last_heartbeat_at) }}</div>
                </div>
                <div class="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-4 text-sm text-amber-100">
                  <div class="flex items-center gap-2 font-medium text-amber-200"><TriangleAlert class="h-4 w-4" />Important check</div>
                  <div class="mt-2 leading-6">If a modem observed IP does not match what a client sees through the proxy, the issue is in local egress or policy routing, not in the main server.</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4 space-y-3">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Auto-flash</div>
                      <div class="mt-1 text-sm text-muted-foreground">Disable this before manual recovery or low-level modem work. Manual <span class="font-medium text-foreground">Flash now</span> stays available.</div>
                    </div>
                    <Button
                      :variant="flashSettings.auto_flash_enabled ? 'default' : 'outline'"
                      class="rounded-full"
                      :disabled="flashSettingsLoading || flashSettingsSaving"
                      @click="toggleAutoFlash()"
                    >
                      {{ flashSettingsSaving ? "Applying..." : flashSettings.auto_flash_enabled ? "Auto-flash ON" : "Auto-flash OFF" }}
                    </Button>
                  </div>
                  <div class="text-xs text-muted-foreground">
                    Current mode: {{ flashSettings.auto_flash_enabled ? "new modems may start provisioning automatically" : "automatic provisioning is paused" }}
                  </div>
                  <div v-if="flashSettingsMessage" class="rounded-xl border border-border/70 bg-muted/50 px-3 py-2 text-sm">{{ flashSettingsMessage }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4 space-y-3">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Node update</div>
                      <div class="mt-1 text-sm text-muted-foreground">Refresh node-agent, local UI, flash helpers, and systemd units without a full reinstall. The current partner key and installed config stay in place.</div>
                    </div>
                    <Button
                      variant="outline"
                      class="rounded-full"
                      :disabled="localUpdateRunning || isActiveFlashJob(flashJob)"
                      @click="runLocalNodeUpdate()"
                    >
                      {{ localUpdateRunning ? "Starting..." : "Update node" }}
                    </Button>
                  </div>
                  <div class="text-xs text-muted-foreground">
                    This downloads the latest installer update script from GitHub and runs it on the node. partner services may briefly restart.
                  </div>
                  <div v-if="localUpdateMessage" class="rounded-xl border border-border/70 bg-muted/50 px-3 py-2 text-sm">{{ localUpdateMessage }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4 space-y-3">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Local modem speed test</div>
                      <div class="mt-1 text-sm text-muted-foreground">Runs directly on the node through the selected modem port. You can choose any endpoint or enter a custom URL.</div>
                    </div>
                    <Button variant="outline" class="rounded-full" :disabled="localSpeedTestLoading || selectedModem === 'all'" @click="runLocalSpeedTest()"><Play class="mr-2 h-4 w-4" />{{ localSpeedTestLoading ? "Testing..." : "Run test" }}</Button>
                  </div>
                  <div class="grid gap-3 md:grid-cols-[220px_minmax(0,1fr)]">
                    <div class="space-y-2">
                      <div class="text-sm font-medium">Service</div>
                      <Select v-model="speedTestTarget">
                        <SelectTrigger class="rounded-2xl"><SelectValue placeholder="Choose service" /></SelectTrigger>
                        <SelectContent><SelectItem v-for="item in speedTestTargets" :key="item.value" :value="item.value">{{ item.label }}</SelectItem></SelectContent>
                      </Select>
                    </div>
                    <div v-if="speedTestTarget === 'custom'" class="space-y-2">
                      <div class="text-sm font-medium">Custom URL</div>
                      <Input v-model="speedTestCustomUrl" class="rounded-2xl" placeholder="https://example.com/test.bin" />
                    </div>
                  </div>
                  <div class="text-xs text-muted-foreground">Select a modem in the command center first. For Cloudflare-style endpoints the `bytes` query is added automatically if needed.</div>
                  <div v-if="localSpeedTestError" class="rounded-xl border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">{{ localSpeedTestError }}</div>
                  <div v-if="localSpeedTest" class="rounded-xl border border-border/70 bg-muted/40 p-3 text-sm space-y-2">
                    <div class="flex items-center justify-between gap-3"><span class="text-muted-foreground">Download</span><span class="font-semibold">{{ localSpeedTest.download_mbps }} Mbps</span></div>
                    <div class="flex items-center justify-between gap-3"><span class="text-muted-foreground">Transferred</span><span>{{ bytesLabel(localSpeedTest.bytes_received) }}</span></div>
                    <div class="flex items-center justify-between gap-3"><span class="text-muted-foreground">Duration</span><span>{{ localSpeedTest.duration_ms }} ms</span></div>
                    <div class="flex items-center justify-between gap-3"><span class="text-muted-foreground">Remote IP</span><span class="font-mono text-xs">{{ localSpeedTest.remote_ip || "-" }}</span></div>
                    <div class="flex items-center justify-between gap-3"><span class="text-muted-foreground">URL</span><span class="max-w-[220px] truncate text-right font-mono text-xs">{{ localSpeedTest.target_url || "-" }}</span></div>
                  </div>
                </div>
              </CardContent>
            </Card>
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
                    <div class="text-sm font-medium">Target node</div>
                    <Select v-model="selectedNode">
                      <SelectTrigger id="node-select" class="rounded-2xl"><SelectValue placeholder="Choose node" /></SelectTrigger>
                      <SelectContent>
                        <SelectItem value="all">Auto / first online node</SelectItem>
                        <SelectItem v-for="node in nodes" :key="node.node_id" :value="node.node_id">{{ node.node_id }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Target modem</div>
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
                    <div class="text-sm font-medium">Command</div>
                    <Select v-model="commandType">
                      <SelectTrigger id="command-type" class="rounded-2xl"><SelectValue placeholder="Choose command" /></SelectTrigger>
                      <SelectContent>
                        <SelectItem v-for="item in commandOptions" :key="item.value" :value="item.value">{{ item.label }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Timeout, sec</div>
                    <Input id="timeout-sec" v-model="timeoutSec" class="rounded-2xl" type="number" min="10" />
                  </div>
                </div>

                <div class="space-y-2">
                  <div class="text-sm font-medium">Extra JSON params</div>
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
    <div v-if="flashOverlay.open" class="fixed inset-0 z-[70] flex items-center justify-center bg-background/80 px-4 backdrop-blur-sm">
      <div class="w-full max-w-2xl rounded-[32px] border border-border/70 bg-card p-6 shadow-2xl">
        <div class="flex items-start justify-between gap-4">
          <div class="space-y-2">
            <Badge variant="destructive" class="rounded-full px-3 py-1 text-[11px] uppercase tracking-[0.18em]">Flashing modem</Badge>
            <h2 class="text-2xl font-semibold tracking-tight">{{ flashOverlay.label || "Selected modem" }}</h2>
            <p class="text-sm leading-6 text-muted-foreground">
              Watch the modem LEDs. During flashing the modem may power-cycle, disconnect, and reconnect. Do not unplug it.
            </p>
          </div>
          <Button v-if="['completed', 'done', 'failed', 'success'].includes(String(flashOverlay.status || '').toLowerCase())" variant="outline" class="rounded-full" @click="closeFlashOverlay()">Close</Button>
        </div>
        <div class="mt-6 space-y-3">
          <div class="flex items-center justify-between gap-3 text-sm">
            <span class="font-medium">{{ flashStatusLabel(flashOverlay.status) }}</span>
            <Badge :variant="tone(normalizedFlashOverlayStatus(flashOverlay.status))" class="rounded-full capitalize">{{ normalizedFlashOverlayStatus(flashOverlay.status) }}</Badge>
          </div>
          <div class="flash-overlay-message rounded-[24px] border border-border/70 bg-muted/40 p-4 text-sm leading-6">
            {{ flashOverlayBody(flashOverlay.status, flashOverlay.message) }}
          </div>
        </div>
        <div v-if="normalizedFlashOverlayStatus(flashOverlay.status) === 'running'" class="mt-6 h-3 overflow-hidden rounded-full bg-muted">
          <div class="h-full w-full rounded-full bg-primary/80 animate-pulse" />
        </div>
      </div>
    </div>
  </main>
</template>
<style scoped>
.flash-overlay-message {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
}
</style>
