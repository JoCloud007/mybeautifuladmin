import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Activity,
  ArrowLeft,
  Boxes,
  Download,
  HardDrive,
  Info,
  Lightbulb,
  MonitorPlay,
  Play,
  Power,
  RefreshCw,
  RotateCcw,
  Server,
  Square,
  TerminalSquare,
  Thermometer,
  Wifi,
  Zap,
} from 'lucide-react'
import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Chart, LiveChart, PALETTE } from '@/components/Chart'
import { Page, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Bar,
  Empty,
  Gauge,
  Modal,
  Spinner,
  StatTile,
  StatusDot,
  Tabs,
  useConfirm,
  useToast,
} from '@/components/ui'
import { get, post } from '@/lib/api'
import { KIND_LABEL, ago, bitrate, bytes, duration, num, percent, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

type Tab = 'live' | 'history' | 'system' | 'containers' | 'processes'

interface HostTemplate {
  /** Quelle vue « temps réel » a du sens pour ce type de machine. */
  live: 'os' | 'bmc'
  tabs: { id: Tab; label: string }[]
}

/**
 * Compose la fiche selon ce que la machine est réellement.
 *
 * Un contrôleur BMC n'a ni processeur ni système de fichiers à montrer : lui
 * afficher des jauges à 0 % et des graphiques vides serait un mensonge poli.
 * On part donc du type d'hôte, puis on ne garde que les onglets dont le relevé
 * porte effectivement la matière.
 */
function templateFor(host: any, sample: any): HostTemplate {
  const kind = host.kind
  const hasOsMetrics = sample['cpu.usage'] !== undefined || sample['mem.percent'] !== undefined
  const hasSensorHistory =
    Object.keys(sample.temps ?? {}).length > 0 ||
    Object.keys(sample.fans ?? {}).length > 0 ||
    sample.bmc?.power_watts != null

  if (kind === 'ipmi') {
    return {
      live: 'bmc',
      tabs: [
        { id: 'live', label: 'Hors-bande' },
        ...(hasSensorHistory ? [{ id: 'history' as Tab, label: 'Historique' }] : []),
        { id: 'system', label: 'Matériel' },
      ],
    }
  }

  const tabs: { id: Tab; label: string }[] = [
    { id: 'live', label: 'Temps réel' },
    { id: 'history', label: 'Historique' },
    { id: 'system', label: kind === 'synology' ? 'DSM & stockage' : 'Système' },
  ]
  if (kind === 'proxmox' || sample.containers) {
    tabs.push({ id: 'containers', label: kind === 'proxmox' ? 'VM & LXC' : 'Conteneurs' })
  }
  if (sample.processes) tabs.push({ id: 'processes', label: 'Processus' })

  // Un hôte joint par le seul socket Docker n'a pas d'historique système.
  if (!hasOsMetrics && sample['docker.containers.total'] !== undefined) {
    return { live: 'os', tabs: tabs.filter((t) => t.id !== 'history') }
  }
  return { live: 'os', tabs }
}

export function HostDetail() {
  const { id } = useParams()
  const hostId = Number(id)
  const [tab, setTab] = useState<Tab>('live')
  const [logs, setLogs] = useState<{ name: string; text: string } | null>(null)

  const { data: host, isLoading } = useQuery({
    queryKey: ['host', hostId],
    queryFn: () => get(`/hosts/${hostId}`),
    refetchInterval: 30000,
  })

  useLive((s) => s.bump)
  const sample = useLive.getState().samples[hostId] ?? host?.sample ?? {}
  const status = useLive.getState().status[hostId] ?? host?.status

  if (isLoading || !host) {
    return (
      <Page>
        <div className="panel p-16 grid place-items-center">
          <Spinner size={24} />
        </div>
      </Page>
    )
  }

  const meta = host.meta ?? {}
  const gpus = sample.gpus ?? []
  const template = templateFor(host, sample)

  // Un onglet retenu d'un hôte précédent peut ne pas exister sur celui-ci.
  const currentTab = template.tabs.some((t) => t.id === tab) ? tab : template.tabs[0].id

  return (
    <Page>
      <div className="flex flex-wrap items-start justify-between gap-3 mb-4">
        <div className="flex items-start gap-3 min-w-0">
          <Link to="/hosts" className="btn-icon mt-1">
            <ArrowLeft size={17} />
          </Link>
          <div className="min-w-0">
            <div className="flex items-center gap-2.5 flex-wrap">
              <StatusDot status={status} size={10} />
              <h1 className="text-[22px] font-semibold text-mist-100 leading-tight tracking-tight truncate">
                {host.name}
              </h1>
              <Badge tone="info">{KIND_LABEL[host.kind] ?? host.kind}</Badge>
              {(host.tags ?? []).map((tag: string) => (
                <Badge key={tag}>{tag}</Badge>
              ))}
            </div>
            <p className="text-sm text-ink-500 mt-1 font-mono">
              {host.address}
              {host.port ? `:${host.port}` : ''}
              {meta.os && <span className="font-sans"> · {meta.os}</span>}
              {sample.uptime ? <span className="font-sans"> · actif depuis {duration(sample.uptime)}</span> : ''}
            </p>
          </div>
        </div>
        <HostActions host={host} />
      </div>

      {status === 'offline' && host.last_error && (
        <div className="panel border-danger/25 bg-danger/[0.05] px-4 py-3 mb-4 text-sm text-danger">
          <b>Hôte injoignable.</b> {host.last_error}
        </div>
      )}

      <div className="mb-4">
        <Tabs<Tab> active={currentTab} onChange={setTab} tabs={template.tabs} />
      </div>

      {currentTab === 'live' &&
        (template.live === 'bmc' ? (
          <BmcTab host={host} sample={sample} />
        ) : (
          <LiveTab hostId={hostId} sample={sample} kind={host.kind} gpus={gpus} />
        ))}
      {currentTab === 'history' && <HistoryTab hostId={hostId} kind={host.kind} />}
      {currentTab === 'system' && <SystemTab host={host} sample={sample} />}
      {currentTab === 'containers' && (
        <ContainersTab host={host} sample={sample} onLogs={(name, text) => setLogs({ name, text })} />
      )}
      {currentTab === 'processes' && <ProcessesTab sample={sample} />}

      <Modal open={!!logs} onClose={() => setLogs(null)} title={`Journaux · ${logs?.name}`} width="max-w-4xl">
        <pre className="text-[12px] font-mono text-mist-300 whitespace-pre-wrap break-words leading-relaxed max-h-[62vh] overflow-y-auto">
          {logs?.text || 'Aucune sortie.'}
        </pre>
      </Modal>
    </Page>
  )
}

// ------------------------------------------------------------------- actions
function HostActions({ host }: { host: any }) {
  const confirm = useConfirm()
  const toast = useToast()
  const queryClient = useQueryClient()
  const [running, setRunning] = useState<string | null>(null)
  const [upgradeLog, setUpgradeLog] = useState<string | null>(null)

  // Un BMC n'héberge rien : ni shell, ni paquets. Un NAS et un hyperviseur se
  // mettent à jour depuis leur propre interface, pas par apt.
  const isBmc = host.kind === 'ipmi'
  const canSsh = host.kind === 'linux' || host.kind === 'docker'
  const canUpgrade = canSsh
  const updates = host.meta?.updates ?? 0

  const run = async (key: string, fn: () => Promise<any>, successMessage: string) => {
    setRunning(key)
    try {
      const result = await fn()
      toast(successMessage, 'ok')
      queryClient.invalidateQueries({ queryKey: ['host', host.id] })
      queryClient.invalidateQueries({ queryKey: ['overview'] })
      return result
    } catch (exc: any) {
      toast(exc.message ?? 'Action échouée', 'danger')
    } finally {
      setRunning(null)
    }
  }

  const upgrade = async () => {
    const ok = await confirm({
      title: 'Lancer la mise à jour ?',
      message: (
        <>
          Tous les paquets de <b className="text-mist-100">{host.name}</b> seront mis à jour
          {updates > 0 ? ` (${updates} en attente)` : ''}. L'opération peut durer plusieurs minutes.
        </>
      ),
      confirmLabel: 'Mettre à jour',
    })
    if (!ok) return
    setUpgradeLog('Démarrage…\n')
    const result = await run('upgrade', () => post(`/hosts/${host.id}/upgrade`), 'Mise à jour terminée')
    setUpgradeLog(null)
    if (result?.log_id) {
      const detail = await get(`/actions?limit=5`).catch(() => [])
      const entry = detail.find?.((a: any) => a.id === result.log_id)
      if (entry?.output) setUpgradeLog(entry.output)
    }
  }

  const power = async (action: 'reboot' | 'shutdown') => {
    const ok = await confirm({
      title: action === 'reboot' ? 'Redémarrer cet hôte ?' : 'Éteindre cet hôte ?',
      message: (
        <>
          <b className="text-mist-100">{host.name}</b> ({host.address}) va{' '}
          {action === 'reboot' ? 'redémarrer' : "s'éteindre"} immédiatement. Les services hébergés seront
          interrompus.
          {isBmc && (
            <span className="block mt-2 text-warn">
              L'ordre passe par le contrôleur hors bande : le système d'exploitation n'en est pas
              averti, comme un appui sur le bouton physique.
            </span>
          )}
        </>
      ),
      confirmLabel: action === 'reboot' ? 'Redémarrer' : 'Éteindre',
      danger: true,
    })
    if (!ok) return
    run(action, () => post(`/hosts/${host.id}/power/${action}`), action === 'reboot' ? 'Redémarrage demandé' : 'Extinction demandée')
  }

  return (
    <>
      <div className="flex items-center gap-2 flex-wrap">
        {canSsh && (
          <Link to={`/terminal?host=${host.id}`} className="btn-ghost">
            <TerminalSquare size={15} />
            Terminal
          </Link>
        )}
        <button className="btn-ghost" onClick={() => run('test', () => post(`/hosts/${host.id}/test`), 'Connexion vérifiée')}>
          {running === 'test' ? <Spinner size={14} /> : <Wifi size={15} />}
          Tester
        </button>
        {canUpgrade && (
          <button className={updates > 0 ? 'btn-primary' : 'btn-ghost'} onClick={upgrade} disabled={running === 'upgrade'}>
            {running === 'upgrade' ? <Spinner size={14} /> : <Download size={15} />}
            Mettre à jour
            {updates > 0 && <span className="ml-0.5 opacity-80">({updates})</span>}
          </button>
        )}
        <button className="btn-ghost" onClick={() => power('reboot')} disabled={running === 'reboot'}>
          {running === 'reboot' ? <Spinner size={14} /> : <RotateCcw size={15} />}
          {isBmc ? 'Reset matériel' : 'Redémarrer'}
        </button>
        <button className="btn-danger" onClick={() => power('shutdown')} disabled={running === 'shutdown'}>
          <Power size={15} />
          Éteindre
        </button>
      </div>

      <Modal open={!!upgradeLog} onClose={() => setUpgradeLog(null)} title="Mise à jour" width="max-w-3xl">
        <pre className="text-[12px] font-mono text-mist-300 whitespace-pre-wrap max-h-[60vh] overflow-y-auto leading-relaxed">
          {upgradeLog}
        </pre>
      </Modal>
    </>
  )
}

// -------------------------------------------------------------- hors-bande
const POWER_STATE: Record<string, { label: string; tone: 'ok' | 'warn' | 'danger' | 'neutral' }> = {
  on: { label: 'Serveur allumé', tone: 'ok' },
  off: { label: 'Serveur éteint', tone: 'neutral' },
  paused: { label: 'En pause', tone: 'warn' },
  unknown: { label: 'État inconnu', tone: 'warn' },
}

/**
 * Vue d'un contrôleur d'administration hors bande.
 *
 * Ce qu'un BMC sait dire, c'est l'état d'alimentation, la santé matérielle et
 * ses capteurs — pas la charge du système d'exploitation, qu'il ne voit pas.
 */
function BmcTab({ host, sample }: { host: any; sample: any }) {
  const bmc = sample.bmc ?? {}
  const meta = host.meta ?? {}
  const temps: Record<string, number> = bmc.temps ?? sample.temps ?? {}
  const fans: Record<string, number> = bmc.fans ?? sample.fans ?? {}
  const psus: any[] = bmc.psus ?? []
  const state = POWER_STATE[bmc.power_state ?? 'unknown'] ?? POWER_STATE.unknown
  const healthy = (bmc.health ?? '').toUpperCase() === 'OK'

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <StatTile
            label="Alimentation"
            value={state.label}
            tone={state.tone === 'ok' ? 'ok' : state.tone === 'danger' ? 'danger' : 'neutral'}
            icon={<Power size={15} />}
          />
          <StatTile
            label="Santé matérielle"
            value={bmc.health ?? '—'}
            tone={healthy ? 'ok' : bmc.health ? 'danger' : 'neutral'}
            icon={<Activity size={15} />}
          />
          <StatTile
            label="Consommation"
            value={bmc.power_watts != null ? `${num(bmc.power_watts, 0)} W` : 'non exposée'}
            icon={<Zap size={15} />}
          />
          <StatTile
            label="LED de localisation"
            value={bmc.indicator_led ?? '—'}
            icon={<Lightbulb size={15} />}
          />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className="panel p-4">
          <SectionTitle>Serveur administré</SectionTitle>
          <Rows
            rows={[
              ['Constructeur', bmc.manufacturer ?? meta.manufacturer],
              ['Modèle', clean(bmc.model) ?? clean(meta.model)],
              ['Numéro de série', clean(bmc.serial) ?? clean(meta.serial)],
              ['BIOS', bmc.bios ?? meta.bios],
              ['Processeurs', bmc.cpu_count ?? meta.cpu_count],
              ['Mémoire installée', bmc.mem_total ? bytes(bmc.mem_total) : null],
              ['Nom d’hôte déclaré', bmc.host_name],
            ]}
          />
        </div>

        <div className="panel p-4">
          <SectionTitle>Contrôleur</SectionTitle>
          <Rows
            rows={[
              ['Adresse', `${host.address}${host.port ? `:${host.port}` : ''}`],
              ['Transport', meta.bmc_mode === 'redfish' ? 'Redfish (HTTPS)' : 'ipmitool'],
              ['Chiffrement', meta.bmc_secure ? 'TLS' : 'en clair'],
              ['Modèle de BMC', bmc.bmc_model ?? meta.bmc_model],
              ['Micrologiciel', bmc.bmc_firmware ?? meta.bmc_firmware],
              ['Châssis', clean(bmc.chassis_model)],
            ]}
          />
          <div className="flex flex-wrap gap-2 mt-3 pt-3 border-t border-ink-800">
            <Link to="/ipmi" className="btn-ghost">
              <Server size={15} />
              Piloter depuis Hors-bande
            </Link>
            {bmc.console_url && (
              <a href={bmc.console_url} target="_blank" rel="noopener noreferrer" className="btn-ghost">
                <MonitorPlay size={15} />
                Console iKVM
              </a>
            )}
          </div>
        </div>
      </div>

      <div className="panel p-4">
        <SectionTitle
          right={
            <span className="text-xs text-ink-500">
              {Object.keys(temps).length + Object.keys(fans).length + psus.length} relevé(s)
            </span>
          }
        >
          Capteurs du châssis
        </SectionTitle>

        {Object.keys(temps).length === 0 && Object.keys(fans).length === 0 && psus.length === 0 ? (
          <Empty
            icon={<Thermometer size={28} />}
            title="Ce BMC n'expose aucun capteur"
            hint="Le contrôleur répond, mais ses collections Thermal et Power sont vides — fréquent sur les cartes ASUS quand le serveur est éteint, ou quand le firmware ne publie les capteurs qu'au démarrage. Rallume le serveur, ou relève les températures depuis l'OS."
          />
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
            {Object.entries(temps).map(([name, value]) => (
              <SensorRow key={name} name={name} value={`${num(value, 0)} °C`} tone={severity(value, 70, 85).color} />
            ))}
            {Object.entries(fans).map(([name, value]) => (
              <SensorRow key={name} name={name} value={`${num(value, 0)} tr/min`} />
            ))}
            {psus.map((psu: any, index: number) => (
              <SensorRow
                key={psu.name ?? index}
                name={psu.name ?? `Alimentation ${index + 1}`}
                value={psu.status ?? '—'}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

/** Les BMC renvoient volontiers des champs remplis d'espaces ou de « Default string ». */
function clean(value: any): string | null {
  const text = String(value ?? '').trim()
  if (!text || text.toLowerCase() === 'default string' || text.startsWith('System ')) return null
  return text
}

function Rows({ rows }: { rows: [string, any][] }) {
  const kept = rows.filter(([, value]) => value !== null && value !== undefined && value !== '')
  if (kept.length === 0) {
    return <p className="text-[13px] text-ink-500">Le contrôleur n'a rien renseigné ici.</p>
  }
  return (
    <div className="space-y-0">
      {kept.map(([label, value]) => (
        <div
          key={label}
          className="flex items-baseline justify-between gap-4 py-1.5 border-b border-ink-800/60 last:border-0"
        >
          <span className="text-[12px] text-ink-500 shrink-0">{label}</span>
          <span className="text-[13px] text-mist-200 font-mono text-right truncate">{String(value)}</span>
        </div>
      ))}
    </div>
  )
}

function SensorRow({ name, value, tone }: { name: string; value: string; tone?: string }) {
  return (
    <div className="flex items-center justify-between gap-3 bg-ink-850 rounded-lg px-3 py-2">
      <span className="text-[12px] text-mist-300 truncate">{name}</span>
      <span className="metric-value text-[13px]" style={tone ? { color: tone } : undefined}>
        {value}
      </span>
    </div>
  )
}

// ---------------------------------------------------------------- temps réel
function LiveTab({ hostId, sample, kind, gpus }: { hostId: number; sample: any; kind: string; gpus: any[] }) {
  const cores: number[] = sample['cpu.cores'] ?? []
  const filesystems = sample.filesystems ?? []
  const temps: Record<string, number> = sample.temps ?? {}
  const interfaces = Object.keys(sample['net.interfaces'] ?? {})
  // Hôte joint uniquement via le socket Docker : pas de métriques /proc.
  const hasSystem = sample['cpu.usage'] !== undefined || sample['mem.percent'] !== undefined

  if (!hasSystem && sample['docker.containers.total'] !== undefined) {
    return <DockerOnlyTab hostId={hostId} sample={sample} />
  }

  return (
    <div className="space-y-4">
      <div className="panel p-4">
        <div className="flex flex-wrap items-center justify-around gap-5">
          <Gauge value={sample['cpu.usage'] ?? 0} label="Processeur" sub={cores.length ? `${cores.length} cœurs` : undefined} />
          <Gauge
            value={sample['mem.percent'] ?? 0}
            label="Mémoire"
            sub={sample['mem.total'] ? bytes(sample['mem.used']) : undefined}
          />
          <Gauge
            value={sample['disk.percent'] ?? 0}
            label="Stockage"
            sub={sample['disk.total'] ? bytes(sample['disk.total']) : undefined}
          />
          {sample['swap.percent'] !== undefined && (
            <Gauge value={sample['swap.percent']} label="Swap" sub={bytes(sample['swap.used'])} warn={40} crit={70} />
          )}
          {sample['load.1'] !== undefined && (
            <div className="flex flex-col items-center gap-1">
              <div className="flex items-end gap-2.5 h-[92px] pb-4">
                {(['load.1', 'load.5', 'load.15'] as const).map((key, index) => (
                  <div key={key} className="flex flex-col items-center gap-1">
                    <span className="metric-value text-base" style={{ color: PALETTE[index] }}>
                      {num(sample[key], 2)}
                    </span>
                    <span className="text-[10px] text-ink-600">{key.split('.')[1]} min</span>
                  </div>
                ))}
              </div>
              <span className="metric-label">Charge moyenne</span>
            </div>
          )}
          {sample['temp.cpu'] !== undefined && (
            <div className="flex flex-col items-center gap-1">
              <div className="h-[92px] flex items-center">
                <div className="flex items-baseline gap-1">
                  <Thermometer size={18} style={{ color: severity(sample['temp.cpu'], 70, 85).color }} />
                  <span className="metric-value text-2xl" style={{ color: severity(sample['temp.cpu'], 70, 85).color }}>
                    {num(sample['temp.cpu'], 0)}
                  </span>
                  <span className="text-sm text-ink-500">°C</span>
                </div>
              </div>
              <span className="metric-label">Température</span>
            </div>
          )}
        </div>
      </div>

      {cores.length > 1 && (
        <div className="panel p-4">
          <SectionTitle right={<span className="text-xs text-ink-500">{cores.length} cœurs</span>}>
            Charge par cœur
          </SectionTitle>
          <div className="grid gap-1.5" style={{ gridTemplateColumns: `repeat(auto-fill, minmax(${cores.length > 32 ? 32 : 48}px, 1fr))` }}>
            {cores.map((value, index) => (
              <div key={index} className="group relative" title={`Cœur ${index} · ${value.toFixed(0)} %`}>
                <div className="h-9 bg-ink-800 rounded-md overflow-hidden flex flex-col justify-end">
                  <div
                    className="w-full transition-all duration-300"
                    style={{ height: `${Math.min(100, value)}%`, background: severity(value).color, opacity: 0.85 }}
                  />
                </div>
                <div className="text-[9px] text-center text-ink-600 mt-0.5 font-mono">{index}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
        <ChartPanel title="Processeur" hint="%">
          <LiveChart
            hostId={hostId}
            height={168}
            format={(v) => `${v.toFixed(0)}%`}
            yRange={[0, 100]}
            specs={[
              { label: 'Utilisateur', metric: 'cpu.user', color: PALETTE[0] },
              { label: 'Système', metric: 'cpu.system', color: PALETTE[3] },
              { label: 'IO wait', metric: 'cpu.iowait', color: PALETTE[4] },
            ]}
          />
        </ChartPanel>

        <ChartPanel title="Mémoire" hint="%">
          <LiveChart
            hostId={hostId}
            height={168}
            format={(v) => `${v.toFixed(1)}%`}
            yRange={[0, 100]}
            specs={[
              { label: 'RAM', metric: 'mem.percent', color: PALETTE[1] },
              ...(sample['swap.percent'] !== undefined
                ? [{ label: 'Swap', metric: 'swap.percent', color: PALETTE[2] }]
                : []),
            ]}
          />
        </ChartPanel>

        <ChartPanel title="Réseau" hint={interfaces.join(', ') || 'total'}>
          <LiveChart
            hostId={hostId}
            height={168}
            format={(v) => bitrate(Math.abs(v))}
            specs={[
              { label: 'Réception', metric: 'net.rx', color: PALETTE[1] },
              { label: 'Émission', metric: 'net.tx', color: PALETTE[2], negative: true },
            ]}
          />
        </ChartPanel>

        <ChartPanel title="Entrées/sorties disque">
          <LiveChart
            hostId={hostId}
            height={168}
            format={(v) => bitrate(Math.abs(v))}
            specs={[
              { label: 'Lecture', metric: 'disk.read', color: PALETTE[0] },
              { label: 'Écriture', metric: 'disk.write', color: PALETTE[4], negative: true },
            ]}
          />
        </ChartPanel>

        {sample['load.1'] !== undefined && (
          <ChartPanel title="Charge système">
            <LiveChart
              hostId={hostId}
              height={150}
              format={(v) => v.toFixed(2)}
              specs={[
                { label: '1 min', metric: 'load.1', color: PALETTE[0] },
                { label: '5 min', metric: 'load.5', color: PALETTE[1], fill: false },
                { label: '15 min', metric: 'load.15', color: PALETTE[2], fill: false },
              ]}
            />
          </ChartPanel>
        )}

        {sample['temp.cpu'] !== undefined && (
          <ChartPanel title="Températures" hint="°C">
            <LiveChart
              hostId={hostId}
              height={150}
              format={(v) => `${v.toFixed(1)} °C`}
              specs={[
                { label: 'CPU', metric: 'temp.cpu', color: PALETTE[4] },
                ...(sample['gpu.temp'] ? [{ label: 'GPU', metric: 'gpu.temp', color: PALETTE[2] }] : []),
              ]}
            />
          </ChartPanel>
        )}

        {gpus.length > 0 && (
          <ChartPanel title="Accélérateur graphique" hint={gpus[0].id}>
            <LiveChart
              hostId={hostId}
              height={150}
              format={(v) => `${v.toFixed(0)}%`}
              yRange={[0, 100]}
              specs={[
                { label: 'Occupation', metric: 'gpu.busy', color: PALETTE[5] },
                { label: 'VRAM', metric: 'gpu.vram_percent', color: PALETTE[2] },
              ]}
            />
          </ChartPanel>
        )}
      </div>

      {filesystems.length > 0 && (
        <div className="panel p-4">
          <SectionTitle>Systèmes de fichiers</SectionTitle>
          <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(280px,1fr))]">
            {filesystems.map((fs: any) => (
              <div key={fs.mount} className="bg-ink-800/50 rounded-lg p-3 space-y-2">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="font-mono text-[13px] text-mist-200 truncate">{fs.mount}</span>
                  <span className="metric-value text-xs" style={{ color: severity(fs.percent).color }}>
                    {percent(fs.percent, 0)}
                  </span>
                </div>
                <Bar value={fs.percent} height={5} />
                <div className="flex justify-between text-[11px] text-ink-500 font-mono">
                  <span>{bytes(fs.used)} utilisés</span>
                  <span>{bytes(fs.available)} libres</span>
                </div>
                <div className="text-[10px] text-ink-600 truncate font-mono">{fs.device}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {Object.keys(temps).length > 1 && (
        <div className="panel p-4">
          <SectionTitle>Capteurs thermiques</SectionTitle>
          <div className="grid gap-2 grid-cols-[repeat(auto-fill,minmax(150px,1fr))]">
            {Object.entries(temps).map(([name, value]) => (
              <div key={name} className="flex items-center justify-between bg-ink-800/50 rounded-lg px-2.5 py-1.5">
                <span className="text-[11px] text-mist-400 truncate font-mono">{name}</span>
                <span className="metric-value text-xs" style={{ color: severity(value, 70, 85).color }}>
                  {num(value, 0)}°
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {kind === 'synology' && <SynologyStorage sample={sample} />}
    </div>
  )
}

/** Vue réduite pour un hôte vu uniquement à travers son socket Docker. */
function DockerOnlyTab({ hostId, sample }: { hostId: number; sample: any }) {
  const running = sample['docker.containers.running'] ?? 0
  const total = sample['docker.containers.total'] ?? 0

  return (
    <div className="space-y-4">
      <div className="panel p-4 flex flex-wrap items-center justify-around gap-6">
        <div className="flex flex-col items-center gap-1">
          <span className="metric-value text-3xl text-accent">
            {running}
            <span className="text-ink-600 text-lg">/{total}</span>
          </span>
          <span className="metric-label">Conteneurs actifs</span>
        </div>
        <Gauge
          value={Math.min(100, sample['docker.cpu.total'] ?? 0)}
          label="CPU cumulé"
          format={(v) => `${v.toFixed(0)}%`}
        />
        <div className="flex flex-col items-center gap-1">
          <div className="h-[92px] flex items-center">
            <span className="metric-value text-2xl">{bytes(sample['docker.mem.total'])}</span>
          </div>
          <span className="metric-label">Mémoire cumulée</span>
        </div>
      </div>

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
        <ChartPanel title="CPU cumulé des conteneurs" hint="%">
          <LiveChart
            hostId={hostId}
            height={168}
            format={(v) => `${v.toFixed(1)}%`}
            specs={[{ label: 'CPU', metric: 'docker.cpu.total', color: PALETTE[0] }]}
          />
        </ChartPanel>
        <ChartPanel title="Conteneurs actifs">
          <LiveChart
            hostId={hostId}
            height={168}
            format={(v) => v.toFixed(0)}
            specs={[
              { label: 'Actifs', metric: 'docker.containers.running', color: PALETTE[1] },
              { label: 'Total', metric: 'docker.containers.total', color: PALETTE[3], fill: false },
            ]}
          />
        </ChartPanel>
      </div>

      <p className="text-[13px] text-ink-500 panel p-3.5">
        Cet hôte est supervisé via le socket Docker : seules les métriques des conteneurs sont disponibles.
        Enregistre-le comme <b className="text-mist-300">serveur Linux</b> avec des identifiants SSH pour obtenir
        aussi le CPU, la mémoire, le réseau et les disques de la machine.
      </p>
    </div>
  )
}

function ChartPanel({ title, hint, children }: { title: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="panel p-4">
      <div className="flex items-baseline justify-between mb-1">
        <h3 className="text-sm font-semibold text-mist-200">{title}</h3>
        {hint && <span className="text-[10px] text-ink-600 font-mono">{hint}</span>}
      </div>
      {children}
    </div>
  )
}

// --------------------------------------------------------------- historique
const RANGES = ['15m', '1h', '6h', '24h', '7d', '30d'] as const

function HistoryTab({ hostId, kind }: { hostId: number; kind: string }) {
  const [range, setRange] = useState<(typeof RANGES)[number]>('6h')
  const metrics = 'cpu.usage,mem.percent,disk.percent,net.rx,net.tx,disk.read,disk.write,load.1,temp.cpu,gpu.busy'

  const { data, isFetching } = useQuery({
    queryKey: ['history', hostId, range],
    queryFn: () => get(`/hosts/${hostId}/metrics?metrics=${metrics}&range=${range}&points=400`),
    refetchInterval: range === '15m' ? 15000 : 60000,
  })

  const build = (names: string[]): any => {
    const series = data?.series ?? {}
    const timestamps = new Set<number>()
    names.forEach((name) => (series[name] ?? []).forEach(([t]: [number, number]) => timestamps.add(t)))
    const axis = [...timestamps].sort((a, b) => a - b)
    const columns = names.map((name) => {
      const lookup = new Map<number, number>((series[name] ?? []).map(([t, v]: [number, number]) => [t, v]))
      return axis.map((t) => lookup.get(t) ?? null)
    })
    return [axis, ...columns]
  }

  const hasData = Object.values(data?.series ?? {}).some((s: any) => s.length > 0)

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
          {RANGES.map((value) => (
            <button
              key={value}
              onClick={() => setRange(value)}
              className={clsx(
                'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                range === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
              )}
            >
              {value}
            </button>
          ))}
        </div>
        {isFetching && <Spinner size={14} className="text-ink-500" />}
        <span className="text-xs text-ink-600">résolution {data?.bucket ?? '—'} s</span>
      </div>

      {!hasData && !isFetching && (
        <div className="panel">
          <Empty
            icon={<Activity size={34} />}
            title="Pas encore d'historique"
            hint="Les métriques s'accumulent au fil des cycles de collecte. Reviens dans quelques minutes."
          />
        </div>
      )}

      {hasData && (
        <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
          <ChartPanel title="Processeur" hint="%">
            <Chart height={190} data={build(['cpu.usage'])} format={(v) => `${v.toFixed(0)}%`} yRange={[0, 100]}
              specs={[{ label: 'CPU', metric: 'cpu.usage', color: PALETTE[0] }]} />
          </ChartPanel>
          <ChartPanel title="Mémoire" hint="%">
            <Chart height={190} data={build(['mem.percent'])} format={(v) => `${v.toFixed(0)}%`} yRange={[0, 100]}
              specs={[{ label: 'RAM', metric: 'mem.percent', color: PALETTE[1] }]} />
          </ChartPanel>
          <ChartPanel title="Réseau">
            <Chart height={190} data={build(['net.rx', 'net.tx'])} format={(v) => bitrate(Math.abs(v))}
              specs={[
                { label: 'Réception', color: PALETTE[1] },
                { label: 'Émission', color: PALETTE[2] },
              ]} />
          </ChartPanel>
          <ChartPanel title="Entrées/sorties disque">
            <Chart height={190} data={build(['disk.read', 'disk.write'])} format={(v) => bitrate(Math.abs(v))}
              specs={[
                { label: 'Lecture', color: PALETTE[0] },
                { label: 'Écriture', color: PALETTE[4] },
              ]} />
          </ChartPanel>
          <ChartPanel title="Occupation disque" hint="%">
            <Chart height={170} data={build(['disk.percent'])} format={(v) => `${v.toFixed(1)}%`}
              specs={[{ label: 'Disque', color: PALETTE[3] }]} />
          </ChartPanel>
          {(data?.series?.['temp.cpu']?.length ?? 0) > 0 && (
            <ChartPanel title="Température" hint="°C">
              <Chart height={170} data={build(['temp.cpu', 'gpu.busy'])} format={(v) => v.toFixed(1)}
                specs={[
                  { label: 'CPU °C', color: PALETTE[4] },
                  { label: 'GPU %', color: PALETTE[5], fill: false },
                ]} />
            </ChartPanel>
          )}
        </div>
      )}
    </div>
  )
}

// ------------------------------------------------------------------- système
function SystemTab({ host, sample }: { host: any; sample: any }) {
  const meta = host.meta ?? {}
  const failed: string[] = meta.services_failed ?? []
  const running: string[] = meta.services_running ?? []
  const toast = useToast()
  const confirm = useConfirm()
  const [busy, setBusy] = useState<string | null>(null)

  const restart = async (service: string) => {
    const ok = await confirm({
      title: 'Redémarrer le service ?',
      message: (
        <>
          <b className="text-mist-100">{service}</b> sera redémarré sur {host.name}.
        </>
      ),
      confirmLabel: 'Redémarrer',
    })
    if (!ok) return
    setBusy(service)
    try {
      const result = await post(`/hosts/${host.id}/service`, { service, action: 'restart' })
      toast(`${service} : ${result.output?.trim() || result.status}`, result.status === 'success' ? 'ok' : 'danger')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  // Les lignes sans valeur sont masquées : un NAS n'a pas de « noyau »,
  // un Proxmox n'a pas de « version DSM ».
  const rows = ([
    ['Nom', host.name],
    ['Adresse', <span className="font-mono">{host.address}{host.port ? `:${host.port}` : ''}</span>],
    ['Type', KIND_LABEL[host.kind] ?? host.kind],
    ['Système', meta.os ?? '—'],
    ['Noyau', meta.kernel ?? '—'],
    ['Processeur', meta.cpu_model ?? '—'],
    ['Cœurs', meta.cpu_count ?? sample['cpu.count'] ?? '—'],
    ['Mémoire totale', sample['mem.total'] ? bytes(sample['mem.total']) : '—'],
    ['Virtualisation', meta.virt && meta.virt !== 'none' ? meta.virt : 'matériel'],
    ['Modèle', meta.model ?? '—'],
    ['Version DSM', meta.dsm_version ?? '—'],
    ['Numéro de série', meta.serial ?? '—'],
    ['Nœuds Proxmox', (meta.nodes ?? []).join(', ') || '—'],
    ['Version Proxmox', meta.version ?? '—'],
    ['Uptime', sample.uptime ? duration(sample.uptime) : '—'],
    ['Dernier contact', ago(host.last_seen)],
  ] as [string, React.ReactNode][]).filter(([, value]) => value !== '—')

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
      <div className="panel p-4">
        <SectionTitle>Informations</SectionTitle>
        <dl className="divide-y divide-ink-800/70">
          {rows.map(([label, value]) => (
            <div key={label} className="flex items-baseline justify-between gap-4 py-1.5">
              <dt className="text-xs text-ink-500 shrink-0">{label}</dt>
              <dd className="text-[13px] text-mist-200 text-right truncate">{value}</dd>
            </div>
          ))}
        </dl>
      </div>

      <div className="space-y-4">
        {(meta.updates ?? 0) > 0 && (
          <div className="panel p-4 border-warn/25 bg-warn/[0.04]">
            <div className="flex items-center gap-2.5">
              <Download size={18} className="text-warn shrink-0" />
              <div className="flex-1">
                <div className="text-sm text-mist-100 font-medium">
                  {meta.updates} mise{meta.updates > 1 ? 's' : ''} à jour disponible{meta.updates > 1 ? 's' : ''}
                </div>
                {meta.security_updates > 0 && (
                  <div className="text-xs text-warn mt-0.5">dont {meta.security_updates} de sécurité</div>
                )}
              </div>
            </div>
            {meta.reboot_required && (
              <p className="text-xs text-warn mt-2 flex items-center gap-1.5">
                <RotateCcw size={12} /> Un redémarrage est requis pour finaliser des mises à jour déjà installées.
              </p>
            )}
          </div>
        )}

        {failed.length > 0 && (
          <div className="panel p-4 border-danger/25">
            <SectionTitle>Services en échec</SectionTitle>
            <div className="space-y-1">
              {failed.map((service) => (
                <div key={service} className="flex items-center gap-2 bg-danger/8 rounded-lg px-2.5 py-1.5">
                  <StatusDot status="offline" size={6} />
                  <span className="font-mono text-[13px] text-mist-200 flex-1 truncate">{service}</span>
                  <button className="btn-ghost py-1 px-2 text-xs" onClick={() => restart(service)} disabled={busy === service}>
                    {busy === service ? <Spinner size={12} /> : <RefreshCw size={12} />}
                    Relancer
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}

        {running.length > 0 && (
          <div className="panel p-4">
            <SectionTitle right={<span className="text-xs text-ink-500">{running.length}</span>}>
              Services actifs
            </SectionTitle>
            <div className="grid gap-1 grid-cols-1 sm:grid-cols-2 max-h-80 overflow-y-auto -mr-1.5 pr-1.5">
              {running.map((service) => (
                <div key={service} className="flex items-center gap-2 px-2 py-1 rounded hover:bg-ink-800 group">
                  <StatusDot status="online" size={5} />
                  <span className="font-mono text-[12px] text-mist-300 flex-1 truncate">
                    {service.replace('.service', '')}
                  </span>
                  <button
                    className="btn-icon opacity-0 group-hover:opacity-100 py-0.5 px-1"
                    onClick={() => restart(service)}
                    title="Redémarrer"
                  >
                    <RefreshCw size={11} />
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------- conteneurs
function ContainersTab({
  host,
  sample,
  onLogs,
}: {
  host: any
  sample: any
  onLogs: (name: string, text: string) => void
}) {
  const isPve = host.kind === 'proxmox'
  const { data: stored = [] } = useQuery({
    queryKey: ['containers', host.id],
    queryFn: () => get(`/containers?host_id=${host.id}`),
    refetchInterval: 10000,
  })
  const items = isPve ? stored : (sample.containers ?? stored)
  const toast = useToast()
  const confirm = useConfirm()
  const queryClient = useQueryClient()
  const [busy, setBusy] = useState<string | null>(null)

  const act = async (item: any, action: string) => {
    const label = item.name ?? item.ext_id
    if (action === 'stop' || action === 'restart') {
      const ok = await confirm({
        title: action === 'stop' ? 'Arrêter ?' : 'Redémarrer ?',
        message: (
          <>
            <b className="text-mist-100">{label}</b> sur {host.name}.
          </>
        ),
        confirmLabel: action === 'stop' ? 'Arrêter' : 'Redémarrer',
        danger: action === 'stop',
      })
      if (!ok) return
    }
    setBusy(`${item.ext_id}-${action}`)
    try {
      if (isPve) {
        const [kind, vmid] = String(item.ext_id).split('/')
        const pveAction = action === 'restart' ? 'reboot' : action === 'stop' ? 'shutdown' : 'start'
        await post(`/hosts/${host.id}/guest`, { vmid: Number(vmid), kind, action: pveAction })
      } else {
        await post(`/hosts/${host.id}/containers/${item.ext_id}/${action}`)
      }
      toast(`${label} : ${action} envoyé`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['containers', host.id] }), 1500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const showLogs = async (item: any) => {
    setBusy(`${item.ext_id}-logs`)
    try {
      const result = await get(`/hosts/${host.id}/containers/${item.ext_id}/logs?lines=500`)
      onLogs(item.name, result.logs)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  if (items.length === 0) {
    return (
      <div className="panel">
        <Empty icon={<Boxes size={34} />} title="Aucun conteneur" hint="Rien à afficher sur cet hôte." />
      </div>
    )
  }

  return (
    <div className="panel overflow-x-auto">
      <table className="w-full text-sm min-w-[720px]">
        <thead>
          <tr className="text-left border-b border-ink-750">
            {['Nom', isPve ? 'Nœud' : 'Image', 'État', 'CPU', 'Mémoire', ''].map((header) => (
              <th key={header} className="metric-label px-3 py-2 font-semibold">
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {items.map((item: any) => {
            const stats = item.stats ?? {}
            const running = item.state === 'running'
            return (
              <tr key={item.ext_id} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
                <td className="px-3 py-2">
                  <div className="flex items-center gap-2">
                    <StatusDot status={item.state} size={7} />
                    <span className="text-mist-100 truncate">{item.name}</span>
                    {isPve && <Badge>{String(item.ext_id).split('/')[0]}</Badge>}
                  </div>
                  <div className="text-[10px] text-ink-600 font-mono ml-4">{item.status}</div>
                </td>
                <td className="px-3 py-2 text-xs text-ink-500 font-mono truncate max-w-[220px]">
                  {isPve ? (stats.node ?? item.image) : item.image}
                </td>
                <td className="px-3 py-2">
                  <Badge tone={running ? 'ok' : 'neutral'}>{item.state}</Badge>
                </td>
                <td className="px-3 py-2 w-24">
                  <span className="metric-value text-xs">{stats.cpu !== undefined ? `${num(stats.cpu, 1)}%` : '—'}</span>
                </td>
                <td className="px-3 py-2 w-36">
                  {stats.mem !== undefined ? (
                    <div className="space-y-1">
                      <span className="metric-value text-xs">{bytes(stats.mem)}</span>
                      <Bar value={stats.mem_percent ?? 0} height={3} />
                    </div>
                  ) : (
                    '—'
                  )}
                </td>
                <td className="px-3 py-2">
                  <div className="flex items-center justify-end gap-1">
                    {!isPve && (
                      <>
                        <Link
                          to={`/terminal?host=${host.id}&container=${item.ext_id}`}
                          className={clsx('btn-icon', !running && 'pointer-events-none opacity-30')}
                          title="Terminal dans le conteneur"
                        >
                          <TerminalSquare size={14} />
                        </Link>
                        <button className="btn-icon" onClick={() => showLogs(item)} title="Journaux">
                          {busy === `${item.ext_id}-logs` ? <Spinner size={13} /> : <Info size={14} />}
                        </button>
                      </>
                    )}
                    {running ? (
                      <>
                        <button className="btn-icon" onClick={() => act(item, 'restart')} title="Redémarrer">
                          {busy === `${item.ext_id}-restart` ? <Spinner size={13} /> : <RefreshCw size={14} />}
                        </button>
                        <button className="btn-icon hover:text-danger" onClick={() => act(item, 'stop')} title="Arrêter">
                          <Square size={13} />
                        </button>
                      </>
                    ) : (
                      <button className="btn-icon hover:text-accent" onClick={() => act(item, 'start')} title="Démarrer">
                        {busy === `${item.ext_id}-start` ? <Spinner size={13} /> : <Play size={14} />}
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

// ---------------------------------------------------------------- processus
function ProcessesTab({ sample }: { sample: any }) {
  const processes = sample.processes ?? []
  return (
    <div className="panel overflow-x-auto">
      <table className="w-full text-sm min-w-[560px]">
        <thead>
          <tr className="text-left border-b border-ink-750">
            {['PID', 'Utilisateur', 'Commande', 'CPU', 'RAM', 'RSS'].map((header) => (
              <th key={header} className="metric-label px-3 py-2 font-semibold">
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {processes.map((proc: any) => (
            <tr key={proc.pid} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
              <td className="px-3 py-1.5 font-mono text-xs text-ink-500">{proc.pid}</td>
              <td className="px-3 py-1.5 text-xs text-mist-400">{proc.user}</td>
              <td className="px-3 py-1.5 font-mono text-[13px] text-mist-200 truncate max-w-[340px]">{proc.name}</td>
              <td className="px-3 py-1.5 w-32">
                <div className="flex items-center gap-2">
                  <span className="metric-value text-xs w-11 text-right">{num(proc.cpu, 1)}%</span>
                  <Bar value={proc.cpu} height={3} className="flex-1" />
                </div>
              </td>
              <td className="px-3 py-1.5 metric-value text-xs">{num(proc.mem, 1)}%</td>
              <td className="px-3 py-1.5 metric-value text-xs">{bytes(proc.rss)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

// ----------------------------------------------------------- stockage syno
function SynologyStorage({ sample }: { sample: any }) {
  const volumes = sample.volumes ?? []
  const disks = sample.disks ?? []
  if (!volumes.length && !disks.length) return null

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
      {volumes.length > 0 && (
        <div className="panel p-4">
          <SectionTitle>Volumes</SectionTitle>
          <div className="space-y-3">
            {volumes.map((volume: any) => (
              <div key={volume.id} className="space-y-1.5">
                <div className="flex items-baseline justify-between">
                  <span className="text-[13px] text-mist-200">
                    {volume.name} <span className="text-ink-600 text-xs">{volume.fs} · {volume.raid}</span>
                  </span>
                  <span className="metric-value text-xs" style={{ color: severity(volume.percent).color }}>
                    {percent(volume.percent, 0)}
                  </span>
                </div>
                <Bar value={volume.percent} height={6} />
                <div className="flex justify-between text-[11px] text-ink-500 font-mono">
                  <span>{bytes(volume.used)} / {bytes(volume.total)}</span>
                  <Badge tone={volume.status === 'normal' ? 'ok' : 'warn'}>{volume.status}</Badge>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
      {disks.length > 0 && (
        <div className="panel p-4">
          <SectionTitle right={<span className="text-xs text-ink-500">{disks.length} disques</span>}>
            Disques
          </SectionTitle>
          <div className="space-y-1">
            {disks.map((disk: any) => (
              <div key={disk.id} className="flex items-center gap-2.5 py-1.5 border-b border-ink-800/60 last:border-0">
                <HardDrive size={14} className="text-ink-500 shrink-0" />
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-200 truncate">
                    {disk.name} <span className="text-ink-600 text-xs">{disk.model}</span>
                  </div>
                  <div className="text-[10px] text-ink-600 font-mono">{bytes(disk.size)} · {disk.type}</div>
                </div>
                {disk.temp != null && (
                  <span className="metric-value text-xs" style={{ color: severity(disk.temp, 45, 55).color }}>
                    {disk.temp}°
                  </span>
                )}
                <Badge tone={disk.status === 'normal' ? 'ok' : 'danger'}>{disk.smart ?? disk.status}</Badge>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
