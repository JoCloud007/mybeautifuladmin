import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  ChevronDown,
  Clock,
  Eye,
  Globe,
  Network as NetworkIcon,
  Plus,
  Radar,
  Search,
  Server,
  Shield,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Spinner, StatTile, StatusDot, Tabs, useLocalState } from '@/components/ui'
import { get } from '@/lib/api'
import { KIND_LABEL, ago, datetime } from '@/lib/format'

type Tab = 'assets' | 'history'
type GroupBy = 'subnet' | 'tag' | 'location' | 'kind' | 'category'

const GROUP_LABELS: Record<GroupBy, string> = {
  subnet: 'Réseau',
  tag: 'Étiquette',
  location: 'Emplacement',
  kind: 'Type',
  category: 'Catégorie',
}

export function NetworkPage() {
  const [tab, setTab] = useState<Tab>('assets')
  const [groupBy, setGroupBy] = useLocalState<GroupBy>('mba.netGroup', 'subnet')
  const [query, setQuery] = useState('')
  const [onlyUnmanaged, setOnlyUnmanaged] = useState(false)
  const [collapsed, setCollapsed] = useLocalState<string[]>('mba.netCollapsed', [])

  const { data, isLoading } = useQuery({
    queryKey: ['network', groupBy],
    queryFn: () => get(`/network?group_by=${groupBy}`),
    refetchInterval: 30000,
  })

  const summary = data?.summary ?? {}

  const groups = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return (data?.groups ?? [])
      .map((group: any) => ({
        ...group,
        assets: group.assets.filter((asset: any) => {
          if (onlyUnmanaged && asset.supervised) return false
          if (!needle) return true
          return `${asset.name} ${asset.address} ${(asset.roles ?? []).join(' ')} ${asset.os ?? ''}`
            .toLowerCase()
            .includes(needle)
        }),
      }))
      .filter((group: any) => group.assets.length > 0)
  }, [data, query, onlyUnmanaged])

  const toggle = (key: string) =>
    setCollapsed(collapsed.includes(key) ? collapsed.filter((k) => k !== key) : [...collapsed, key])

  return (
    <Page>
      <PageHeader
        title="Réseau"
        subtitle="Tous les équipements vus sur le réseau, supervisés ou non, et leur historique"
        actions={
          tab === 'assets' && (
            <>
              <label className="flex items-center gap-2 text-xs text-mist-400 normal-case tracking-normal font-normal cursor-pointer">
                <input
                  type="checkbox"
                  checked={onlyUnmanaged}
                  onChange={(e) => setOnlyUnmanaged(e.target.checked)}
                />
                Non supervisés seulement
              </label>
              <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
                {(Object.keys(GROUP_LABELS) as GroupBy[]).map((value) => (
                  <button
                    key={value}
                    onClick={() => setGroupBy(value)}
                    className={clsx(
                      'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                      groupBy === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                    )}
                  >
                    {GROUP_LABELS[value]}
                  </button>
                ))}
              </div>
              <div className="relative">
                <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
                <input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="Nom, IP, service…"
                  className="pl-8 py-1.5 w-48"
                />
              </div>
            </>
          )
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 gap-3 mb-5">
        <StatTile label="Équipements" value={summary.total ?? 0} icon={<NetworkIcon size={20} />} />
        <StatTile
          label="Supervisés"
          value={summary.supervised ?? 0}
          sub={`${summary.online ?? 0} en ligne`}
          tone="ok"
          icon={<Server size={20} />}
        />
        <StatTile
          label="Non supervisés"
          value={summary.unmanaged ?? 0}
          sub="vus mais non adoptés"
          tone={summary.unmanaged ? 'warn' : 'ok'}
          icon={<Eye size={20} />}
          onClick={() => setOnlyUnmanaged(true)}
        />
        <StatTile label="Réseaux" value={summary.subnets ?? 0} icon={<Globe size={20} />} />
        <StatTile
          label="Sur Tailscale"
          value={summary.tailscale ?? 0}
          sub="accès hors LAN"
          icon={<Shield size={20} />}
        />
      </div>

      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'assets', label: 'Inventaire réseau' },
            { id: 'history', label: 'Historique' },
          ]}
        />
      </div>

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {tab === 'assets' && !isLoading && (
        <>
          {groups.length === 0 && (
            <div className="panel">
              <Empty
                icon={<NetworkIcon size={38} />}
                title={query || onlyUnmanaged ? 'Aucun résultat' : 'Aucun équipement'}
                hint="Lance une découverte réseau pour peupler cette vue."
                action={
                  <Link to="/discovery" className="btn-primary">
                    <Radar size={15} />
                    Scanner le réseau
                  </Link>
                }
              />
            </div>
          )}

          <div className="space-y-4">
            {groups.map((group: any) => {
              const isCollapsed = collapsed.includes(group.key)
              return (
                <section key={group.key} className="panel overflow-hidden">
                  <button
                    onClick={() => toggle(group.key)}
                    className="w-full flex items-center gap-2.5 px-4 py-2.5 hover:bg-ink-800/40 transition-colors"
                  >
                    <ChevronDown
                      size={15}
                      className={clsx('text-ink-500 transition-transform', isCollapsed && '-rotate-90')}
                    />
                    <NetworkIcon size={14} className="text-accent" />
                    <span className="text-sm font-semibold text-mist-200 font-mono">{group.key}</span>
                    <Badge>{group.assets.length}</Badge>
                    <span className="text-[11px] text-ink-600">
                      {group.online} en ligne · {group.supervised} supervisé(s)
                    </span>
                  </button>

                  {!isCollapsed && (
                    <div className="overflow-x-auto border-t border-ink-800">
                      <table className="w-full text-sm min-w-[760px]">
                        <thead>
                          <tr className="text-left border-b border-ink-800">
                            {['Équipement', 'Adresse', 'Type', 'Services', 'Étiquettes', 'Vu', ''].map(
                              (header) => (
                                <th key={header} className="metric-label px-3 py-2 font-semibold">
                                  {header}
                                </th>
                              ),
                            )}
                          </tr>
                        </thead>
                        <tbody>
                          {group.assets.map((asset: any, index: number) => (
                            <tr
                              key={`${asset.address}-${index}`}
                              className={clsx(
                                'border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40',
                                !asset.supervised && 'opacity-75',
                              )}
                            >
                              <td className="px-3 py-2">
                                <div className="flex items-center gap-2">
                                  <StatusDot status={asset.status} size={6} />
                                  {asset.id ? (
                                    <Link
                                      to={`/hosts/${asset.id}`}
                                      className="text-mist-100 hover:text-accent transition-colors truncate"
                                    >
                                      {asset.name}
                                    </Link>
                                  ) : (
                                    <span className="text-mist-300 truncate">{asset.name}</span>
                                  )}
                                  {asset.tailscale && <Badge tone="violet">TS</Badge>}
                                </div>
                                {asset.os && (
                                  <div className="text-[10px] text-ink-600 ml-4 truncate max-w-[220px]">
                                    {asset.os}
                                  </div>
                                )}
                              </td>
                              <td className="px-3 py-2 text-xs font-mono text-ink-500">{asset.address}</td>
                              <td className="px-3 py-2">
                                <Badge tone={asset.supervised ? 'info' : 'neutral'}>
                                  {KIND_LABEL[asset.host_kind] ?? asset.host_kind ?? '—'}
                                </Badge>
                              </td>
                              <td className="px-3 py-2">
                                <div className="flex flex-wrap gap-1 max-w-[220px]">
                                  {(asset.roles ?? []).slice(0, 5).map((role: string) => (
                                    <span
                                      key={role}
                                      className="chip border-ink-700 bg-ink-800 text-ink-400"
                                    >
                                      {role}
                                    </span>
                                  ))}
                                  {(asset.roles ?? []).length === 0 && (
                                    <span className="text-ink-600 text-xs">—</span>
                                  )}
                                </div>
                              </td>
                              <td className="px-3 py-2">
                                <div className="flex flex-wrap gap-1 max-w-[150px]">
                                  {(asset.tags ?? []).map((tag: string) => (
                                    <Badge key={tag}>{tag}</Badge>
                                  ))}
                                  {(asset.tags ?? []).length === 0 && (
                                    <span className="text-ink-600 text-xs">—</span>
                                  )}
                                </div>
                              </td>
                              <td className="px-3 py-2 text-xs text-ink-500 whitespace-nowrap">
                                {ago(asset.last_seen)}
                              </td>
                              <td className="px-3 py-2 text-right">
                                {!asset.supervised && (
                                  <Link to="/discovery" className="btn-ghost py-1 px-2 text-xs">
                                    <Plus size={12} />
                                    Adopter
                                  </Link>
                                )}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </section>
              )
            })}
          </div>
        </>
      )}

      {tab === 'history' && <HistoryTab />}
    </Page>
  )
}

function HistoryTab() {
  const [days, setDays] = useState(30)
  const { data, isLoading } = useQuery({
    queryKey: ['network-history', days],
    queryFn: () => get(`/network/history?days=${days}`),
  })

  if (isLoading) {
    return (
      <div className="panel p-12 grid place-items-center">
        <Spinner size={22} />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5 w-fit">
        {[7, 30, 90].map((value) => (
          <button
            key={value}
            onClick={() => setDays(value)}
            className={clsx(
              'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
              days === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
            )}
          >
            {value} jours
          </button>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
        <div className="panel p-4">
          <SectionTitle right={<span className="text-xs text-ink-500">{(data?.appeared ?? []).length}</span>}>
            Équipements ajoutés
          </SectionTitle>
          {(data?.appeared ?? []).length === 0 ? (
            <p className="text-xs text-ink-600 py-4">Aucun ajout sur la période.</p>
          ) : (
            <div className="space-y-1">
              {data.appeared.map((entry: any, index: number) => (
                <div key={index} className="flex items-center gap-2.5 py-1.5 border-b border-ink-800/60 last:border-0">
                  <Plus size={13} className="text-accent shrink-0" />
                  <span className="text-[13px] text-mist-200 flex-1 truncate">{entry.name}</span>
                  <span className="text-[11px] text-ink-600 font-mono">{entry.address}</span>
                  <span className="text-[11px] text-ink-600">{ago(entry.created_at)}</span>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="panel p-4">
          <SectionTitle right={<span className="text-xs text-ink-500">{(data?.discovered ?? []).length}</span>}>
            Détections réseau
          </SectionTitle>
          {(data?.discovered ?? []).length === 0 ? (
            <p className="text-xs text-ink-600 py-4">Aucune détection sur la période.</p>
          ) : (
            <div className="space-y-1 max-h-72 overflow-y-auto">
              {data.discovered.map((entry: any, index: number) => (
                <div key={index} className="flex items-center gap-2.5 py-1.5 border-b border-ink-800/60 last:border-0">
                  <Radar size={13} className={entry.adopted ? 'text-accent' : 'text-ink-500'} />
                  <span className="text-[13px] text-mist-300 flex-1 truncate">
                    {entry.hostname || entry.address}
                  </span>
                  {entry.source === 'tailscale' && <Badge tone="violet">TS</Badge>}
                  {entry.adopted && <Badge tone="ok">adopté</Badge>}
                  <span className="text-[11px] text-ink-600">{ago(entry.seen_at)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="panel p-4">
        <SectionTitle>Continuité de la collecte</SectionTitle>
        <p className="text-[12px] text-ink-500 mb-2">
          Nombre de points relevés par machine sur la période — un écart révèle une coupure.
        </p>
        <div className="space-y-1">
          {(data?.availability ?? []).map((entry: any) => (
            <div key={entry.id} className="flex items-center gap-3 py-1.5 border-b border-ink-800/60 last:border-0">
              <Link to={`/hosts/${entry.id}`} className="text-[13px] text-mist-200 hover:text-accent w-40 truncate">
                {entry.name}
              </Link>
              <span className="metric-value text-xs w-20 text-right">{entry.points}</span>
              <span className="text-[11px] text-ink-600 flex-1">
                du {datetime(entry.first_point)} au {datetime(entry.last_point)}
              </span>
            </div>
          ))}
          {(data?.availability ?? []).length === 0 && (
            <p className="text-xs text-ink-600">Pas encore d'historique de collecte.</p>
          )}
        </div>
      </div>

      <div className="panel">
        <div className="px-4 py-2.5 border-b border-ink-800 flex items-center gap-2">
          <Clock size={14} className="text-ink-500" />
          <h3 className="text-sm font-semibold text-mist-200">Évènements réseau</h3>
        </div>
        <div className="divide-y divide-ink-800/60 max-h-96 overflow-y-auto">
          {(data?.events ?? []).map((event: any, index: number) => (
            <div key={index} className="flex items-start gap-3 px-4 py-2">
              <StatusDot
                status={
                  event.level === 'critical' ? 'offline' : event.level === 'warning' ? 'warning' : 'unknown'
                }
                size={6}
              />
              <div className="min-w-0 flex-1">
                <p className="text-[13px] text-mist-300 break-words">{event.message}</p>
                <p className="text-[10px] text-ink-600">
                  {datetime(event.time)} · {event.source}
                  {event.address && ` · ${event.address}`}
                </p>
              </div>
            </div>
          ))}
          {(data?.events ?? []).length === 0 && (
            <Empty icon={<Clock size={30} />} title="Aucun évènement réseau" />
          )}
        </div>
      </div>
    </div>
  )
}
