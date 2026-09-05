import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  ArrowUpCircle,
  Boxes,
  ChevronDown,
  Eraser,
  ExternalLink,
  Layers,
  LayoutGrid,
  Play,
  RefreshCw,
  RotateCcw,
  Rows3,
  ScrollText,
  Search,
  Server,
  Square,
  Table2,
  Tag,
  TerminalSquare,
} from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Page, PageHeader } from '@/components/PageHeader'
import {
  Badge,
  Bar,
  Empty,
  Modal,
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
import { bytes, num } from '@/lib/format'

type GroupBy = 'project' | 'host' | 'tag' | 'none'
type ViewMode = 'summary' | 'rows' | 'cards'

interface Group {
  key: string
  label: string
  sub?: string
  items: any[]
  host?: { id: number; name: string; kind: string }
  /** Renseigné uniquement pour un vrai projet compose : porte les actions de pile. */
  project?: string
  tags: string[]
  stats: GroupStats
}

interface GroupStats {
  total: number
  running: number
  cpu: number
  mem: number
  ports: number
  images: number
  /** Images sur un tag flottant (`:latest`) : impossible de savoir ce qui tourne. */
  floating: number
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
    floating: items.filter((c) => imageParts(c.image).tag === 'latest').length,
  }
}

/** « ghcr.io/home-assistant/core:2024.6 » → dépôt court, dépôt complet, tag. */
export function imageParts(image?: string | null): { repo: string; full: string; tag: string } {
  if (!image) return { repo: '—', full: '', tag: '' }
  const digest = image.indexOf('@')
  const clean = digest > 0 ? image.slice(0, digest) : image
  const slash = clean.lastIndexOf('/')
  const colon = clean.lastIndexOf(':')
  const tagged = colon > slash
  const full = tagged ? clean.slice(0, colon) : clean
  return { repo: full.split('/').pop() || full, full, tag: tagged ? clean.slice(colon + 1) : '' }
}

export function ContainersPage() {
  const [params] = useSearchParams()
  const [query, setQuery] = useState(params.get('q') ?? '')
  const [onlyIssues, setOnlyIssues] = useState(false)
  const [groupBy, setGroupBy] = useLocalState<GroupBy>('mba.ctGroup', 'project')
  const [stored, setView] = useLocalState<ViewMode>('mba.ctView2', 'rows')
  // Sans regroupement, la synthèse n'a rien à résumer : on retombe sur la liste.
  const view: ViewMode = groupBy === 'none' && stored === 'summary' ? 'rows' : stored
  const [tagFilter, setTagFilter] = useLocalState<string[]>('mba.ctTags', [])
  // On mémorise les groupes *dépliés*, et non les repliés : avec des dizaines
  // de piles, arriver sur une page toute dépliée n'aide personne.
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
    (host: any) =>
      host.kind === 'docker' || host.meta?.has_docker || containers.some((c: any) => c.host_id === host.id),
  )

  // Étiquettes réellement portées par des hôtes qui hébergent des conteneurs.
  const tags = useMemo(() => {
    const counts = new Map<string, number>()
    for (const container of containers)
      for (const tag of container.host_tags ?? []) counts.set(tag, (counts.get(tag) ?? 0) + 1)
    return [...counts.entries()]
      .map(([tag, count]) => ({ tag, count }))
      .sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag))
  }, [containers])

  const filtered = containers.filter((container: any) => {
    if (onlyIssues && container.state === 'running') return false
    if (tagFilter.length && !tagFilter.some((tag) => (container.host_tags ?? []).includes(tag)))
      return false
    const needle = query.trim().toLowerCase()
    if (!needle) return true
    return `${container.name} ${container.service ?? ''} ${container.image} ${container.host_name} ${
      container.project ?? ''
    } ${(container.host_tags ?? []).join(' ')}`
      .toLowerCase()
      .includes(needle)
  })

  // Regroupement : par pile compose, par hôte, par étiquette, ou pas du tout.
  const groups = useMemo<Group[]>(() => {
    if (groupBy === 'none')
      return [
        {
          key: 'all',
          label: 'Tous les conteneurs',
          items: filtered,
          tags: [],
          stats: aggregate(filtered),
        },
      ]

    const map = new Map<string, Group>()
    const push = (key: string, base: Omit<Group, 'items' | 'stats'>, container: any) => {
      const entry = map.get(key) ?? { ...base, items: [], stats: aggregate([]) }
      entry.items.push(container)
      for (const tag of container.host_tags ?? [])
        if (!entry.tags.includes(tag)) entry.tags.push(tag)
      map.set(key, entry)
    }

    for (const container of filtered) {
      const host = { id: container.host_id, name: container.host_name, kind: container.host_kind }
      if (groupBy === 'host') {
        push(`h${container.host_id}`, { key: `h${container.host_id}`, label: container.host_name, host, tags: [] }, container)
      } else if (groupBy === 'project') {
        const key = `${container.host_id}:${container.project ?? '~'}`
        push(
          key,
          {
            key,
            label: container.project ?? 'Hors compose',
            sub: container.host_name,
            host,
            project: container.project ?? undefined,
            tags: [],
          },
          container,
        )
      } else {
        // Par étiquette : un conteneur dont l'hôte porte deux étiquettes
        // apparaît sous chacune — c'est ce qu'on veut d'une vue par étiquette.
        const hostTags: string[] = container.host_tags ?? []
        for (const tag of hostTags.length ? hostTags : ['~'])
          push(
            `t:${tag}`,
            { key: `t:${tag}`, label: tag === '~' ? 'Sans étiquette' : tag, tags: [], host },
            container,
          )
      }
    }

    return [...map.values()]
      .map((group) => ({ ...group, stats: aggregate(group.items) }))
      .sort((a, b) => {
        // Ce qui ne tourne pas remonte : c'est ce qu'on vient regarder.
        const aKo = a.stats.total - a.stats.running > 0
        const bKo = b.stats.total - b.stats.running > 0
        if (aKo !== bKo) return aKo ? -1 : 1
        // Les conteneurs hors compose (ou sans étiquette) passent en dernier.
        const aLoose = groupBy === 'project' ? !a.project : a.key === 't:~'
        const bLoose = groupBy === 'project' ? !b.project : b.key === 't:~'
        if (aLoose !== bLoose) return aLoose ? 1 : -1
        return a.label.localeCompare(b.label)
      })
  }, [filtered, groupBy])

  // Peu de groupes : on les ouvre d'emblée, la page reste lisible d'un coup d'œil.
  const seeded = useRef(false)
  useEffect(() => {
    if (seeded.current || groups.length === 0) return
    seeded.current = true
    if (expanded.length === 0 && groups.length <= 6) setExpanded(groups.map((g) => g.key))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groups.length])

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

  const projectAction = async (group: Group, action: 'start' | 'stop' | 'restart') => {
    const label = { start: 'Démarrer', stop: 'Arrêter', restart: 'Redémarrer' }[action]
    const ok = await confirm({
      title: `${label} la pile « ${group.label} » ?`,
      message: (
        <>
          {group.items.length} conteneur(s) sur <b className="text-mist-100">{group.host?.name}</b> seront
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
        `/hosts/${group.host!.id}/projects/${encodeURIComponent(group.project ?? '')}/${action}`,
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

  const updateStack = async (group: Group) => {
    const ok = await confirm({
      title: `Mettre à jour la pile « ${group.label} » ?`,
      message: (
        <>
          MBA va exécuter <b className="text-mist-100">docker compose pull</b> puis{' '}
          <b className="text-mist-100">up -d</b> sur {group.host?.name}.
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
        `/hosts/${group.host!.id}/projects/${encodeURIComponent(group.project ?? '')}/update`,
      )
      toast(result.updated ? `${group.label} : pile mise à jour` : `${group.label} : déjà à jour`, 'ok')
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

  const total = aggregate(containers)
  const stacks = new Set(containers.filter((c: any) => c.project).map((c: any) => `${c.host_id}:${c.project}`))
  const stopped = total.total - total.running

  return (
    <Page>
      <PageHeader
        title="Conteneurs"
        subtitle={`${total.running} actif(s) sur ${total.total}${stacks.size ? ` · ${stacks.size} pile(s)` : ''}`}
        actions={
          <>
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {(
                [
                  ['project', 'Pile', Layers],
                  ['host', 'Hôte', Server],
                  ['tag', 'Étiquette', Tag],
                  ['none', 'À plat', Rows3],
                ] as const
              ).map(([value, label, Icon]) => (
                <button
                  key={value}
                  onClick={() => setGroupBy(value)}
                  className={clsx(
                    'px-2.5 py-1 rounded-md text-xs font-medium transition-colors flex items-center gap-1.5',
                    groupBy === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                  title={`Regrouper par ${label.toLowerCase()}`}
                >
                  <Icon size={13} />
                  <span className="hidden lg:inline">{label}</span>
                </button>
              ))}
            </div>
            {groupBy !== 'none' && (
              <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
                {(
                  [
                    ['summary', 'Synthèse', Table2],
                    ['rows', 'Liste', Rows3],
                    ['cards', 'Cartes', LayoutGrid],
                  ] as const
                ).map(([value, label, Icon]) => (
                  <button
                    key={value}
                    onClick={() => setView(value)}
                    className={clsx(
                      'px-2 py-1 rounded-md text-xs font-medium transition-colors',
                      view === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                    )}
                    title={label}
                  >
                    <Icon size={13} />
                  </button>
                ))}
              </div>
            )}
            {groupBy !== 'none' && view !== 'summary' && (
              <button className="btn-ghost" onClick={toggleAll}>
                <ChevronDown size={14} className={clsx('transition-transform', allCollapsed && '-rotate-90')} />
                {allCollapsed ? 'Tout déplier' : 'Tout replier'}
              </button>
            )}
            <div className="relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Filtrer…"
                className="pl-8 py-1.5 w-44"
              />
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

      {/* Synthèse chiffrée : l'état du parc conteneurisé en une ligne. */}
      {!isLoading && total.total > 0 && (
        <div className="grid gap-3 grid-cols-2 md:grid-cols-4 xl:grid-cols-5 mb-4">
          <StatTile label="En marche" value={`${total.running}/${total.total}`} icon={<Play size={18} />} tone="ok" />
          <StatTile
            label="À l'arrêt"
            value={stopped}
            icon={<Square size={17} />}
            tone={stopped ? 'warn' : 'neutral'}
            sub={stopped ? 'cliquer pour filtrer' : 'tout tourne'}
            onClick={stopped ? () => setOnlyIssues(!onlyIssues) : undefined}
          />
          <StatTile label="Piles compose" value={stacks.size} icon={<Layers size={18} />} tone="info" />
          <StatTile label="RAM cumulée" value={bytes(total.mem)} icon={<Boxes size={18} />} />
          <StatTile
            label="Images flottantes"
            value={total.floating}
            sub=":latest — version non figée"
            icon={<ArrowUpCircle size={18} />}
            tone={total.floating ? 'warn' : 'neutral'}
          />
        </div>
      )}

      {!isLoading && total.total > 0 && (
        <div className="flex flex-wrap items-center gap-3 mb-4">
          <TagFilter tags={tags} selected={tagFilter} onChange={setTagFilter} />
          <label className="flex items-center gap-2 text-xs text-mist-400 cursor-pointer ml-auto">
            <input type="checkbox" checked={onlyIssues} onChange={(e) => setOnlyIssues(e.target.checked)} />
            Uniquement ce qui ne tourne pas
          </label>
        </div>
      )}

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && filtered.length === 0 && (
        <div className="panel">
          <Empty
            icon={<Boxes size={36} />}
            title={query || tagFilter.length || onlyIssues ? 'Aucun résultat' : 'Aucun conteneur détecté'}
            hint={
              query || tagFilter.length || onlyIssues
                ? 'Aucun conteneur ne correspond aux filtres actifs.'
                : 'Les conteneurs sont découverts automatiquement sur les hôtes Linux disposant de Docker, et sur les hyperviseurs Proxmox.'
            }
          />
        </div>
      )}

      {/* Synthèse : une ligne par groupe, sans détail des conteneurs. */}
      {view === 'summary' && groupBy !== 'none' && groups.length > 0 && (
        <div className="panel overflow-x-auto">
          <table className="w-full text-sm min-w-[780px]">
            <thead>
              <tr className="text-left border-b border-ink-750">
                {[
                  groupBy === 'project' ? 'Pile' : groupBy === 'tag' ? 'Étiquette' : 'Hôte',
                  'État',
                  'CPU cumulé',
                  'RAM cumulée',
                  'Étiquettes',
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
                const { stats } = group
                const allUp = stats.running === stats.total
                return (
                  <tr
                    key={group.key}
                    className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40 transition-colors"
                  >
                    <td className="px-3 py-2.5">
                      <button
                        onClick={() => {
                          // Depuis la synthèse, on bascule en détail sur ce seul
                          // groupe : les autres restent repliés.
                          setView('rows')
                          setExpanded([group.key])
                        }}
                        className="flex items-center gap-2 group text-left"
                      >
                        <GroupIcon group={group} groupBy={groupBy} />
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
                        <span className={clsx('metric-value text-xs', !allUp && 'text-warn')}>
                          {stats.running}/{stats.total}
                        </span>
                      </div>
                    </td>
                    <td className="px-3 py-2.5 w-32">
                      <div className="flex items-center gap-2">
                        <span className="metric-value text-xs w-12 text-right">{num(stats.cpu, 1)}%</span>
                        <Bar value={Math.min(100, stats.cpu)} height={3} className="flex-1" />
                      </div>
                    </td>
                    <td className="px-3 py-2.5 metric-value text-xs">{bytes(stats.mem)}</td>
                    <td className="px-3 py-2.5">
                      <TagList tags={group.tags} onPick={(tag) => setTagFilter([tag])} max={3} />
                    </td>
                    <td className="px-3 py-2.5 text-xs text-mist-400">{stats.ports}</td>
                    <td className="px-3 py-2.5">
                      <div className="flex items-center justify-end gap-1">
                        <StackActions
                          group={group}
                          busy={busy}
                          compact
                          onUpdate={updateStack}
                          onAction={projectAction}
                        />
                        {group.host?.id && groupBy !== 'tag' && (
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

      {view !== 'summary' && (
        <div className="space-y-3">
          {groups.map((group) => {
            // Une recherche a déjà réduit la liste : replier le résultat le
            // cacherait au moment précis où on le cherche.
            const isCollapsed = groupBy !== 'none' && !query.trim() && !expanded.includes(group.key)
            const { stats } = group
            const allUp = stats.running === stats.total

            return (
              <section key={group.key} className="panel overflow-hidden">
                {groupBy !== 'none' && (
                  <header
                    onClick={() => toggleCollapse(group.key)}
                    className={clsx(
                      'flex flex-wrap items-center gap-x-3 gap-y-2 px-3 py-2.5 cursor-pointer select-none',
                      'hover:bg-ink-800/40 transition-colors',
                      !isCollapsed && 'border-b border-ink-800',
                    )}
                  >
                    <ChevronDown
                      size={15}
                      className={clsx('text-ink-500 transition-transform shrink-0', isCollapsed && '-rotate-90')}
                    />
                    <GroupIcon group={group} groupBy={groupBy} />
                    <div className="min-w-0">
                      <div className="text-[13px] font-semibold text-mist-100 truncate">{group.label}</div>
                      {group.sub && <div className="text-[10px] text-ink-600 truncate">{group.sub}</div>}
                    </div>

                    <Badge tone={allUp ? 'ok' : stats.running ? 'warn' : 'danger'}>
                      {stats.running}/{stats.total}
                    </Badge>

                    {/* Ressources du groupe : toujours visibles, replié ou non. */}
                    <div className="flex items-center gap-3 text-[11px] text-ink-500 font-mono">
                      <span title="CPU cumulé">{num(stats.cpu, 1)}%</span>
                      <span title="RAM cumulée">{bytes(stats.mem)}</span>
                      {stats.ports > 0 && <span title="Ports publiés">{stats.ports} ports</span>}
                      {stats.floating > 0 && (
                        <span className="text-warn" title="Conteneurs sur une image :latest">
                          {stats.floating} × latest
                        </span>
                      )}
                    </div>

                    {groupBy !== 'tag' && group.tags.length > 0 && (
                      <span onClick={(e) => e.stopPropagation()}>
                        <TagList tags={group.tags} onPick={(tag) => setTagFilter([tag])} max={3} />
                      </span>
                    )}

                    <div
                      className="flex items-center gap-1 ml-auto"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <StackActions group={group} busy={busy} onUpdate={updateStack} onAction={projectAction} />
                      {group.host?.id && groupBy !== 'tag' && (
                        <Link to={`/hosts/${group.host.id}`} className="btn-icon" title="Voir l'hôte">
                          <ExternalLink size={13} />
                        </Link>
                      )}
                    </div>
                  </header>
                )}

                {!isCollapsed &&
                  (view === 'cards' ? (
                    <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(290px,1fr))] p-3">
                      {sortItems(group.items).map((container: any) => (
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
                  ) : (
                    <div className="divide-y divide-ink-800/60">
                      {sortItems(group.items).map((container: any) => (
                        <ContainerRow
                          key={container.id}
                          container={container}
                          showHost={groupBy !== 'host' && groupBy !== 'project'}
                          showProject={groupBy !== 'project'}
                          busy={busy}
                          onAction={act}
                          onLogs={showLogs}
                          onPull={pull}
                        />
                      ))}
                    </div>
                  ))}
              </section>
            )
          })}
        </div>
      )}

      <Modal open={!!logs} onClose={() => setLogs(null)} title={`Journaux · ${logs?.name}`} width="max-w-4xl">
        <pre className="text-[12px] font-mono text-mist-300 whitespace-pre-wrap break-words leading-relaxed max-h-[62vh] overflow-y-auto">
          {logs?.text || 'Aucune sortie.'}
        </pre>
      </Modal>

      <PruneModal host={pruneHost} hosts={dockerHosts} onSelect={setPruneHost} onClose={() => setPruneHost(null)} />
    </Page>
  )
}

/** Ce qui ne tourne pas d'abord : c'est ce qui demande une décision. */
function sortItems(items: any[]): any[] {
  return [...items].sort((a, b) => {
    const aUp = a.state === 'running'
    const bUp = b.state === 'running'
    if (aUp !== bUp) return aUp ? 1 : -1
    return (a.service || a.name).localeCompare(b.service || b.name)
  })
}

function GroupIcon({ group, groupBy }: { group: Group; groupBy: GroupBy }) {
  if (groupBy === 'tag') return <Tag size={14} className="text-violet shrink-0" />
  if (groupBy === 'project')
    return group.project ? (
      <Layers size={14} className="text-accent shrink-0" />
    ) : (
      <Boxes size={14} className="text-ink-500 shrink-0" />
    )
  return <Server size={14} className="text-ink-500 shrink-0" />
}

/** Actions de pile : réservées à un vrai projet compose sur un hôte Docker. */
function StackActions({
  group,
  busy,
  compact,
  onUpdate,
  onAction,
}: {
  group: Group
  busy: string | null
  compact?: boolean
  onUpdate: (group: Group) => void
  onAction: (group: Group, action: 'start' | 'stop' | 'restart') => void
}) {
  if (!group.project || group.host?.kind === 'proxmox') return null
  const running = group.stats.running
  return (
    <>
      <button
        className={compact ? 'btn-icon' : 'btn-ghost py-1 px-2 text-xs'}
        onClick={() => onUpdate(group)}
        disabled={busy === `${group.key}-update`}
        title="docker compose pull puis up -d"
      >
        {busy === `${group.key}-update` ? <Spinner size={12} /> : <ArrowUpCircle size={13} />}
        {!compact && 'Mettre à jour'}
      </button>
      <button
        className={compact ? 'btn-icon' : 'btn-ghost py-1 px-2 text-xs'}
        onClick={() => onAction(group, 'restart')}
        disabled={busy === `${group.key}-restart`}
        title="Redémarrer toute la pile"
      >
        {busy === `${group.key}-restart` ? <Spinner size={12} /> : <RotateCcw size={13} />}
        {!compact && 'Pile'}
      </button>
      {running < group.stats.total && (
        <button className="btn-icon" onClick={() => onAction(group, 'start')} title="Démarrer la pile">
          <Play size={13} />
        </button>
      )}
      {running > 0 && (
        <button className="btn-icon hover:text-danger" onClick={() => onAction(group, 'stop')} title="Arrêter la pile">
          <Square size={12} />
        </button>
      )}
    </>
  )
}

/** Ligne compacte : le format par défaut, pensé pour être scanné du regard. */
function ContainerRow({
  container,
  showHost,
  showProject,
  busy,
  onAction,
  onLogs,
  onPull,
}: {
  container: any
  showHost: boolean
  showProject: boolean
  busy: string | null
  onAction: (container: any, action: string) => void
  onLogs: (container: any) => void
  onPull: (container: any) => void
}) {
  const stats = container.stats ?? {}
  const isRunning = container.state === 'running'
  const isPve = container.host_kind === 'proxmox'
  const image = imageParts(container.image)

  return (
    <div
      className={clsx(
        'flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 hover:bg-ink-800/40 transition-colors',
        !isRunning && 'bg-danger/[0.03]',
      )}
    >
      <StatusDot status={container.state} size={7} />

      <div className="min-w-0 w-44 flex-1">
        <div className={clsx('text-[13px] truncate', isRunning ? 'text-mist-100' : 'text-mist-300')}>
          {container.service && container.service !== container.name ? container.service : container.name}
        </div>
        <div className="text-[10px] text-ink-600 truncate" title={container.status}>
          {container.status || container.state}
        </div>
      </div>

      {/* Image : le dépôt court suffit, le tag est ce qui se lit. */}
      <div className="hidden md:block w-52 min-w-0" title={container.image}>
        <span className="text-[11px] font-mono text-mist-400 truncate">{image.repo}</span>
        {image.tag && (
          <span className={clsx('text-[11px] font-mono ml-1', image.tag === 'latest' ? 'text-warn' : 'text-ink-500')}>
            :{image.tag}
          </span>
        )}
      </div>

      {showProject && container.project && (
        <Badge tone="violet" className="hidden xl:inline-flex">
          {container.project}
        </Badge>
      )}
      {showHost && <span className="hidden xl:block text-[11px] text-ink-500 w-28 truncate">{container.host_name}</span>}

      {/* Ressources : la barre donne l'ordre de grandeur, le chiffre la précision. */}
      <div className="w-28 hidden sm:flex items-center gap-2">
        {isRunning && stats.cpu !== undefined ? (
          <>
            <span className="metric-value text-[11px] w-10 text-right">{num(stats.cpu, 1)}%</span>
            <Bar value={Math.min(100, stats.cpu)} height={3} className="flex-1" />
          </>
        ) : (
          <span className="text-[11px] text-ink-700">—</span>
        )}
      </div>
      <span className="metric-value text-[11px] w-16 text-right hidden sm:block">
        {isRunning && stats.mem ? bytes(stats.mem) : <span className="text-ink-700">—</span>}
      </span>

      <div className="hidden lg:flex flex-wrap gap-1 w-36 justify-end">
        {(container.ports ?? []).slice(0, 2).map((port: any, index: number) => (
          <span key={index} className="chip border-ink-700 bg-ink-800 text-ink-400 font-mono py-0">
            {port.public}→{port.private}
          </span>
        ))}
        {(container.ports ?? []).length > 2 && (
          <span className="text-[10px] text-ink-600">+{container.ports.length - 2}</span>
        )}
      </div>

      <div className="flex items-center gap-0.5 ml-auto">
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
            <button className="btn-icon" onClick={() => onPull(container)} title="Récupérer la dernière image">
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
  const image = imageParts(container.image)

  return (
    <div className={clsx('panel panel-hover p-3 space-y-2.5', !isRunning && 'opacity-65')}>
      <div className="flex items-start gap-2">
        <StatusDot status={container.state} />
        <div className="min-w-0 flex-1">
          <div className="text-[13px] font-medium text-mist-100 truncate">
            {container.service && container.service !== container.name ? container.service : container.name}
          </div>
          <div className="text-[10px] text-ink-600 font-mono truncate" title={container.image}>
            {image.repo}
            {image.tag && (
              <span className={image.tag === 'latest' ? 'text-warn' : undefined}>:{image.tag}</span>
            )}
          </div>
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
            <button className="btn-icon" onClick={() => onPull(container)} title="Récupérer la dernière image">
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
