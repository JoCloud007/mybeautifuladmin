import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { LayoutGrid, List, Plus, Search, Server, Trash2, Wifi } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { AddHostModal } from '@/components/AddHostModal'
import { HostCard } from '@/components/HostCard'
import { Page, PageHeader } from '@/components/PageHeader'
import { Badge, Bar, Empty, Modal, Spinner, StatusDot, useConfirm, useLocalState, useToast } from '@/components/ui'
import { del, get, post } from '@/lib/api'
import { ago, KIND_LABEL, percent } from '@/lib/format'
import { useLive } from '@/lib/live'

export function HostsPage() {
  const [params, setParams] = useSearchParams()
  const [query, setQuery] = useState('')
  const [kind, setKind] = useState('all')
  const [view, setView] = useLocalState<'grid' | 'list'>('mba.hostsView', 'grid')
  const [addOpen, setAddOpen] = useState(params.get('add') === '1')
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  useEffect(() => {
    if (params.get('add') === '1') {
      setAddOpen(true)
      params.delete('add')
      setParams(params, { replace: true })
    }
  }, [params, setParams])

  const { data: hosts = [], isLoading } = useQuery({
    queryKey: ['hosts'],
    queryFn: () => get('/hosts'),
    refetchInterval: 20000,
  })

  const remove = useMutation({
    mutationFn: (id: number) => del(`/hosts/${id}`),
    onSuccess: () => {
      toast('Hôte supprimé', 'ok')
      queryClient.invalidateQueries({ queryKey: ['hosts'] })
      queryClient.invalidateQueries({ queryKey: ['overview'] })
    },
    onError: (e: any) => toast(e.message, 'danger'),
  })

  const filtered = hosts.filter((host: any) => {
    if (kind !== 'all' && host.kind !== kind) return false
    const needle = query.trim().toLowerCase()
    if (!needle) return true
    return `${host.name} ${host.address} ${(host.tags ?? []).join(' ')}`.toLowerCase().includes(needle)
  })

  const kinds = ['all', ...new Set(hosts.map((h: any) => h.kind))] as string[]

  return (
    <Page>
      <PageHeader
        title="Hôtes"
        subtitle={`${hosts.length} équipement(s) supervisé(s)`}
        actions={
          <>
            <div className="relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Filtrer…"
                className="pl-8 py-1.5 w-44"
              />
            </div>
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {(['grid', 'list'] as const).map((mode) => (
                <button
                  key={mode}
                  onClick={() => setView(mode)}
                  className={clsx(
                    'px-2 py-1 rounded-md transition-colors',
                    view === mode ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                  title={mode === 'grid' ? 'Vue cartes' : 'Vue liste'}
                >
                  {mode === 'grid' ? <LayoutGrid size={15} /> : <List size={15} />}
                </button>
              ))}
            </div>
            <button className="btn-primary" onClick={() => setAddOpen(true)}>
              <Plus size={15} />
              Ajouter
            </button>
          </>
        }
      />

      {kinds.length > 2 && (
        <div className="flex gap-1.5 mb-4 flex-wrap">
          {kinds.map((k) => (
            <button
              key={k}
              onClick={() => setKind(k)}
              className={clsx(
                'chip transition-colors',
                kind === k
                  ? 'border-accent/40 bg-accent/10 text-accent'
                  : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
              )}
            >
              {k === 'all' ? 'Tous' : (KIND_LABEL[k] ?? k)}
              <span className="text-ink-500 ml-0.5">
                {k === 'all' ? hosts.length : hosts.filter((h: any) => h.kind === k).length}
              </span>
            </button>
          ))}
        </div>
      )}

      {isLoading && <div className="panel p-10 grid place-items-center"><Spinner size={22} /></div>}

      {!isLoading && filtered.length === 0 && (
        <div className="panel">
          <Empty
            icon={<Server size={38} />}
            title={query ? 'Aucun résultat' : 'Aucun hôte'}
            hint={query ? 'Essaie un autre filtre.' : 'Ajoute un hôte manuellement ou lance une découverte réseau.'}
            action={
              <Link to="/discovery" className="btn-primary">
                Scanner le réseau
              </Link>
            }
          />
        </div>
      )}

      {view === 'grid' ? (
        <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(260px,1fr))]">
          {filtered.map((host: any) => (
            <HostCard key={host.id} host={host} />
          ))}
        </div>
      ) : (
        <HostTable hosts={filtered} onDelete={async (host) => {
          const ok = await confirm({
            title: 'Supprimer cet hôte ?',
            message: (
              <>
                <b className="text-mist-100">{host.name}</b> et tout son historique de métriques seront supprimés.
                Cette action est irréversible.
              </>
            ),
            confirmLabel: 'Supprimer',
            danger: true,
          })
          if (ok) remove.mutate(host.id)
        }} />
      )}

      <AddHostModal open={addOpen} onClose={() => setAddOpen(false)} />
    </Page>
  )
}

function HostTable({ hosts, onDelete }: { hosts: any[]; onDelete: (host: any) => void }) {
  useLive((s) => s.bump)
  const samples = useLive.getState().samples
  const toast = useToast()
  const [testing, setTesting] = useState<number | null>(null)

  const test = async (host: any) => {
    setTesting(host.id)
    try {
      const result = await post(`/hosts/${host.id}/test`)
      toast(
        <>
          <b>{host.name}</b> — {result.detail}
        </>,
        result.ok ? 'ok' : 'danger',
      )
    } catch (e: any) {
      toast(e.message, 'danger')
    } finally {
      setTesting(null)
    }
  }

  return (
    <div className="panel overflow-x-auto">
      <table className="w-full text-sm min-w-[680px]">
        <thead>
          <tr className="text-left border-b border-ink-750">
            {['Hôte', 'Type', 'CPU', 'RAM', 'Disque', 'Vu', ''].map((h) => (
              <th key={h} className="metric-label px-3 py-2 font-semibold">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {hosts.map((host) => {
            const live = samples[host.id] ?? host.live ?? {}
            return (
              <tr key={host.id} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40 transition-colors">
                <td className="px-3 py-2">
                  <Link to={`/hosts/${host.id}`} className="flex items-center gap-2 group">
                    <StatusDot status={host.status} />
                    <div className="min-w-0">
                      <div className="text-mist-100 group-hover:text-accent transition-colors truncate">{host.name}</div>
                      <div className="text-[11px] text-ink-500 font-mono">{host.address}</div>
                    </div>
                  </Link>
                </td>
                <td className="px-3 py-2">
                  <Badge>{KIND_LABEL[host.kind] ?? host.kind}</Badge>
                </td>
                {(['cpu.usage', 'mem.percent', 'disk.percent'] as const).map((metric) => (
                  <td key={metric} className="px-3 py-2 w-28">
                    <div className="flex items-center gap-2">
                      <span className="metric-value text-xs w-10 text-right">{percent(live[metric], 0)}</span>
                      <Bar value={live[metric] ?? 0} height={4} className="flex-1" />
                    </div>
                  </td>
                ))}
                <td className="px-3 py-2 text-xs text-ink-500 whitespace-nowrap">{ago(host.last_seen)}</td>
                <td className="px-3 py-2">
                  <div className="flex items-center justify-end gap-1">
                    <button className="btn-icon" onClick={() => test(host)} title="Tester la connexion">
                      {testing === host.id ? <Spinner size={14} /> : <Wifi size={14} />}
                    </button>
                    <button className="btn-icon hover:text-danger" onClick={() => onDelete(host)} title="Supprimer">
                      <Trash2 size={14} />
                    </button>
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
