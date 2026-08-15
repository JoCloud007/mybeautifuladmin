import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { AlertTriangle, History, ScrollText, Search, ShieldCheck } from 'lucide-react'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Modal, Spinner, StatusDot, Tabs, useToast } from '@/components/ui'
import { get, post } from '@/lib/api'
import { ago, datetime, duration } from '@/lib/format'
import { useLive } from '@/lib/live'

type Tab = 'events' | 'alerts' | 'actions'

export function EventsPage() {
  const [tab, setTab] = useState<Tab>('events')
  const [level, setLevel] = useState<string>('')
  const [source, setSource] = useState<string>('')
  const [search, setSearch] = useState<string>('')
  const [expanded, setExpanded] = useState<number[]>([])
  const [detail, setDetail] = useState<any | null>(null)
  const queryClient = useQueryClient()
  const toast = useToast()
  const liveEvents = useLive((s) => s.events)

  const { data: journal, isLoading: loadingEvents } = useQuery({
    queryKey: ['events', level, source, search],
    queryFn: () =>
      get(
        `/events?limit=400${level ? `&level=${level}` : ''}` +
          `${source ? `&source=${encodeURIComponent(source)}` : ''}` +
          `${search ? `&search=${encodeURIComponent(search)}` : ''}`,
      ),
    refetchInterval: 20000,
  })
  const events = journal?.events ?? []
  const { data: alerts = [] } = useQuery({
    queryKey: ['alerts'],
    queryFn: () => get('/alerts?state=firing'),
    refetchInterval: 15000,
  })
  const { data: actions = [] } = useQuery({
    queryKey: ['actions'],
    queryFn: () => get('/actions?limit=100'),
    refetchInterval: 15000,
    enabled: tab === 'actions',
  })

  const merged = level
    ? events
    : [...liveEvents.filter((e) => !events.some((s: any) => s.message === e.message)), ...events]

  const ack = async (alert: any) => {
    await post(`/alerts/${alert.id}/ack`)
    toast('Alerte acquittée', 'ok')
    queryClient.invalidateQueries({ queryKey: ['alerts'] })
    queryClient.invalidateQueries({ queryKey: ['overview'] })
  }

  return (
    <Page>
      <PageHeader
        title="Journal"
        subtitle="Évènements, alertes et historique des actions administratives"
        actions={
          tab === 'events' && (
            <>
            <div className="relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
              <input
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="Rechercher…"
                className="pl-8 py-1.5 w-44"
              />
            </div>
            <select value={source} onChange={(e) => setSource(e.target.value)} className="py-1.5">
              <option value="">Toutes les sources</option>
              {(journal?.sources ?? []).map((entry: any) => (
                <option key={entry.source} value={entry.source}>
                  {entry.source} ({entry.count})
                </option>
              ))}
            </select>
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {[
                { id: '', label: 'Tous' },
                { id: 'info', label: 'Info' },
                { id: 'warning', label: 'Avert.' },
                { id: 'critical', label: 'Critique' },
              ].map((option) => (
                <button
                  key={option.id}
                  onClick={() => setLevel(option.id)}
                  className={clsx(
                    'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                    level === option.id ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                >
                  {option.label}
                </button>
              ))}
            </div>
            </>
          )
        }
      />

      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'events', label: 'Évènements' },
            {
              id: 'alerts',
              label: 'Alertes',
              badge: alerts.length > 0 ? <Badge tone="danger">{alerts.length}</Badge> : undefined,
            },
            { id: 'actions', label: 'Actions' },
          ]}
        />
      </div>

      {tab === 'events' && (
        <div className="panel divide-y divide-ink-800/60">
          {loadingEvents && (
            <div className="p-10 grid place-items-center">
              <Spinner size={20} />
            </div>
          )}
          {!loadingEvents && merged.length === 0 && (
            <Empty icon={<ScrollText size={34} />} title="Aucun évènement" hint="Le journal se remplit au fil de l'activité." />
          )}
          {merged.map((event: any, index: number) => {
            const payload = event.data && Object.keys(event.data).length > 0 ? event.data : null
            const isOpen = expanded.includes(index)
            return (
              <div key={index} className="px-4 py-2.5 hover:bg-ink-800/30">
                <div className="flex items-start gap-3">
                  <StatusDot
                    status={
                      event.level === 'critical' ? 'offline' : event.level === 'warning' ? 'warning' : 'unknown'
                    }
                    size={7}
                  />
                  <div className="min-w-0 flex-1">
                    <p className="text-[13px] text-mist-200 leading-snug break-words whitespace-pre-wrap">
                      {event.message}
                    </p>
                    <p className="text-[11px] text-ink-600 mt-0.5 flex items-center gap-2 flex-wrap">
                      <span title={event.time}>{datetime(event.time)}</span>
                      <span>·</span>
                      <span className="font-mono">{event.source}</span>
                      {event.host_name && (
                        <>
                          <span>·</span>
                          {event.host_id ? (
                            <Link to={`/hosts/${event.host_id}`} className="hover:text-accent">
                              {event.host_name}
                            </Link>
                          ) : (
                            <span>{event.host_name}</span>
                          )}
                        </>
                      )}
                      {payload && (
                        <button
                          onClick={() =>
                            setExpanded(
                              isOpen ? expanded.filter((i) => i !== index) : [...expanded, index],
                            )
                          }
                          className="text-accent hover:underline"
                        >
                          {isOpen ? 'masquer le détail' : 'voir le détail'}
                        </button>
                      )}
                    </p>
                  </div>
                  <Badge
                    tone={event.level === 'critical' ? 'danger' : event.level === 'warning' ? 'warn' : 'neutral'}
                  >
                    {event.level}
                  </Badge>
                </div>

                {payload && isOpen && (
                  <pre className="mt-2 ml-6 text-[11px] font-mono text-mist-400 bg-ink-900 rounded-lg p-2.5 whitespace-pre-wrap break-words max-h-64 overflow-y-auto">
                    {JSON.stringify(payload, null, 2)}
                  </pre>
                )}
              </div>
            )
          })}
        </div>
      )}

      {tab === 'alerts' && (
        <div className="panel divide-y divide-ink-800/60">
          {alerts.length === 0 && (
            <Empty icon={<ShieldCheck size={34} />} title="Aucune alerte active" hint="Tout va bien de ce côté." />
          )}
          {alerts.map((alert: any) => (
            <div key={alert.id} className="flex items-start gap-3 px-4 py-3 hover:bg-ink-800/30">
              <AlertTriangle
                size={16}
                className={clsx('mt-0.5 shrink-0', alert.severity === 'critical' ? 'text-danger' : 'text-warn')}
              />
              <div className="min-w-0 flex-1">
                <p className="text-[13px] text-mist-100">{alert.message}</p>
                <p className="text-[11px] text-ink-600 mt-0.5">
                  {alert.rule_name} · déclenchée {ago(alert.started_at)}
                  {alert.host_name && ` · ${alert.host_name}`}
                </p>
              </div>
              <button className="btn-ghost py-1 px-2 text-xs" onClick={() => ack(alert)}>
                <ShieldCheck size={13} />
                Acquitter
              </button>
            </div>
          ))}
        </div>
      )}

      {tab === 'actions' && (
        <div className="panel overflow-x-auto">
          <table className="w-full text-sm min-w-[680px]">
            <thead>
              <tr className="text-left border-b border-ink-750">
                {['Action', 'Hôte', 'Cible', 'État', 'Par', 'Quand', 'Durée'].map((header) => (
                  <th key={header} className="metric-label px-3 py-2 font-semibold">
                    {header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {actions.map((action: any) => {
                const elapsed = action.ended_at
                  ? (new Date(action.ended_at).getTime() - new Date(action.started_at).getTime()) / 1000
                  : null
                return (
                  <tr
                    key={action.id}
                    onClick={() => action.output && setDetail(action)}
                    className={clsx(
                      'border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40',
                      action.output && 'cursor-pointer',
                    )}
                  >
                    <td className="px-3 py-2 font-mono text-[13px] text-mist-100">{action.action}</td>
                    <td className="px-3 py-2 text-xs text-mist-400">{action.host_name ?? '—'}</td>
                    <td className="px-3 py-2 text-xs text-ink-500 font-mono truncate max-w-[180px]">
                      {action.target ?? '—'}
                    </td>
                    <td className="px-3 py-2">
                      <Badge
                        tone={
                          action.status === 'success' ? 'ok' : action.status === 'failed' ? 'danger' : 'warn'
                        }
                      >
                        {action.status}
                      </Badge>
                    </td>
                    <td className="px-3 py-2 text-xs text-mist-400">{action.username ?? '—'}</td>
                    <td className="px-3 py-2 text-xs text-ink-500 whitespace-nowrap">{ago(action.started_at)}</td>
                    <td className="px-3 py-2 text-xs text-ink-500">{elapsed !== null ? duration(elapsed) : '—'}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
          {actions.length === 0 && <Empty icon={<History size={32} />} title="Aucune action enregistrée" />}
        </div>
      )}

      <Modal open={!!detail} onClose={() => setDetail(null)} title={`${detail?.action} · ${detail?.host_name ?? ''}`} width="max-w-4xl">
        <div className="space-y-3">
          <SectionTitle>Sortie</SectionTitle>
          <pre className="text-[12px] font-mono text-mist-300 whitespace-pre-wrap break-words leading-relaxed max-h-[60vh] overflow-y-auto bg-ink-900 rounded-lg p-3">
            {detail?.output}
          </pre>
        </div>
      </Modal>
    </Page>
  )
}
