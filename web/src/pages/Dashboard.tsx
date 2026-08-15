import { useQuery } from '@tanstack/react-query'
import {
  AlertTriangle,
  Boxes,
  Cpu,
  Download,
  Globe,
  MemoryStick,
  Plus,
  Radar,
  Server,
  ShieldCheck,
} from 'lucide-react'
import { Link, useNavigate } from 'react-router-dom'
import { HostCard, HostCardSkeleton } from '@/components/HostCard'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, StatTile, StatusDot } from '@/components/ui'
import { get, post } from '@/lib/api'
import { ago, datetime, percent } from '@/lib/format'
import { useLive } from '@/lib/live'

export function Dashboard() {
  const navigate = useNavigate()
  const { data, isLoading, refetch } = useQuery({
    queryKey: ['overview'],
    queryFn: () => get('/overview'),
    refetchInterval: 15000,
  })
  const liveEvents = useLive((s) => s.events)

  const summary = data?.summary ?? {}
  const hosts = data?.hosts ?? []
  const alerts = data?.alerts ?? []

  const grouped = groupByKind(hosts)
  const events = mergeEvents(liveEvents, data?.events ?? [])

  return (
    <Page>
      <PageHeader
        title="Vue d'ensemble"
        subtitle={`${summary.hosts_online ?? 0} hôte(s) en ligne sur ${summary.hosts_total ?? 0} · flux temps réel`}
        actions={
          <>
            <Link to="/discovery" className="btn-ghost">
              <Radar size={15} />
              Scanner
            </Link>
            <Link to="/hosts?add=1" className="btn-primary">
              <Plus size={15} />
              Ajouter un hôte
            </Link>
          </>
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-3 mb-5">
        <StatTile
          label="Hôtes"
          value={`${summary.hosts_online ?? 0}/${summary.hosts_total ?? 0}`}
          sub={summary.hosts_offline ? `${summary.hosts_offline} hors ligne` : 'tous joignables'}
          tone={summary.hosts_offline ? 'danger' : 'ok'}
          icon={<Server size={20} />}
          onClick={() => navigate('/hosts')}
        />
        <StatTile
          label="CPU moyen"
          value={percent(summary.cpu_avg, 0)}
          sub="sur les hôtes en ligne"
          icon={<Cpu size={20} />}
          tone={summary.cpu_avg > 85 ? 'danger' : summary.cpu_avg > 65 ? 'warn' : 'neutral'}
        />
        <StatTile
          label="RAM moyenne"
          value={percent(summary.mem_avg, 0)}
          sub="sur les hôtes en ligne"
          icon={<MemoryStick size={20} />}
          tone={summary.mem_avg > 88 ? 'danger' : summary.mem_avg > 70 ? 'warn' : 'neutral'}
        />
        <StatTile
          label="Conteneurs"
          value={`${summary.containers_running ?? 0}/${summary.containers_total ?? 0}`}
          sub="actifs"
          icon={<Boxes size={20} />}
          onClick={() => navigate('/containers')}
        />
        <StatTile
          label="Services web"
          value={`${summary.services?.up ?? 0}`}
          sub={summary.services?.down ? `${summary.services.down} en panne` : 'tous en ligne'}
          tone={summary.services?.down ? 'danger' : 'ok'}
          icon={<Globe size={20} />}
          onClick={() => navigate('/services')}
        />
        <StatTile
          label="Mises à jour"
          value={summary.updates_pending ?? 0}
          sub="paquets en attente"
          tone={summary.updates_pending ? 'warn' : 'ok'}
          icon={<Download size={20} />}
        />
      </div>

      {alerts.length > 0 && (
        <div className="panel border-danger/25 bg-danger/[0.04] p-3.5 mb-5">
          <SectionTitle
            right={
              <Link to="/events" className="text-xs text-mist-400 hover:text-mist-100">
                Tout voir
              </Link>
            }
          >
            <span className="flex items-center gap-2 text-danger">
              <AlertTriangle size={15} />
              {alerts.length} alerte{alerts.length > 1 ? 's' : ''} active{alerts.length > 1 ? 's' : ''}
            </span>
          </SectionTitle>
          <div className="space-y-1.5">
            {alerts.slice(0, 4).map((alert: any) => (
              <AlertRow key={alert.id} alert={alert} onAck={() => post(`/alerts/${alert.id}/ack`).then(() => refetch())} />
            ))}
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 2xl:grid-cols-[1fr,320px] gap-5 items-start">
        <div className="space-y-5">
          {isLoading && (
            <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(260px,1fr))]">
              {[0, 1, 2, 3, 4, 5].map((i) => (
                <HostCardSkeleton key={i} />
              ))}
            </div>
          )}

          {!isLoading && hosts.length === 0 && (
            <div className="panel">
              <Empty
                icon={<Server size={38} />}
                title="Aucun hôte enregistré"
                hint="Lance un scan du réseau pour détecter automatiquement tes serveurs Linux, Proxmox, NAS Synology et endpoints Ollama."
                action={
                  <Link to="/discovery" className="btn-primary">
                    <Radar size={15} />
                    Scanner le réseau
                  </Link>
                }
              />
            </div>
          )}

          {grouped.map(([kind, list]) => (
            <section key={kind}>
              <SectionTitle right={<span className="text-xs text-ink-500">{list.length}</span>}>
                {KIND_TITLE[kind] ?? kind}
              </SectionTitle>
              <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(260px,1fr))]">
                {list.map((host: any) => (
                  <HostCard key={host.id} host={host} />
                ))}
              </div>
            </section>
          ))}
        </div>

        <aside className="panel p-3.5 2xl:sticky 2xl:top-[76px]">
          <SectionTitle
            right={
              <Link to="/events" className="text-xs text-mist-400 hover:text-mist-100">
                Journal
              </Link>
            }
          >
            Activité récente
          </SectionTitle>
          {events.length === 0 ? (
            <p className="text-sm text-ink-500 py-6 text-center">Rien à signaler.</p>
          ) : (
            <ol className="space-y-0.5 max-h-[62vh] overflow-y-auto -mr-1.5 pr-1.5">
              {events.slice(0, 40).map((event: any, index: number) => (
                <li key={index} className="flex gap-2.5 py-1.5 border-b border-ink-800/60 last:border-0">
                  <span className="mt-1.5">
                    <StatusDot
                      status={event.level === 'critical' ? 'offline' : event.level === 'warning' ? 'warning' : 'unknown'}
                      size={6}
                    />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className="text-[13px] text-mist-300 leading-snug break-words">{event.message}</p>
                    <p className="text-[10px] text-ink-600 mt-0.5">
                      {event.host_name && <span className="text-ink-500">{event.host_name} · </span>}
                      {ago(event.time)}
                    </p>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </aside>
      </div>
    </Page>
  )
}

function AlertRow({ alert, onAck }: { alert: any; onAck: () => void }) {
  return (
    <div className="flex items-center gap-2.5 text-sm bg-ink-850/60 rounded-lg px-3 py-2">
      <Badge tone={alert.severity === 'critical' ? 'danger' : 'warn'}>{alert.severity}</Badge>
      <span className="flex-1 min-w-0 truncate text-mist-200">{alert.message}</span>
      <span className="text-[11px] text-ink-600 hidden sm:block">{datetime(alert.started_at)}</span>
      <button onClick={onAck} className="btn-ghost py-1 px-2 text-xs" title="Acquitter">
        <ShieldCheck size={13} />
      </button>
    </div>
  )
}

const KIND_TITLE: Record<string, string> = {
  linux: 'Serveurs Linux',
  proxmox: 'Hyperviseurs Proxmox',
  synology: 'NAS Synology',
  docker: 'Hôtes Docker',
  generic: 'Autres équipements',
}
const ORDER = ['proxmox', 'linux', 'synology', 'docker', 'generic']

function groupByKind(hosts: any[]): [string, any[]][] {
  const map = new Map<string, any[]>()
  for (const host of hosts) {
    const list = map.get(host.kind) ?? []
    list.push(host)
    map.set(host.kind, list)
  }
  return [...map.entries()].sort((a, b) => ORDER.indexOf(a[0]) - ORDER.indexOf(b[0]))
}

/** Fusionne le flux WebSocket et l'historique API, sans doublon. */
function mergeEvents(live: any[], stored: any[]) {
  const normalized = live.map((e) => ({ ...e, time: e.time }))
  const seen = new Set(normalized.map((e) => `${e.message}`))
  return [...normalized, ...stored.filter((e) => !seen.has(e.message))]
}
