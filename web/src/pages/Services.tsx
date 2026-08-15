import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { ExternalLink, Globe, Plus, RefreshCw, Trash2 } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Chart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Modal, Spinner, StatusDot, useConfirm, useToast } from '@/components/ui'
import { del, get, post } from '@/lib/api'
import { ago, ms, percent } from '@/lib/format'
import { useLive } from '@/lib/live'

export function ServicesPage() {
  const [addOpen, setAddOpen] = useState(false)
  const [detail, setDetail] = useState<any | null>(null)
  const queryClient = useQueryClient()
  const toast = useToast()
  const confirm = useConfirm()
  const liveServices = useLive((s) => s.services)

  const { data: services = [], isLoading } = useQuery({
    queryKey: ['services'],
    queryFn: () => get('/services'),
    refetchInterval: 20000,
  })

  const merged = services.map((service: any) => ({ ...service, ...(liveServices[service.id] ?? {}) }))
  const groups = new Map<string, any[]>()
  for (const service of merged) {
    const key = service.group_name || 'Sans groupe'
    groups.set(key, [...(groups.get(key) ?? []), service])
  }

  const down = merged.filter((s: any) => s.status === 'down').length

  const remove = async (service: any) => {
    const ok = await confirm({
      title: 'Supprimer ce service ?',
      message: (
        <>
          <b className="text-mist-100">{service.name}</b> et son historique de disponibilité seront supprimés.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await del(`/services/${service.id}`)
    toast('Service supprimé', 'ok')
    queryClient.invalidateQueries({ queryKey: ['services'] })
  }

  const checkNow = async (service: any) => {
    try {
      await post(`/services/${service.id}/check`)
      queryClient.invalidateQueries({ queryKey: ['services'] })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    }
  }

  return (
    <Page>
      <PageHeader
        title="Services web"
        subtitle={
          down > 0 ? `${down} service(s) en panne sur ${merged.length}` : `${merged.length} service(s) surveillé(s)`
        }
        actions={
          <button className="btn-primary" onClick={() => setAddOpen(true)}>
            <Plus size={15} />
            Ajouter un service
          </button>
        }
      />

      {isLoading && <div className="panel p-12 grid place-items-center"><Spinner size={22} /></div>}

      {!isLoading && merged.length === 0 && (
        <div className="panel">
          <Empty
            icon={<Globe size={36} />}
            title="Aucun service surveillé"
            hint="Ajoute les URL de tes applications web : MBA vérifie leur disponibilité, mesure la latence et t'alerte en cas de panne."
            action={
              <button className="btn-primary" onClick={() => setAddOpen(true)}>
                <Plus size={15} />
                Ajouter un service
              </button>
            }
          />
        </div>
      )}

      <div className="space-y-5">
        {[...groups.entries()].map(([group, list]) => (
          <section key={group}>
            <SectionTitle right={<span className="text-xs text-ink-500">{list.length}</span>}>{group}</SectionTitle>
            <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(290px,1fr))]">
              {list.map((service: any) => (
                <ServiceCard
                  key={service.id}
                  service={service}
                  onOpen={() => setDetail(service)}
                  onCheck={() => checkNow(service)}
                  onDelete={() => remove(service)}
                />
              ))}
            </div>
          </section>
        ))}
      </div>

      <AddServiceModal open={addOpen} onClose={() => setAddOpen(false)} />
      <ServiceDetail service={detail} onClose={() => setDetail(null)} />
    </Page>
  )
}

function ServiceCard({
  service,
  onOpen,
  onCheck,
  onDelete,
}: {
  service: any
  onOpen: () => void
  onCheck: () => void
  onDelete: () => void
}) {
  const up = service.status === 'up'
  const latency = service.latency_ms ?? service.last_latency_ms
  const uptime = service.uptime_24h ?? 0

  return (
    <div
      className={clsx(
        'panel panel-hover p-3.5 space-y-3 cursor-pointer group',
        service.status === 'down' && 'border-danger/25',
      )}
      onClick={onOpen}
    >
      <div className="flex items-start gap-2.5">
        <StatusDot status={service.status} />
        <div className="min-w-0 flex-1">
          <div className="text-sm font-medium text-mist-100 truncate group-hover:text-accent transition-colors">
            {service.name}
          </div>
          <div className="text-[11px] text-ink-600 truncate font-mono">{service.url}</div>
        </div>
        <a
          href={service.url}
          target="_blank"
          rel="noopener noreferrer"
          onClick={(e) => e.stopPropagation()}
          className="btn-icon shrink-0"
          title="Ouvrir"
        >
          <ExternalLink size={14} />
        </a>
      </div>

      <div className="grid grid-cols-3 gap-2 text-center">
        <div>
          <div className="metric-label">État</div>
          <div className={clsx('metric-value text-sm', up ? 'text-accent' : 'text-danger')}>
            {up ? 'En ligne' : service.status === 'down' ? 'Panne' : '—'}
          </div>
        </div>
        <div>
          <div className="metric-label">Latence</div>
          <div className="metric-value text-sm">{ms(latency)}</div>
        </div>
        <div>
          <div className="metric-label">24 h</div>
          <div
            className="metric-value text-sm"
            style={{ color: uptime >= 99.5 ? '#00d4aa' : uptime >= 95 ? '#ffb020' : '#ff4d6d' }}
          >
            {percent(uptime, 1)}
          </div>
        </div>
      </div>

      {service.error && (
        <div className="text-[11px] text-danger bg-danger/8 rounded px-2 py-1 truncate">{service.error}</div>
      )}

      <div className="flex items-center gap-1 pt-1 border-t border-ink-800">
        <span className="text-[10px] text-ink-600 flex-1">
          {service.host_name && <span>{service.host_name} · </span>}
          vérifié {ago(service.last_checked)}
        </span>
        <button
          className="btn-icon"
          onClick={(e) => {
            e.stopPropagation()
            onCheck()
          }}
          title="Vérifier maintenant"
        >
          <RefreshCw size={13} />
        </button>
        <button
          className="btn-icon hover:text-danger"
          onClick={(e) => {
            e.stopPropagation()
            onDelete()
          }}
          title="Supprimer"
        >
          <Trash2 size={13} />
        </button>
      </div>
    </div>
  )
}

function ServiceDetail({ service, onClose }: { service: any | null; onClose: () => void }) {
  const [range, setRange] = useState<'1h' | '24h' | '7d' | '30d'>('24h')
  const { data } = useQuery({
    queryKey: ['service-history', service?.id, range],
    queryFn: () => get(`/services/${service.id}/history?range=${range}`),
    enabled: !!service,
  })

  const chart = useMemo(() => {
    const points = data?.points ?? []
    return [points.map((p: any) => p.t), points.map((p: any) => p.latency)] as any
  }, [data])

  return (
    <Modal open={!!service} onClose={onClose} title={service?.name ?? ''} width="max-w-3xl">
      <div className="space-y-4">
        <div className="flex items-center gap-2 flex-wrap">
          <Badge tone={service?.status === 'up' ? 'ok' : 'danger'}>{service?.status}</Badge>
          <a href={service?.url} target="_blank" rel="noopener noreferrer" className="text-xs text-accent hover:underline font-mono">
            {service?.url}
          </a>
          <div className="flex-1" />
          <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
            {(['1h', '24h', '7d', '30d'] as const).map((value) => (
              <button
                key={value}
                onClick={() => setRange(value)}
                className={clsx(
                  'px-2 py-0.5 rounded text-xs transition-colors',
                  range === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                )}
              >
                {value}
              </button>
            ))}
          </div>
        </div>

        <div>
          <SectionTitle>Latence</SectionTitle>
          <Chart height={180} data={chart} format={(v) => ms(v)} specs={[{ label: 'Latence', color: PALETTE[1] }]} />
        </div>

        <div>
          <SectionTitle>Incidents récents</SectionTitle>
          {(data?.incidents ?? []).length === 0 ? (
            <p className="text-sm text-ink-500 py-4 text-center">Aucun incident sur la période. 🎉</p>
          ) : (
            <div className="space-y-1 max-h-52 overflow-y-auto">
              {data.incidents.map((incident: any, index: number) => (
                <div key={index} className="flex items-center gap-2.5 text-xs bg-danger/[0.06] rounded px-2.5 py-1.5">
                  <StatusDot status="offline" size={5} />
                  <span className="text-ink-500 font-mono shrink-0">{new Date(incident.time).toLocaleString('fr-FR')}</span>
                  <span className="text-mist-300 truncate flex-1">
                    {incident.error || `Code HTTP ${incident.status_code}`}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </Modal>
  )
}

function AddServiceModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [form, setForm] = useState({
    name: '',
    url: '',
    host_id: '',
    expect_status: 200,
    interval_s: 30,
    group_name: '',
  })
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()
  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      await post('/services', {
        name: form.name,
        url: form.url,
        host_id: form.host_id ? Number(form.host_id) : null,
        expect_status: Number(form.expect_status),
        interval_s: Number(form.interval_s),
        group_name: form.group_name || null,
      })
      toast('Service ajouté', 'ok')
      queryClient.invalidateQueries({ queryKey: ['services'] })
      setForm({ name: '', url: '', host_id: '', expect_status: 200, interval_s: 30, group_name: '' })
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Ajouter un service web"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" form="add-service" type="submit" disabled={busy || !form.url}>
            {busy ? <Spinner /> : <Plus size={15} />}
            Ajouter
          </button>
        </>
      }
    >
      <form id="add-service" onSubmit={submit} className="space-y-4">
        <div className="space-y-1.5">
          <label>URL</label>
          <input
            value={form.url}
            onChange={(e) => setForm({ ...form, url: e.target.value })}
            placeholder="https://nextcloud.maison.lan"
            required
            className="w-full font-mono"
          />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="Nextcloud"
              required
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Groupe</label>
            <input
              value={form.group_name}
              onChange={(e) => setForm({ ...form, group_name: e.target.value })}
              placeholder="Maison"
              className="w-full"
            />
          </div>
        </div>
        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5">
            <label>Code attendu</label>
            <input
              type="number"
              value={form.expect_status}
              onChange={(e) => setForm({ ...form, expect_status: Number(e.target.value) })}
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Intervalle (s)</label>
            <input
              type="number"
              min={5}
              value={form.interval_s}
              onChange={(e) => setForm({ ...form, interval_s: Number(e.target.value) })}
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Hôte lié</label>
            <select value={form.host_id} onChange={(e) => setForm({ ...form, host_id: e.target.value })} className="w-full">
              <option value="">— aucun —</option>
              {hosts.map((host: any) => (
                <option key={host.id} value={host.id}>
                  {host.name}
                </option>
              ))}
            </select>
          </div>
        </div>
      </form>
    </Modal>
  )
}
