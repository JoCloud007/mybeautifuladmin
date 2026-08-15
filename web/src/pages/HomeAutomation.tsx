import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  BatteryLow,
  ChevronDown,
  House,
  Lightbulb,
  Plus,
  Power,
  RefreshCw,
  Search,
  ToggleLeft,
  Trash2,
  TriangleAlert,
  Wifi,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Empty,
  Modal,
  Spinner,
  StatTile,
  StatusDot,
  useConfirm,
  useLocalState,
  useToast,
} from '@/components/ui'
import { del, get, post } from '@/lib/api'
import { ago } from '@/lib/format'
import { useLive } from '@/lib/live'

/** Domaines pilotables et le service à appeler pour basculer leur état. */
const TOGGLEABLE: Record<string, string> = {
  light: 'toggle',
  switch: 'toggle',
  fan: 'toggle',
  input_boolean: 'toggle',
  automation: 'toggle',
  media_player: 'toggle',
}
const RUNNABLE: Record<string, string> = {
  script: 'turn_on',
  scene: 'turn_on',
  button: 'press',
}

export function HomeAutomationPage() {
  const [addOpen, setAddOpen] = useState(false)
  useLive((s) => s.bump)

  const { data, isLoading } = useQuery({
    queryKey: ['home'],
    queryFn: () => get('/home'),
    refetchInterval: 20000,
  })

  const hubs = data?.hubs ?? []

  return (
    <Page>
      <PageHeader
        title="Domotique"
        subtitle="Home Assistant : état des équipements, pilotage et points d'attention"
        actions={
          <button className="btn-primary" onClick={() => setAddOpen(true)}>
            <Plus size={15} />
            Ajouter une instance
          </button>
        }
      />

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && hubs.length === 0 && (
        <div className="panel">
          <Empty
            icon={<House size={38} />}
            title="Aucune instance Home Assistant"
            hint="Crée un jeton d'accès longue durée dans ton profil Home Assistant (en bas de la page), enregistre-le comme identifiant de type « jeton d'API », puis déclare l'instance ici."
            action={
              <button className="btn-primary" onClick={() => setAddOpen(true)}>
                <Plus size={15} />
                Ajouter une instance
              </button>
            }
          />
        </div>
      )}

      <div className="space-y-5">
        {hubs.map((hub: any) => (
          <HubPanel key={hub.id} hub={hub} labels={data?.domain_labels ?? {}} />
        ))}
      </div>

      <AddHubModal open={addOpen} onClose={() => setAddOpen(false)} />
    </Page>
  )
}

function HubPanel({ hub, labels }: { hub: any; labels: Record<string, string> }) {
  const [query, setQuery] = useState('')
  const [onlyIssues, setOnlyIssues] = useState(false)
  const [collapsed, setCollapsed] = useLocalState<string[]>('mba.hassCollapsed', [
    'sensor',
    'binary_sensor',
    'device_tracker',
    'zone',
  ])
  const [busy, setBusy] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const live = useLive.getState().samples[hub.id] ?? {}
  const entities: any[] = live.entities ?? hub.entities ?? []
  const stats = live.hass ?? hub.stats ?? {}

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return entities.filter((entity) => {
      if (onlyIssues && entity.available && !(entity.battery != null && entity.battery <= 20)) return false
      if (!needle) return true
      return `${entity.name} ${entity.entity_id}`.toLowerCase().includes(needle)
    })
  }, [entities, query, onlyIssues])

  const groups = useMemo(() => {
    const map = new Map<string, any[]>()
    for (const entity of filtered) map.set(entity.domain, [...(map.get(entity.domain) ?? []), entity])
    // Les domaines pilotables passent devant, les capteurs derrière.
    const rank = (domain: string) =>
      TOGGLEABLE[domain] ? 0 : RUNNABLE[domain] ? 1 : domain === 'sensor' ? 3 : 2
    return [...map.entries()].sort(
      (a, b) => rank(a[0]) - rank(b[0]) || a[0].localeCompare(b[0]),
    )
  }, [filtered])

  const call = async (entity: any, service: string) => {
    // Une action domotique est visible dans le monde physique : on confirme
    // tout ce qui n'est pas une simple bascule de lumière.
    if (!['light', 'switch', 'input_boolean', 'fan'].includes(entity.domain)) {
      const ok = await confirm({
        title: `${service} — ${entity.name} ?`,
        message: (
          <>
            L'appel <b className="text-mist-100">{entity.domain}.{service}</b> sera envoyé à Home
            Assistant pour <b className="text-mist-100">{entity.entity_id}</b>.
          </>
        ),
        confirmLabel: 'Envoyer',
        danger: entity.domain === 'lock' || entity.domain === 'cover',
      })
      if (!ok) return
    }
    setBusy(entity.entity_id)
    try {
      await post(`/home/${hub.id}/call`, { entity_id: entity.entity_id, service })
      toast(`${entity.name} : ${service}`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['home'] }), 1200)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const remove = async () => {
    const ok = await confirm({
      title: 'Retirer cette instance ?',
      message: (
        <>
          <b className="text-mist-100">{hub.name}</b> ne sera plus supervisé. Home Assistant lui-même
          n'est pas modifié.
        </>
      ),
      confirmLabel: 'Retirer',
      danger: true,
    })
    if (!ok) return
    await del(`/home/${hub.id}`)
    queryClient.invalidateQueries({ queryKey: ['home'] })
    toast('Instance retirée', 'ok')
  }

  const test = async () => {
    setBusy('test')
    try {
      const result = await post(`/home/${hub.id}/test`)
      toast(result.detail, result.ok ? 'ok' : 'danger')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const toggleGroup = (domain: string) =>
    setCollapsed(
      collapsed.includes(domain) ? collapsed.filter((d) => d !== domain) : [...collapsed, domain],
    )

  return (
    <div className="space-y-4">
      <div className="panel p-4">
        <div className="flex flex-wrap items-center gap-3">
          <div className="w-10 h-10 rounded-lg bg-info/12 border border-info/25 grid place-items-center shrink-0">
            <House size={19} className="text-info" />
          </div>
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <StatusDot status={hub.status} />
              <h2 className="font-semibold text-mist-100">{hub.name}</h2>
              {hub.meta?.version && <Badge tone="info">{hub.meta.version}</Badge>}
              {hub.meta?.location && <Badge>{hub.meta.location}</Badge>}
            </div>
            <p className="text-[12px] text-ink-500 font-mono mt-1">
              {hub.meta?.url ?? `${hub.address}:${hub.port}`}
            </p>
          </div>
          <div className="flex-1" />
          <div className="flex items-center gap-1.5">
            <a
              href={hub.meta?.url ?? `http://${hub.address}:${hub.port}`}
              target="_blank"
              rel="noopener noreferrer"
              className="btn-ghost"
            >
              Ouvrir l'interface
            </a>
            <button className="btn-ghost" onClick={test} disabled={busy === 'test'}>
              {busy === 'test' ? <Spinner size={14} /> : <Wifi size={15} />}
              Tester
            </button>
            <button className="btn-icon hover:text-danger" onClick={remove} title="Retirer">
              <Trash2 size={14} />
            </button>
          </div>
        </div>

        <div className="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-3 mt-4 pt-4 border-t border-ink-800">
          <StatTile label="Entités" value={stats.entities ?? 0} sub={`${stats.domains ?? 0} domaines`} />
          <StatTile
            label="Lumières allumées"
            value={stats.lights_on ?? 0}
            icon={<Lightbulb size={20} />}
            tone={stats.lights_on ? 'warn' : 'neutral'}
          />
          <StatTile label="Prises actives" value={stats.switches_on ?? 0} icon={<Power size={20} />} />
          <StatTile
            label="Indisponibles"
            value={stats.unavailable ?? 0}
            tone={stats.unavailable ? 'danger' : 'ok'}
            icon={<TriangleAlert size={20} />}
            onClick={() => setOnlyIssues(true)}
          />
          <StatTile
            label="Batteries faibles"
            value={stats.low_battery ?? 0}
            sub="≤ 20 %"
            tone={stats.low_battery ? 'warn' : 'ok'}
            icon={<BatteryLow size={20} />}
          />
          <StatTile
            label="Automatisations off"
            value={stats.automations_off ?? 0}
            tone={stats.automations_off ? 'warn' : 'ok'}
            icon={<ToggleLeft size={20} />}
          />
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="relative">
          <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Nom ou entity_id…"
            className="pl-8 py-1.5 w-56"
          />
        </div>
        <label className="flex items-center gap-2 text-xs text-mist-400 normal-case tracking-normal font-normal cursor-pointer">
          <input type="checkbox" checked={onlyIssues} onChange={(e) => setOnlyIssues(e.target.checked)} />
          Points d'attention seulement
        </label>
        <span className="text-xs text-ink-600">{filtered.length} entité(s)</span>
      </div>

      {entities.length === 0 && (
        <div className="panel">
          <Empty
            icon={<House size={34} />}
            title={hub.status === 'offline' ? 'Instance injoignable' : 'Première collecte en cours…'}
            hint={hub.status === 'offline' ? hub.last_error ?? undefined : undefined}
          />
        </div>
      )}

      {groups.map(([domain, items]) => {
        const isCollapsed = collapsed.includes(domain)
        const toggleService = TOGGLEABLE[domain]
        const runService = RUNNABLE[domain]
        return (
          <section key={domain} className="panel overflow-hidden">
            <button
              onClick={() => toggleGroup(domain)}
              className="w-full flex items-center gap-2.5 px-4 py-2.5 hover:bg-ink-800/40 transition-colors"
            >
              <ChevronDown
                size={15}
                className={clsx('text-ink-500 transition-transform', isCollapsed && '-rotate-90')}
              />
              <span className="text-sm font-semibold text-mist-200">{labels[domain] ?? domain}</span>
              <Badge>{items.length}</Badge>
              {items.some((e: any) => !e.available) && (
                <Badge tone="danger">{items.filter((e: any) => !e.available).length} KO</Badge>
              )}
            </button>

            {!isCollapsed && (
              <div className="grid gap-2 grid-cols-[repeat(auto-fill,minmax(260px,1fr))] p-3 pt-0 border-t border-ink-800">
                {items.map((entity: any) => {
                  const on = entity.state === 'on' || entity.state === 'open' || entity.state === 'playing'
                  return (
                    <div
                      key={entity.entity_id}
                      className={clsx(
                        'bg-ink-850 border border-ink-750 rounded-lg px-3 py-2 flex items-center gap-2.5',
                        !entity.available && 'opacity-55 border-danger/25',
                      )}
                    >
                      <StatusDot
                        status={!entity.available ? 'offline' : on ? 'online' : 'unknown'}
                        size={7}
                      />
                      <div className="min-w-0 flex-1">
                        <div className="text-[13px] text-mist-100 truncate" title={entity.entity_id}>
                          {entity.name}
                        </div>
                        <div className="text-[10px] text-ink-600 truncate">
                          {entity.changed ? ago(entity.changed) : entity.entity_id}
                          {entity.battery != null && (
                            <span className={clsx('ml-1.5', entity.battery <= 20 && 'text-warn')}>
                              · {entity.battery} %
                            </span>
                          )}
                        </div>
                      </div>

                      <span
                        className={clsx(
                          'metric-value text-xs shrink-0',
                          on && 'text-accent',
                          !entity.available && 'text-danger',
                        )}
                      >
                        {entity.state}
                        {entity.unit ? ` ${entity.unit}` : ''}
                      </span>

                      {toggleService && entity.available && (
                        <button
                          className="btn-icon shrink-0"
                          onClick={() => call(entity, toggleService)}
                          disabled={busy === entity.entity_id}
                          title="Basculer"
                        >
                          {busy === entity.entity_id ? (
                            <Spinner size={13} />
                          ) : (
                            <ToggleLeft size={15} className={on ? 'text-accent' : 'text-ink-500'} />
                          )}
                        </button>
                      )}
                      {runService && entity.available && (
                        <button
                          className="btn-icon shrink-0"
                          onClick={() => call(entity, runService)}
                          disabled={busy === entity.entity_id}
                          title="Déclencher"
                        >
                          {busy === entity.entity_id ? <Spinner size={13} /> : <Power size={14} />}
                        </button>
                      )}
                    </div>
                  )
                })}
              </div>
            )}
          </section>
        )
      })}
    </div>
  )
}

function AddHubModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [form, setForm] = useState({
    name: 'Home Assistant',
    address: '',
    port: 8123,
    credential_id: '',
    secure: false,
  })
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data: credentials = [] } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
    enabled: open,
  })
  const tokens = credentials.filter((c: any) => c.kind === 'token' || c.kind === 'api_token')

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      await post('/home', {
        name: form.name,
        address: form.address,
        port: Number(form.port),
        credential_id: Number(form.credential_id),
        secure: form.secure,
      })
      toast('Instance ajoutée — collecte des entités en cours', 'ok')
      queryClient.invalidateQueries({ queryKey: ['home'] })
      queryClient.invalidateQueries({ queryKey: ['hosts'] })
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
      title="Ajouter Home Assistant"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button
            className="btn-primary"
            form="add-hass"
            type="submit"
            disabled={busy || !form.address || !form.credential_id}
          >
            {busy ? <Spinner /> : <Plus size={15} />}
            Ajouter
          </button>
        </>
      }
    >
      <form id="add-hass" onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5 col-span-2">
            <label>Adresse</label>
            <input
              value={form.address}
              onChange={(e) => setForm({ ...form, address: e.target.value })}
              placeholder="homeassistant.local"
              required
              autoFocus
              className="w-full font-mono"
            />
          </div>
          <div className="space-y-1.5">
            <label>Port</label>
            <input
              type="number"
              value={form.port}
              onChange={(e) => setForm({ ...form, port: Number(e.target.value) })}
              className="w-full"
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom affiché</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Jeton d'accès</label>
            <select
              value={form.credential_id}
              onChange={(e) => setForm({ ...form, credential_id: e.target.value })}
              required
              className="w-full"
            >
              <option value="">— choisir —</option>
              {tokens.map((cred: any) => (
                <option key={cred.id} value={cred.id}>
                  {cred.name}
                </option>
              ))}
            </select>
          </div>
        </div>

        <label className="flex items-center gap-2 text-sm text-mist-300 normal-case tracking-normal font-normal cursor-pointer">
          <input
            type="checkbox"
            checked={form.secure}
            onChange={(e) => setForm({ ...form, secure: e.target.checked, port: e.target.checked ? 443 : 8123 })}
          />
          Accès en HTTPS
        </label>

        <p className="text-[11px] text-ink-500">
          Le jeton se crée dans Home Assistant : clique sur ton profil (en bas à gauche), onglet
          « Sécurité », puis « Créer un jeton ». Enregistre-le dans Réglages → Identifiants avec le
          type « jeton d'API ».
        </p>
      </form>
    </Modal>
  )
}
