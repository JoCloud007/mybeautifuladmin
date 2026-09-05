import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Bot,
  Check,
  ChevronDown,
  CircleAlert,
  Eye,
  History,
  Lightbulb,
  Pause,
  Play,
  Plus,
  Trash2,
  Wand2,
  X,
  Zap,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Empty,
  Modal,
  Spinner,
  StatTile,
  Tabs,
  useConfirm,
  useToast,
} from '@/components/ui'
import { del, get, patch, post } from '@/lib/api'
import { ago, datetime, duration } from '@/lib/format'

type Tab = 'agents' | 'pending' | 'history'

const MODE_META: Record<string, { label: string; tone: 'neutral' | 'info' | 'warn'; icon: typeof Eye }> = {
  observe: { label: 'Observation', tone: 'neutral', icon: Eye },
  suggest: { label: 'Proposition', tone: 'info', icon: Lightbulb },
  auto: { label: 'Autonome', tone: 'warn', icon: Zap },
}

const SEVERITY_TONE: Record<string, 'danger' | 'warn' | 'info' | 'neutral'> = {
  critical: 'danger',
  high: 'danger',
  medium: 'warn',
  low: 'info',
}

export function AgentsPage() {
  const [tab, setTab] = useState<Tab>('agents')
  const [editing, setEditing] = useState<any | null>(null)
  const [creating, setCreating] = useState(false)
  const [historyOf, setHistoryOf] = useState<any | null>(null)
  const [running, setRunning] = useState<number | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['agents'],
    queryFn: () => get('/agents'),
    refetchInterval: 15000,
  })
  const { data: catalog } = useQuery({ queryKey: ['agents-catalog'], queryFn: () => get('/agents/catalog') })

  const agents = data?.agents ?? []
  const pending = data?.pending ?? []
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['agents'] })

  const runNow = async (agent: any) => {
    setRunning(agent.id)
    try {
      const result = await post(`/agents/${agent.id}/run`)
      if (result.status === 'failed') {
        toast(`${agent.name} : ${result.error}`, 'danger')
      } else {
        toast(
          `${agent.name} — ${result.proposals} proposition(s)` +
            (result.executed ? `, ${result.executed} exécutée(s)` : ''),
          'ok',
        )
      }
      setHistoryOf(agent)
      refresh()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setRunning(null)
    }
  }

  const decide = async (proposal: any, approve: boolean) => {
    if (approve) {
      const ok = await confirm({
        title: 'Exécuter cette action ?',
        message: (
          <>
            <b className="text-mist-100">{proposal.label}</b> sur{' '}
            <b className="text-mist-100">{proposal.host_name}</b>.
            <span className="block mt-2 text-mist-400">« {proposal.reason} »</span>
            <span className="block mt-2 text-ink-500">
              Proposée par l'agent {proposal.agent_name}. L'action est tracée dans le journal.
            </span>
          </>
        ),
        confirmLabel: 'Exécuter',
        danger: ['high', 'critical'].includes(proposal.severity),
      })
      if (!ok) return
    }
    try {
      await post(`/agents/proposals/${proposal.id}/decide`, { approve })
      toast(approve ? 'Action exécutée' : 'Proposition écartée', approve ? 'ok' : 'info')
      refresh()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    }
  }

  const toggle = async (agent: any) => {
    await patch(`/agents/${agent.id}`, { enabled: !agent.enabled })
    refresh()
  }

  const remove = async (agent: any) => {
    const ok = await confirm({
      title: 'Supprimer cet agent ?',
      message: (
        <>
          <b className="text-mist-100">{agent.name}</b>, son historique et ses propositions en
          attente seront supprimés.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await del(`/agents/${agent.id}`)
    toast('Agent supprimé', 'ok')
    refresh()
  }

  const autonomous = agents.filter((a: any) => a.mode === 'auto' && a.enabled).length
  const noEndpoint = (catalog?.endpoints ?? []).length === 0

  return (
    <Page>
      <PageHeader
        title="Agents IA"
        subtitle="Des agents spécialisés analysent l'infra et proposent — ou appliquent — les corrections"
        actions={
          <button className="btn-primary" onClick={() => setCreating(true)} disabled={noEndpoint}>
            <Plus size={15} />
            Nouvel agent
          </button>
        }
      />

      {noEndpoint && (
        <div className="panel mb-4">
          <Empty
            icon={<Bot size={38} />}
            title="Aucun endpoint IA configuré"
            hint="Les agents s'appuient sur un modèle local. Déclare d'abord ton serveur Ollama dans la page « IA & accélérateurs », puis reviens créer un agent."
            action={
              <a href="/ai" className="btn-primary">
                Configurer Ollama
              </a>
            }
          />
        </div>
      )}

      {!noEndpoint && (
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-5">
          <StatTile label="Agents" value={agents.length} sub={`${agents.filter((a: any) => a.enabled).length} actif(s)`} icon={<Bot size={20} />} />
          <StatTile
            label="En attente de validation"
            value={pending.length}
            tone={pending.length ? 'warn' : 'ok'}
            icon={<Lightbulb size={20} />}
            onClick={() => setTab('pending')}
          />
          <StatTile
            label="Mode autonome"
            value={autonomous}
            sub="agents qui agissent seuls"
            tone={autonomous ? 'warn' : 'neutral'}
            icon={<Zap size={20} />}
          />
          <StatTile
            label="Modèles disponibles"
            value={(catalog?.endpoints ?? []).reduce((n: number, e: any) => n + (e.models?.length ?? 0), 0)}
            sub={`${(catalog?.endpoints ?? []).length} endpoint(s)`}
            icon={<Wand2 size={20} />}
          />
        </div>
      )}

      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'agents', label: 'Agents', badge: <Badge>{agents.length}</Badge> },
            {
              id: 'pending',
              label: 'À valider',
              badge: pending.length ? <Badge tone="warn">{pending.length}</Badge> : undefined,
            },
            { id: 'history', label: 'Exécutions' },
          ]}
        />
      </div>

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {tab === 'agents' && !isLoading && (
        <>
          {agents.length === 0 && !noEndpoint && (
            <div className="panel">
              <Empty
                icon={<Bot size={38} />}
                title="Aucun agent"
                hint="Crée un agent spécialisé — exploitation, mises à jour, sécurité ou sauvegardes — et choisis son niveau d'autonomie."
                action={
                  <button className="btn-primary" onClick={() => setCreating(true)}>
                    <Plus size={15} />
                    Créer un agent
                  </button>
                }
              />
            </div>
          )}
          <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(360px,1fr))]">
            {agents.map((agent: any) => {
              const mode = MODE_META[agent.mode] ?? MODE_META.observe
              const ModeIcon = mode.icon
              return (
                <div
                  key={agent.id}
                  className={clsx('panel panel-hover p-4 space-y-3', !agent.enabled && 'opacity-60')}
                >
                  <div className="flex items-start gap-2.5">
                    <div
                      className={clsx(
                        'w-8 h-8 rounded-lg grid place-items-center shrink-0 border',
                        agent.mode === 'auto'
                          ? 'bg-warn/12 border-warn/25 text-warn'
                          : 'bg-accent/12 border-accent/25 text-accent',
                      )}
                    >
                      {agent.running ? <Spinner size={15} /> : <Bot size={16} />}
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="text-sm font-medium text-mist-100 truncate">{agent.name}</div>
                      <div className="text-[11px] text-ink-600 truncate">
                        {catalog?.roles?.[agent.role]?.label ?? agent.role} · {agent.model}
                      </div>
                    </div>
                    <Badge tone={mode.tone}>
                      <ModeIcon size={10} />
                      {mode.label}
                    </Badge>
                  </div>

                  {agent.description && (
                    <p className="text-[12px] text-mist-400 line-clamp-2">{agent.description}</p>
                  )}

                  <div className="grid grid-cols-3 gap-2 text-center">
                    <div>
                      <div className="metric-label">Périmètre</div>
                      <div className="metric-value text-sm">{agent.scope_count}</div>
                    </div>
                    <div>
                      <div className="metric-label">À valider</div>
                      <div className={clsx('metric-value text-sm', agent.pending && 'text-warn')}>
                        {agent.pending}
                      </div>
                    </div>
                    <div>
                      <div className="metric-label">Dernière</div>
                      <div
                        className={clsx(
                          'metric-value text-sm',
                          agent.last_status === 'success' && 'text-accent',
                          agent.last_status === 'failed' && 'text-danger',
                        )}
                      >
                        {agent.last_run ? (agent.last_status ?? '—') : 'jamais'}
                      </div>
                    </div>
                  </div>

                  <div className="flex flex-wrap gap-1">
                    {(agent.allowed_actions ?? []).slice(0, 4).map((action: string) => (
                      <Badge key={action}>{catalog?.actions?.[action]?.label ?? action}</Badge>
                    ))}
                    {(agent.allowed_actions ?? []).length === 0 && (
                      <span className="text-[11px] text-ink-600">Analyse seule</span>
                    )}
                  </div>

                  <div className="flex items-center justify-between text-[10px] text-ink-600 font-mono">
                    <span>{agent.cron || 'manuel'}</span>
                    {agent.last_run && <span>lancé {ago(agent.last_run)}</span>}
                  </div>

                  <div className="flex items-center gap-1 pt-1 border-t border-ink-800">
                    <button
                      className="btn-icon"
                      onClick={() => toggle(agent)}
                      title={agent.enabled ? 'Suspendre' : 'Activer'}
                    >
                      {agent.enabled ? <Pause size={14} /> : <Play size={14} />}
                    </button>
                    <button
                      className="btn-icon"
                      onClick={() => runNow(agent)}
                      disabled={running === agent.id || agent.running}
                      title="Lancer une analyse"
                    >
                      {running === agent.id ? <Spinner size={13} /> : <Zap size={14} />}
                    </button>
                    <button className="btn-ghost py-1 px-2 text-xs" onClick={() => setHistoryOf(agent)}>
                      <History size={12} />
                      Historique
                    </button>
                    <div className="flex-1" />
                    <button className="btn-ghost py-1 px-2 text-xs" onClick={() => setEditing(agent)}>
                      Modifier
                    </button>
                    <button className="btn-icon hover:text-danger" onClick={() => remove(agent)}>
                      <Trash2 size={14} />
                    </button>
                  </div>
                </div>
              )
            })}
          </div>
        </>
      )}

      {tab === 'pending' && (
        <div className="panel divide-y divide-ink-800/60">
          {pending.length === 0 && (
            <Empty
              icon={<Check size={34} />}
              title="Rien à valider"
              hint="Les agents en mode « proposition » déposent ici les actions qu'ils recommandent."
            />
          )}
          {pending.map((proposal: any) => (
            <div key={proposal.id} className="flex items-start gap-3 px-4 py-3 hover:bg-ink-800/30">
              <Badge tone={SEVERITY_TONE[proposal.severity] ?? 'neutral'} className="mt-0.5 shrink-0">
                {proposal.severity}
              </Badge>
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-100">
                  {proposal.label}
                  <span className="text-ink-500"> — {proposal.host_name}</span>
                </div>
                {proposal.reason && (
                  <div className="text-[12px] text-mist-400 mt-0.5">« {proposal.reason} »</div>
                )}
                <div className="text-[10px] text-ink-600 mt-1">
                  {proposal.agent_name} · {ago(proposal.created_at)}
                  {Object.keys(proposal.params ?? {}).length > 0 && (
                    <span className="font-mono ml-2">{JSON.stringify(proposal.params)}</span>
                  )}
                </div>
              </div>
              <div className="flex items-center gap-1.5 shrink-0">
                <button className="btn-primary py-1 px-2.5 text-xs" onClick={() => decide(proposal, true)}>
                  <Check size={13} />
                  Exécuter
                </button>
                <button className="btn-icon hover:text-danger" onClick={() => decide(proposal, false)} title="Écarter">
                  <X size={15} />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {tab === 'history' && (
        <div className="space-y-3">
          {agents.length === 0 && <div className="panel"><Empty icon={<History size={32} />} title="Aucun agent" /></div>}
          {agents.map((agent: any) => (
            <button
              key={agent.id}
              onClick={() => setHistoryOf(agent)}
              className="panel panel-hover p-3.5 w-full flex items-center gap-3 text-left"
            >
              <Bot size={16} className="text-ink-500 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-100">{agent.name}</div>
                <div className="text-[11px] text-ink-600">
                  {agent.last_run ? `dernière exécution ${ago(agent.last_run)}` : 'jamais exécuté'}
                </div>
              </div>
              <Badge tone={agent.last_status === 'success' ? 'ok' : agent.last_status === 'failed' ? 'danger' : 'neutral'}>
                {agent.last_status ?? '—'}
              </Badge>
              <ChevronDown size={14} className="text-ink-500 -rotate-90" />
            </button>
          ))}
        </div>
      )}

      <AgentModal
        open={creating || !!editing}
        agent={editing}
        catalog={catalog}
        onClose={() => {
          setCreating(false)
          setEditing(null)
        }}
        onSaved={refresh}
      />
      <HistoryModal agent={historyOf} onClose={() => setHistoryOf(null)} onChanged={refresh} />
    </Page>
  )
}

function HistoryModal({
  agent,
  onClose,
  onChanged,
}: {
  agent: any | null
  onClose: () => void
  onChanged: () => void
}) {
  const { data: runs = [], isLoading } = useQuery({
    queryKey: ['agent-runs', agent?.id],
    queryFn: () => get(`/agents/${agent.id}/runs?limit=15`),
    enabled: !!agent,
    refetchInterval: agent ? 10000 : false,
  })

  return (
    <Modal open={!!agent} onClose={onClose} title={`Exécutions · ${agent?.name ?? ''}`} width="max-w-3xl">
      {isLoading ? (
        <div className="py-10 grid place-items-center">
          <Spinner size={20} />
        </div>
      ) : runs.length === 0 ? (
        <Empty icon={<History size={32} />} title="Aucune exécution" />
      ) : (
        <div className="space-y-3 max-h-[64vh] overflow-y-auto">
          {runs.map((run: any) => (
            <div key={run.id} className="panel bg-ink-900/40 p-3 space-y-2">
              <div className="flex items-center gap-2 flex-wrap">
                <Badge tone={run.status === 'success' ? 'ok' : run.status === 'failed' ? 'danger' : 'warn'}>
                  {run.status}
                </Badge>
                <span className="text-[11px] text-ink-500">{datetime(run.started_at)}</span>
                <span className="text-[11px] text-ink-600">{run.trigger}</span>
                {run.duration_s != null && (
                  <span className="text-[11px] text-ink-600 font-mono">{duration(run.duration_s)}</span>
                )}
              </div>

              {run.error && <div className="text-[12px] text-danger">{run.error}</div>}
              {run.summary && <div className="text-[13px] text-mist-100">{run.summary}</div>}
              {run.analysis && (
                <p className="text-[12px] text-mist-400 leading-relaxed whitespace-pre-wrap">
                  {run.analysis}
                </p>
              )}

              {(run.proposals ?? []).length > 0 && (
                <div className="space-y-1 pt-1 border-t border-ink-800">
                  {run.proposals.map((proposal: any) => (
                    <div key={proposal.id} className="flex items-center gap-2 text-[12px]">
                      <Badge
                        tone={
                          proposal.state === 'executed'
                            ? 'ok'
                            : proposal.state === 'rejected' || proposal.state === 'failed'
                              ? 'danger'
                              : proposal.state === 'observed'
                                ? 'neutral'
                                : 'warn'
                        }
                      >
                        {proposal.state}
                      </Badge>
                      <span className="text-mist-200">{proposal.label}</span>
                      <span className="text-ink-500">{proposal.host_name}</span>
                      <span className="text-ink-600 truncate flex-1">{proposal.reason}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </Modal>
  )
}

function AgentModal({
  open,
  agent,
  catalog,
  onClose,
  onSaved,
}: {
  open: boolean
  agent: any | null
  catalog: any
  onClose: () => void
  onSaved: () => void
}) {
  const empty = {
    name: '',
    description: '',
    role: 'ops',
    endpoint_id: '' as string | number,
    model: '',
    system_prompt: '',
    mode: 'suggest',
    scope_kind: 'all',
    scope_value: '',
    allowed_actions: [] as string[],
    max_actions: 3,
    cron: '',
    enabled: true,
  }
  const [form, setForm] = useState(empty)
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<any | null>(null)
  const toast = useToast()
  const hasInit = useRef(false)

  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })
  const { data: inventory } = useQuery({ queryKey: ['inventory'], queryFn: () => get('/inventory'), enabled: open })

  // Initialise le formulaire une seule fois par ouverture de modal.
  // Le parent re-fetch agents toutes les 15 s : sans cette garde, la nouvelle
  // référence de l'objet agent réinitialiserait le formulaire en pleine saisie.
  useEffect(() => {
    if (!open) {
      hasInit.current = false
      return
    }
    if (hasInit.current) return
    hasInit.current = true
    setPreview(null)
    if (agent) {
      setForm({
        ...empty,
        ...agent,
        endpoint_id: agent.endpoint_id ?? '',
        description: agent.description ?? '',
        system_prompt: agent.system_prompt ?? '',
        scope_value: agent.scope_value ?? '',
        cron: agent.cron ?? '',
        allowed_actions: agent.allowed_actions ?? [],
      })
    } else {
      const first = (catalog?.endpoints ?? [])[0]
      setForm({
        ...empty,
        endpoint_id: first?.id ?? '',
        model: first?.models?.[0] ?? '',
        allowed_actions: catalog?.roles?.ops?.actions ?? [],
      })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [agent, open, catalog])

  const endpoint = (catalog?.endpoints ?? []).find((e: any) => String(e.id) === String(form.endpoint_id))
  const models: string[] = endpoint?.models ?? []

  const payload = () => ({
    name: form.name || 'Agent',
    description: form.description || null,
    role: form.role,
    endpoint_id: Number(form.endpoint_id),
    model: form.model,
    system_prompt: form.system_prompt || null,
    mode: form.mode,
    scope_kind: form.scope_kind,
    scope_value: form.scope_kind === 'all' ? null : form.scope_value,
    allowed_actions: form.allowed_actions,
    max_actions: Number(form.max_actions),
    cron: form.cron || null,
    enabled: form.enabled,
  })

  const applyRole = (role: string) => {
    const preset = catalog?.roles?.[role]
    setForm((f) => ({
      ...f,
      role,
      allowed_actions: preset?.actions ?? [],
      description: f.description || preset?.description || '',
    }))
  }

  const runPreview = async () => {
    try {
      setPreview(await post('/agents/preview', payload()))
    } catch (exc: any) {
      toast(exc.message, 'danger')
    }
  }

  const save = async () => {
    setBusy(true)
    try {
      if (agent) await patch(`/agents/${agent.id}`, payload())
      else await post('/agents', payload())
      toast(agent ? 'Agent mis à jour' : 'Agent créé', 'ok')
      onSaved()
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const toggleAction = (name: string) =>
    setForm((f) => ({
      ...f,
      allowed_actions: f.allowed_actions.includes(name)
        ? f.allowed_actions.filter((a) => a !== name)
        : [...f.allowed_actions, name],
    }))

  // En mode autonome, seules les actions réversibles partent sans validation.
  const autoCapable = form.allowed_actions.filter((a) => catalog?.actions?.[a]?.auto)
  const needsApproval = form.allowed_actions.filter((a) => !catalog?.actions?.[a]?.auto)

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={agent ? "Modifier l'agent" : 'Nouvel agent'}
      width="max-w-3xl"
      footer={
        <>
          <button className="btn-ghost" onClick={runPreview}>
            Aperçu du contexte
          </button>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button
            className="btn-primary"
            onClick={save}
            disabled={busy || !form.name || !form.model || !form.endpoint_id}
          >
            {busy ? <Spinner /> : agent ? 'Enregistrer' : 'Créer'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        {/* Rôle */}
        <div className="space-y-1.5">
          <label>Spécialité</label>
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            {Object.entries(catalog?.roles ?? {}).map(([key, role]: [string, any]) => (
              <button
                key={key}
                type="button"
                onClick={() => applyRole(key)}
                className={clsx(
                  'rounded-lg border px-3 py-2 text-left transition-colors',
                  form.role === key
                    ? 'border-accent/40 bg-accent/[0.07]'
                    : 'border-ink-750 bg-ink-850 hover:border-ink-600',
                )}
              >
                <div className="text-[13px] text-mist-100">{role.label}</div>
                <div className="text-[10px] text-ink-600 mt-0.5 line-clamp-2">{role.description}</div>
              </button>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="Gardien des mises à jour"
              className="w-full"
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

        {/* Modèle */}
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Endpoint IA</label>
            <select
              value={form.endpoint_id}
              onChange={(e) => {
                const next = (catalog?.endpoints ?? []).find((x: any) => String(x.id) === e.target.value)
                setForm({ ...form, endpoint_id: e.target.value, model: next?.models?.[0] ?? '' })
              }}
              className="w-full"
            >
              <option value="">— choisir —</option>
              {(catalog?.endpoints ?? []).map((e: any) => (
                <option key={e.id} value={e.id}>
                  {e.name} ({e.status})
                </option>
              ))}
            </select>
            {!form.endpoint_id && (
              <p className="text-[11px] text-danger">Veuillez sélectionner un endpoint IA.</p>
            )}
          </div>
          <div className="space-y-1.5">
            <label>Modèle</label>
            {models.length > 0 ? (
              <select
                value={form.model}
                onChange={(e) => setForm({ ...form, model: e.target.value })}
                className="w-full font-mono"
              >
                {models.map((m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ))}
              </select>
            ) : (
              <input
                value={form.model}
                onChange={(e) => setForm({ ...form, model: e.target.value })}
                placeholder="qwen2.5:14b"
                className="w-full font-mono"
              />
            )}
            <p className="text-[11px] text-ink-500">
              Un modèle de 7 B suffit pour observer ; vise 14 B ou plus si tu actives les actions.
            </p>
          </div>
        </div>

        {/* Autonomie */}
        <div className="space-y-1.5">
          <label>Niveau d'autonomie</label>
          <div className="grid grid-cols-3 gap-2">
            {Object.entries(catalog?.modes ?? {}).map(([key, help]: [string, any]) => {
              const meta = MODE_META[key]
              const Icon = meta.icon
              return (
                <button
                  key={key}
                  type="button"
                  onClick={() => setForm({ ...form, mode: key })}
                  className={clsx(
                    'rounded-lg border px-3 py-2 text-left transition-colors',
                    form.mode === key
                      ? key === 'auto'
                        ? 'border-warn/50 bg-warn/[0.07]'
                        : 'border-accent/40 bg-accent/[0.07]'
                      : 'border-ink-750 bg-ink-850 hover:border-ink-600',
                  )}
                >
                  <div className="text-[13px] text-mist-100 flex items-center gap-1.5">
                    <Icon size={13} />
                    {meta.label}
                  </div>
                  <div className="text-[10px] text-ink-600 mt-0.5 line-clamp-3">{help}</div>
                </button>
              )
            })}
          </div>
        </div>

        {/* Actions */}
        <div className="space-y-1.5">
          <label>Actions autorisées</label>
          <div className="space-y-1">
            {Object.entries(catalog?.actions ?? {}).map(([name, spec]: [string, any]) => {
              const selected = form.allowed_actions.includes(name)
              return (
                <label
                  key={name}
                  className={clsx(
                    'flex items-start gap-2.5 rounded-lg px-3 py-2 cursor-pointer transition-colors border',
                    selected ? 'bg-accent/[0.07] border-accent/30' : 'bg-ink-850 border-ink-750 hover:border-ink-600',
                  )}
                >
                  <input type="checkbox" checked={selected} onChange={() => toggleAction(name)} className="mt-0.5" />
                  <div className="min-w-0 flex-1">
                    <div className="text-[13px] text-mist-100 normal-case tracking-normal font-normal flex items-center gap-2">
                      {spec.label}
                      {!spec.auto && <Badge tone="warn">validation requise</Badge>}
                    </div>
                    <div className="text-[11px] text-ink-500">{spec.help}</div>
                  </div>
                </label>
              )
            })}
          </div>
        </div>

        {form.mode === 'auto' && (
          <div
            className={clsx(
              'rounded-lg px-3 py-2.5 text-[12px] border',
              needsApproval.length ? 'border-warn/30 bg-warn/[0.06] text-warn' : 'border-accent/25 bg-accent/[0.05] text-mist-300',
            )}
          >
            <div className="flex items-start gap-2">
              <CircleAlert size={14} className="mt-0.5 shrink-0" />
              <div>
                En mode autonome, cet agent exécutera seul :{' '}
                <b>{autoCapable.map((a) => catalog?.actions?.[a]?.label).join(', ') || 'rien'}</b>.
                {needsApproval.length > 0 && (
                  <>
                    {' '}
                    <b>{needsApproval.map((a) => catalog?.actions?.[a]?.label).join(', ')}</b>{' '}
                    resteront soumises à ta validation — elles interrompent un service ou détruisent
                    des données.
                  </>
                )}
              </div>
            </div>
          </div>
        )}

        {/* Périmètre et cadence */}
        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5">
            <label>Périmètre</label>
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
          <div className="space-y-1.5">
            <label>Actions max / exécution</label>
            <input
              type="number"
              min={1}
              max={10}
              value={form.max_actions}
              onChange={(e) => setForm({ ...form, max_actions: Number(e.target.value) })}
              className="w-full"
            />
          </div>
        </div>

        <div className="space-y-1.5">
          <label>Cadence (cron, vide = manuel)</label>
          <div className="flex flex-wrap gap-1.5 mb-1.5">
            {[
              ['', 'Manuel'],
              ['0 * * * *', 'Chaque heure'],
              ['0 7 * * *', 'Chaque matin 7 h'],
              ['0 4 * * 1', 'Lundi 4 h'],
            ].map(([cron, label]) => (
              <button
                key={label}
                type="button"
                onClick={() => setForm({ ...form, cron })}
                className={clsx(
                  'chip transition-colors',
                  form.cron === cron
                    ? 'border-accent/40 bg-accent/10 text-accent'
                    : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
                )}
              >
                {label}
              </button>
            ))}
          </div>
          <input
            value={form.cron}
            onChange={(e) => setForm({ ...form, cron: e.target.value })}
            placeholder="min heure jour mois jour-semaine"
            className="w-full font-mono"
          />
        </div>

        <div className="space-y-1.5">
          <label>Invite système (vide = celle du rôle)</label>
          <textarea
            value={form.system_prompt}
            onChange={(e) => setForm({ ...form, system_prompt: e.target.value })}
            rows={4}
            placeholder={catalog?.roles?.[form.role]?.prompt ?? ''}
            className="w-full text-[12px] leading-relaxed"
          />
        </div>

        {preview && (
          <div className="panel bg-ink-900/60 p-3 space-y-2">
            <SectionTitle>Aperçu</SectionTitle>
            <div className="text-[12px] text-mist-300">
              <b className="text-mist-100">{preview.hosts.length}</b> machine(s) dans le périmètre ·{' '}
              contexte de <b className="text-mist-100">{Math.round(preview.estimated_chars / 1000)} k</b>{' '}
              caractères
            </div>
            <details className="text-[11px]">
              <summary className="cursor-pointer text-ink-500 hover:text-mist-300">
                Voir l'invite système
              </summary>
              <pre className="mt-2 whitespace-pre-wrap text-mist-400 font-mono max-h-52 overflow-y-auto">
                {preview.system_prompt}
              </pre>
            </details>
          </div>
        )}
      </div>
    </Modal>
  )
}
