import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  AlertTriangle,
  Archive,
  CheckCircle2,
  Database,
  HardDriveDownload,
  Plus,
  RefreshCw,
  Search,
  ShieldOff,
  Wrench,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { AddHostModal } from '@/components/AddHostModal'
import { Cloud, HardDrive, Info } from 'lucide-react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Bar, Empty, Modal, Spinner, StatTile, StatusDot, Tabs, useToast } from '@/components/ui'
import { get } from '@/lib/api'
import { bytes, datetime, duration, percent, severity } from '@/lib/format'

type Tab = 'coverage' | 'gaps' | 'risks' | 'stores' | 'tasks'

const FRESHNESS: Record<string, { label: string; tone: 'ok' | 'warn' | 'danger' | 'neutral' }> = {
  fresh: { label: 'à jour', tone: 'ok' },
  stale: { label: 'en retard', tone: 'warn' },
  critical: { label: 'périmée', tone: 'danger' },
  unknown: { label: 'inconnue', tone: 'neutral' },
}

const SOURCE_LABEL: Record<string, string> = {
  pbs: 'Proxmox Backup Server',
  vzdump: 'vzdump (PVE)',
  hyperbackup: 'Hyper Backup',
  c2: 'Synology C2',
  global: 'Analyse globale',
}

/** Choix de la source à déclarer : chaque type a ses prérequis. */
function SourcePicker({
  open,
  onClose,
  onPick,
}: {
  open: boolean
  onClose: () => void
  onPick: (kind: string) => void
}) {
  const options = [
    {
      kind: 'pbs',
      label: 'Proxmox Backup Server',
      icon: Database,
      hint: "Port 8007, jeton d'API « user@pbs!id:secret » avec lecture sur les datastores.",
    },
    {
      kind: 'synology',
      label: 'NAS Synology',
      icon: HardDrive,
      hint: 'Hyper Backup et les destinations C2 sont découverts automatiquement depuis le NAS.',
    },
    {
      kind: 'proxmox',
      label: 'Hyperviseur Proxmox',
      icon: Database,
      hint: 'Les sauvegardes vzdump de ses VM et conteneurs sont lues directement.',
    },
  ]
  return (
    <Modal open={open} onClose={onClose} title="Quelle source de sauvegarde ?" width="max-w-xl">
      <div className="space-y-2">
        {options.map((option) => {
          const Icon = option.icon
          return (
            <button
              key={option.kind}
              onClick={() => onPick(option.kind)}
              className="w-full flex items-start gap-3 rounded-lg border border-ink-750 bg-ink-850 px-3.5 py-3 text-left hover:border-accent/40 hover:bg-accent/[0.05] transition-colors"
            >
              <Icon size={18} className="text-accent shrink-0 mt-0.5" />
              <div>
                <div className="text-[13px] text-mist-100">{option.label}</div>
                <div className="text-[11px] text-ink-500 mt-0.5">{option.hint}</div>
              </div>
            </button>
          )
        })}
      </div>
      <p className="text-[11px] text-ink-500 mt-4">
        Synology C2 n'expose pas d'API publique de supervision : MBA le repère à travers les tâches
        Hyper Backup dont la destination est C2, et les compte comme copie hors site.
      </p>
    </Modal>
  )
}

const SEVERITY_TONE: Record<string, 'danger' | 'warn' | 'info' | 'neutral'> = {
  critical: 'danger',
  high: 'danger',
  medium: 'warn',
  low: 'info',
}

export function ProtectionPage() {
  const [tab, setTab] = useState<Tab>('coverage')
  const [query, setQuery] = useState('')
  const [addKind, setAddKind] = useState<string | null>(null)
  const [sourcePicker, setSourcePicker] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data, isLoading, isFetching } = useQuery({
    queryKey: ['protection'],
    queryFn: () => get('/protection'),
    refetchInterval: 120000,
  })
  const { data: sources } = useQuery({ queryKey: ['protection-sources'], queryFn: () => get('/protection/sources') })

  const summary = data?.summary ?? {}
  const protectedItems = data?.protected ?? []

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return protectedItems
    return protectedItems.filter((item: any) =>
      `${item.name} ${item.store ?? ''} ${item.source_host}`.toLowerCase().includes(needle),
    )
  }, [protectedItems, query])

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['protection'] })
    toast('Analyse relancée', 'ok')
  }

  const coverageTone = summary.coverage >= 90 ? '#00d4aa' : summary.coverage >= 70 ? '#ffb020' : '#ff4d6d'

  if (isLoading) {
    return (
      <Page>
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      </Page>
    )
  }

  const noSources = (sources?.sources ?? []).length === 0

  return (
    <Page>
      <PageHeader
        title="Protection des données"
        subtitle="Couverture des sauvegardes, écarts et risques — PBS, vzdump et Hyper Backup"
        actions={
          <>
            <button className="btn-ghost" onClick={refresh} disabled={isFetching}>
              {isFetching ? <Spinner size={14} /> : <RefreshCw size={15} />}
              Actualiser
            </button>
            <button className="btn-primary" onClick={() => setSourcePicker(true)}>
              <Plus size={15} />
              Ajouter une source
            </button>
          </>
        }
      />

      {noSources && (
        <div className="panel mb-4">
          <Empty
            icon={<Archive size={38} />}
            title="Aucune source de sauvegarde"
            hint="Enregistre ton Proxmox Backup Server (port 8007, jeton d'API), ton hyperviseur PVE pour les vzdump, ou ton NAS Synology pour lire les tâches Hyper Backup."
            action={
              <button className="btn-primary" onClick={() => setSourcePicker(true)}>
                <Plus size={15} />
                Ajouter une source
              </button>
            }
          />
        </div>
      )}

      {(data?.notices ?? []).length > 0 && (
        <div className="panel border-info/25 bg-info/[0.04] px-4 py-2.5 mb-4 space-y-1">
          {data.notices.map((notice: any, index: number) => (
            <div key={index} className="text-[13px] text-mist-300 flex items-start gap-2">
              <Info size={14} className="text-info shrink-0 mt-0.5" />
              <span>
                <b className="text-mist-100">{notice.host}</b> — {notice.message}
              </span>
            </div>
          ))}
        </div>
      )}

      <div className="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-3 mb-5">
        <div className="panel px-4 py-3">
          <div className="metric-label">Couverture</div>
          <div className="metric-value text-2xl font-semibold" style={{ color: coverageTone }}>
            {percent(summary.coverage, 0)}
          </div>
          <Bar value={summary.coverage ?? 0} height={4} warn={101} crit={102} className="mt-1.5" />
          <div className="text-[10px] text-ink-500 mt-1">
            {summary.fresh ?? 0} objet(s) à jour
          </div>
        </div>
        <StatTile
          label="Sauvegardés"
          value={summary.protected ?? 0}
          sub={bytes(summary.total_size)}
          icon={<Archive size={20} />}
        />
        <StatTile
          label="En retard"
          value={summary.stale ?? 0}
          sub={`${summary.critical ?? 0} périmée(s)`}
          tone={summary.critical ? 'danger' : summary.stale ? 'warn' : 'ok'}
          icon={<AlertTriangle size={20} />}
          onClick={() => setTab('risks')}
        />
        <StatTile
          label="Non protégés"
          value={summary.gaps ?? 0}
          sub="écarts détectés"
          tone={summary.gaps ? 'danger' : 'ok'}
          icon={<ShieldOff size={20} />}
          onClick={() => setTab('gaps')}
        />
        <StatTile
          label="Risques"
          value={summary.risks ?? 0}
          sub={`${summary.risks_critical ?? 0} critique(s)`}
          tone={summary.risks_critical ? 'danger' : summary.risks ? 'warn' : 'ok'}
          icon={<AlertTriangle size={20} />}
          onClick={() => setTab('risks')}
        />
        <StatTile
          label="Hors site"
          value={summary.offsite ?? 0}
          sub={summary.offsite ? 'copies distantes' : 'aucune copie distante'}
          tone={summary.offsite ? 'ok' : 'warn'}
          icon={<Cloud size={20} />}
        />
      </div>

      {(data?.errors ?? []).length > 0 && (
        <div className="panel border-warn/25 bg-warn/[0.04] px-4 py-2.5 mb-4 space-y-1">
          {data.errors.map((error: any, index: number) => (
            <div key={index} className="text-[13px] text-warn">
              <b>{error.host}</b> ({error.kind}) : {error.error}
            </div>
          ))}
        </div>
      )}

      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'coverage', label: 'Couverture', badge: <Badge>{protectedItems.length}</Badge> },
            {
              id: 'gaps',
              label: 'Écarts',
              badge: summary.gaps ? <Badge tone="danger">{summary.gaps}</Badge> : undefined,
            },
            {
              id: 'risks',
              label: 'Risques',
              badge: summary.risks ? <Badge tone="warn">{summary.risks}</Badge> : undefined,
            },
            { id: 'stores', label: 'Stockages' },
            { id: 'tasks', label: 'Tâches' },
          ]}
        />
      </div>

      {tab === 'coverage' && (
        <>
          <div className="relative mb-3 w-64">
            <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Filtrer…"
              className="pl-8 py-1.5 w-full"
            />
          </div>
          <div className="panel overflow-x-auto">
            <table className="w-full text-sm min-w-[820px]">
              <thead>
                <tr className="text-left border-b border-ink-750">
                  {['Objet', 'Source', 'Emplacement', 'Dernière sauvegarde', 'Âge', 'Versions', 'Taille', 'État'].map(
                    (header) => (
                      <th key={header} className="metric-label px-3 py-2 font-semibold">
                        {header}
                      </th>
                    ),
                  )}
                </tr>
              </thead>
              <tbody>
                {filtered.map((item: any, index: number) => {
                  const meta = FRESHNESS[item.freshness] ?? FRESHNESS.unknown
                  return (
                    <tr key={index} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
                      <td className="px-3 py-2.5">
                        <div className="flex items-center gap-2">
                          <StatusDot
                            status={
                              item.freshness === 'fresh'
                                ? 'online'
                                : item.freshness === 'stale'
                                  ? 'warning'
                                  : 'offline'
                            }
                            size={6}
                          />
                          <span className="text-mist-100 truncate">{item.name}</span>
                        </div>
                      </td>
                      <td className="px-3 py-2.5">
                        <Badge tone={item.source === 'pbs' ? 'violet' : 'info'}>
                          {SOURCE_LABEL[item.source] ?? item.source}
                        </Badge>
                      </td>
                      <td className="px-3 py-2.5 text-xs text-ink-500 font-mono truncate max-w-[180px]">
                        {item.store ?? item.source_host}
                      </td>
                      <td className="px-3 py-2.5 text-xs text-mist-400">{datetime(item.last_backup)}</td>
                      <td className="px-3 py-2.5">
                        <span
                          className="metric-value text-xs"
                          style={{ color: severity(item.age_hours ?? 0, 36, 168).color }}
                        >
                          {item.age_hours != null ? duration(item.age_hours * 3600) : '—'}
                        </span>
                      </td>
                      <td className="px-3 py-2.5 text-xs text-mist-400">{item.count ?? '—'}</td>
                      <td className="px-3 py-2.5 metric-value text-xs">{bytes(item.size)}</td>
                      <td className="px-3 py-2.5">
                        <Badge tone={meta.tone}>{meta.label}</Badge>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
            {filtered.length === 0 && (
              <Empty
                icon={<Archive size={32} />}
                title="Aucune sauvegarde recensée"
                hint="Vérifie que le jeton PBS a le droit de lecture sur les datastores."
              />
            )}
          </div>
        </>
      )}

      {tab === 'gaps' && (
        <div className="panel divide-y divide-ink-800/60">
          {(data?.gaps ?? []).length === 0 && (
            <Empty
              icon={<CheckCircle2 size={34} />}
              title="Aucun écart détecté"
              hint="Chaque VM, conteneur et machine connus apparaît dans au moins une sauvegarde."
            />
          )}
          {(data?.gaps ?? []).map((gap: any, index: number) => (
            <div key={index} className="flex items-start gap-3 px-4 py-3 hover:bg-ink-800/30">
              <ShieldOff
                size={16}
                className={clsx('mt-0.5 shrink-0', gap.severity === 'high' ? 'text-danger' : 'text-warn')}
              />
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-100">{gap.name}</div>
                <div className="text-[12px] text-mist-400 mt-0.5">{gap.detail}</div>
              </div>
              <Badge tone={gap.severity === 'high' ? 'danger' : 'warn'}>
                {gap.kind === 'guest' ? 'VM / LXC' : 'Machine'}
              </Badge>
              {gap.host_id && (
                <Link to={`/hosts/${gap.host_id}`} className="btn-ghost py-1 px-2 text-xs">
                  Voir
                </Link>
              )}
            </div>
          ))}
        </div>
      )}

      {tab === 'risks' && (
        <div className="panel divide-y divide-ink-800/60">
          {(data?.risks ?? []).length === 0 && (
            <Empty
              icon={<CheckCircle2 size={34} />}
              title="Aucun risque identifié"
              hint="Sauvegardes fraîches, stockages sains, tâches réussies."
            />
          )}
          {(data?.risks ?? []).map((risk: any, index: number) => (
            <div key={index} className="flex items-start gap-3 px-4 py-3 hover:bg-ink-800/30">
              <Badge tone={SEVERITY_TONE[risk.severity] ?? 'neutral'} className="mt-0.5 shrink-0">
                {risk.severity}
              </Badge>
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-100">{risk.title}</div>
                {risk.detail && <div className="text-[12px] text-mist-400 mt-0.5">{risk.detail}</div>}
                {risk.remediation && (
                  <div className="text-[12px] text-accent/85 mt-1 flex items-start gap-1.5">
                    <Wrench size={12} className="mt-0.5 shrink-0" />
                    <span>{risk.remediation}</span>
                  </div>
                )}
              </div>
              <Badge>{SOURCE_LABEL[risk.source] ?? risk.source}</Badge>
            </div>
          ))}
        </div>
      )}

      {tab === 'stores' && (
        <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(300px,1fr))]">
          {(data?.datastores ?? []).length === 0 && (
            <div className="panel col-span-full">
              <Empty
                icon={<Database size={34} />}
                title="Aucun datastore"
                hint="Les datastores proviennent du Proxmox Backup Server."
              />
            </div>
          )}
          {(data?.datastores ?? []).map((store: any, index: number) => (
            <div key={index} className="panel p-4 space-y-2.5">
              <div className="flex items-center gap-2">
                <HardDriveDownload size={15} className="text-violet" />
                <span className="text-sm font-medium text-mist-100 flex-1 truncate">{store.name}</span>
                <Badge>{store.source_host}</Badge>
              </div>
              <div className="flex items-baseline justify-between">
                <span className="text-[12px] text-ink-500">
                  {bytes(store.used)} / {bytes(store.total)}
                </span>
                <span className="metric-value text-sm" style={{ color: severity(store.percent, 80, 92).color }}>
                  {percent(store.percent, 1)}
                </span>
              </div>
              <Bar value={store.percent} height={6} warn={80} crit={92} />
              <div className="flex justify-between text-[11px] text-ink-600">
                <span>{bytes(store.available)} libres</span>
                {store.estimated_full && <span>saturation : {datetime(store.estimated_full)}</span>}
              </div>
            </div>
          ))}
        </div>
      )}

      {tab === 'tasks' && (
        <div className="panel divide-y divide-ink-800/60">
          {(data?.tasks ?? []).length === 0 && (
            <Empty icon={<Archive size={32} />} title="Aucune tâche récente" />
          )}
          {(data?.tasks ?? []).map((task: any, index: number) => {
            const ok = task.status === 'OK' || task.status === 'running'
            return (
              <div key={index} className="flex items-center gap-3 px-4 py-2.5">
                <StatusDot status={ok ? 'online' : 'offline'} size={6} />
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-200 truncate">
                    {task.target || task.type}
                    {task.schedule && <span className="text-ink-600 text-[11px] ml-2">{task.schedule}</span>}
                  </div>
                  <div className="text-[10px] text-ink-600">
                    {task.source_host} · {datetime(task.started)}
                    {task.next && ` · prochaine ${datetime(task.next)}`}
                  </div>
                </div>
                <Badge tone={ok ? 'ok' : 'danger'}>{task.status}</Badge>
              </div>
            )
          })}
        </div>
      )}

      <SourcePicker
        open={sourcePicker}
        onClose={() => setSourcePicker(false)}
        onPick={(kind) => {
          setSourcePicker(false)
          setAddKind(kind)
        }}
      />
      <AddHostModal
        open={!!addKind}
        onClose={() => setAddKind(null)}
        kind={addKind ?? 'pbs'}
        title={
          addKind === 'synology'
            ? 'Ajouter un NAS Synology'
            : addKind === 'proxmox'
              ? 'Ajouter un hyperviseur Proxmox'
              : 'Ajouter un Proxmox Backup Server'
        }
      />
    </Page>
  )
}
