import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { Bot, History, Pause, Play, Plus, ShieldCheck, Trash2, TriangleAlert, Wand2, Zap } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Modal, Spinner, StatTile, Tabs, useConfirm, useToast } from '@/components/ui'
import { del, get, patch, post } from '@/lib/api'
import { ago, datetime, duration } from '@/lib/format'

type Tab = 'rules' | 'history'

export function RemediationPage() {
  const [tab, setTab] = useState<Tab>('rules')
  const [editing, setEditing] = useState<any | null>(null)
  const [creating, setCreating] = useState(false)
  const [running, setRunning] = useState<number | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['remediation'],
    queryFn: () => get('/remediation'),
    refetchInterval: 20000,
  })
  const { data: catalog } = useQuery({
    queryKey: ['remediation-catalog'],
    queryFn: () => get('/remediation/catalog'),
  })

  const rules = data?.rules ?? []
  const runs = data?.runs ?? []
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['remediation'] })

  const runNow = async (rule: any) => {
    const ok = await confirm({
      title: 'Appliquer cette règle maintenant ?',
      message: (
        <>
          <b className="text-mist-100">{rule.name}</b> va évaluer ses cibles et appliquer{' '}
          <b className="text-mist-100">{rule.action_label}</b> sur celles qui correspondent.
        </>
      ),
      confirmLabel: 'Appliquer',
      danger: rule.allow_destructive,
    })
    if (!ok) return
    setRunning(rule.id)
    try {
      const result = await post(`/remediation/${rule.id}/run`)
      toast(
        result.applied
          ? `${result.applied} remédiation(s) appliquée(s) sur ${result.matched} cible(s)`
          : `Aucune cible ne correspond${result.note ? ` — ${result.note}` : ''}`,
        result.applied ? 'ok' : 'info',
      )
      refresh()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setRunning(null)
    }
  }

  const toggle = async (rule: any) => {
    await patch(`/remediation/${rule.id}`, { enabled: !rule.enabled })
    refresh()
  }

  const remove = async (rule: any) => {
    const ok = await confirm({
      title: 'Supprimer cette règle ?',
      message: (
        <>
          <b className="text-mist-100">{rule.name}</b> et son historique seront supprimés.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await del(`/remediation/${rule.id}`)
    toast('Règle supprimée', 'ok')
    refresh()
  }

  const active = rules.filter((r: any) => r.enabled).length
  const destructive = rules.filter((r: any) => r.allow_destructive && r.enabled).length
  const last24 = runs.filter(
    (r: any) => new Date(r.started_at).getTime() > Date.now() - 86400000,
  ).length

  return (
    <Page>
      <PageHeader
        title="Auto-remédiation"
        subtitle="Des règles qui corrigent d'elles-mêmes, sous conditions et avec quotas"
        actions={
          <button className="btn-primary" onClick={() => setCreating(true)}>
            <Plus size={15} />
            Nouvelle règle
          </button>
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
        <StatTile label="Règles" value={rules.length} sub={`${active} active(s)`} icon={<Wand2 size={20} />} />
        <StatTile label="Exécutions (24 h)" value={last24} icon={<Zap size={20} />} onClick={() => setTab('history')} />
        <StatTile
          label="Actions destructives"
          value={destructive}
          sub="règles autorisées à interrompre"
          tone={destructive ? 'warn' : 'ok'}
          icon={<TriangleAlert size={20} />}
        />
        <StatTile
          label="Réussites"
          value={runs.filter((r: any) => r.status === 'success').length}
          sub={`sur ${runs.length} exécution(s)`}
          tone="ok"
          icon={<ShieldCheck size={20} />}
        />
      </div>

      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'rules', label: 'Règles', badge: <Badge>{rules.length}</Badge> },
            { id: 'history', label: 'Historique' },
          ]}
        />
      </div>

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {tab === 'rules' && !isLoading && (
        <>
          {rules.length === 0 && (
            <div className="panel">
              <Empty
                icon={<Wand2 size={38} />}
                title="Aucune règle d'auto-remédiation"
                hint="Une règle observe une condition — machine injoignable, service en panne, disque plein — attend qu'elle persiste, puis applique la correction. Tu peux aussi confier le diagnostic à un agent IA."
                action={
                  <button className="btn-primary" onClick={() => setCreating(true)}>
                    <Plus size={15} />
                    Créer une règle
                  </button>
                }
              />
            </div>
          )}

          <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(370px,1fr))]">
            {rules.map((rule: any) => (
              <div
                key={rule.id}
                className={clsx('panel panel-hover p-4 space-y-3', !rule.enabled && 'opacity-60')}
              >
                <div className="flex items-start gap-2.5">
                  <div
                    className={clsx(
                      'w-8 h-8 rounded-lg grid place-items-center shrink-0 border',
                      rule.allow_destructive
                        ? 'bg-warn/12 border-warn/25 text-warn'
                        : 'bg-accent/12 border-accent/25 text-accent',
                    )}
                  >
                    {rule.action === 'run_agent' ? <Bot size={16} /> : <Wand2 size={16} />}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-medium text-mist-100 truncate">{rule.name}</div>
                    <div className="text-[11px] text-ink-600 truncate">
                      {rule.trigger_label} → {rule.action_label}
                    </div>
                  </div>
                  {rule.allow_destructive && <Badge tone="warn">destructif</Badge>}
                </div>

                {rule.description && (
                  <p className="text-[12px] text-mist-400 line-clamp-2">{rule.description}</p>
                )}

                <div className="grid grid-cols-3 gap-2 text-center">
                  <div>
                    <div className="metric-label">Confirmation</div>
                    <div className="metric-value text-sm">{duration(rule.confirm_seconds)}</div>
                  </div>
                  <div>
                    <div className="metric-label">Repos</div>
                    <div className="metric-value text-sm">{duration(rule.cooldown_seconds)}</div>
                  </div>
                  <div>
                    <div className="metric-label">Quota / j</div>
                    <div className="metric-value text-sm">
                      {rule.stats?.today ?? 0}/{rule.max_per_day}
                    </div>
                  </div>
                </div>

                <div className="flex items-center justify-between text-[10px] text-ink-600">
                  <span>
                    {rule.scope_kind === 'all' ? 'tout le parc' : `${rule.scope_kind} : ${rule.scope_value}`}
                  </span>
                  {rule.last_run && (
                    <span
                      className={clsx(
                        rule.last_status === 'success' && 'text-accent',
                        rule.last_status === 'failed' && 'text-danger',
                      )}
                    >
                      {rule.last_status} · {ago(rule.last_run)}
                    </span>
                  )}
                </div>

                <div className="flex items-center gap-1 pt-1 border-t border-ink-800">
                  <button
                    className="btn-icon"
                    onClick={() => toggle(rule)}
                    title={rule.enabled ? 'Suspendre' : 'Activer'}
                  >
                    {rule.enabled ? <Pause size={14} /> : <Play size={14} />}
                  </button>
                  <button
                    className="btn-icon"
                    onClick={() => runNow(rule)}
                    disabled={running === rule.id}
                    title="Appliquer maintenant"
                  >
                    {running === rule.id ? <Spinner size={13} /> : <Zap size={14} />}
                  </button>
                  <div className="flex-1" />
                  <button className="btn-ghost py-1 px-2 text-xs" onClick={() => setEditing(rule)}>
                    Modifier
                  </button>
                  <button className="btn-icon hover:text-danger" onClick={() => remove(rule)}>
                    <Trash2 size={14} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </>
      )}

      {tab === 'history' && (
        <div className="panel divide-y divide-ink-800/60">
          {runs.length === 0 && <Empty icon={<History size={34} />} title="Aucune exécution" />}
          {runs.map((run: any) => (
            <div key={run.id} className="flex items-start gap-3 px-4 py-2.5">
              <Badge
                tone={run.status === 'success' ? 'ok' : run.status === 'failed' ? 'danger' : 'warn'}
                className="mt-0.5 shrink-0"
              >
                {run.status}
              </Badge>
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-100">
                  {run.rule_name}
                  {run.host_name && <span className="text-ink-500"> — {run.host_name}</span>}
                </div>
                {run.detail && (
                  <div className="text-[12px] text-mist-400 mt-0.5 break-words">{run.detail}</div>
                )}
                <div className="text-[10px] text-ink-600 mt-0.5">
                  {datetime(run.started_at)} · déclencheur {run.trigger}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      <RuleModal
        open={creating || !!editing}
        rule={editing}
        catalog={catalog}
        onClose={() => {
          setCreating(false)
          setEditing(null)
        }}
        onSaved={refresh}
      />
    </Page>
  )
}

function RuleModal({
  open,
  rule,
  catalog,
  onClose,
  onSaved,
}: {
  open: boolean
  rule: any | null
  catalog: any
  onClose: () => void
  onSaved: () => void
}) {
  const empty = {
    name: '',
    description: '',
    trigger: 'host_offline',
    action: 'notify_only',
    params: {} as Record<string, any>,
    scope_kind: 'all',
    scope_value: '',
    confirm_seconds: 300,
    cooldown_seconds: 1800,
    max_per_day: 3,
    allow_destructive: false,
    enabled: true,
  }
  const [form, setForm] = useState(empty)
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<any | null>(null)
  const toast = useToast()

  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })
  const { data: inventory } = useQuery({ queryKey: ['inventory'], queryFn: () => get('/inventory'), enabled: open })

  const payload = () => ({
    ...form,
    scope_value: form.scope_kind === 'all' ? null : form.scope_value,
    confirm_seconds: Number(form.confirm_seconds),
    cooldown_seconds: Number(form.cooldown_seconds),
    max_per_day: Number(form.max_per_day),
  })

  useEffect(() => {
    if (!open) return
    setPreview(null)
    setForm(rule ? { ...empty, ...rule, params: rule.params ?? {}, scope_value: rule.scope_value ?? '' } : empty)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rule, open])

  useEffect(() => {
    if (!open) return
    const timer = setTimeout(() => {
      // L'aperçu ne dépend pas du nom : on en fournit un pour que la règle
      // encore anonyme soit tout de même évaluable.
      post('/remediation/preview', { ...payload(), name: form.name || 'aperçu' })
        .then(setPreview)
        .catch(() => setPreview(null))
    }, 400)
    return () => clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form, open])

  const actionSpec = catalog?.actions?.[form.action]
  const setParam = (key: string, value: any) =>
    setForm({ ...form, params: { ...form.params, [key]: value } })

  const save = async () => {
    setBusy(true)
    try {
      if (rule) await patch(`/remediation/${rule.id}`, payload())
      else await post('/remediation', payload())
      toast(rule ? 'Règle mise à jour' : 'Règle créée', 'ok')
      onSaved()
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
      title={rule ? 'Modifier la règle' : 'Nouvelle règle de remédiation'}
      width="max-w-2xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" onClick={save} disabled={busy || !form.name}>
            {busy ? <Spinner /> : rule ? 'Enregistrer' : 'Créer'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="Relancer les conteneurs tombés"
              className="w-full"
              autoFocus
            />
          </div>
          <div className="space-y-1.5">
            <label>Description</label>
            <input
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
              className="w-full"
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Quand</label>
            <select
              value={form.trigger}
              onChange={(e) => setForm({ ...form, trigger: e.target.value })}
              className="w-full"
            >
              {Object.entries(catalog?.triggers ?? {}).map(([key, spec]: [string, any]) => (
                <option key={key} value={key}>
                  {spec.label}
                </option>
              ))}
            </select>
            <p className="text-[11px] text-ink-500">{catalog?.triggers?.[form.trigger]?.help}</p>
          </div>
          <div className="space-y-1.5">
            <label>Alors</label>
            <select
              value={form.action}
              onChange={(e) => setForm({ ...form, action: e.target.value, params: {} })}
              className="w-full"
            >
              {Object.entries(catalog?.actions ?? {}).map(([key, spec]: [string, any]) => (
                <option key={key} value={key}>
                  {spec.label}
                  {spec.destructive ? ' (destructif)' : ''}
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* Paramètres de l'action */}
        {(actionSpec?.params ?? []).includes('service') && (
          <div className="space-y-1.5">
            <label>Service systemd</label>
            <input
              value={form.params.service ?? ''}
              onChange={(e) => setParam('service', e.target.value)}
              placeholder="nginx.service"
              className="w-full font-mono"
            />
          </div>
        )}
        {(actionSpec?.params ?? []).includes('agent_id') && (
          <div className="space-y-1.5">
            <label>Agent chargé du diagnostic</label>
            <select
              value={form.params.agent_id ?? ''}
              onChange={(e) => setParam('agent_id', e.target.value)}
              className="w-full"
            >
              <option value="">— choisir —</option>
              {(catalog?.agents ?? []).map((agent: any) => (
                <option key={agent.id} value={agent.id}>
                  {agent.name} ({agent.mode})
                </option>
              ))}
            </select>
            <p className="text-[11px] text-ink-500">
              L'agent analyse la situation et applique ce que son propre mode autorise.
            </p>
          </div>
        )}
        {form.trigger === 'security_finding' && (
          <div className="space-y-1.5">
            <label>Code de constat (vide = tous)</label>
            <input
              value={form.params.code ?? ''}
              onChange={(e) => setParam('code', e.target.value)}
              placeholder="patch.security"
              className="w-full font-mono"
            />
          </div>
        )}
        {form.trigger === 'disk_pressure' && (
          <div className="space-y-1.5">
            <label>Seuil d'occupation (%)</label>
            <input
              type="number"
              min={50}
              max={99}
              value={form.params.threshold ?? 90}
              onChange={(e) => setParam('threshold', Number(e.target.value))}
              className="w-full"
            />
          </div>
        )}

        {actionSpec?.destructive && (
          <label className="flex items-start gap-2.5 rounded-lg border border-warn/30 bg-warn/[0.06] px-3 py-2.5 cursor-pointer">
            <input
              type="checkbox"
              checked={form.allow_destructive}
              onChange={(e) => setForm({ ...form, allow_destructive: e.target.checked })}
              className="mt-0.5"
            />
            <span className="text-[12px] text-warn normal-case tracking-normal font-normal">
              <b>Autoriser cette action destructive.</b> « {actionSpec.label} » interrompt les services
              hébergés. Sans cette case, la règle refusera de s'exécuter.
            </span>
          </label>
        )}

        {/* Portée et garde-fous */}
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Portée</label>
            <select
              value={form.scope_kind}
              onChange={(e) => setForm({ ...form, scope_kind: e.target.value, scope_value: '' })}
              className="w-full"
            >
              <option value="all">Tout le parc</option>
              <option value="tag">Par étiquette</option>
              <option value="kind">Par type</option>
              <option value="host">Un hôte</option>
            </select>
          </div>
          <div className="space-y-1.5">
            <label>Cible</label>
            {form.scope_kind === 'all' ? (
              <input disabled value="tous les hôtes" className="w-full opacity-60" />
            ) : (
              <select
                value={form.scope_value}
                onChange={(e) => setForm({ ...form, scope_value: e.target.value })}
                className="w-full"
              >
                <option value="">— choisir —</option>
                {form.scope_kind === 'host' &&
                  hosts.map((h: any) => (
                    <option key={h.id} value={String(h.id)}>
                      {h.name}
                    </option>
                  ))}
                {form.scope_kind === 'tag' &&
                  (inventory?.tags ?? []).map((t: any) => (
                    <option key={t.tag} value={t.tag}>
                      {t.tag} ({t.count})
                    </option>
                  ))}
                {form.scope_kind === 'kind' &&
                  [...new Set(hosts.map((h: any) => h.kind))].map((k: any) => (
                    <option key={k} value={k}>
                      {k}
                    </option>
                  ))}
              </select>
            )}
          </div>
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5">
            <label>Confirmation (s)</label>
            <input
              type="number"
              min={30}
              step={30}
              value={form.confirm_seconds}
              onChange={(e) => setForm({ ...form, confirm_seconds: Number(e.target.value) })}
              className="w-full"
            />
            <p className="text-[10px] text-ink-600">Durée pendant laquelle la condition doit tenir.</p>
          </div>
          <div className="space-y-1.5">
            <label>Repos (s)</label>
            <input
              type="number"
              min={60}
              step={60}
              value={form.cooldown_seconds}
              onChange={(e) => setForm({ ...form, cooldown_seconds: Number(e.target.value) })}
              className="w-full"
            />
            <p className="text-[10px] text-ink-600">Délai avant une nouvelle tentative.</p>
          </div>
          <div className="space-y-1.5">
            <label>Max / jour</label>
            <input
              type="number"
              min={1}
              max={50}
              value={form.max_per_day}
              onChange={(e) => setForm({ ...form, max_per_day: Number(e.target.value) })}
              className="w-full"
            />
            <p className="text-[10px] text-ink-600">Empêche les rafales sur panne durable.</p>
          </div>
        </div>

        <div className="panel bg-ink-900/60 p-3 space-y-1.5">
          <SectionTitle>Cibles actuelles</SectionTitle>
          {!preview ? (
            <p className="text-xs text-ink-500">Règle incomplète, ou aucune cible.</p>
          ) : preview.count === 0 ? (
            <p className="text-xs text-ink-500">
              Aucune machine ne remplit cette condition en ce moment — c'est plutôt bon signe.
            </p>
          ) : (
            <div className="text-[12px] text-mist-300">
              <b className="text-mist-100">{preview.count}</b> cible(s) :{' '}
              {preview.targets.slice(0, 6).map((t: any) => t.name).join(', ')}
              {preview.count > 6 && ` +${preview.count - 6}`}
            </div>
          )}
        </div>
      </div>
    </Modal>
  )
}
