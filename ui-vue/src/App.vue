<script setup>
import { computed, onMounted, ref } from "vue"
import {
  Activity,
  CircleAlert,
  Gauge,
  HardDrive,
  RefreshCcw,
  Router,
  ShieldCheck,
  Signal,
  Workflow,
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
const commandType = ref("self_check")
const timeoutSec = ref("120")
const extraParams = ref("")
const selectedModem = ref("all")
const commandHistory = ref([])

const commandOptions = [
  { value: "self_check", label: "Self Check", note: "Проверка node-agent, tunnel, modem и proxy." },
  { value: "transport_self_check", label: "Transport Check", note: "Диагностика связи с main server." },
  { value: "reconcile_config", label: "Reconcile Config", note: "Пересборка desired config и 3proxy." },
  { value: "restart_proxy", label: "Restart Proxy", note: "Перезапуск локального 3proxy." },
  { value: "rotate_ip", label: "Rotate IP", note: "Ротация выбранных HiLink-модемов." },
  { value: "self_update", label: "Self Update", note: "Обновление node-agent до целевой версии." },
]

const runbookChecks = [
  { label: "node-agent", command: "systemctl status partner-node --no-pager", expected: "active (running)" },
  { label: "local ui", command: "systemctl status partner-node-ui --no-pager", expected: "active (running)" },
  { label: "3proxy", command: "systemctl status 3proxy --no-pager", expected: "active (running)" },
  { label: "last logs", command: "journalctl -u partner-node -n 120 --no-pager", expected: "heartbeat / commands / proxy" },
  { label: "modem route", command: "ip rule show && ip route show table 1101", expected: "source-based routing for HiLink" },
  { label: "proxy test", command: "curl --proxy socks5h://127.0.0.1:31001 http://api.ipify.org", expected: "real modem egress ip" },
]

const nodeStatus = computed(() => String(overview.value?.node_status || "unknown").toLowerCase())
const modems = computed(() => Array.isArray(overview.value?.modems) ? overview.value.modems : [])
const readyModems = computed(() => modems.value.filter((item) => String(item.state || "").toLowerCase() === "ready"))
const onlineIP = computed(() => overview.value?.external_ip || "-")
const activeSessions = computed(() => Number(overview.value?.metrics?.active_sessions || 0))
const bytesInTotal = computed(() => Number(overview.value?.bytes_in_total || 0))
const bytesOutTotal = computed(() => Number(overview.value?.bytes_out_total || 0))
const pendingCommands = computed(() => Number(overview.value?.pending_commands || 0))
const selectedCommandNote = computed(() => commandOptions.find((item) => item.value === commandType.value)?.note || "")

function bytesLabel(value) {
  const size = Number(value || 0)
  if (size < 1024) return `${size} B`
  if (size < 1024 ** 2) return `${(size / 1024).toFixed(1)} KB`
  if (size < 1024 ** 3) return `${(size / 1024 ** 2).toFixed(2)} MB`
  return `${(size / 1024 ** 3).toFixed(2)} GB`
}

function tone(status) {
  const value = String(status || "").toLowerCase()
  if (["online", "ready", "success", "active", "running"].includes(value)) return "default"
  if (["degraded", "busy", "rotating", "warning", "pending"].includes(value)) return "secondary"
  if (["error", "failed", "offline", "timeout"].includes(value)) return "destructive"
  return "outline"
}

async function loadOverview() {
  loading.value = true
  refreshError.value = ""
  try {
    const response = await fetch("/api/overview", { cache: "no-store" })
    if (!response.ok) {
      throw new Error(await response.text())
    }
    const data = await response.json()
    overview.value = data
    commandHistory.value = Array.isArray(data.last_results) ? data.last_results : []
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
  if (extraParams.value.trim()) {
    payload.params = JSON.parse(extraParams.value)
  }
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
    if (!response.ok) {
      throw new Error(await response.text())
    }
    const result = await response.json()
    const message = `${targetMessage}: ${type} queued (${result.command?.id || "-"})`
    if (targetMessage === "quick") {
      quickMessage.value = message
    } else {
      commandMessage.value = message
    }
    await loadOverview()
  } catch (error) {
    const text = error instanceof Error ? error.message : "command failed"
    if (targetMessage === "quick") {
      quickMessage.value = text
    } else {
      commandMessage.value = text
    }
  }
}

function quickAction(type) {
  sendCommand(type, "quick")
}

onMounted(() => {
  loadOverview()
  window.setInterval(loadOverview, 6000)
})
</script>

<template>
  <main class="min-h-screen bg-background text-foreground">
    <section class="mx-auto flex max-w-[1500px] flex-col gap-6 px-4 py-5 sm:px-6 xl:px-8">
      <header class="glass-panel grid-noise overflow-hidden rounded-[32px] border border-border/70">
        <div class="flex flex-col gap-5 px-5 py-5 lg:flex-row lg:items-end lg:justify-between lg:px-7 lg:py-7">
          <div class="max-w-4xl space-y-3">
            <Badge variant="secondary" class="rounded-full px-3 py-1 text-[11px] uppercase tracking-[0.18em]">
              Partner Node Console
            </Badge>
            <div class="space-y-2">
              <h1 class="text-3xl font-semibold tracking-tight sm:text-4xl">
                Локальная админка ноды
              </h1>
              <p class="max-w-3xl text-sm leading-6 text-muted-foreground sm:text-base">
                Партнёр видит реальный статус ноды, модемов, egress IP, команды поддержки и последние результаты без main admin.
              </p>
            </div>
          </div>
          <div class="grid gap-3 sm:grid-cols-2 xl:min-w-[420px]">
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4">
              <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Partner Key</div>
              <div class="mt-2 font-mono text-sm">{{ overview?.partner_key || "-" }}</div>
            </div>
            <div class="rounded-[26px] border border-border/70 bg-card/80 p-4">
              <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Main Server</div>
              <div class="mt-2 font-mono text-sm break-all">{{ overview?.main_server || "configured in ui.env" }}</div>
            </div>
          </div>
        </div>
      </header>

      <div class="grid gap-4 xl:grid-cols-6">
        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><ShieldCheck class="h-4 w-4" /> Node Status</CardDescription>
            <CardTitle class="text-2xl capitalize">{{ nodeStatus }}</CardTitle>
          </CardHeader>
          <CardContent>
            <Badge :variant="tone(nodeStatus)" class="rounded-full capitalize">{{ nodeStatus }}</Badge>
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Router class="h-4 w-4" /> Egress IP</CardDescription>
            <CardTitle class="text-xl font-mono">{{ onlineIP }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            То, что main server считает текущим внешним IP ноды.
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><HardDrive class="h-4 w-4" /> Modems</CardDescription>
            <CardTitle class="text-2xl">{{ modems.length }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Ready: <span class="font-medium text-foreground">{{ readyModems.length }}</span>
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Activity class="h-4 w-4" /> Sessions</CardDescription>
            <CardTitle class="text-2xl">{{ activeSessions }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Pending commands: <span class="font-medium text-foreground">{{ pendingCommands }}</span>
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Workflow class="h-4 w-4" /> Traffic In</CardDescription>
            <CardTitle class="text-2xl">{{ bytesLabel(bytesInTotal) }}</CardTitle>
          </CardHeader>
          <CardContent class="text-sm text-muted-foreground">
            Aggregate bytes_in_total from overview.
          </CardContent>
        </Card>

        <Card class="rounded-[28px] border-border/70 shadow-sm xl:col-span-1">
          <CardHeader class="pb-3">
            <CardDescription class="flex items-center gap-2"><Gauge class="h-4 w-4" /> Traffic Out</CardDescription>
            <CardTitle class="text-2xl">{{ bytesLabel(bytesOutTotal) }}</CardTitle>
          </CardHeader>
          <CardContent class="flex items-center justify-between text-sm text-muted-foreground">
            <span>{{ loading ? "refresh..." : "auto refresh 6s" }}</span>
            <Button variant="outline" size="sm" class="rounded-full" @click="loadOverview">
              <RefreshCcw class="h-4 w-4" />
              Refresh
            </Button>
          </CardContent>
        </Card>
      </div>

      <div v-if="refreshError" class="rounded-[24px] border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive">
        {{ refreshError }}
      </div>

      <Tabs default-value="fleet" class="space-y-4">
        <TabsList class="w-fit rounded-2xl bg-muted/60 p-1">
          <TabsTrigger value="fleet" class="rounded-xl px-4">Флит</TabsTrigger>
          <TabsTrigger value="commands" class="rounded-xl px-4">Команды</TabsTrigger>
          <TabsTrigger value="activity" class="rounded-xl px-4">Результаты</TabsTrigger>
          <TabsTrigger value="runbook" class="rounded-xl px-4">Runbook</TabsTrigger>
        </TabsList>

        <TabsContent value="fleet" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.35fr)_minmax(380px,0.65fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Модемы и реальный egress</CardTitle>
                <CardDescription>Тут должен быть тот IP, который реально видит интернет через локальный 3proxy.</CardDescription>
              </CardHeader>
              <CardContent class="p-4 sm:p-6">
                <div class="overflow-hidden rounded-[24px] border border-border/70">
                  <Table>
                    <TableHeader>
                      <TableRow class="hover:bg-transparent">
                        <TableHead>Modem</TableHead>
                        <TableHead>Status</TableHead>
                        <TableHead>Observed IP</TableHead>
                        <TableHead>Operator</TableHead>
                        <TableHead>Tech</TableHead>
                        <TableHead>Signal</TableHead>
                        <TableHead>Port</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      <TableRow v-for="modem in modems" :key="modem.id">
                        <TableCell>
                          <div class="font-medium">{{ modem.id }}</div>
                          <div class="text-xs text-muted-foreground">ordinal {{ modem.ordinal ?? "-" }}</div>
                        </TableCell>
                        <TableCell><Badge :variant="tone(modem.state)" class="rounded-full capitalize">{{ modem.state || "unknown" }}</Badge></TableCell>
                        <TableCell class="font-mono text-xs">{{ modem.wan_ip || "-" }}</TableCell>
                        <TableCell>{{ modem.operator || "-" }}</TableCell>
                        <TableCell>{{ modem.technology || "-" }}</TableCell>
                        <TableCell>
                          <div class="flex items-center gap-3">
                            <Signal class="h-4 w-4 text-muted-foreground" />
                            <span>{{ modem.signal_strength ?? "-" }}</span>
                          </div>
                        </TableCell>
                        <TableCell class="font-mono text-xs">{{ modem.port || "-" }}</TableCell>
                      </TableRow>
                      <TableRow v-if="!modems.length">
                        <TableCell colspan="7" class="py-10 text-center text-muted-foreground">Модемы пока не обнаружены.</TableCell>
                      </TableRow>
                    </TableBody>
                  </Table>
                </div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Быстрые действия</CardTitle>
                <CardDescription>Самые частые support-операции прямо с локальной ноды.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6">
                <Button class="w-full rounded-full justify-start" @click="quickAction('self_check')">Self Check</Button>
                <Button variant="outline" class="w-full rounded-full justify-start" @click="quickAction('transport_self_check')">Transport Self Check</Button>
                <Button variant="outline" class="w-full rounded-full justify-start" @click="quickAction('reconcile_config')">Reconcile Config</Button>
                <Button variant="outline" class="w-full rounded-full justify-start" @click="quickAction('restart_proxy')">Restart Proxy</Button>
                <Button variant="outline" class="w-full rounded-full justify-start" @click="quickAction('self_update')">Self Update</Button>
                <div class="rounded-[22px] border border-border/70 bg-muted/30 p-4 text-sm text-muted-foreground">
                  {{ quickMessage || "Последние быстрые действия и ошибки будут показываться здесь." }}
                </div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="commands" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(360px,0.7fr)]">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Command Center</CardTitle>
                <CardDescription>Отправка node-команд и ротации по конкретному HiLink-модему.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-5 p-4 sm:p-6">
                <div class="grid gap-4 md:grid-cols-2">
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Command Type</div>
                    <Select v-model="commandType">
                      <SelectTrigger class="rounded-2xl">
                        <SelectValue placeholder="Выбери команду" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem v-for="option in commandOptions" :key="option.value" :value="option.value">{{ option.label }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>

                  <div class="space-y-2">
                    <div class="text-sm font-medium">Target Modem</div>
                    <Select v-model="selectedModem">
                      <SelectTrigger class="rounded-2xl">
                        <SelectValue placeholder="auto" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="all">auto / all ready</SelectItem>
                        <SelectItem v-for="modem in readyModems" :key="modem.id" :value="modem.id">{{ modem.id }}</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                </div>

                <div class="grid gap-4 md:grid-cols-[180px_minmax(0,1fr)]">
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Timeout, sec</div>
                    <Input v-model="timeoutSec" class="rounded-2xl" />
                  </div>
                  <div class="space-y-2">
                    <div class="text-sm font-medium">Extra Params JSON</div>
                    <Textarea v-model="extraParams" class="rounded-[22px] font-mono text-xs" placeholder='{"reason":"manual","force":true}' />
                  </div>
                </div>

                <div class="rounded-[22px] border border-border/70 bg-muted/30 p-4 text-sm text-muted-foreground">
                  {{ selectedCommandNote }}
                </div>

                <div class="flex flex-wrap gap-3">
                  <Button class="rounded-full" @click="sendCommand()">Отправить команду</Button>
                  <Button variant="outline" class="rounded-full" @click="extraParams = ''">Очистить params</Button>
                </div>

                <div class="rounded-[22px] border border-border/70 bg-card p-4 text-sm">
                  {{ commandMessage || "Результат постановки команды в очередь появится здесь." }}
                </div>
              </CardContent>
            </Card>

            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Node Snapshot</CardTitle>
                <CardDescription>Самые важные поля из overview без лишнего шума.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-4 p-4 sm:p-6">
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Node ID</div>
                  <div class="mt-2 font-mono text-sm">{{ overview?.node_id || "-" }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Agent Version</div>
                  <div class="mt-2 font-medium">{{ overview?.agent_version || "-" }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Country</div>
                  <div class="mt-2 font-medium">{{ overview?.country || "-" }}</div>
                </div>
                <div class="rounded-2xl border border-border/70 p-4">
                  <div class="text-xs uppercase tracking-[0.18em] text-muted-foreground">Last Heartbeat</div>
                  <div class="mt-2 font-mono text-xs">{{ overview?.last_heartbeat_at || "-" }}</div>
                </div>
              </CardContent>
            </Card>
          </div>
        </TabsContent>

        <TabsContent value="activity" class="space-y-4">
          <Card class="rounded-[28px] border-border/70 shadow-sm">
            <CardHeader class="border-b border-border/60 pb-5">
              <CardTitle class="text-2xl">Последние результаты команд</CardTitle>
              <CardDescription>То, что main server уже получил обратно от node-agent.</CardDescription>
            </CardHeader>
            <CardContent class="p-4 sm:p-6">
              <div class="overflow-hidden rounded-[24px] border border-border/70">
                <Table>
                  <TableHeader>
                    <TableRow class="hover:bg-transparent">
                      <TableHead>Command ID</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Message</TableHead>
                      <TableHead>Node</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    <TableRow v-for="result in commandHistory" :key="result.command_id">
                      <TableCell class="font-mono text-xs">{{ result.command_id || "-" }}</TableCell>
                      <TableCell><Badge :variant="tone(result.status)" class="rounded-full capitalize">{{ result.status || "unknown" }}</Badge></TableCell>
                      <TableCell>{{ result.message || "-" }}</TableCell>
                      <TableCell>{{ result.node_id || overview?.node_id || "-" }}</TableCell>
                    </TableRow>
                    <TableRow v-if="!commandHistory.length">
                      <TableCell colspan="4" class="py-10 text-center text-muted-foreground">Команд ещё не было или main server не вернул last_results.</TableCell>
                    </TableRow>
                  </TableBody>
                </Table>
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="runbook" class="space-y-4">
          <div class="grid gap-4 xl:grid-cols-2">
            <Card class="rounded-[28px] border-border/70 shadow-sm">
              <CardHeader class="border-b border-border/60 pb-5">
                <CardTitle class="text-2xl">Локальные команды</CardTitle>
                <CardDescription>Что запускать на Linux, если что-то поехало.</CardDescription>
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
                <CardTitle class="text-2xl">Что здесь должно быть видно</CardTitle>
                <CardDescription>Чек-лист полезности локальной админки.</CardDescription>
              </CardHeader>
              <CardContent class="space-y-3 p-4 sm:p-6 text-sm text-muted-foreground">
                <div class="rounded-2xl border border-border/70 p-4">Текущий observed egress IP по модему, а не только то, что говорит HiLink API.</div>
                <div class="rounded-2xl border border-border/70 p-4">Ready / degraded / offline по ноде и каждому модему отдельно.</div>
                <div class="rounded-2xl border border-border/70 p-4">Быстрые support-команды без main admin и без ручного curl.</div>
                <div class="rounded-2xl border border-border/70 p-4">Последние результаты команд, чтобы партнёр видел, что реально произошло.</div>
                <div class="rounded-2xl border border-border/70 p-4">Локальный runbook, чтобы не лазить по документации вслепую.</div>
                <div class="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-4 text-amber-100">
                  <div class="flex items-center gap-2 font-medium text-amber-200"><CircleAlert class="h-4 w-4" /> Важно</div>
                  <div class="mt-2 leading-6">
                    Если observed IP и прокси-тест не совпадают, значит сломан не main server, а локальный egress через ноду или policy routing модема.
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
