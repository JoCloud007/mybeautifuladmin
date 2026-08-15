import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Archive,
  Camera,
  Copy,
  Cpu,
  ExternalLink,
  History,
  MonitorPlay,
  MoveRight,
  Play,
  Plus,
  RotateCcw,
  Search,
  Server,
  Settings2,
  Square,
  Trash2,
  Undo2,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Chart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Bar,
  Empty,
  Modal,
  Spinner,
  StatusDot,
  Tabs,
  useConfirm,
  useLocalState,
  useToast,
} from '@/components/ui'
import { del, get, patch, post } from '@/lib/api'
import { bytes, datetime, duration, percent, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

export function ProxmoxPage() {
  const [selectedHost, setSelectedHost] = useState<number | null>(null)
  const { data: clusters = [], isLoading } = useQuery({
    queryKey: ['pve-hosts'],
    queryFn: () => get('/proxmox/hosts'),
    refetchInterval: 30000,
  })
  useLive((s) => s.bump)

  const current = clusters.find((c: any) => c.id === (selectedHost ?? clusters[0]?.id))

  if (isLoading) {
    return (
      <Page>
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      </Page>
    )
  }

  if (clusters.length === 0) {
    return (
      <Page>
        <PageHeader title="Proxmox" />
        <EmptyState />
      </Page>
    )
  }

  return (
    <Page>
      <PageHeader
        title="Proxmox"
        subtitle={`${clusters.length} hyperviseur(s) · administration des VM et conteneurs`}
        actions={
          clusters.length > 1 && (
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {clusters.map((cluster: any) => (
                <button
                  key={cluster.id}
                  onClick={() => setSelectedHost(cluster.id)}
                  className={clsx(
                    'px-3 py-1 rounded-md text-xs font-medium transition-colors flex items-center gap-1.5',
                    current?.id === cluster.id ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                >
                  <StatusDot status={cluster.status} size={6} />
                  {cluster.name}
                </button>
              ))}
            </div>
          )
        }
      />
      {current && <ClusterPanel cluster={current} />}
    </Page>
  )
}

/** Aucun hyperviseur typé « proxmox » : on propose de convertir les hôtes
 *  Linux sur lesquels /etc/pve a été détecté. */
function EmptyState() {
  const [converting, setConverting] = useState<number | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data: candidates = [] } = useQuery({
    queryKey: ['pve-candidates'],
    queryFn: () => get('/proxmox/candidates'),
    refetchInterval: 60000,
  })
  const { data: credentials = [] } = useQuery({ queryKey: ['credentials'], queryFn: () => get('/credentials') })
  const tokens = credentials.filter((c: any) => c.kind === 'api_token')

  const convert = async (candidate: any) => {
    const ok = await confirm({
      title: 'Basculer en mode Proxmox ?',
      message: (
        <>
          <b className="text-mist-100">{candidate.name}</b> passera du collecteur SSH générique à
          l'API Proxmox (port 8006), ce qui débloque l'administration des VM.
          {tokens.length === 0 && (
            <span className="block mt-2 text-warn">
              Aucun jeton d'API enregistré : crée-le d'abord dans Réglages → Identifiants, sinon la
              collecte s'arrêtera.
            </span>
          )}
        </>
      ),
      confirmLabel: 'Basculer',
      danger: tokens.length === 0,
    })
    if (!ok) return
    setConverting(candidate.id)
    try {
      await patch(`/hosts/${candidate.id}`, {
        kind: 'proxmox',
        port: 8006,
        ...(tokens.length === 1 ? { credential_id: tokens[0].id } : {}),
      })
      toast(`${candidate.name} est désormais géré comme hyperviseur`, 'ok')
      queryClient.invalidateQueries({ queryKey: ['pve-hosts'] })
      queryClient.invalidateQueries({ queryKey: ['hosts'] })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setConverting(null)
    }
  }

  return (
    <div className="space-y-4">
      <div className="panel">
        <Empty
          icon={<Server size={38} />}
          title="Aucun hyperviseur Proxmox"
          hint="Ajoute ton nœud PVE avec un jeton d'API (Datacenter → Permissions → API Tokens). MBA gère alors le cycle de vie des VM et conteneurs, les snapshots, les sauvegardes et les migrations."
          action={
            <Link to="/hosts?add=1" className="btn-primary">
              <Plus size={15} />
              Ajouter un hyperviseur
            </Link>
          }
        />
      </div>

      {candidates.length > 0 && (
        <div className="panel border-accent/25 bg-accent/[0.03] p-4">
          <SectionTitle>Nœuds Proxmox détectés</SectionTitle>
          <p className="text-[13px] text-mist-400 mb-3">
            Ces machines sont supervisées en SSH mais portent <span className="font-mono text-mist-200">/etc/pve</span>.
            Bascule-les en type « Proxmox » pour accéder à l'administration des VM.
          </p>
          <div className="space-y-1.5">
            {candidates.map((candidate: any) => (
              <div key={candidate.id} className="flex items-center gap-2.5 bg-ink-850 rounded-lg px-3 py-2">
                <Server size={15} className="text-accent shrink-0" />
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-100 truncate">{candidate.name}</div>
                  <div className="text-[10px] text-ink-600 font-mono truncate">
                    {candidate.address}
                    {candidate.version && ` · ${candidate.version}`}
                  </div>
                </div>
                <button
                  className="btn-primary py-1 px-2.5 text-xs"
                  onClick={() => convert(candidate)}
                  disabled={converting === candidate.id}
                >
                  {converting === candidate.id ? <Spinner size={12} /> : null}
                  Basculer en Proxmox
                </button>
              </div>
            ))}
          </div>
          {tokens.length === 0 && (
            <p className="text-[11px] text-warn mt-2.5">
              Pense à créer un jeton d'API Proxmox dans{' '}
              <Link to="/settings" className="underline">
                Réglages → Identifiants
              </Link>{' '}
              avant de basculer.
            </p>
          )}
        </div>
      )}
    </div>
  )
}

function ClusterPanel({ cluster }: { cluster: any }) {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useLocalState<'all' | 'running' | 'stopped' | 'qemu' | 'lxc'>(
    'mba.pveFilter',
    'all',
  )
  const [detail, setDetail] = useState<{ kind: string; vmid: number; name: string } | null>(null)
  const [tasksOpen, setTasksOpen] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['pve-guests', cluster.id],
    queryFn: () => get(`/proxmox/${cluster.id}/guests`),
    refetchInterval: 10000,
  })

  const guests = data?.guests ?? []
  const summary = data?.summary ?? {}
  const nodes = cluster.nodes ?? []

  const filtered = guests.filter((guest: any) => {
    if (filter === 'running' && guest.status !== 'running') return false
    if (filter === 'stopped' && guest.status === 'running') return false
    if (filter === 'qemu' && guest.type !== 'qemu') return false
    if (filter === 'lxc' && guest.type !== 'lxc') return false
    const needle = query.trim().toLowerCase()
    if (!needle) return true
    return `${guest.name} ${guest.vmid} ${guest.node} ${(guest.tags ?? []).join(' ')}`
      .toLowerCase()
      .includes(needle)
  })

  const byNode = useMemo(() => {
    const map = new Map<string, any[]>()
    for (const guest of filtered) map.set(guest.node, [...(map.get(guest.node) ?? []), guest])
    return [...map.entries()].sort((a, b) => a[0].localeCompare(b[0]))
  }, [filtered])

  const power = async (guest: any, action: string) => {
    const labels: Record<string, string> = {
      start: 'Démarrer',
      shutdown: 'Arrêt propre',
      stop: 'Arrêt forcé',
      reboot: 'Redémarrer',
      reset: 'Reset matériel',
      suspend: 'Suspendre',
      resume: 'Reprendre',
    }
    if (action !== 'start' && action !== 'resume') {
      const ok = await confirm({
        title: `${labels[action]} — ${guest.name} ?`,
        message: (
          <>
            {guest.type === 'qemu' ? 'La VM' : 'Le conteneur'}{' '}
            <b className="text-mist-100">
              {guest.name} ({guest.vmid})
            </b>{' '}
            sur {guest.node}.
            {(action === 'stop' || action === 'reset') && (
              <span className="block mt-2 text-warn">
                Arrêt brutal : équivalent d'une coupure de courant, risque de corruption.
              </span>
            )}
          </>
        ),
        confirmLabel: labels[action],
        danger: action === 'stop' || action === 'reset',
      })
      if (!ok) return
    }
    setBusy(`${guest.vmid}-${action}`)
    try {
      await post(`/proxmox/${cluster.id}/guests/${guest.type}/${guest.vmid}/power/${action}`)
      toast(`${labels[action]} envoyé à ${guest.name}`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['pve-guests', cluster.id] }), 2500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="space-y-4">
      {/* Nœuds */}
      <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(280px,1fr))]">
        {nodes.map((node: any) => (
          <div key={node.node} className="panel p-3.5 space-y-2.5">
            <div className="flex items-center gap-2">
              <StatusDot status={node.status === 'online' ? 'online' : 'offline'} />
              <span className="text-sm font-medium text-mist-100 flex-1 truncate">{node.node}</span>
              <Badge tone="violet">{node.cpu_count ?? '?'} cœurs</Badge>
            </div>
            <div className="grid grid-cols-3 gap-2">
              {[
                ['CPU', node.cpu, percent(node.cpu, 0)],
                [
                  'RAM',
                  node.mem_total ? (100 * node.mem_used) / node.mem_total : 0,
                  node.mem_total ? percent((100 * node.mem_used) / node.mem_total, 0) : '—',
                ],
                [
                  'Disque',
                  node.disk_total ? (100 * node.disk_used) / node.disk_total : 0,
                  node.disk_total ? percent((100 * node.disk_used) / node.disk_total, 0) : '—',
                ],
              ].map(([label, value, text]) => (
                <div key={String(label)} className="space-y-1">
                  <div className="flex justify-between">
                    <span className="metric-label">{String(label)}</span>
                    <span className="metric-value text-[10px]">{String(text)}</span>
                  </div>
                  <Bar value={Number(value) || 0} height={3} />
                </div>
              ))}
            </div>
            <div className="flex items-center justify-between text-[10px] text-ink-600">
              <span>{node.uptime ? `up ${duration(node.uptime)}` : ''}</span>
              <span className="font-mono truncate max-w-[55%]" title={node.cpu_model}>
                {node.cpu_model}
              </span>
            </div>
          </div>
        ))}
      </div>

      {/* Barre de filtres */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
          {(
            [
              ['all', `Tous ${summary.total ?? 0}`],
              ['running', `Actifs ${summary.running ?? 0}`],
              ['stopped', `Arrêtés ${(summary.total ?? 0) - (summary.running ?? 0)}`],
              ['qemu', `VM ${summary.qemu ?? 0}`],
              ['lxc', `LXC ${summary.lxc ?? 0}`],
            ] as const
          ).map(([value, label]) => (
            <button
              key={value}
              onClick={() => setFilter(value)}
              className={clsx(
                'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                filter === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
              )}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="relative">
          <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Nom, VMID, nœud…"
            className="pl-8 py-1.5 w-48"
          />
        </div>
        <div className="flex-1" />
        <button className="btn-ghost" onClick={() => setTasksOpen(true)}>
          <History size={15} />
          Tâches PVE
        </button>
      </div>

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && filtered.length === 0 && (
        <div className="panel">
          <Empty icon={<Server size={34} />} title="Aucun invité pour ces filtres" />
        </div>
      )}

      {byNode.map(([node, items]) => (
        <section key={node}>
          <SectionTitle right={<span className="text-xs text-ink-500">{items.length}</span>}>
            {node}
          </SectionTitle>
          <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(320px,1fr))]">
            {items.map((guest: any) => (
              <GuestCard
                key={`${guest.type}-${guest.vmid}`}
                guest={guest}
                busy={busy}
                onPower={power}
                onOpen={() => setDetail({ kind: guest.type, vmid: guest.vmid, name: guest.name })}
              />
            ))}
          </div>
        </section>
      ))}

      {detail && (
        <GuestModal
          clusterId={cluster.id}
          guest={detail}
          onClose={() => setDetail(null)}
          onChanged={() => queryClient.invalidateQueries({ queryKey: ['pve-guests', cluster.id] })}
        />
      )}

      <TasksModal open={tasksOpen} onClose={() => setTasksOpen(false)} clusterId={cluster.id} />
    </div>
  )
}

function GuestCard({
  guest,
  busy,
  onPower,
  onOpen,
}: {
  guest: any
  busy: string | null
  onPower: (guest: any, action: string) => void
  onOpen: () => void
}) {
  const running = guest.status === 'running'
  return (
    <div className={clsx('panel panel-hover p-3 space-y-2.5', !running && 'opacity-70')}>
      <div className="flex items-start gap-2">
        <StatusDot status={guest.status} />
        <button onClick={onOpen} className="min-w-0 flex-1 text-left group">
          <div className="text-[13px] font-medium text-mist-100 truncate group-hover:text-accent transition-colors">
            {guest.name}
          </div>
          <div className="text-[10px] text-ink-600 font-mono">
            {guest.type === 'qemu' ? 'VM' : 'LXC'} {guest.vmid}
          </div>
        </button>
        <Badge tone={guest.type === 'qemu' ? 'violet' : 'info'}>{guest.type === 'qemu' ? 'VM' : 'LXC'}</Badge>
      </div>

      {running && (
        <div className="grid grid-cols-2 gap-2.5">
          <div className="space-y-1">
            <div className="flex justify-between">
              <span className="metric-label">CPU</span>
              <span className="metric-value text-[11px]" style={{ color: severity(guest.cpu).color }}>
                {percent(guest.cpu, 1)}
              </span>
            </div>
            <Bar value={guest.cpu ?? 0} height={3} />
          </div>
          <div className="space-y-1">
            <div className="flex justify-between">
              <span className="metric-label">RAM</span>
              <span className="metric-value text-[11px]">{bytes(guest.mem)}</span>
            </div>
            <Bar value={guest.mem_percent ?? 0} height={3} />
          </div>
        </div>
      )}

      {(guest.tags ?? []).length > 0 && (
        <div className="flex flex-wrap gap-1">
          {guest.tags.map((tag: string) => (
            <Badge key={tag}>{tag}</Badge>
          ))}
        </div>
      )}

      <div className="flex items-center gap-1 pt-1 border-t border-ink-800">
        <span className="text-[10px] text-ink-600 flex-1 truncate">
          {running && guest.uptime ? `up ${duration(guest.uptime)}` : guest.status}
        </span>
        <button className="btn-icon" onClick={onOpen} title="Administrer">
          <Settings2 size={14} />
        </button>
        {running ? (
          <>
            <button
              className="btn-icon"
              onClick={() => onPower(guest, 'reboot')}
              title="Redémarrer"
              disabled={busy === `${guest.vmid}-reboot`}
            >
              {busy === `${guest.vmid}-reboot` ? <Spinner size={13} /> : <RotateCcw size={14} />}
            </button>
            <button
              className="btn-icon"
              onClick={() => onPower(guest, 'shutdown')}
              title="Arrêt propre"
              disabled={busy === `${guest.vmid}-shutdown`}
            >
              {busy === `${guest.vmid}-shutdown` ? <Spinner size={13} /> : <Square size={13} />}
            </button>
          </>
        ) : (
          <button
            className="btn-icon hover:text-accent"
            onClick={() => onPower(guest, 'start')}
            title="Démarrer"
            disabled={busy === `${guest.vmid}-start`}
          >
            {busy === `${guest.vmid}-start` ? <Spinner size={13} /> : <Play size={14} />}
          </button>
        )}
      </div>
    </div>
  )
}

// --------------------------------------------------------- fiche d'un invité
type GuestTab = 'overview' | 'snapshots' | 'backups' | 'config'

function GuestModal({
  clusterId,
  guest,
  onClose,
  onChanged,
}: {
  clusterId: number
  guest: { kind: string; vmid: number; name: string }
  onClose: () => void
  onChanged: () => void
}) {
  const [tab, setTab] = useState<GuestTab>('overview')
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)

  const key = ['pve-guest', clusterId, guest.kind, guest.vmid]
  const { data, isLoading } = useQuery({
    queryKey: key,
    queryFn: () => get(`/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}`),
    refetchInterval: 30000,
  })

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: key })
    onChanged()
  }

  const base = `/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}`

  const rollback = async (snapshot: any) => {
    const ok = await confirm({
      title: 'Restaurer ce snapshot ?',
      message: (
        <>
          <b className="text-mist-100">{guest.name}</b> reviendra à l'état «{' '}
          <b className="text-mist-100">{snapshot.name}</b> » du {datetime(snapshot.created)}.
          <span className="block mt-2 text-warn">
            Tout ce qui a changé depuis sera définitivement perdu.
          </span>
        </>
      ),
      confirmLabel: 'Restaurer',
      danger: true,
    })
    if (!ok) return
    setBusy(`rollback-${snapshot.name}`)
    try {
      await post(`${base}/snapshots/${snapshot.name}/rollback`)
      toast('Restauration lancée', 'ok')
      setTimeout(refresh, 3000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const removeSnapshot = async (snapshot: any) => {
    const ok = await confirm({
      title: 'Supprimer ce snapshot ?',
      message: (
        <>
          Le snapshot <b className="text-mist-100">{snapshot.name}</b> sera effacé. La VM n'est pas
          affectée.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    setBusy(`del-${snapshot.name}`)
    try {
      await del(`${base}/snapshots/${snapshot.name}`)
      toast('Snapshot supprimé', 'ok')
      setTimeout(refresh, 1500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const history = useMemo(() => {
    const points = data?.history ?? []
    return {
      cpu: [points.map((p: any) => p.time), points.map((p: any) => p.cpu)] as any,
      mem: [
        points.map((p: any) => p.time),
        points.map((p: any) => (p.maxmem ? (100 * p.mem) / p.maxmem : null)),
      ] as any,
      net: [
        points.map((p: any) => p.time),
        points.map((p: any) => p.netin),
        points.map((p: any) => -(p.netout ?? 0)),
      ] as any,
    }
  }, [data])

  return (
    <Modal
      open
      onClose={onClose}
      width="max-w-5xl"
      title={
        <div className="flex items-center gap-2.5 flex-wrap">
          <span>{guest.name}</span>
          <Badge tone={guest.kind === 'qemu' ? 'violet' : 'info'}>
            {guest.kind === 'qemu' ? 'VM' : 'LXC'} {guest.vmid}
          </Badge>
          {data?.node && <span className="text-xs text-ink-500 font-mono">{data.node}</span>}
          {data?.console_url && (
            <a
              href={data.console_url}
              target="_blank"
              rel="noopener noreferrer"
              className="btn-ghost py-1 px-2 text-xs"
            >
              <MonitorPlay size={13} />
              Console
              <ExternalLink size={10} />
            </a>
          )}
        </div>
      }
    >
      {isLoading ? (
        <div className="py-16 grid place-items-center">
          <Spinner size={22} />
        </div>
      ) : (
        <div className="space-y-4">
          <Tabs<GuestTab>
            active={tab}
            onChange={setTab}
            tabs={[
              { id: 'overview', label: "Vue d'ensemble" },
              {
                id: 'snapshots',
                label: 'Snapshots',
                badge: <Badge>{(data?.snapshots ?? []).length}</Badge>,
              },
              {
                id: 'backups',
                label: 'Sauvegardes',
                badge: <Badge>{(data?.backups ?? []).length}</Badge>,
              },
              { id: 'config', label: 'Configuration' },
            ]}
          />

          {tab === 'overview' && (
            <div className="space-y-4">
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
                <Metric label="Cœurs" value={data.config.cores ?? '—'} icon={<Cpu size={13} />} />
                <Metric
                  label="Mémoire"
                  value={data.config.memory ? `${data.config.memory} Mio` : '—'}
                />
                <Metric label="Démarrage auto" value={data.config.onboot ? 'oui' : 'non'} />
                <Metric label="Système" value={data.config.ostype ?? '—'} />
              </div>

              <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div className="panel bg-ink-900/40 p-3">
                  <div className="metric-label mb-1">Processeur (1 h, source Proxmox)</div>
                  <Chart
                    height={150}
                    data={history.cpu}
                    format={(v) => `${v.toFixed(0)} %`}
                    yRange={[0, 100]}
                    specs={[{ label: 'CPU', color: PALETTE[0] }]}
                  />
                </div>
                <div className="panel bg-ink-900/40 p-3">
                  <div className="metric-label mb-1">Mémoire</div>
                  <Chart
                    height={150}
                    data={history.mem}
                    format={(v) => `${v.toFixed(0)} %`}
                    yRange={[0, 100]}
                    specs={[{ label: 'RAM', color: PALETTE[1] }]}
                  />
                </div>
              </div>

              <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div>
                  <SectionTitle>Disques</SectionTitle>
                  <div className="space-y-1">
                    {(data.config.disks ?? []).map((disk: any) => (
                      <div
                        key={disk.slot}
                        className="flex items-center justify-between bg-ink-800/40 rounded-lg px-2.5 py-1.5 text-[12px]"
                      >
                        <span className="font-mono text-mist-200">{disk.slot}</span>
                        <span className="text-ink-500 font-mono truncate mx-2 flex-1">{disk.spec}</span>
                        <span className="metric-value text-xs">{disk.size ?? '—'}</span>
                      </div>
                    ))}
                    {(data.config.disks ?? []).length === 0 && (
                      <p className="text-xs text-ink-600">Aucun disque déclaré.</p>
                    )}
                  </div>
                </div>
                <div>
                  <SectionTitle>Réseau</SectionTitle>
                  <div className="space-y-1">
                    {(data.config.networks ?? []).map((net: any) => (
                      <div
                        key={net.slot}
                        className="flex items-center justify-between bg-ink-800/40 rounded-lg px-2.5 py-1.5 text-[12px]"
                      >
                        <span className="font-mono text-mist-200">{net.slot}</span>
                        <span className="text-ink-500">{net.bridge}</span>
                        <span className="font-mono text-[10px] text-ink-600">{net.mac}</span>
                      </div>
                    ))}
                    {(data.config.networks ?? []).length === 0 && (
                      <p className="text-xs text-ink-600">Aucune interface déclarée.</p>
                    )}
                  </div>
                </div>
              </div>

              <div className="flex flex-wrap gap-2 pt-2 border-t border-ink-800">
                <CloneButton clusterId={clusterId} guest={guest} node={data.node} onDone={refresh} />
                <MigrateButton
                  clusterId={clusterId}
                  guest={guest}
                  currentNode={data.node}
                  onDone={refresh}
                />
              </div>
            </div>
          )}

          {tab === 'snapshots' && (
            <div className="space-y-3">
              <SnapshotForm clusterId={clusterId} guest={guest} onDone={refresh} />
              <div className="space-y-1">
                {(data.snapshots ?? []).length === 0 && (
                  <Empty
                    icon={<Camera size={30} />}
                    title="Aucun snapshot"
                    hint="Un snapshot fige l'état du disque : idéal avant une mise à jour risquée."
                  />
                )}
                {(data.snapshots ?? []).map((snapshot: any) => (
                  <div
                    key={snapshot.name}
                    className="flex items-center gap-2.5 bg-ink-850 rounded-lg px-3 py-2"
                  >
                    <Camera size={14} className="text-ink-500 shrink-0" />
                    <div className="min-w-0 flex-1">
                      <div className="text-[13px] text-mist-100 truncate">
                        {snapshot.name}
                        {snapshot.vmstate && <Badge tone="violet" className="ml-1.5">avec RAM</Badge>}
                      </div>
                      <div className="text-[10px] text-ink-600">
                        {datetime(snapshot.created)}
                        {snapshot.description && ` · ${snapshot.description}`}
                      </div>
                    </div>
                    <button
                      className="btn-ghost py-1 px-2 text-xs"
                      onClick={() => rollback(snapshot)}
                      disabled={busy === `rollback-${snapshot.name}`}
                    >
                      {busy === `rollback-${snapshot.name}` ? <Spinner size={12} /> : <Undo2 size={12} />}
                      Restaurer
                    </button>
                    <button
                      className="btn-icon hover:text-danger"
                      onClick={() => removeSnapshot(snapshot)}
                      disabled={busy === `del-${snapshot.name}`}
                      title="Supprimer"
                    >
                      {busy === `del-${snapshot.name}` ? <Spinner size={12} /> : <Trash2 size={13} />}
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}

          {tab === 'backups' && (
            <BackupsTab clusterId={clusterId} guest={guest} data={data} onDone={refresh} />
          )}

          {tab === 'config' && (
            <ConfigForm clusterId={clusterId} guest={guest} config={data.config} onDone={refresh} />
          )}
        </div>
      )}
    </Modal>
  )
}

function Metric({ label, value, icon }: { label: string; value: any; icon?: React.ReactNode }) {
  return (
    <div className="bg-ink-800/40 rounded-lg px-2.5 py-2">
      <div className="metric-label flex items-center gap-1">
        {icon}
        {label}
      </div>
      <div className="metric-value text-sm mt-0.5">{String(value)}</div>
    </div>
  )
}

function SnapshotForm({
  clusterId,
  guest,
  onDone,
}: {
  clusterId: number
  guest: { kind: string; vmid: number }
  onDone: () => void
}) {
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [vmstate, setVmstate] = useState(false)
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  const create = async () => {
    setBusy(true)
    try {
      await post(`/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}/snapshots`, {
        name: name.trim(),
        description,
        vmstate,
      })
      toast('Snapshot créé', 'ok')
      setName('')
      setDescription('')
      setTimeout(onDone, 1500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const suggested = `avant-maj-${new Date().toISOString().slice(0, 10).replace(/-/g, '')}`

  return (
    <div className="panel bg-ink-900/40 p-3 space-y-2.5">
      <div className="grid grid-cols-1 sm:grid-cols-[1fr,1.5fr] gap-2.5">
        <div className="space-y-1.5">
          <label>Nom</label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value.replace(/[^A-Za-z0-9_-]/g, ''))}
            placeholder={suggested}
            className="w-full font-mono"
          />
        </div>
        <div className="space-y-1.5">
          <label>Description</label>
          <input
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Avant montée de version"
            className="w-full"
          />
        </div>
      </div>
      <div className="flex items-center gap-3">
        {guest.kind === 'qemu' && (
          <label className="flex items-center gap-2 text-xs text-mist-400 normal-case tracking-normal font-normal cursor-pointer">
            <input type="checkbox" checked={vmstate} onChange={(e) => setVmstate(e.target.checked)} />
            Inclure la RAM (restauration à chaud)
          </label>
        )}
        <div className="flex-1" />
        <button className="btn-primary" onClick={create} disabled={busy || !name.trim()}>
          {busy ? <Spinner /> : <Camera size={15} />}
          Créer un snapshot
        </button>
      </div>
    </div>
  )
}

function BackupsTab({
  clusterId,
  guest,
  data,
  onDone,
}: {
  clusterId: number
  guest: { kind: string; vmid: number }
  data: any
  onDone: () => void
}) {
  const storages = data.backup_storages ?? []
  const [storage, setStorage] = useState(storages[0]?.name ?? '')
  const [mode, setMode] = useState<'snapshot' | 'suspend' | 'stop'>('snapshot')
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  useEffect(() => {
    if (!storage && storages.length) setStorage(storages[0].name)
  }, [storages, storage])

  const run = async () => {
    setBusy(true)
    try {
      await post(`/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}/backup`, {
        storage,
        mode,
        compress: 'zstd',
      })
      toast('Sauvegarde lancée — suis sa progression dans les tâches PVE', 'ok')
      setTimeout(onDone, 2000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-3">
      <div className="panel bg-ink-900/40 p-3 flex flex-wrap items-end gap-2.5">
        <div className="space-y-1.5 flex-1 min-w-[160px]">
          <label>Stockage de destination</label>
          <select value={storage} onChange={(e) => setStorage(e.target.value)} className="w-full">
            {storages.map((entry: any) => (
              <option key={entry.name} value={entry.name}>
                {entry.name} ({bytes(entry.available)} libres)
              </option>
            ))}
            {storages.length === 0 && <option value="">aucun stockage de sauvegarde</option>}
          </select>
        </div>
        <div className="space-y-1.5">
          <label>Mode</label>
          <select value={mode} onChange={(e) => setMode(e.target.value as any)} className="w-full">
            <option value="snapshot">Snapshot (sans interruption)</option>
            <option value="suspend">Suspend</option>
            <option value="stop">Stop (arrêt puis sauvegarde)</option>
          </select>
        </div>
        <button className="btn-primary" onClick={run} disabled={busy || !storage}>
          {busy ? <Spinner /> : <Archive size={15} />}
          Sauvegarder maintenant
        </button>
      </div>

      <div className="space-y-1">
        {(data.backups ?? []).length === 0 && (
          <Empty icon={<Archive size={30} />} title="Aucune sauvegarde trouvée" />
        )}
        {(data.backups ?? []).map((backup: any) => (
          <div key={backup.volid} className="flex items-center gap-2.5 bg-ink-850 rounded-lg px-3 py-2">
            <Archive size={14} className="text-ink-500 shrink-0" />
            <div className="min-w-0 flex-1">
              <div className="text-[12px] text-mist-200 font-mono truncate">{backup.volid}</div>
              <div className="text-[10px] text-ink-600">
                {datetime(backup.created)} · {backup.storage}
                {backup.notes && ` · ${backup.notes}`}
              </div>
            </div>
            {backup.protected && <Badge tone="violet">protégée</Badge>}
            <span className="metric-value text-xs">{bytes(backup.size)}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

function ConfigForm({
  clusterId,
  guest,
  config,
  onDone,
}: {
  clusterId: number
  guest: { kind: string; vmid: number; name: string }
  config: any
  onDone: () => void
}) {
  const [form, setForm] = useState({
    cores: config.cores ?? 1,
    memory: config.memory ?? 512,
    name: config.name ?? guest.name,
    description: config.description ?? '',
    onboot: !!config.onboot,
  })
  const [busy, setBusy] = useState(false)
  const confirm = useConfirm()
  const toast = useToast()

  const save = async () => {
    const ok = await confirm({
      title: 'Appliquer la configuration ?',
      message: (
        <>
          {form.cores} cœur(s), {form.memory} Mio de RAM pour{' '}
          <b className="text-mist-100">{guest.name}</b>.
          <span className="block mt-2 text-ink-500">
            Sur une VM allumée, les changements de CPU et de mémoire ne prennent effet qu'après
            redémarrage (sauf hotplug configuré).
          </span>
        </>
      ),
      confirmLabel: 'Appliquer',
    })
    if (!ok) return
    setBusy(true)
    try {
      await patch(`/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}/config`, {
        cores: Number(form.cores),
        memory: Number(form.memory),
        name: form.name,
        description: form.description,
        onboot: form.onboot,
      })
      toast('Configuration appliquée', 'ok')
      setTimeout(onDone, 1500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label>Cœurs</label>
          <input
            type="number"
            min={1}
            max={128}
            value={form.cores}
            onChange={(e) => setForm({ ...form, cores: Number(e.target.value) })}
            className="w-full"
          />
        </div>
        <div className="space-y-1.5">
          <label>Mémoire (Mio)</label>
          <input
            type="number"
            min={64}
            step={128}
            value={form.memory}
            onChange={(e) => setForm({ ...form, memory: Number(e.target.value) })}
            className="w-full"
          />
        </div>
      </div>
      <div className="space-y-1.5">
        <label>Nom</label>
        <input
          value={form.name}
          onChange={(e) => setForm({ ...form, name: e.target.value })}
          className="w-full"
        />
      </div>
      <div className="space-y-1.5">
        <label>Description</label>
        <textarea
          value={form.description}
          onChange={(e) => setForm({ ...form, description: e.target.value })}
          rows={3}
          className="w-full text-sm"
        />
      </div>
      <label className="flex items-center gap-2 text-sm text-mist-300 normal-case tracking-normal font-normal cursor-pointer">
        <input
          type="checkbox"
          checked={form.onboot}
          onChange={(e) => setForm({ ...form, onboot: e.target.checked })}
        />
        Démarrer automatiquement avec le nœud
      </label>
      <div className="flex justify-end">
        <button className="btn-primary" onClick={save} disabled={busy}>
          {busy ? <Spinner /> : <Settings2 size={15} />}
          Appliquer
        </button>
      </div>
    </div>
  )
}

function CloneButton({
  clusterId,
  guest,
  node,
  onDone,
}: {
  clusterId: number
  guest: { kind: string; vmid: number; name: string }
  node: string
  onDone: () => void
}) {
  const [open, setOpen] = useState(false)
  const [name, setName] = useState(`${guest.name}-copie`)
  const [full, setFull] = useState(true)
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  const run = async () => {
    setBusy(true)
    try {
      const result = await post(`/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}/clone`, {
        name,
        full,
      })
      toast(`Clone lancé → VMID ${result.newid}`, 'ok')
      setOpen(false)
      setTimeout(onDone, 2500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button className="btn-ghost" onClick={() => setOpen(true)}>
        <Copy size={15} />
        Cloner
      </button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={`Cloner ${guest.name}`}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setOpen(false)}>
              Annuler
            </button>
            <button className="btn-primary" onClick={run} disabled={busy || !name.trim()}>
              {busy ? <Spinner /> : <Copy size={15} />}
              Cloner
            </button>
          </>
        }
      >
        <div className="space-y-4">
          <div className="space-y-1.5">
            <label>Nom du clone</label>
            <input value={name} onChange={(e) => setName(e.target.value)} className="w-full" />
            <p className="text-[11px] text-ink-500">
              Le VMID est attribué automatiquement par Proxmox. Nœud source : {node}.
            </p>
          </div>
          <div className="space-y-1.5">
            <label>Type de clone</label>
            <div className="grid grid-cols-2 gap-2">
              {(
                [
                  [true, 'Complet', 'Copie indépendante des disques'],
                  [false, 'Lié', 'Plus rapide, dépend du disque parent'],
                ] as const
              ).map(([value, label, hint]) => (
                <button
                  key={String(value)}
                  type="button"
                  onClick={() => setFull(value)}
                  className={clsx(
                    'rounded-lg border px-3 py-2 text-left transition-colors',
                    full === value
                      ? 'border-accent/40 bg-accent/[0.07]'
                      : 'border-ink-750 bg-ink-850 hover:border-ink-600',
                  )}
                >
                  <div className="text-[13px] text-mist-100">{label}</div>
                  <div className="text-[10px] text-ink-600 mt-0.5">{hint}</div>
                </button>
              ))}
            </div>
          </div>
        </div>
      </Modal>
    </>
  )
}

function MigrateButton({
  clusterId,
  guest,
  currentNode,
  onDone,
}: {
  clusterId: number
  guest: { kind: string; vmid: number; name: string }
  currentNode: string
  onDone: () => void
}) {
  const [open, setOpen] = useState(false)
  const [target, setTarget] = useState('')
  const [online, setOnline] = useState(true)
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  const confirm = useConfirm()

  const { data: clusters = [] } = useQuery({
    queryKey: ['pve-hosts'],
    queryFn: () => get('/proxmox/hosts'),
    enabled: open,
  })
  const nodes = (clusters.find((c: any) => c.id === clusterId)?.nodes ?? [])
    .map((n: any) => n.node)
    .filter((n: string) => n !== currentNode)

  const run = async () => {
    const ok = await confirm({
      title: 'Migrer cet invité ?',
      message: (
        <>
          <b className="text-mist-100">{guest.name}</b> sera déplacé de {currentNode} vers{' '}
          <b className="text-mist-100">{target}</b>
          {online ? ' à chaud (sans interruption)' : ' après arrêt'}.
        </>
      ),
      confirmLabel: 'Migrer',
      danger: !online,
    })
    if (!ok) return
    setBusy(true)
    try {
      await post(`/proxmox/${clusterId}/guests/${guest.kind}/${guest.vmid}/migrate`, {
        target,
        online,
      })
      toast('Migration lancée', 'ok')
      setOpen(false)
      setTimeout(onDone, 3000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button className="btn-ghost" onClick={() => setOpen(true)}>
        <MoveRight size={15} />
        Migrer
      </button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title={`Migrer ${guest.name}`}
        footer={
          <>
            <button className="btn-ghost" onClick={() => setOpen(false)}>
              Annuler
            </button>
            <button className="btn-primary" onClick={run} disabled={busy || !target}>
              {busy ? <Spinner /> : <MoveRight size={15} />}
              Migrer
            </button>
          </>
        }
      >
        <div className="space-y-4">
          {nodes.length === 0 ? (
            <p className="text-sm text-ink-500">
              Un seul nœud dans ce cluster : rien vers quoi migrer.
            </p>
          ) : (
            <>
              <div className="space-y-1.5">
                <label>Nœud de destination</label>
                <select value={target} onChange={(e) => setTarget(e.target.value)} className="w-full">
                  <option value="">— choisir —</option>
                  {nodes.map((node: string) => (
                    <option key={node} value={node}>
                      {node}
                    </option>
                  ))}
                </select>
              </div>
              <label className="flex items-center gap-2 text-sm text-mist-300 normal-case tracking-normal font-normal cursor-pointer">
                <input type="checkbox" checked={online} onChange={(e) => setOnline(e.target.checked)} />
                Migration à chaud (l'invité reste allumé)
              </label>
            </>
          )}
        </div>
      </Modal>
    </>
  )
}

function TasksModal({
  open,
  onClose,
  clusterId,
}: {
  open: boolean
  onClose: () => void
  clusterId: number
}) {
  const { data: tasks = [], isLoading } = useQuery({
    queryKey: ['pve-tasks', clusterId],
    queryFn: () => get(`/proxmox/${clusterId}/tasks`),
    enabled: open,
    refetchInterval: open ? 5000 : false,
  })

  return (
    <Modal open={open} onClose={onClose} title="Tâches Proxmox" width="max-w-3xl">
      {isLoading ? (
        <div className="py-10 grid place-items-center">
          <Spinner size={20} />
        </div>
      ) : (
        <div className="space-y-1 max-h-[60vh] overflow-y-auto">
          {tasks.length === 0 && <Empty icon={<History size={30} />} title="Aucune tâche récente" />}
          {tasks.map((task: any) => {
            const running = !task.ended
            return (
              <div key={task.upid} className="flex items-center gap-2.5 bg-ink-850 rounded-lg px-3 py-2">
                {running ? (
                  <Spinner size={13} className="text-accent shrink-0" />
                ) : (
                  <StatusDot status={task.status === 'OK' ? 'online' : 'offline'} size={6} />
                )}
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-100">
                    {task.type}
                    {task.vmid && <span className="text-ink-500 font-mono ml-1.5">{task.vmid}</span>}
                  </div>
                  <div className="text-[10px] text-ink-600">
                    {task.node} · {task.user} · {datetime(task.started)}
                  </div>
                </div>
                <Badge tone={running ? 'warn' : task.status === 'OK' ? 'ok' : 'danger'}>
                  {running ? 'en cours' : task.status}
                </Badge>
              </div>
            )
          })}
        </div>
      )}
    </Modal>
  )
}
