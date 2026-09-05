import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  ArrowUpCircle,
  Boxes,
  CheckCircle2,
  Download,
  HardDrive,
  Layers,
  PackageCheck,
  RefreshCw,
  RotateCcw,
  Server,
  ShieldAlert,
  Tag,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Empty,
  Spinner,
  StatTile,
  StatusDot,
  TagFilter,
  TagList,
  useConfirm,
  useLocalState,
  useToast,
} from '@/components/ui'
import { get, post } from '@/lib/api'
import { ago, KIND_LABEL } from '@/lib/format'

type Family = 'hosts' | 'stacks' | 'synology'

const stackKey = (stack: any) => `${stack.host_id}:${stack.project}`

export function UpdatesPage() {
  const [family, setFamily] = useLocalState<Family>('mba.updFamily', 'hosts')
  const [tagFilter, setTagFilter] = useLocalState<string[]>('mba.updTags', [])
  const [pickedHosts, setPickedHosts] = useState<number[]>([])
  const [pickedStacks, setPickedStacks] = useState<string[]>([])
  const [busy, setBusy] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading, isFetching, refetch } = useQuery({
    queryKey: ['updates'],
    queryFn: () => get('/updates'),
    refetchInterval: 60000,
  })

  // Le journal se rafraîchit vite : c'est lui qui donne l'impression de progrès
  // pendant qu'un lot tourne en fond.
  const { data: activity } = useQuery({
    queryKey: ['updates-activity'],
    queryFn: () => get('/updates/activity'),
    refetchInterval: 5000,
  })

  const summary = data?.summary ?? {}
  const hosts: any[] = data?.hosts ?? []
  const stacks: any[] = data?.stacks ?? []
  const synology: any[] = data?.synology ?? []

  const tags = useMemo(() => {
    const counts = new Map<string, number>()
    for (const entry of [...hosts, ...stacks, ...synology])
      for (const tag of entry.tags ?? []) counts.set(tag, (counts.get(tag) ?? 0) + 1)
    return [...counts.entries()]
      .map(([tag, count]) => ({ tag, count }))
      .sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag))
  }, [hosts, stacks, synology])

  const keep = (entry: any) =>
    !tagFilter.length || tagFilter.some((tag) => (entry.tags ?? []).includes(tag))

  // Le retard le plus lourd en tête : correctifs de sécurité, puis volume.
  const visibleHosts = hosts
    .filter(keep)
    .sort(
      (a, b) =>
        b.security_updates - a.security_updates ||
        b.updates - a.updates ||
        Number(b.reboot_required) - Number(a.reboot_required) ||
        a.name.localeCompare(b.name),
    )
  const visibleStacks = stacks.filter(keep).sort((a, b) => b.floating - a.floating || a.project.localeCompare(b.project))
  const visibleNas = synology.filter(keep)

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['updates-activity'] })
    return refetch()
  }

  /** Force un nouvel interrogatoire des NAS, dont l'état est mis en cache. */
  const hardRefresh = async () => {
    setBusy('refresh')
    try {
      const fresh = await get('/updates?refresh=1')
      queryClient.setQueryData(['updates'], fresh)
      toast('État des mises à jour actualisé', 'ok')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const toggleHost = (id: number) =>
    setPickedHosts((current) =>
      current.includes(id) ? current.filter((h) => h !== id) : [...current, id],
    )
  const toggleStack = (key: string) =>
    setPickedStacks((current) =>
      current.includes(key) ? current.filter((s) => s !== key) : [...current, key],
    )

  const selectableHosts = visibleHosts.filter((host) => host.upgradable && host.status !== 'offline')
  const pickedHostRows = hosts.filter((host) => pickedHosts.includes(host.id))

  const runHosts = async (action: 'upgrade' | 'reboot') => {
    const rows = pickedHostRows
    const ok = await confirm({
      title: action === 'upgrade' ? 'Mettre à jour ces machines ?' : 'Redémarrer ces machines ?',
      message: (
        <>
          {rows.length} machine(s) : <b className="text-mist-100">{rows.map((h) => h.name).join(', ')}</b>.
          <span className="block mt-2 text-ink-500">
            {action === 'upgrade'
              ? 'MBA applique les correctifs deux machines à la fois et journalise chaque sortie.'
              : 'Les services hébergés seront interrompus le temps du redémarrage.'}
          </span>
        </>
      ),
      confirmLabel: action === 'upgrade' ? 'Mettre à jour' : 'Redémarrer',
      danger: action === 'reboot',
    })
    if (!ok) return
    setBusy('hosts')
    try {
      const result = await post('/updates/hosts', { host_ids: rows.map((h) => h.id), action })
      toast(
        `${result.started.length} machine(s) lancée(s)` +
          (result.skipped.length ? `, ${result.skipped.length} ignorée(s)` : ''),
        result.skipped.length ? 'warn' : 'ok',
      )
      setPickedHosts([])
      refresh()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const runStacks = async () => {
    const targets = stacks.filter((stack) => pickedStacks.includes(stackKey(stack)))
    const ok = await confirm({
      title: 'Mettre à jour ces piles ?',
      message: (
        <>
          {targets.length} pile(s) : <b className="text-mist-100">{targets.map((s) => s.project).join(', ')}</b>.
          <span className="block mt-2 text-warn">
            <b>compose pull</b> puis <b>up -d</b> : les conteneurs sont recréés, une courte interruption
            est attendue sur chaque pile.
          </span>
        </>
      ),
      confirmLabel: 'Mettre à jour',
      danger: true,
    })
    if (!ok) return
    setBusy('stacks')
    try {
      const result = await post('/updates/stacks', {
        targets: targets.map((s) => ({ host_id: s.host_id, project: s.project })),
      })
      toast(`${result.started.length} pile(s) en cours de mise à jour`, 'ok')
      setPickedStacks([])
      refresh()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const pending = activity?.running ?? 0

  return (
    <Page>
      <PageHeader
        title="Mises à jour"
        subtitle={
          isLoading
            ? 'Relevé en cours…'
            : `${summary.packages ?? 0} paquet(s) en attente sur ${summary.hosts_pending ?? 0} machine(s)` +
              (summary.syno_packages ? ` · ${summary.syno_packages} paquet(s) Synology` : '') +
              (summary.dsm_pending ? ` · ${summary.dsm_pending} DSM` : '')
        }
        actions={
          <>
            {pending > 0 && (
              <span className="flex items-center gap-2 text-xs text-accent">
                <Spinner size={13} />
                {pending} en cours
              </span>
            )}
            <button className="btn-ghost" onClick={hardRefresh} disabled={busy === 'refresh'}>
              {busy === 'refresh' || isFetching ? <Spinner size={14} /> : <RefreshCw size={15} />}
              Actualiser
            </button>
          </>
        }
      />

      <div className="grid gap-3 grid-cols-2 md:grid-cols-3 xl:grid-cols-6 mb-4">
        <StatTile
          label="Paquets en attente"
          value={summary.packages ?? 0}
          icon={<PackageCheck size={18} />}
          tone={summary.packages ? 'warn' : 'ok'}
          sub={`${summary.hosts_pending ?? 0} machine(s)`}
        />
        <StatTile
          label="Correctifs sécurité"
          value={summary.security ?? 0}
          icon={<ShieldAlert size={18} />}
          tone={summary.security ? 'danger' : 'ok'}
          sub={summary.security ? 'à traiter en priorité' : 'rien en attente'}
        />
        <StatTile
          label="Redémarrages requis"
          value={summary.reboot_required ?? 0}
          icon={<RotateCcw size={17} />}
          tone={summary.reboot_required ? 'warn' : 'neutral'}
          sub="noyau ou paquet critique"
        />
        <StatTile
          label="Piles Docker"
          value={summary.stacks ?? 0}
          icon={<Layers size={18} />}
          tone="info"
          sub={`${summary.floating_images ?? 0} image(s) :latest`}
        />
        <StatTile
          label="Paquets Synology"
          value={summary.syno_packages ?? 0}
          icon={<HardDrive size={18} />}
          tone={summary.syno_packages ? 'warn' : 'neutral'}
          sub={summary.dsm_pending ? `${summary.dsm_pending} mise(s) à jour DSM` : 'DSM à jour'}
        />
        <StatTile
          label="Mise à jour auto"
          value={`${summary.auto_updates ?? 0}/${summary.hosts ?? 0}`}
          icon={<CheckCircle2 size={18} />}
          tone="neutral"
          sub="machines en unattended-upgrades"
        />
      </div>

      <div className="flex flex-wrap items-center gap-3 mb-4">
        <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
          {(
            [
              ['hosts', 'Machines', Server, visibleHosts.length],
              ['stacks', 'Piles Docker', Boxes, visibleStacks.length],
              ['synology', 'Synology', HardDrive, visibleNas.length],
            ] as const
          ).map(([value, label, Icon, count]) => (
            <button
              key={value}
              onClick={() => setFamily(value)}
              className={clsx(
                'px-2.5 py-1 rounded-md text-xs font-medium transition-colors flex items-center gap-1.5',
                family === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
              )}
            >
              <Icon size={13} />
              {label}
              <span className="text-ink-500">{count}</span>
            </button>
          ))}
        </div>
        <TagFilter tags={tags} selected={tagFilter} onChange={setTagFilter} />
      </div>

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && family === 'hosts' && (
        <HostsTable
          hosts={visibleHosts}
          selectable={selectableHosts}
          picked={pickedHosts}
          onToggle={toggleHost}
          onPickMany={setPickedHosts}
          onPickTag={(tag) => setTagFilter([tag])}
          busy={busy === 'hosts'}
          onRun={runHosts}
        />
      )}

      {!isLoading && family === 'stacks' && (
        <StacksTable
          stacks={visibleStacks}
          picked={pickedStacks}
          onToggle={toggleStack}
          onPickMany={setPickedStacks}
          onPickTag={(tag) => setTagFilter([tag])}
          busy={busy === 'stacks'}
          onRun={runStacks}
        />
      )}

      {!isLoading && family === 'synology' && <SynologyPanel nas={visibleNas} onDone={refresh} />}

      <ActivityPanel entries={activity?.entries ?? []} />
    </Page>
  )
}

// ------------------------------------------------------------------ machines
function HostsTable({
  hosts,
  selectable,
  picked,
  onToggle,
  onPickMany,
  onPickTag,
  busy,
  onRun,
}: {
  hosts: any[]
  selectable: any[]
  picked: number[]
  onToggle: (id: number) => void
  onPickMany: (ids: number[]) => void
  onPickTag: (tag: string) => void
  busy: boolean
  onRun: (action: 'upgrade' | 'reboot') => void
}) {
  if (hosts.length === 0) {
    return (
      <div className="panel">
        <Empty
          icon={<CheckCircle2 size={36} />}
          title="Aucune machine à mettre à jour"
          hint="Les compteurs de paquets sont relevés toutes les cinq minutes sur les hôtes Linux joignables en SSH."
        />
      </div>
    )
  }

  const late = selectable.filter((host) => host.updates > 0)
  const risky = selectable.filter((host) => host.security_updates > 0)
  const allPicked = picked.length > 0 && picked.length === selectable.length

  return (
    <div className="space-y-3">
      {/* Sélection par lot : ce sont les trois découpes qu'on veut vraiment. */}
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-[11px] text-ink-500 uppercase tracking-wide">Sélectionner</span>
        <button
          className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-accent transition-colors"
          onClick={() => onPickMany(allPicked ? [] : selectable.map((h) => h.id))}
        >
          {allPicked ? 'Rien' : `Tout (${selectable.length})`}
        </button>
        <button
          className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-accent transition-colors"
          onClick={() => onPickMany(late.map((h) => h.id))}
          disabled={late.length === 0}
        >
          En retard ({late.length})
        </button>
        <button
          className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-danger transition-colors"
          onClick={() => onPickMany(risky.map((h) => h.id))}
          disabled={risky.length === 0}
        >
          Correctifs sécurité ({risky.length})
        </button>

        <div className="flex items-center gap-2 ml-auto">
          <span className="text-xs text-ink-500">{picked.length} sélectionnée(s)</span>
          <button className="btn-ghost" onClick={() => onRun('reboot')} disabled={busy || picked.length === 0}>
            <RotateCcw size={14} />
            Redémarrer
          </button>
          <button className="btn-primary" onClick={() => onRun('upgrade')} disabled={busy || picked.length === 0}>
            {busy ? <Spinner size={14} /> : <ArrowUpCircle size={15} />}
            Mettre à jour
          </button>
        </div>
      </div>

      <div className="panel overflow-x-auto">
        <table className="w-full text-sm min-w-[820px]">
          <thead>
            <tr className="text-left border-b border-ink-750">
              {['', 'Machine', 'Système', 'Paquets', 'Sécurité', 'Redémarrage', 'Étiquettes', 'Vu'].map(
                (header, index) => (
                  <th key={index} className="metric-label px-3 py-2 font-semibold">
                    {header}
                  </th>
                ),
              )}
            </tr>
          </thead>
          <tbody>
            {hosts.map((host) => {
              const blocked = !host.upgradable || host.status === 'offline'
              return (
                <tr
                  key={host.id}
                  className={clsx(
                    'border-b border-ink-800/60 last:border-0 transition-colors',
                    picked.includes(host.id) ? 'bg-accent/[0.06]' : 'hover:bg-ink-800/40',
                  )}
                >
                  <td className="px-3 py-2 w-8">
                    <input
                      type="checkbox"
                      checked={picked.includes(host.id)}
                      onChange={() => onToggle(host.id)}
                      disabled={blocked}
                      title={
                        blocked
                          ? host.status === 'offline'
                            ? 'Hôte injoignable'
                            : 'Mise à jour non gérée pour ce type'
                          : undefined
                      }
                    />
                  </td>
                  <td className="px-3 py-2">
                    <Link to={`/hosts/${host.id}`} className="flex items-center gap-2 group">
                      <StatusDot status={host.status} />
                      <div className="min-w-0">
                        <div className="text-mist-100 group-hover:text-accent transition-colors truncate">
                          {host.name}
                        </div>
                        <div className="text-[11px] text-ink-500 font-mono">{host.address}</div>
                      </div>
                    </Link>
                  </td>
                  <td className="px-3 py-2">
                    <div className="text-xs text-mist-400 truncate max-w-[200px]">{host.os ?? '—'}</div>
                    <div className="text-[10px] text-ink-600">{KIND_LABEL[host.kind] ?? host.kind}</div>
                  </td>
                  <td className="px-3 py-2">
                    {host.updates ? (
                      <span className="metric-value text-sm text-warn">{host.updates}</span>
                    ) : (
                      <span className="text-ink-600">à jour</span>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    {host.security_updates ? (
                      <Badge tone="danger">{host.security_updates}</Badge>
                    ) : (
                      <span className="text-ink-700">—</span>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    {host.reboot_required ? (
                      <Badge tone="warn" >
                        {host.kernel_stale ? `noyau ${host.kernel_installed}` : 'requis'}
                      </Badge>
                    ) : (
                      <span className="text-ink-700">—</span>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    {(host.tags ?? []).length ? (
                      <TagList tags={host.tags} onPick={onPickTag} max={2} />
                    ) : (
                      <span className="text-ink-700">—</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs text-ink-500 whitespace-nowrap">{ago(host.last_seen)}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}

// -------------------------------------------------------------- piles Docker
function StacksTable({
  stacks,
  picked,
  onToggle,
  onPickMany,
  onPickTag,
  busy,
  onRun,
}: {
  stacks: any[]
  picked: string[]
  onToggle: (key: string) => void
  onPickMany: (keys: string[]) => void
  onPickTag: (tag: string) => void
  busy: boolean
  onRun: () => void
}) {
  if (stacks.length === 0) {
    return (
      <div className="panel">
        <Empty
          icon={<Layers size={36} />}
          title="Aucune pile compose détectée"
          hint="Les piles sont lues dans les labels com.docker.compose.* des conteneurs."
        />
      </div>
    )
  }

  const floating = stacks.filter((stack) => stack.floating > 0)
  const allPicked = picked.length === stacks.length && stacks.length > 0

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-[11px] text-ink-500 uppercase tracking-wide">Sélectionner</span>
        <button
          className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-accent transition-colors"
          onClick={() => onPickMany(allPicked ? [] : stacks.map(stackKey))}
        >
          {allPicked ? 'Rien' : `Tout (${stacks.length})`}
        </button>
        <button
          className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-accent transition-colors"
          onClick={() => onPickMany(floating.map(stackKey))}
          disabled={floating.length === 0}
        >
          Images :latest ({floating.length})
        </button>
        <div className="flex items-center gap-2 ml-auto">
          <span className="text-xs text-ink-500">{picked.length} sélectionnée(s)</span>
          <button className="btn-primary" onClick={onRun} disabled={busy || picked.length === 0}>
            {busy ? <Spinner size={14} /> : <ArrowUpCircle size={15} />}
            compose pull && up -d
          </button>
        </div>
      </div>

      <div className="panel overflow-x-auto">
        <table className="w-full text-sm min-w-[720px]">
          <thead>
            <tr className="text-left border-b border-ink-750">
              {['', 'Pile', 'Hôte', 'Conteneurs', 'Images flottantes', 'Étiquettes', ''].map((header, index) => (
                <th key={index} className="metric-label px-3 py-2 font-semibold">
                  {header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {stacks.map((stack) => {
              const key = stackKey(stack)
              return (
                <tr
                  key={key}
                  className={clsx(
                    'border-b border-ink-800/60 last:border-0 transition-colors',
                    picked.includes(key) ? 'bg-accent/[0.06]' : 'hover:bg-ink-800/40',
                  )}
                >
                  <td className="px-3 py-2 w-8">
                    <input type="checkbox" checked={picked.includes(key)} onChange={() => onToggle(key)} />
                  </td>
                  <td className="px-3 py-2">
                    <div className="flex items-center gap-2">
                      <Layers size={14} className="text-accent shrink-0" />
                      <span className="text-mist-100">{stack.project}</span>
                    </div>
                  </td>
                  <td className="px-3 py-2 text-xs text-mist-400">{stack.host_name}</td>
                  <td className="px-3 py-2">
                    <span className={clsx('metric-value text-xs', stack.running < stack.total && 'text-warn')}>
                      {stack.running}/{stack.total}
                    </span>
                  </td>
                  <td className="px-3 py-2">
                    {stack.floating ? (
                      <Badge tone="warn">{stack.floating} × latest</Badge>
                    ) : (
                      <span className="text-ink-700">—</span>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    {(stack.tags ?? []).length ? (
                      <TagList tags={stack.tags} onPick={onPickTag} max={2} />
                    ) : (
                      <span className="text-ink-700">—</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <Link
                      to={`/containers?q=${encodeURIComponent(stack.project)}`}
                      className="text-xs text-ink-500 hover:text-accent"
                    >
                      Voir
                    </Link>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}

// ------------------------------------------------------------------ Synology
function SynologyPanel({ nas, onDone }: { nas: any[]; onDone: () => void }) {
  const [busy, setBusy] = useState<string | null>(null)
  const confirm = useConfirm()
  const toast = useToast()

  if (nas.length === 0) {
    return (
      <div className="panel">
        <Empty icon={<HardDrive size={36} />} title="Aucun NAS Synology enregistré" />
      </div>
    )
  }

  const upgradePackages = async (entry: any) => {
    const ok = await confirm({
      title: 'Mettre à jour tous les paquets ?',
      message: (
        <>
          {entry.packages.length} paquet(s) sur <b className="text-mist-100">{entry.name}</b> :{' '}
          {entry.packages.map((p: any) => p.name).join(', ')}.
          <span className="block mt-2 text-warn">
            DSM interrompt chaque paquet le temps de son installation.
          </span>
        </>
      ),
      confirmLabel: 'Tout mettre à jour',
    })
    if (!ok) return
    setBusy(`${entry.host_id}-pkg`)
    try {
      const result = await post(`/synology/${entry.host_id}/packages/upgrade-all`, {})
      toast(
        result.detail ??
          `${result.done.length} paquet(s) lancé(s)` +
            (result.errors.length ? `, ${result.errors.length} en échec` : ''),
        result.errors.length ? 'warn' : 'ok',
      )
      onDone()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const dsmStep = async (entry: any, step: 'download' | 'install') => {
    if (step === 'install') {
      const ok = await confirm({
        title: 'Installer la mise à jour DSM ?',
        message: (
          <>
            <b className="text-mist-100">{entry.name}</b> installera{' '}
            <code className="font-mono text-accent">{entry.dsm?.version}</code> puis redémarrera. Tous les
            partages et paquets seront interrompus plusieurs minutes.
          </>
        ),
        confirmLabel: 'Installer et redémarrer',
        danger: true,
      })
      if (!ok) return
    }
    setBusy(`${entry.host_id}-${step}`)
    try {
      await post(`/synology/${entry.host_id}/dsm-update/${step}`)
      toast(step === 'download' ? 'Téléchargement lancé' : 'Installation lancée — le NAS va redémarrer', 'ok')
      onDone()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(340px,1fr))]">
      {nas.map((entry) => {
        const dsm = entry.dsm ?? {}
        return (
          <div key={entry.host_id} className="panel p-4 space-y-3">
            <div className="flex items-center gap-2">
              <HardDrive size={16} className="text-warn shrink-0" />
              <Link to="/synology" className="text-sm font-medium text-mist-100 hover:text-accent">
                {entry.name}
              </Link>
              {dsm.current && <span className="text-[11px] text-ink-500 font-mono ml-auto">{dsm.current}</span>}
            </div>

            {entry.error && <p className="text-[12px] text-danger">{entry.error}</p>}
            {entry.reason && !entry.error && <p className="text-[12px] text-ink-500">{entry.reason}</p>}

            <div className="flex items-center gap-2">
              <ArrowUpCircle size={15} className={entry.packages.length ? 'text-accent' : 'text-ink-600'} />
              <span className="text-[13px] text-mist-300 flex-1">
                {entry.packages.length
                  ? `${entry.packages.length} paquet(s) à mettre à jour`
                  : 'Paquets à jour'}
              </span>
              {entry.packages.length > 0 && (
                <button
                  className="btn-ghost py-1 px-2 text-xs"
                  onClick={() => upgradePackages(entry)}
                  disabled={busy === `${entry.host_id}-pkg`}
                >
                  {busy === `${entry.host_id}-pkg` ? <Spinner size={12} /> : <ArrowUpCircle size={13} />}
                  Tout mettre à jour
                </button>
              )}
            </div>
            {entry.packages.length > 0 && (
              <div className="text-[11px] text-ink-500 font-mono leading-relaxed">
                {entry.packages.map((p: any) => `${p.name} ${p.installed_version ?? ''} → ${p.version}`).join(' · ')}
              </div>
            )}

            <div className="pt-2 border-t border-ink-800 flex items-center gap-2">
              <Server size={15} className={dsm.available ? 'text-warn' : 'text-ink-600'} />
              <span className="text-[13px] text-mist-300 flex-1">
                {dsm.available ? `DSM ${dsm.version} disponible` : 'DSM à jour'}
              </span>
              {dsm.available && dsm.can_download && !dsm.download?.finished && (
                <button
                  className="btn-ghost py-1 px-2 text-xs"
                  onClick={() => dsmStep(entry, 'download')}
                  disabled={busy === `${entry.host_id}-download`}
                >
                  {busy === `${entry.host_id}-download` ? <Spinner size={12} /> : <Download size={13} />}
                  Télécharger
                </button>
              )}
              {dsm.available && dsm.can_install && (
                <button
                  className="btn-ghost py-1 px-2 text-xs hover:text-danger"
                  onClick={() => dsmStep(entry, 'install')}
                  disabled={busy === `${entry.host_id}-install`}
                >
                  {busy === `${entry.host_id}-install` ? <Spinner size={12} /> : <ArrowUpCircle size={13} />}
                  Installer
                </button>
              )}
            </div>

            {(entry.tags ?? []).length > 0 && (
              <div className="flex items-center gap-1.5">
                <Tag size={11} className="text-ink-600" />
                <TagList tags={entry.tags} max={4} />
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

// ------------------------------------------------------------------ activité
const ACTION_LABEL: Record<string, string> = {
  upgrade: 'Mise à jour des paquets',
  reboot: 'Redémarrage',
  'compose update': 'Mise à jour de pile',
  'docker pull': 'Récupération d’image',
}

function ActivityPanel({ entries }: { entries: any[] }) {
  if (entries.length === 0) return null
  return (
    <div className="panel p-4 mt-4">
      <SectionTitle right={<Link to="/events" className="text-xs text-ink-500 hover:text-accent">Journal complet</Link>}>
        Activité récente
      </SectionTitle>
      <div className="space-y-0.5 max-h-72 overflow-y-auto">
        {entries.map((entry) => (
          <div key={entry.id} className="flex items-center gap-2.5 py-1.5 border-b border-ink-800/60 last:border-0">
            {entry.status === 'running' ? (
              <Spinner size={12} />
            ) : (
              <StatusDot status={entry.status === 'success' ? 'running' : 'exited'} size={6} />
            )}
            <span className="text-[13px] text-mist-200 truncate">
              {ACTION_LABEL[entry.action] ?? entry.action}
            </span>
            <span className="text-[12px] text-ink-500 truncate">
              {entry.host_name}
              {entry.target ? ` · ${entry.target}` : ''}
            </span>
            <span className="text-[11px] text-ink-600 ml-auto whitespace-nowrap">{ago(entry.started_at)}</span>
            <Badge tone={entry.status === 'success' ? 'ok' : entry.status === 'running' ? 'info' : 'danger'}>
              {entry.status}
            </Badge>
          </div>
        ))}
      </div>
    </div>
  )
}
