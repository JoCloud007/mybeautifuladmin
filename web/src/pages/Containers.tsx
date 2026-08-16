import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Boxes,
  ChevronDown,
  Cpu,
  Eraser,
  ExternalLink,
  Layers,
  LayoutGrid,
  MemoryStick,
  Network,
  Play,
  RefreshCw,
  RotateCcw,
  Rows3,
  ArrowUpCircle,
  ScrollText,
  Search,
  Server,
  Square,
  TerminalSquare,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Page, PageHeader } from '@/components/PageHeader'
import {
  Badge,
  Bar,
  Empty,
  Modal,
  Spinner,
  StatusDot,
  useConfirm,
  useLocalState,
  useToast,
} from '@/components/ui'
import { get, post } from '@/lib/api'
import { bytes, num } from '@/lib/format'

type GroupBy = 'host' | 'project' | 'none'
type ViewMode = 'expanded' | 'summary'

interface Group {
  key: string
  label: string
  sub?: string
  items: any[]
  host?: { id: number; name: string; kind: string }
  /** Renseigné uniquement pour un vrai projet compose : porte les actions de pile. */
  project?: string
  stats?: GroupStats
}

interface GroupStats {
  total: number
  running: number
  cpu: number
  mem: number
  ports: number
  images: number
}

/** Somme des ressources d'un groupe — base de la vue synthétique. */
function aggregate(items: any[]): GroupStats {
  const running = items.filter((c) => c.state === 'running')
  return {
    total: items.length,
    running: running.length,
    cpu: running.reduce((sum, c) => sum + ((c.stats ?? {}).cpu ?? 0), 0),
    mem: running.reduce((sum, c) => sum + ((c.stats ?? {}).mem ?? 0), 0),
    ports: items.reduce((sum, c) => sum + (c.ports ?? []).length, 0),
    images: new Set(items.map((c) => c.image).filter(Boolean)).size,
  }
}

export function ContainersPage() {
  const [params] = useSearchParams()
  const [query, setQuery] = useState(params.get('q') ?? '')
  const [onlyRunning, setOnlyRunning] = useState(false)
  const [groupBy, setGroupBy] = useLocalState<GroupBy>('mba.ctGroup', 'project')
  const [view, setView] = useLocalState<ViewMode>('mba.ctView', 'expanded')
  // On mémorise les groupes *dépliés*, et non les repliés : avec des dizaines
  // de piles, arriver sur une page toute dépliée n'aide personne. Par défaut
  // on voit donc la liste des piles, et on ouvre celle qui intéresse.
  const [expanded, setExpanded] = useLocalState<string[]>('mba.ctExpanded', [])
  const [logs, setLogs] = useState<{ name: string; text: string } | null>(null)
  const [pruneHost, setPruneHost] = useState<any | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const toast = useToast()
  const confirm = useConfirm()

  const { data: containers = [], isLoading } = useQuery({
    queryKey: ['containers'],
    queryFn: () => get('/containers'),
    refetchInterval: 8000,
  })
  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts') })

  const dockerHosts = hosts.filter(
    (host: any) => host.kind === 'docker' || host.meta?.has_docker || containers.some((c: any) => c.host_id === host.id),
  )

  const filtered = containers.filter((container: any) => {
    if (onlyRunning && container.state !== 'running') return false
    const needle = query.trim().toLowerCase()
    if (!needle) return true
    return `${container.name} ${container.image} ${container.host_name} ${container.project ?? ''}`
      .toLowerCase()
      .includes(needle)
  })

  // Regroupement : par hôte, par pile compose, ou pas du tout.
  const groups = useMemo<Group[]>(() => {
    if (groupBy === 'none') return [{ key: 'all', label: 'Tous les conteneurs', items: filtered }]
    const map = new Map<string, Group>()
    for (const container of filtered) {
      const key =
        groupBy === 'host'
          ? `h${container.host_id}`
          : `${container.host_id}:${container.project ?? '~'}`
      const entry: Group = map.get(key) ?? {
        key,
        label:
          groupBy === 'host'
            ? container.host_name
            : (container.project ?? 'Hors compose'),
        sub: groupBy === 'project' ? container.host_name : undefined,
        items: [],
        host: { id: container.host_id, name: container.host_name, kind: container.host_kind },
        project: groupBy === 'project' ? container.project : undefined,
      }
      entry.items.push(container)
      map.set(key, entry)
    }
    return [...map.values()]
      .map((group) => ({ ...group, stats: aggregate(group.items) }))
      .sort((a, b) => {
        // Les conteneurs hors compose passent en dernier.
        if (!a.project && b.project) return 1
        if (a.project && !b.project) return -1
        return a.label.localeCompare(b.label)
      })
  }, [filtered, groupBy])

  const toggleCollapse = (key: string) =>
    setExpanded(expanded.includes(key) ? expanded.filter((k) => k !== key) : [...expanded, key])

  const allCollapsed = groups.length > 0 && expanded.length === 0
  const toggleAll = () => setExpanded(allCollapsed ? groups.map((g) => g.key) : [])

  const act = async (container: any, action: string) => {
    if (action === 'stop' || action === 'restart') {
      const ok = await confirm({
        title: action === 'stop' ? 'Arrêter le conteneur ?' : 'Redémarrer le conteneur ?',
        message: (
          <>
            <b className="text-mist-100">{container.name}</b> sur {container.host_name}.
          </>
        ),
        confirmLabel: action === 'stop' ? 'Arrêter' : 'Redémarrer',
        danger: action === 'stop',
      })
      if (!ok) return
    }
    setBusy(`${container.id}-${action}`)
    try {
      if (container.host_kind === 'proxmox') {
        const [kind, vmid] = String(container.ext_id).split('/')
        const pveAction = action === 'restart' ? 'reboot' : action === 'stop' ? 'shutdown' : 'start'
        await post(`/hosts/${container.host_id}/guest`, { vmid: Number(vmid), kind, action: pveAction })
      } else {
        await post(`/hosts/${container.host_id}/containers/${container.ext_id}/${action}`)
      }
      toast(`${container.name} : ${action} envoyé`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['containers'] }), 1500)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const projectAction = async (group: any, action: 'start' | 'stop' | 'restart') => {
    const label = { start: 'Démarrer', stop: 'Arrêter', restart: 'Redémarrer' }[action]
    const ok = await confirm({
      title: `${label} la pile « ${group.label} » ?`,
      message: (
        <>
          {group.items.length} conteneur(s) sur <b className="text-mist-100">{group.host.name}</b> seront
          affectés.
        </>
      ),
      confirmLabel: label,
      danger: action === 'stop',
    })
    if (!ok) return
    setBusy(`${group.key}-${action}`)
    try {
      const result = await post(
        `/hosts/${group.host.id}/projects/${encodeURIComponent(group.project ?? '')}/${action}`,
      )
      toast(
        `${group.label} : ${result.done.length} conteneur(s) traité(s)` +
          (result.errors.length ? `, ${result.errors.length} en erreur` : ''),
        result.errors.length ? 'warn' : 'ok',
      )
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['containers'] }), 1800)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const pull = async (container: any) => {
    setBusy(`${container.id}-pull`)
    try {
      const result = await post(`/hosts/${container.host_id}/containers/${container.ext_id}/pull`)
      toast(
        result.updated
          ? `${container.name} : nouvelle image récupérée${
              container.project ? ' — recrée la pile pour l’appliquer' : ' — recrée le conteneur pour l’appliquer'
            }`
          : `${container.name} : déjà à jour`,
        result.updated ? 'ok' : 'info',
      )
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const updateStack = async (group: any) => {
    const ok = await confirm({
      title: `Mettre à jour la pile « ${group.label} » ?`,
      message: (
        <>
          MBA va exécuter <b className="text-mist-100">docker compose pull</b> puis{' '}
          <b className="text-mist-100">up -d</b> sur {group.host.name}.
          <span className="block mt-2 text-warn">
            Les conteneurs de la pile seront recréés : une courte interruption est attendue.
          </span>
        </>
      ),
      confirmLabel: 'Mettre à jour',
      danger: true,
    })
    if (!ok) return
    setBusy(`${group.key}-update`)
    try {
      const result = await post(
        `/hosts/${group.host.id}/projects/${encodeURIComponent(group.project ?? '')}/update`,
      )
      toast(
        result.updated ? `${group.label} : pile mise à jour` : `${group.label} : déjà à jour`,
        'ok',
      )
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['containers'] }), 3000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const showLogs = async (container: any) => {
    setBusy(`${container.id}-logs`)
    try {
      const result = await get(`/hosts/${container.host_id}/containers/${container.ext_id}/logs?lines=500`)
      setLogs({ name: container.name, text: result.logs })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const running = containers.filter((c: any) => c.state === 'running').length
  const projects = new Set(containers.filter((c: any) => c.project).map((c: any) => c.project)).size

  return (
    <Page>
      <PageHeader
        title="Conteneurs"
        subtitle={`${running} actif(s) sur ${containers.length}${projects ? ` · ${projects} pile(s) compose` : ''}`}
        actions={
          <>
            <label className="flex items-center gap-2 text-xs text-mist-400 normal-case tracking-normal font-normal cursor-pointer">
              <input type="checkbox" checked={onlyRunning} onChange={(e) => setOnlyRunning(e.target.checked)} />
              Actifs seulement
            </label>
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {(
                [
                  ['project', 'Par pile'],
                  ['host', 'Par hôte'],
                  ['none', 'À plat'],
                ] as const
              ).map(([value, label]) => (
                <button
                  key={value}
                  onClick={() => setGroupBy(value)}
                  className={clsx(
                    'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                    groupBy === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                >
                  {label}
                </button>
              ))}
            </div>
            {groupBy !== 'none' && (
              <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
                {(
                  [
                    ['expanded', 'Détail', LayoutGrid],
                    ['summary', 'Synthèse', Rows3],
                  ] as const
                ).map(([value, label, Icon]) => (
                  <button
                    key={value}
                    onClick={() => setView(value)}
                    className={clsx(
                      'px-2.5 py-1 rounded-md text-xs font-medium transition-colors flex items-center gap-1.5',
                      view === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                    )}
                    title={value === 'summary' ? 'Une ligne par groupe' : 'Toutes les cartes'}
                  >
                    <Icon size={13} />
                    {label}
                  </button>
                ))}
              </div>
            )}
            {groupBy !== 'none' && view === 'expanded' && (
              <button className="btn-ghost" onClick={toggleAll}>
                <ChevronDown size={14} className={clsx('transition-transform', allCollapsed && '-rotate-90')} />
                {allCollapsed ? 'Tout déplier' : 'Tout replier'}
              </button>
            )}
            <div className="relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
              <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Filtrer…" className="pl-8 py-1.5 w-44" />
            </div>
            {dockerHosts.length > 0 && (
              <button className="btn-ghost" onClick={() => setPruneHost(dockerHosts[0])}>
                <Eraser size={15} />
                Nettoyer
              </button>
            )}
          </>
        }
      />

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && filtered.length === 0 && (
        <div className="panel">
          <Empty
            icon={<Boxes size={36} />}
            title={query ? 'Aucun résultat' : 'Aucun conteneur détecté'}
            hint="Les conteneurs sont découverts automatiquement sur les hôtes Linux disposant de Docker, et sur les hyperviseurs Proxmox."
          />
        </div>
      )}

      {/* Vue synthétique : une ligne par groupe, sans détail des conteneurs. */}
      {view === 'summary' && groupBy !== 'none' && groups.length > 0 && (
        <div className="panel overflow-x-auto">
          <table className="w-full text-sm min-w-[720px]">
            <thead>
              <tr className="text-left border-b border-ink-750">
                {[
                  groupBy === 'project' ? 'Pile' : 'Hôte',
                  'Conteneurs',
                  'CPU cumulé',
                  'RAM cumulée',
                  'Images',
                  'Ports',
                  '',
                ].map((header) => (
                  <th key={header} className="metric-label px-3 py-2 font-semibold">
                    {header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {groups.map((group) => {
                const stats = group.stats!
                const allUp = stats.running === stats.total
                return (
                  <tr
                    key={group.key}
                    className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40 transition-colors"
                  >
                    <td className="px-3 py-2.5">
                      <button
                        onClick={() => {
                          // Depuis la synthèse, on bascule en détail sur cette
                          // seule pile : les autres restent repliées.
                          setView('expanded')
                          setExpanded([group.key])
                        }}
                        className="flex items-center gap-2 group text-left"
                      >
                        {group.project ? (
                          <Layers size={14} className="text-accent shrink-0" />
                        ) : (
                          <Server size={14} className="text-ink-500 shrink-0" />
                        )}
                        <div className="min-w-0">
                          <div className="text-mist-100 group-hover:text-accent transition-colors truncate">
                            {group.label}
                          </div>
                          {group.sub && <div className="text-[10px] text-ink-600">{group.sub}</div>}
                        </div>
                      </button>
                    </td>
                    <td className="px-3 py-2.5">
                      <div className="flex items-center gap-2">
                        <StatusDot status={allUp ? 'running' : stats.running ? 'warning' : 'exited'} size={6} />
                        <span className="metric-value text-xs">
                          {stats.running}/{stats.total}
                        </span>
                      </div>
                    </td>
                    <td className="px-3 py-2.5 w-32">
                      <div className="flex items-center gap-2">
                        <span className="metric-value text-xs w-12 text-right">
                          {num(stats.cpu, 1)}%
                        </span>
                        <Bar value={Math.min(100, stats.cpu)} height={3} className="flex-1" />
                      </div>
                    </td>
                    <td className="px-3 py-2.5 metric-value text-xs">{bytes(stats.mem)}</td>
                    <td className="px-3 py-2.5 text-xs text-mist-400">{stats.images}</td>
                    <td className="px-3 py-2.5 text-xs text-mist-400">{stats.ports}</td>
                    <td className="px-3 py-2.5">
                      <div className="flex items-center justify-end gap-1">
                        {group.project && group.host?.kind !== 'proxmox' && (
                          <>
                            <button
                              className="btn-icon"
                              onClick={() => updateStack(group)}
                              disabled={busy === `${group.key}-update`}
                              title="Mettre à jour la pile"
                            >
                              {busy === `${group.key}-update` ? (
                                <Spinner size={13} />
                              ) : (
                                <ArrowUpCircle size={14} />
                              )}
                            </button>
                            <button
                              className="btn-icon"
                              onClick={() => projectAction(group, 'restart')}
                              disabled={busy === `${group.key}-restart`}
                              title="Redémarrer la pile"
                            >
                              {busy === `${group.key}-restart` ? (
                                <Spinner size={13} />
                              ) : (
                                <RotateCcw size={14} />
                              )}
                            </button>
                            <button
                              className="btn-icon hover:text-danger"
                              onClick={() => projectAction(group, 'stop')}
                              title="Arrêter la pile"
                            >
                              <Square size={12} />
                            </button>
                          </>
                        )}
                        {group.host?.id && (
                          <Link to={`/hosts/${group.host.id}`} className="btn-icon" title="Voir l'hôte">
                            <ExternalLink size={13} />
                          </Link>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      <div className={clsx('space-y-5', view === 'summary' && groupBy !== 'none' && 'hidden')}>
        {groups.map((group) => {
          // Une recherche a déjà réduit la liste : replier le résultat le
          // cacherait au moment précis où on le cherche.
          const isCollapsed =
            groupBy !== 'none' && !query.trim() && !expanded.includes(group.key)
          const stats = group.stats
          return (
          <section key={group.key}>
            <div className="flex flex-wrap items-center gap-2 mb-2">
              {groupBy !== 'none' && (
                <button
                  onClick={() => toggleCollapse(group.key)}
                  className="text-ink-500 hover:text-mist-200 transition-colors"
                  title={isCollapsed ? 'Déplier' : 'Replier'}
                >
                  <ChevronDown
                    size={15}
                    className={clsx('transition-transform', isCollapsed && '-rotate-90')}
                  />
                </button>
              )}
              {groupBy === 'project' && group.project ? (
                <Layers size={14} className="text-accent" />
              ) : (
                <Server size={14} className="text-ink-500" />
              )}
              <button
                onClick={() => groupBy !== 'none' && toggleCollapse(group.key)}
                className="text-sm font-semibold text-mist-200 hover:text-mist-100 transition-colors"
              >
                {group.label}
              </button>
              <Badge>
                {group.items.filter((c: any) => c.state === 'running').length}/{group.items.length}
              </Badge>
              {group.sub && <span className="text-xs text-ink-600">{group.sub}</span>}

              {/* Replié : on garde l'essentiel des ressources visible. */}
              {isCollapsed && stats && (
                <div className="flex items-center gap-3 text-[11px] text-ink-500 font-mono">
                  <span className="flex items-center gap-1">
                    <Cpu size={10} />
                    {num(stats.cpu, 1)}%
                  </span>
                  <span className="flex items-center gap-1">
                    <MemoryStick size={10} />
                    {bytes(stats.mem)}
                  </span>
                  {stats.ports > 0 && (
                    <span className="flex items-center gap-1">
                      <Network size={10} />
                      {stats.ports}
                    </span>
                  )}
                </div>
              )}

              {group.host?.id && !isCollapsed && (
                <Link
                  to={`/hosts/${group.host.id}`}
                  className="text-xs text-ink-500 hover:text-accent flex items-center gap-1"
                >
                  Voir l'hôte <ExternalLink size={11} />
                </Link>
              )}

              {/* Actions de pile : uniquement pour un vrai projet compose. */}
              {groupBy === 'project' && group.project && group.host?.kind !== 'proxmox' && (
                <div className="flex items-center gap-1 ml-auto">
                  <button
                    className="btn-ghost py-1 px-2 text-xs"
                    onClick={() => updateStack(group)}
                    disabled={busy === `${group.key}-update`}
                    title="docker compose pull puis up -d"
                  >
                    {busy === `${group.key}-update` ? <Spinner size={12} /> : <ArrowUpCircle size={12} />}
                    Mettre à jour
                  </button>
                  <button
                    className="btn-ghost py-1 px-2 text-xs"
                    onClick={() => projectAction(group, 'restart')}
                    disabled={busy === `${group.key}-restart`}
                    title="Redémarrer toute la pile"
                  >
                    {busy === `${group.key}-restart` ? <Spinner size={12} /> : <RotateCcw size={12} />}
                    Pile
                  </button>
                  <button
                    className="btn-icon"
                    onClick={() => projectAction(group, 'start')}
                    title="Démarrer la pile"
                  >
                    <Play size={13} />
                  </button>
                  <button
                    className="btn-icon hover:text-danger"
                    onClick={() => projectAction(group, 'stop')}
                    title="Arrêter la pile"
                  >
                    <Square size={12} />
                  </button>
                </div>
              )}
            </div>

            <div
              className={clsx(
                'grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(300px,1fr))]',
                isCollapsed && 'hidden',
              )}
            >
              {group.items.map((container: any) => (
                <ContainerCard
                  key={container.id}
                  container={container}
                  showProject={groupBy !== 'project'}
                  busy={busy}
                  onAction={act}
                  onLogs={showLogs}
                  onPull={pull}
                />
              ))}
            </div>
          </section>
          )
        })}
      </div>

      <Modal open={!!logs} onClose={() => setLogs(null)} title={`Journaux · ${logs?.name}`} width="max-w-4xl">
        <pre className="text-[12px] font-mono text-mist-300 whitespace-pre-wrap break-words leading-relaxed max-h-[62vh] overflow-y-auto">
          {logs?.text || 'Aucune sortie.'}
        </pre>
      </Modal>

      <PruneModal host={pruneHost} hosts={dockerHosts} onSelect={setPruneHost} onClose={() => setPruneHost(null)} />
    </Page>
  )
}

function ContainerCard({
  container,
  showProject,
  busy,
  onAction,
  onLogs,
  onPull,
}: {
  container: any
  showProject: boolean
  busy: string | null
  onAction: (container: any, action: string) => void
  onLogs: (container: any) => void
  onPull: (container: any) => void
}) {
  const stats = container.stats ?? {}
  const isRunning = container.state === 'running'
  const isPve = container.host_kind === 'proxmox'

  return (
    <div className={clsx('panel panel-hover p-3 space-y-2.5', !isRunning && 'opacity-65')}>
      <div className="flex items-start gap-2">
        <StatusDot status={container.state} />
        <div className="min-w-0 flex-1">
          <div className="text-[13px] font-medium text-mist-100 truncate">
            {container.service && container.service !== container.name ? container.service : container.name}
          </div>
          <div className="text-[10px] text-ink-600 font-mono truncate">{container.image || container.kind}</div>
        </div>
        {showProject && container.project ? (
          <Badge tone="violet">{container.project}</Badge>
        ) : (
          <Badge tone={isRunning ? 'ok' : 'neutral'}>{container.kind}</Badge>
        )}
      </div>

      {isRunning && stats.cpu !== undefined && (
        <div className="grid grid-cols-2 gap-2.5">
          <div className="space-y-1">
            <div className="flex justify-between">
              <span className="metric-label">CPU</span>
              <span className="metric-value text-[11px]">{num(stats.cpu, 1)}%</span>
            </div>
            <Bar value={Math.min(100, stats.cpu)} height={3} />
          </div>
          <div className="space-y-1">
            <div className="flex justify-between">
              <span className="metric-label">RAM</span>
              <span className="metric-value text-[11px]">{bytes(stats.mem)}</span>
            </div>
            <Bar value={stats.mem_percent ?? 0} height={3} />
          </div>
        </div>
      )}

      {(container.ports ?? []).length > 0 && (
        <div className="flex flex-wrap gap-1">
          {container.ports.slice(0, 4).map((port: any, index: number) => (
            <span key={index} className="chip border-ink-700 bg-ink-800 text-ink-400 font-mono">
              {port.public}→{port.private}
            </span>
          ))}
        </div>
      )}

      <div className="flex items-center gap-1 pt-1 border-t border-ink-800">
        <span className="text-[10px] text-ink-600 flex-1 truncate">{container.status}</span>
        {!isPve && (
          <>
            <Link
              to={`/terminal?host=${container.host_id}&container=${container.ext_id}`}
              className={clsx('btn-icon', !isRunning && 'pointer-events-none opacity-30')}
              title="Terminal"
            >
              <TerminalSquare size={14} />
            </Link>
            <button className="btn-icon" onClick={() => onLogs(container)} title="Journaux">
              {busy === `${container.id}-logs` ? <Spinner size={13} /> : <ScrollText size={14} />}
            </button>
            <button
              className="btn-icon"
              onClick={() => onPull(container)}
              title="Récupérer la dernière image"
            >
              {busy === `${container.id}-pull` ? <Spinner size={13} /> : <ArrowUpCircle size={14} />}
            </button>
          </>
        )}
        {isRunning ? (
          <>
            <button className="btn-icon" onClick={() => onAction(container, 'restart')} title="Redémarrer">
              {busy === `${container.id}-restart` ? <Spinner size={13} /> : <RefreshCw size={14} />}
            </button>
            <button className="btn-icon hover:text-danger" onClick={() => onAction(container, 'stop')} title="Arrêter">
              {busy === `${container.id}-stop` ? <Spinner size={13} /> : <Square size={13} />}
            </button>
          </>
        ) : (
          <button className="btn-icon hover:text-accent" onClick={() => onAction(container, 'start')} title="Démarrer">
            {busy === `${container.id}-start` ? <Spinner size={13} /> : <Play size={14} />}
          </button>
        )}
      </div>
    </div>
  )
}

const PRUNE_LABELS: Record<string, { label: string; hint: string; safe: boolean }> = {
  containers: { label: 'Conteneurs arrêtés', hint: 'Supprime les conteneurs qui ne tournent plus', safe: true },
  build_cache: { label: 'Cache de construction', hint: 'Couches intermédiaires des builds', safe: true },
  images: { label: 'Images orphelines', hint: 'Images sans tag, non référencées', safe: true },
  networks: { label: 'Réseaux inutilisés', hint: "Réseaux qu'aucun conteneur n'utilise", safe: true },
  images_all: {
    label: 'Toutes les images inutilisées',
    hint: "Y compris les images taguées : à retélécharger si besoin",
    safe: false,
  },
  volumes: {
    label: 'Volumes orphelins',
    hint: "⚠ Contient potentiellement des données (bases, uploads)",
    safe: false,
  },
}

function PruneModal({
  host,
  hosts,
  onSelect,
  onClose,
}: {
  host: any | null
  hosts: any[]
  onSelect: (host: any) => void
  onClose: () => void
}) {
  const [selected, setSelected] = useState<string[]>(['containers', 'build_cache', 'images'])
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<any | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data: usage, isLoading } = useQuery({
    queryKey: ['docker-usage', host?.id],
    queryFn: () => get(`/hosts/${host.id}/docker/usage`),
    enabled: !!host,
    retry: false,
  })

  const toggle = (key: string) =>
    setSelected((current) => (current.includes(key) ? current.filter((k) => k !== key) : [...current, key]))

  // Ce que la sélection va effectivement libérer.
  const estimate = selected.reduce((total, key) => {
    const bucket = key === 'images_all' ? 'images' : key === 'build_cache' ? 'build_cache' : key
    return total + ((usage?.usage?.[bucket]?.reclaimable ?? 0) as number)
  }, 0)

  const run = async () => {
    const risky = selected.filter((key) => !PRUNE_LABELS[key].safe)
    const ok = await confirm({
      title: 'Lancer le nettoyage ?',
      message: (
        <>
          {selected.map((key) => PRUNE_LABELS[key].label).join(', ')} seront supprimés sur{' '}
          <b className="text-mist-100">{host.name}</b>, soit environ{' '}
          <b className="text-mist-100">{bytes(estimate)}</b> à libérer.
          {risky.length > 0 && (
            <span className="block mt-2 text-warn">
              Attention : {risky.map((key) => PRUNE_LABELS[key].label.toLowerCase()).join(' et ')} — cette
              suppression est définitive.
            </span>
          )}
        </>
      ),
      confirmLabel: 'Nettoyer',
      danger: risky.length > 0,
    })
    if (!ok) return
    setBusy(true)
    try {
      const outcome = await post(`/hosts/${host.id}/docker/prune`, { targets: selected })
      setResult(outcome)
      toast(`${bytes(outcome.reclaimed)} libérés sur ${host.name}`, 'ok')
      queryClient.invalidateQueries({ queryKey: ['docker-usage', host.id] })
      queryClient.invalidateQueries({ queryKey: ['containers'] })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={!!host}
      onClose={onClose}
      title="Nettoyage Docker"
      width="max-w-2xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Fermer
          </button>
          <button className="btn-primary" onClick={run} disabled={busy || selected.length === 0}>
            {busy ? <Spinner /> : <Eraser size={15} />}
            Nettoyer {estimate > 0 && `(~${bytes(estimate)})`}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {hosts.length > 1 && (
          <div className="space-y-1.5">
            <label>Hôte</label>
            <select
              value={host?.id ?? ''}
              onChange={(e) => onSelect(hosts.find((h) => String(h.id) === e.target.value))}
              className="w-full"
            >
              {hosts.map((entry) => (
                <option key={entry.id} value={entry.id}>
                  {entry.name} ({entry.address})
                </option>
              ))}
            </select>
          </div>
        )}

        {isLoading && (
          <div className="py-6 grid place-items-center">
            <Spinner size={20} />
          </div>
        )}

        {usage && (
          <>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
              {Object.entries(usage.usage).map(([key, value]: [string, any]) => (
                <div key={key} className="bg-ink-800/50 rounded-lg px-2.5 py-2">
                  <div className="metric-label truncate">
                    {{ images: 'Images', containers: 'Conteneurs', volumes: 'Volumes', build_cache: 'Cache' }[
                      key
                    ] ?? key}
                  </div>
                  <div className="metric-value text-sm mt-0.5">{bytes(value.size)}</div>
                  <div className="text-[10px] text-accent">{bytes(value.reclaimable)} récupérables</div>
                </div>
              ))}
            </div>

            <div className="space-y-1.5">
              <label>Que supprimer</label>
              <div className="space-y-1">
                {Object.entries(PRUNE_LABELS).map(([key, meta]) => (
                  <label
                    key={key}
                    className={clsx(
                      'flex items-start gap-2.5 rounded-lg px-3 py-2 cursor-pointer transition-colors border',
                      selected.includes(key)
                        ? 'bg-accent/[0.07] border-accent/30'
                        : 'bg-ink-850 border-ink-750 hover:border-ink-600',
                    )}
                  >
                    <input
                      type="checkbox"
                      checked={selected.includes(key)}
                      onChange={() => toggle(key)}
                      className="mt-0.5"
                    />
                    <div className="min-w-0 flex-1">
                      <div className="text-[13px] text-mist-100 normal-case tracking-normal font-normal">
                        {meta.label}
                      </div>
                      <div className={clsx('text-[11px]', meta.safe ? 'text-ink-500' : 'text-warn')}>
                        {meta.hint}
                      </div>
                    </div>
                  </label>
                ))}
              </div>
            </div>
          </>
        )}

        {result && (
          <div className="panel bg-ink-900/60 p-3 space-y-1">
            <div className="text-sm text-accent font-medium">{bytes(result.reclaimed)} libérés</div>
            {result.results.map((entry: any) => (
              <div key={entry.target} className="text-[12px] text-mist-400 flex justify-between">
                <span>{entry.label}</span>
                <span className="font-mono">
                  {entry.removed} objet(s) · {bytes(entry.reclaimed)}
                </span>
              </div>
            ))}
            {result.errors.map((entry: any) => (
              <div key={entry.target} className="text-[12px] text-danger">
                {entry.target} : {entry.error}
              </div>
            ))}
          </div>
        )}
      </div>
    </Modal>
  )
}
