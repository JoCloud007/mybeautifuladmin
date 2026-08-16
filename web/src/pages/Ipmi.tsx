import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  CircuitBoard,
  ExternalLink,
  Fan,
  Lightbulb,
  Plus,
  Power,
  RotateCcw,
  ScrollText,
  Server,
  Thermometer,
  Trash2,
  Wifi,
  Zap,
} from 'lucide-react'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { LiveChart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Modal, Spinner, StatusDot, useConfirm, useToast } from '@/components/ui'

const STEP_LABEL: Record<string, string> = {
  dns: 'Résolution du nom',
  tcp: 'Ouverture du port',
  tls: 'Poignée de main TLS',
  redfish: 'Service Redfish',
  auth: 'Authentification',
  inventaire: 'Lecture des capteurs',
}

function DiagnosticSteps({ steps }: { steps: any[] }) {
  return (
    <div className="space-y-1.5">
      {steps.map((step, index) => (
        <div
          key={index}
          className={clsx(
            'rounded-lg px-3 py-2 border',
            step.ok ? 'border-accent/25 bg-accent/[0.05]' : 'border-danger/30 bg-danger/[0.06]',
          )}
        >
          <div className="flex items-center gap-2">
            <StatusDot status={step.ok ? 'online' : 'offline'} size={6} />
            <span className="text-[13px] text-mist-100">{STEP_LABEL[step.step] ?? step.step}</span>
            <span className="text-[11px] text-ink-500 truncate flex-1">{step.detail}</span>
          </div>
          {step.hint && <p className="text-[11px] text-warn mt-1 ml-4">{step.hint}</p>}
        </div>
      ))}
    </div>
  )
}
import { del, get, post } from '@/lib/api'
import { bytes, num, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

/** Actions d'alimentation, de la plus douce à la plus brutale. */
const POWER_ACTIONS: { id: string; label: string; hint: string; danger: boolean }[] = [
  { id: 'on', label: 'Allumer', hint: 'Met la machine sous tension', danger: false },
  { id: 'graceful', label: 'Arrêt propre', hint: "Demande à l'OS de s'arrêter (ACPI)", danger: true },
  { id: 'restart', label: 'Redémarrage forcé', hint: 'Équivalent du bouton reset', danger: true },
  { id: 'cycle', label: "Cycle d'alimentation", hint: 'Coupe puis rallume', danger: true },
  { id: 'off', label: 'Coupure forcée', hint: 'Coupe le courant sans prévenir l’OS', danger: true },
]

export function IpmiPage() {
  const [addOpen, setAddOpen] = useState(false)
  const [selLog, setSelLog] = useState<{ name: string; entries: any[] } | null>(null)
  const [diagnostic, setDiagnostic] = useState<{ name: string; steps: any[] } | null>(null)
  useLive((s) => s.bump)

  const { data, isLoading } = useQuery({
    queryKey: ['ipmi'],
    queryFn: () => get('/ipmi'),
    refetchInterval: 20000,
  })

  const bmcs = data?.bmcs ?? []

  return (
    <Page>
      <PageHeader
        title="Gestion hors-bande"
        subtitle="Contrôleurs BMC : alimentation, capteurs et journal matériel, même serveur éteint"
        actions={
          <button className="btn-primary" onClick={() => setAddOpen(true)}>
            <Plus size={15} />
            Ajouter un BMC
          </button>
        }
      />

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && bmcs.length === 0 && (
        <div className="panel">
          <Empty
            icon={<CircuitBoard size={38} />}
            title="Aucun contrôleur enregistré"
            hint="Sur une carte ASUS équipée d'un ASMB (AST2500/2600), MBA parle Redfish en HTTPS. Si le BMC est plus ancien ou Redfish désactivé, choisis le mode ipmitool : les commandes partent alors depuis une machine relais de ton réseau."
            action={
              <button className="btn-primary" onClick={() => setAddOpen(true)}>
                <Plus size={15} />
                Ajouter un BMC
              </button>
            }
          />
        </div>
      )}

      <div className="space-y-4">
        {bmcs.map((bmc: any) => (
          <BmcPanel key={bmc.id} bmc={bmc} onSel={setSelLog} onDiagnostic={setDiagnostic} />
        ))}
      </div>

      <AddBmcModal open={addOpen} onClose={() => setAddOpen(false)} />

      <Modal
        open={!!diagnostic}
        onClose={() => setDiagnostic(null)}
        title={`Diagnostic · ${diagnostic?.name ?? ''}`}
        width="max-w-2xl"
      >
        <DiagnosticSteps steps={diagnostic?.steps ?? []} />
      </Modal>

      <Modal
        open={!!selLog}
        onClose={() => setSelLog(null)}
        title={`Journal matériel · ${selLog?.name ?? ''}`}
        width="max-w-3xl"
      >
        {(selLog?.entries ?? []).length === 0 ? (
          <p className="text-sm text-ink-500 py-8 text-center">Journal vide — aucun évènement matériel.</p>
        ) : (
          <div className="space-y-1 max-h-[60vh] overflow-y-auto">
            {selLog!.entries.map((entry: any, index: number) => (
              <div
                key={index}
                className={clsx(
                  'flex items-start gap-2.5 rounded-lg px-2.5 py-1.5 text-[12px]',
                  entry.severity === 'critical' ? 'bg-danger/[0.07]' : 'bg-ink-850',
                )}
              >
                <StatusDot status={entry.severity === 'critical' ? 'offline' : 'online'} size={5} />
                <span className="text-ink-500 font-mono shrink-0">{entry.time ?? '—'}</span>
                <span className="text-mist-300 flex-1">{entry.message}</span>
              </div>
            ))}
          </div>
        )}
      </Modal>
    </Page>
  )
}

function BmcPanel({
  bmc,
  onSel,
  onDiagnostic,
}: {
  bmc: any
  onSel: (log: { name: string; entries: any[] }) => void
  onDiagnostic: (diag: { name: string; steps: any[] }) => void
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const confirm = useConfirm()
  const toast = useToast()
  const queryClient = useQueryClient()

  const live = useLive.getState().samples[bmc.id] ?? {}
  const info = live.bmc ?? bmc.bmc ?? {}
  const temps: Record<string, number> = live.temps ?? bmc.temps ?? {}
  const fans: Record<string, number> = live.fans ?? bmc.fans ?? {}
  const on = info.power_state === 'on'

  const power = async (action: (typeof POWER_ACTIONS)[number]) => {
    const ok = await confirm({
      title: `${action.label} — ${bmc.name} ?`,
      message: (
        <>
          {action.hint}. La commande passe par le contrôleur hors-bande et s'applique{' '}
          <b className="text-mist-100">immédiatement</b>, indépendamment de l'état du système.
          {action.id === 'off' && (
            <span className="block mt-2 text-warn">
              Une coupure forcée peut corrompre les systèmes de fichiers montés en écriture.
            </span>
          )}
        </>
      ),
      confirmLabel: action.label,
      danger: action.danger,
    })
    if (!ok) return
    setBusy(action.id)
    try {
      await post(`/ipmi/${bmc.id}/power/${action.id}`)
      toast(`${action.label} envoyé à ${bmc.name}`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['ipmi'] }), 3000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const showSel = async () => {
    setBusy('sel')
    try {
      const entries = await get(`/ipmi/${bmc.id}/sel?limit=80`)
      onSel({ name: bmc.name, entries })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const identify = async () => {
    setBusy('identify')
    try {
      await post(`/ipmi/${bmc.id}/identify?on=true`)
      toast('LED de localisation allumée', 'ok')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const test = async () => {
    setBusy('test')
    try {
      const result = await post(`/ipmi/${bmc.id}/test`)
      toast(result.detail, result.ok ? 'ok' : 'danger')
      // En cas d'échec, le détail par étape vaut mieux qu'un message unique.
      if (result.steps?.length) onDiagnostic({ name: bmc.name, steps: result.steps })
      queryClient.invalidateQueries({ queryKey: ['ipmi'] })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const remove = async () => {
    const ok = await confirm({
      title: 'Retirer ce contrôleur ?',
      message: (
        <>
          <b className="text-mist-100">{bmc.name}</b> ne sera plus supervisé. Le serveur lui-même n'est pas
          affecté.
        </>
      ),
      confirmLabel: 'Retirer',
      danger: true,
    })
    if (!ok) return
    await del(`/ipmi/${bmc.id}`)
    queryClient.invalidateQueries({ queryKey: ['ipmi'] })
    toast('Contrôleur retiré', 'ok')
  }

  const hottest = Object.entries(temps).sort((a, b) => b[1] - a[1])[0]

  return (
    <div className="panel">
      <header className="flex flex-wrap items-center gap-3 px-4 py-3 border-b border-ink-750">
        <div
          className={clsx(
            'w-10 h-10 rounded-lg grid place-items-center shrink-0 border',
            on ? 'bg-accent/12 border-accent/25 text-accent' : 'bg-ink-800 border-ink-700 text-ink-500',
          )}
        >
          <Server size={19} />
        </div>
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <StatusDot status={bmc.status} />
            <h2 className="font-semibold text-mist-100">{bmc.name}</h2>
            <Badge tone={on ? 'ok' : 'neutral'}>{on ? 'sous tension' : 'hors tension'}</Badge>
            <Badge tone="info">{bmc.mode === 'ipmitool' ? 'ipmitool' : 'Redfish'}</Badge>
            {info.health && info.health !== 'OK' && <Badge tone="danger">{info.health}</Badge>}
          </div>
          <p className="text-[12px] text-ink-500 font-mono mt-1">
            {bmc.bmc_address ?? bmc.address}
            {info.model && ` · ${info.manufacturer ?? ''} ${info.model}`}
            {info.bmc_firmware && ` · BMC ${info.bmc_firmware}`}
          </p>
        </div>

        <div className="flex-1" />

        <div className="flex items-center gap-1.5 flex-wrap">
          {bmc.server && (
            <Link to={`/hosts/${bmc.server.id}`} className="btn-ghost">
              <ExternalLink size={14} />
              Voir l'OS
            </Link>
          )}
          <button className="btn-ghost" onClick={test} disabled={busy === 'test'}>
            {busy === 'test' ? <Spinner size={14} /> : <Wifi size={15} />}
            Tester
          </button>
          <button className="btn-ghost" onClick={showSel} disabled={busy === 'sel'}>
            {busy === 'sel' ? <Spinner size={14} /> : <ScrollText size={15} />}
            Journal
          </button>
          <button className="btn-ghost" onClick={identify} disabled={busy === 'identify'} title="Allumer la LED">
            <Lightbulb size={15} />
          </button>
          <button className="btn-icon hover:text-danger" onClick={remove} title="Retirer">
            <Trash2 size={14} />
          </button>
        </div>
      </header>

      <div className="p-4 grid grid-cols-1 xl:grid-cols-[320px,1fr] gap-4">
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-2">
            <Tile label="Alimentation" value={on ? 'Allumé' : 'Éteint'} tone={on ? 'ok' : 'neutral'} />
            <Tile
              label="Consommation"
              value={info.power_watts ? `${num(info.power_watts, 0)} W` : '—'}
              icon={<Zap size={13} />}
            />
            <Tile
              label="Plus chaud"
              value={hottest ? `${num(hottest[1], 0)} °C` : '—'}
              sub={hottest?.[0]}
              tone={hottest && hottest[1] >= 80 ? 'danger' : hottest && hottest[1] >= 65 ? 'warn' : 'ok'}
              icon={<Thermometer size={13} />}
            />
            <Tile
              label="Ventilateurs"
              value={Object.keys(fans).length ? `${Object.keys(fans).length}` : '—'}
              sub={
                Object.keys(fans).length
                  ? `${Math.round(Math.max(...Object.values(fans)))} rpm max`
                  : undefined
              }
              icon={<Fan size={13} />}
            />
          </div>

          <div className="space-y-1.5">
            <div className="metric-label">Alimentation</div>
            <div className="grid grid-cols-2 gap-1.5">
              {POWER_ACTIONS.map((action) => {
                const disabled = (action.id === 'on' && on) || (action.id !== 'on' && !on)
                return (
                  <button
                    key={action.id}
                    onClick={() => power(action)}
                    disabled={disabled || busy === action.id}
                    className={clsx(
                      action.danger ? 'btn-danger' : 'btn-primary',
                      'py-1.5 text-xs justify-start',
                    )}
                    title={action.hint}
                  >
                    {busy === action.id ? (
                      <Spinner size={12} />
                    ) : action.id === 'on' ? (
                      <Power size={13} />
                    ) : action.id === 'restart' || action.id === 'cycle' ? (
                      <RotateCcw size={13} />
                    ) : (
                      <Power size={13} />
                    )}
                    {action.label}
                  </button>
                )
              })}
            </div>
          </div>

          {(info.serial || info.cpu_model || info.mem_total) && (
            <div className="bg-ink-800/40 rounded-lg p-2.5 space-y-1">
              <div className="metric-label">Matériel vu par le BMC</div>
              {[
                ['Modèle', info.model],
                ['Série', info.serial],
                ['BIOS', info.bios],
                ['Processeur', info.cpu_model],
                ['Cœurs', info.cpu_count],
                ['Mémoire', info.mem_total ? bytes(info.mem_total) : null],
              ]
                .filter(([, value]) => value)
                .map(([label, value]) => (
                  <div key={String(label)} className="flex justify-between text-[11px]">
                    <span className="text-ink-500">{label}</span>
                    <span className="text-mist-300 font-mono truncate ml-2">{String(value)}</span>
                  </div>
                ))}
            </div>
          )}
        </div>

        <div className="space-y-4">
          {Object.keys(temps).length > 0 ? (
            <>
              <div>
                <SectionTitle>Capteurs thermiques</SectionTitle>
                <div className="grid gap-2 grid-cols-[repeat(auto-fill,minmax(150px,1fr))]">
                  {Object.entries(temps)
                    .sort((a, b) => b[1] - a[1])
                    .map(([name, value]) => (
                      <div key={name} className="bg-ink-800/40 rounded-lg px-2.5 py-1.5">
                        <div className="metric-label truncate" title={name}>
                          {name}
                        </div>
                        <div
                          className="metric-value text-sm mt-0.5"
                          style={{ color: severity(value, 70, 85).color }}
                        >
                          {num(value, 0)} °C
                        </div>
                      </div>
                    ))}
                </div>
              </div>

              <div className="panel bg-ink-900/40 p-3">
                <div className="metric-label mb-1">Température et consommation</div>
                <LiveChart
                  hostId={bmc.id}
                  height={150}
                  format={(v) => v.toFixed(0)}
                  specs={[
                    { label: 'Temp. max', metric: 'temp.cpu', color: PALETTE[4] },
                    { label: 'Puissance', metric: 'power.total', color: PALETTE[3], fill: false },
                  ]}
                />
              </div>
            </>
          ) : (
            <div className="grid place-items-center py-10 text-sm text-ink-500">
              {bmc.status === 'offline'
                ? 'Contrôleur injoignable — vérifie l’adresse et les identifiants.'
                : 'Première collecte en cours…'}
            </div>
          )}

          {Object.keys(fans).length > 0 && (
            <div>
              <SectionTitle>Ventilateurs</SectionTitle>
              <div className="grid gap-2 grid-cols-[repeat(auto-fill,minmax(150px,1fr))]">
                {Object.entries(fans).map(([name, value]) => (
                  <div key={name} className="bg-ink-800/40 rounded-lg px-2.5 py-1.5">
                    <div className="metric-label truncate" title={name}>
                      {name}
                    </div>
                    <div className="metric-value text-sm mt-0.5">{num(value, 0)} rpm</div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {(info.psus ?? []).length > 0 && (
            <div>
              <SectionTitle>Alimentations</SectionTitle>
              <div className="space-y-1">
                {info.psus.map((psu: any, index: number) => (
                  <div
                    key={index}
                    className="flex items-center gap-2.5 bg-ink-800/40 rounded-lg px-2.5 py-1.5 text-[12px]"
                  >
                    <StatusDot status={psu.status === 'OK' ? 'online' : 'offline'} size={6} />
                    <span className="text-mist-200 flex-1 truncate">{psu.name}</span>
                    {psu.input != null && <span className="metric-value text-xs">{psu.input} W</span>}
                    <Badge tone={psu.status === 'OK' ? 'ok' : 'danger'}>{psu.status ?? '—'}</Badge>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function Tile({
  label,
  value,
  sub,
  tone = 'neutral',
  icon,
}: {
  label: string
  value: string
  sub?: string
  tone?: 'ok' | 'warn' | 'danger' | 'neutral'
  icon?: React.ReactNode
}) {
  const colors = { ok: 'text-accent', warn: 'text-warn', danger: 'text-danger', neutral: 'text-mist-100' }
  return (
    <div className="bg-ink-800/40 rounded-lg px-2.5 py-2">
      <div className="metric-label flex items-center gap-1">
        {icon}
        {label}
      </div>
      <div className={clsx('metric-value text-base mt-0.5', colors[tone])}>{value}</div>
      {sub && <div className="text-[10px] text-ink-600 truncate">{sub}</div>}
    </div>
  )
}

function AddBmcModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [form, setForm] = useState({
    name: '',
    address: '',
    port: 443,
    credential_id: '',
    mode: 'redfish' as 'redfish' | 'ipmitool',
    secure: true,
    proxy_host_id: '',
    server_host_id: '',
  })
  const [busy, setBusy] = useState(false)
  const [steps, setSteps] = useState<any[] | null>(null)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data: credentials = [] } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
    enabled: open,
  })

  const runDiagnostic = async () => {
    setBusy(true)
    setSteps(null)
    try {
      const result = await post('/ipmi/diagnose', {
        address: form.address,
        port: Number(form.port),
        credential_id: Number(form.credential_id),
        secure: form.secure,
      })
      setSteps(result.steps)
      toast(
        result.ok ? 'Contrôleur joignable' : 'Le diagnostic a échoué — voir le détail',
        result.ok ? 'ok' : 'danger',
      )
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }
  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })
  const sshHosts = hosts.filter((h: any) => ['linux', 'docker'].includes(h.kind))

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      await post('/ipmi', {
        name: form.name || form.address,
        address: form.address,
        port: Number(form.port),
        credential_id: Number(form.credential_id),
        mode: form.mode,
        secure: form.secure,
        proxy_host_id: form.proxy_host_id ? Number(form.proxy_host_id) : null,
        server_host_id: form.server_host_id ? Number(form.server_host_id) : null,
      })
      toast('Contrôleur ajouté — première interrogation en cours', 'ok')
      queryClient.invalidateQueries({ queryKey: ['ipmi'] })
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
      title="Ajouter un contrôleur BMC"
      width="max-w-xl"
      footer={
        <>
          <button
            className="btn-ghost"
            onClick={runDiagnostic}
            disabled={busy || !form.address || !form.credential_id || form.mode !== 'redfish'}
          >
            {busy ? <Spinner size={14} /> : <Wifi size={15} />}
            Diagnostiquer
          </button>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button
            className="btn-primary"
            form="add-bmc"
            type="submit"
            disabled={busy || !form.address || !form.credential_id}
          >
            {busy ? <Spinner /> : <Plus size={15} />}
            Ajouter
          </button>
        </>
      }
    >
      <form id="add-bmc" onSubmit={submit} className="space-y-4">
        <div className="space-y-1.5">
          <label>Mode de dialogue</label>
          <div className="grid grid-cols-2 gap-2">
            {(
              [
                ['redfish', 'Redfish (HTTPS)', 'ASUS ASMB9/10, Supermicro X11+, iDRAC, iLO'],
                ['ipmitool', 'ipmitool (relais SSH)', 'BMC anciens ou Redfish désactivé'],
              ] as const
            ).map(([value, label, hint]) => (
              <button
                key={value}
                type="button"
                onClick={() => setForm({ ...form, mode: value, port: value === 'redfish' ? 443 : 623 })}
                className={clsx(
                  'rounded-lg border px-3 py-2 text-left transition-colors',
                  form.mode === value
                    ? 'border-accent/40 bg-accent/[0.07]'
                    : 'border-ink-750 bg-ink-850 hover:border-ink-600',
                )}
              >
                <div className="text-[13px] text-mist-100">{label}</div>
                <div className="text-[10px] text-ink-600 mt-0.5">{hint}</div>
              </button>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5 col-span-2">
            <label>Adresse du BMC</label>
            <input
              value={form.address}
              onChange={(e) => setForm({ ...form, address: e.target.value })}
              placeholder="192.168.1.90"
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
              placeholder="asus-bmc"
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Identifiants BMC</label>
            <select
              value={form.credential_id}
              onChange={(e) => setForm({ ...form, credential_id: e.target.value })}
              required
              className="w-full"
            >
              <option value="">— choisir —</option>
              {credentials.map((cred: any) => (
                <option key={cred.id} value={cred.id}>
                  {cred.name} {cred.username ? `· ${cred.username}` : ''}
                </option>
              ))}
            </select>
          </div>
        </div>

        <p className="text-[11px] text-ink-500 -mt-1">
          Compte du contrôleur lui-même (souvent <span className="font-mono text-mist-300">admin</span>), pas
          celui du système. Enregistre-le dans Réglages → Identifiants, type « mot de passe ».
        </p>

        {form.mode === 'ipmitool' && (
          <div className="space-y-1.5">
            <label>Machine relais</label>
            <select
              value={form.proxy_host_id}
              onChange={(e) => setForm({ ...form, proxy_host_id: e.target.value })}
              required
              className="w-full"
            >
              <option value="">— choisir un hôte Linux —</option>
              {sshHosts.map((host: any) => (
                <option key={host.id} value={host.id}>
                  {host.name} ({host.address})
                </option>
              ))}
            </select>
            <p className="text-[11px] text-ink-500">
              MBA y exécute <span className="font-mono text-mist-300">ipmitool -I lanplus</span> ; le paquet
              doit y être installé.
            </p>
          </div>
        )}

        <div className="space-y-1.5">
          <label>Système correspondant (optionnel)</label>
          <select
            value={form.server_host_id}
            onChange={(e) => setForm({ ...form, server_host_id: e.target.value })}
            className="w-full"
          >
            <option value="">— aucun —</option>
            {hosts
              .filter((h: any) => h.kind !== 'ipmi')
              .map((host: any) => (
                <option key={host.id} value={host.id}>
                  {host.name} ({host.address})
                </option>
              ))}
          </select>
          <p className="text-[11px] text-ink-500">
            Relier le BMC à l'OS supervisé permet de passer de l'un à l'autre en un clic.
          </p>
        </div>
      </form>
    </Modal>
  )
}
