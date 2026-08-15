import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Boxes,
  Cpu,
  Download,
  Eraser,
  Gauge as GaugeIcon,
  Plus,
  Send,
  Server,
  Sparkles,
  Square,
  Thermometer,
  Trash2,
  Zap,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { LiveChart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Bar, Empty, Gauge, Modal, Spinner, StatusDot, useConfirm, useToast } from '@/components/ui'
import { del, get, post, sse } from '@/lib/api'
import { bitrate, bytes, duration, percent, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

export function AiPage() {
  const [addOpen, setAddOpen] = useState(false)
  const [pullOpen, setPullOpen] = useState<number | null>(null)
  const queryClient = useQueryClient()
  useLive((s) => s.bump)

  const { data, isLoading } = useQuery({
    queryKey: ['ai-overview'],
    queryFn: () => get('/ai/overview'),
    refetchInterval: 10000,
  })

  const endpoints = data?.endpoints ?? []
  const accelerators = data?.accelerators ?? []
  const summary = data?.summary ?? {}

  return (
    <Page>
      <PageHeader
        title="IA & accélérateurs"
        subtitle={`${summary.endpoints_online ?? 0} endpoint(s) en ligne · ${summary.models_total ?? 0} modèle(s) · ${summary.models_loaded ?? 0} chargé(s)`}
        actions={
          <button className="btn-primary" onClick={() => setAddOpen(true)}>
            <Plus size={15} />
            Ajouter un endpoint
          </button>
        }
      />

      {isLoading && <div className="panel p-12 grid place-items-center"><Spinner size={22} /></div>}

      {accelerators.length > 0 && (
        <section className="mb-5">
          <SectionTitle right={<span className="text-xs text-ink-500">{accelerators.length} GPU/APU</span>}>
            Accélérateurs
          </SectionTitle>
          <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(390px,1fr))]">
            {accelerators.map((gpu: any, index: number) => (
              <AcceleratorCard key={`${gpu.host_id}-${gpu.card}-${index}`} gpu={gpu} />
            ))}
          </div>
        </section>
      )}

      <section>
        <SectionTitle>Endpoints Ollama</SectionTitle>
        {endpoints.length === 0 && !isLoading ? (
          <div className="panel">
            <Empty
              icon={<Sparkles size={36} />}
              title="Aucun endpoint IA"
              hint="Déclare l'URL d'un serveur Ollama (par exemple http://10.0.0.5:11434) pour suivre ses modèles, leur occupation mémoire, et dialoguer directement depuis cette page."
              action={
                <button className="btn-primary" onClick={() => setAddOpen(true)}>
                  <Plus size={15} />
                  Ajouter un endpoint
                </button>
              }
            />
          </div>
        ) : (
          <div className="space-y-4">
            {endpoints.map((endpoint: any) => (
              <div key={endpoint.id} className="space-y-3">
                <EndpointPanel
                  endpoint={endpoint}
                  onPull={() => setPullOpen(endpoint.id)}
                  onChanged={() => queryClient.invalidateQueries({ queryKey: ['ai-overview'] })}
                />
                {endpoint.host_id && <HostVitals hostId={endpoint.host_id} name={endpoint.host_name} />}
              </div>
            ))}
          </div>
        )}
      </section>

      <AddEndpointModal open={addOpen} onClose={() => setAddOpen(false)} />
      <PullModal endpointId={pullOpen} onClose={() => setPullOpen(null)} />
    </Page>
  )
}

// ------------------------------------------------------------- accélérateurs
function AcceleratorCard({ gpu }: { gpu: any }) {
  const powerPct = gpu.power_cap ? (gpu.power / gpu.power_cap) * 100 : 0
  const memTotal = gpu.unified ? gpu.gtt_total || gpu.vram_total : gpu.vram_total
  const memUsed = gpu.unified ? gpu.gtt_used + gpu.vram_used : gpu.vram_used
  const memPct = memTotal ? (memUsed / memTotal) * 100 : gpu.vram_percent

  return (
    <div className="panel p-4 space-y-3.5">
      <div className="flex items-start gap-2.5">
        <div className="w-8 h-8 rounded-lg bg-violet/15 border border-violet/25 grid place-items-center shrink-0">
          <Zap size={16} className="text-violet" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="text-sm font-medium text-mist-100 truncate">{gpu.host_name}</div>
          <div className="text-[11px] text-ink-600 truncate">{gpu.cpu_model ?? gpu.card}</div>
        </div>
        {gpu.unified && <Badge tone="violet">Mémoire unifiée</Badge>}
      </div>

      <div className="flex items-center justify-around">
        <Gauge value={gpu.busy} label="Occupation" size={84} />
        <Gauge value={memPct} label="Mémoire" sub={bytes(memUsed)} size={84} warn={80} crit={93} />
        <div className="flex flex-col items-center gap-1">
          <div className="h-[84px] flex flex-col items-center justify-center gap-1">
            <div className="flex items-baseline gap-1">
              <Thermometer size={14} style={{ color: severity(gpu.temp, 75, 90).color }} />
              <span className="metric-value text-lg" style={{ color: severity(gpu.temp, 75, 90).color }}>
                {gpu.temp.toFixed(0)}
              </span>
              <span className="text-xs text-ink-500">°C</span>
            </div>
            {gpu.power > 0 && (
              <div className="text-[11px] text-ink-500 font-mono">
                {gpu.power.toFixed(1)} W{gpu.power_cap ? ` / ${gpu.power_cap.toFixed(0)}` : ''}
              </div>
            )}
          </div>
          <span className="metric-label">Thermique</span>
        </div>
      </div>

      {gpu.power_cap > 0 && (
        <div className="space-y-1">
          <div className="flex justify-between">
            <span className="metric-label">Enveloppe de puissance</span>
            <span className="metric-value text-[11px]">{percent(powerPct, 0)}</span>
          </div>
          <Bar value={powerPct} height={4} warn={85} crit={97} />
        </div>
      )}

      <div className="grid grid-cols-2 gap-2 text-[11px]">
        <Stat label="Fréquence GPU" value={gpu.sclk ? `${gpu.sclk} MHz` : '—'} />
        <Stat label="Fréquence mémoire" value={gpu.mclk ? `${gpu.mclk} MHz` : '—'} />
        <Stat label="VRAM dédiée" value={`${bytes(gpu.vram_used)} / ${bytes(gpu.vram_total)}`} />
        <Stat label="GTT (partagée)" value={gpu.gtt_total ? `${bytes(gpu.gtt_used)} / ${bytes(gpu.gtt_total)}` : '—'} />
      </div>

      {gpu.host_id && (
        <div className="-mx-1">
          <LiveChart
            hostId={gpu.host_id}
            height={100}
            showLegend={false}
            format={(v) => `${v.toFixed(0)}%`}
            yRange={[0, 100]}
            specs={[
              { label: 'GPU', metric: 'gpu.busy', color: PALETTE[2] },
              { label: 'VRAM', metric: 'gpu.vram_percent', color: PALETTE[5] },
            ]}
          />
        </div>
      )}
    </div>
  )
}

/** Santé de la machine qui sert les modèles : l'inférence est autant limitée
 *  par le CPU, la RAM et le disque que par le GPU. */
function HostVitals({ hostId, name }: { hostId: number; name?: string }) {
  useLive((s) => s.bump)
  const sample = useLive.getState().samples[hostId] ?? {}
  const meta = sample.meta ?? {}
  const filesystems = sample.filesystems ?? []
  const hasData = sample['cpu.usage'] !== undefined

  return (
    <div className="panel p-4 space-y-3.5">
      <div className="flex items-center gap-2 flex-wrap">
        <Server size={15} className="text-ink-500" />
        <h3 className="text-sm font-semibold text-mist-200">
          Machine hôte{name ? ` · ${name}` : ''}
        </h3>
        {meta.os && <Badge>{meta.os}</Badge>}
        {sample.uptime ? (
          <span className="text-[11px] text-ink-600">actif depuis {duration(sample.uptime)}</span>
        ) : null}
        <div className="flex-1" />
        <Link to={`/hosts/${hostId}`} className="text-xs text-ink-500 hover:text-accent">
          Fiche complète →
        </Link>
      </div>

      {!hasData ? (
        <p className="text-xs text-ink-600 py-4 text-center">
          Aucune métrique système : relie cet endpoint à un hôte supervisé en SSH pour suivre CPU,
          mémoire et disque pendant l'inférence.
        </p>
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-around gap-5">
            <Gauge value={sample['cpu.usage'] ?? 0} label="Processeur" size={78}
                   sub={meta.cpu_count ? `${meta.cpu_count} cœurs` : undefined} />
            <Gauge value={sample['mem.percent'] ?? 0} label="Mémoire" size={78}
                   sub={sample['mem.total'] ? bytes(sample['mem.used']) : undefined} />
            <Gauge value={sample['disk.percent'] ?? 0} label="Stockage" size={78}
                   sub={sample['disk.total'] ? bytes(sample['disk.total']) : undefined} />
            {sample['swap.percent'] !== undefined && (
              <Gauge value={sample['swap.percent']} label="Swap" size={78} warn={40} crit={70} />
            )}
            {sample['temp.cpu'] !== undefined && (
              <div className="flex flex-col items-center gap-1">
                <div className="h-[78px] flex items-center">
                  <span className="metric-value text-xl"
                        style={{ color: severity(sample['temp.cpu'], 70, 85).color }}>
                    {sample['temp.cpu'].toFixed(0)}°
                  </span>
                </div>
                <span className="metric-label">Température</span>
              </div>
            )}
            {sample['load.1'] !== undefined && (
              <div className="flex flex-col items-center gap-1">
                <div className="h-[78px] flex items-center gap-2">
                  {(['load.1', 'load.5', 'load.15'] as const).map((key, index) => (
                    <div key={key} className="flex flex-col items-center">
                      <span className="metric-value text-sm" style={{ color: PALETTE[index] }}>
                        {(sample[key] ?? 0).toFixed(2)}
                      </span>
                      <span className="text-[9px] text-ink-600">{key.split('.')[1]}m</span>
                    </div>
                  ))}
                </div>
                <span className="metric-label">Charge</span>
              </div>
            )}
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-3 gap-3">
            <div>
              <div className="metric-label mb-1">Processeur</div>
              <LiveChart
                hostId={hostId}
                height={110}
                showLegend={false}
                format={(v) => `${v.toFixed(0)}%`}
                yRange={[0, 100]}
                specs={[
                  { label: 'Utilisateur', metric: 'cpu.user', color: PALETTE[0] },
                  { label: 'Système', metric: 'cpu.system', color: PALETTE[3] },
                ]}
              />
            </div>
            <div>
              <div className="metric-label mb-1">Mémoire</div>
              <LiveChart
                hostId={hostId}
                height={110}
                showLegend={false}
                format={(v) => `${v.toFixed(0)}%`}
                yRange={[0, 100]}
                specs={[{ label: 'RAM', metric: 'mem.percent', color: PALETTE[1] }]}
              />
            </div>
            <div>
              <div className="metric-label mb-1">Disque (chargement des modèles)</div>
              <LiveChart
                hostId={hostId}
                height={110}
                showLegend={false}
                format={(v) => bitrate(Math.abs(v))}
                specs={[
                  { label: 'Lecture', metric: 'disk.read', color: PALETTE[0] },
                  { label: 'Écriture', metric: 'disk.write', color: PALETTE[4], negative: true },
                ]}
              />
            </div>
          </div>

          {filesystems.length > 0 && (
            <div className="flex flex-wrap gap-2">
              {filesystems.slice(0, 4).map((fs: any) => (
                <div key={fs.mount} className="bg-ink-800/40 rounded-lg px-2.5 py-1.5 min-w-[140px]">
                  <div className="flex items-baseline justify-between gap-2">
                    <span className="text-[11px] font-mono text-mist-300 truncate">{fs.mount}</span>
                    <span className="metric-value text-[11px]" style={{ color: severity(fs.percent).color }}>
                      {percent(fs.percent, 0)}
                    </span>
                  </div>
                  <Bar value={fs.percent} height={3} className="mt-1" />
                  <div className="text-[9px] text-ink-600 mt-0.5">{bytes(fs.available)} libres</div>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-ink-800/50 rounded-lg px-2.5 py-1.5">
      <div className="metric-label">{label}</div>
      <div className="metric-value text-xs mt-0.5">{value}</div>
    </div>
  )
}

// ------------------------------------------------------------------ endpoints
function EndpointPanel({
  endpoint,
  onPull,
  onChanged,
}: {
  endpoint: any
  onPull: () => void
  onChanged: () => void
}) {
  const [chatOpen, setChatOpen] = useState(false)
  const [chatModel, setChatModel] = useState<string>('')
  const toast = useToast()
  const confirm = useConfirm()

  const models = endpoint.models ?? []
  const loaded = endpoint.loaded ?? []
  const loadedNames = new Set(loaded.map((m: any) => m.name))

  const removeModel = async (name: string) => {
    const ok = await confirm({
      title: 'Supprimer ce modèle ?',
      message: (
        <>
          <b className="text-mist-100">{name}</b> sera effacé du disque de {endpoint.name}. Il faudra le retélécharger
          pour l'utiliser à nouveau.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    try {
      await del(`/ai/endpoints/${endpoint.id}/models/${encodeURIComponent(name)}`)
      toast('Modèle supprimé', 'ok')
      onChanged()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    }
  }

  const unload = async (name: string) => {
    try {
      await post(`/ai/endpoints/${endpoint.id}/unload/${encodeURIComponent(name)}`)
      toast(`${name} déchargé de la mémoire`, 'ok')
      onChanged()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    }
  }

  const removeEndpoint = async () => {
    const ok = await confirm({
      title: "Retirer cet endpoint ?",
      message: `${endpoint.name} ne sera plus surveillé. Les modèles ne sont pas touchés.`,
      confirmLabel: 'Retirer',
      danger: true,
    })
    if (!ok) return
    await del(`/ai/endpoints/${endpoint.id}`)
    onChanged()
  }

  return (
    <div className="panel">
      <header className="flex flex-wrap items-center gap-2.5 px-4 py-3 border-b border-ink-750">
        <StatusDot status={endpoint.status} />
        <div className="min-w-0">
          <div className="text-sm font-medium text-mist-100 truncate">{endpoint.name}</div>
          <div className="text-[11px] text-ink-600 font-mono truncate">
            {endpoint.url}
            {endpoint.version && ` · v${endpoint.version}`}
            {endpoint.host_name && ` · ${endpoint.host_name}`}
          </div>
        </div>
        <div className="flex-1" />
        {endpoint.error && <span className="text-[11px] text-danger truncate max-w-xs">{endpoint.error}</span>}
        <Badge>{models.length} modèles</Badge>
        {loaded.length > 0 && <Badge tone="ok">{loaded.length} en mémoire</Badge>}
        <button
          className="btn-ghost"
          onClick={() => {
            setChatModel(loaded[0]?.name ?? models[0]?.name ?? '')
            setChatOpen(true)
          }}
          disabled={models.length === 0}
        >
          <Sparkles size={14} />
          Dialoguer
        </button>
        <button className="btn-ghost" onClick={onPull}>
          <Download size={14} />
          Télécharger
        </button>
        <button className="btn-icon hover:text-danger" onClick={removeEndpoint} title="Retirer l'endpoint">
          <Trash2 size={14} />
        </button>
      </header>

      {loaded.length > 0 && (
        <div className="px-4 py-3 border-b border-ink-800 bg-accent/[0.03]">
          <div className="metric-label mb-2">Chargés en mémoire</div>
          <div className="grid gap-2 grid-cols-[repeat(auto-fill,minmax(260px,1fr))]">
            {loaded.map((model: any) => (
              <div key={model.name} className="flex items-center gap-2.5 bg-ink-850 rounded-lg px-3 py-2">
                <Cpu size={14} className="text-accent shrink-0" />
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-100 truncate">{model.name}</div>
                  <div className="text-[10px] text-ink-600 font-mono">
                    {bytes(model.size_vram)} en VRAM
                    {model.expires_at && ` · expire ${new Date(model.expires_at).toLocaleTimeString('fr-FR')}`}
                  </div>
                </div>
                <button className="btn-icon" onClick={() => unload(model.name)} title="Décharger de la mémoire">
                  <Eraser size={13} />
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {models.length === 0 ? (
        <p className="px-4 py-6 text-sm text-ink-500 text-center">
          {endpoint.status === 'online' ? 'Aucun modèle installé.' : 'Endpoint injoignable.'}
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[560px]">
            <thead>
              <tr className="text-left border-b border-ink-800">
                {['Modèle', 'Famille', 'Paramètres', 'Quantization', 'Taille', ''].map((header) => (
                  <th key={header} className="metric-label px-4 py-2 font-semibold">
                    {header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {models.map((model: any) => (
                <tr key={model.name} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
                  <td className="px-4 py-2">
                    <div className="flex items-center gap-2">
                      {loadedNames.has(model.name) && <StatusDot status="online" size={6} />}
                      <span className="text-mist-100 font-mono text-[13px]">{model.name}</span>
                    </div>
                  </td>
                  <td className="px-4 py-2 text-xs text-mist-400">{model.family ?? '—'}</td>
                  <td className="px-4 py-2 text-xs text-mist-400">{model.parameters ?? '—'}</td>
                  <td className="px-4 py-2">
                    {model.quantization ? <Badge tone="info">{model.quantization}</Badge> : '—'}
                  </td>
                  <td className="px-4 py-2 metric-value text-xs">{bytes(model.size)}</td>
                  <td className="px-4 py-2">
                    <div className="flex justify-end gap-1">
                      <button
                        className="btn-icon"
                        title="Dialoguer avec ce modèle"
                        onClick={() => {
                          setChatModel(model.name)
                          setChatOpen(true)
                        }}
                      >
                        <Sparkles size={13} />
                      </button>
                      <button className="btn-icon hover:text-danger" onClick={() => removeModel(model.name)} title="Supprimer">
                        <Trash2 size={13} />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <ChatModal
        open={chatOpen}
        onClose={() => setChatOpen(false)}
        endpoint={endpoint}
        model={chatModel}
        onModelChange={setChatModel}
      />
    </div>
  )
}

// ----------------------------------------------------------------- dialogue
interface Message {
  role: 'user' | 'assistant'
  content: string
  stats?: { tokens: number; tps: number; total: number }
}

function ChatModal({
  open,
  onClose,
  endpoint,
  model,
  onModelChange,
}: {
  open: boolean
  onClose: () => void
  endpoint: any
  model: string
  onModelChange: (model: string) => void
}) {
  const [messages, setMessages] = useState<Message[]>([])
  const [input, setInput] = useState('')
  const [streaming, setStreaming] = useState(false)
  const abort = useRef<AbortController | null>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const toast = useToast()

  useEffect(() => {
    scroller.current?.scrollTo({ top: scroller.current.scrollHeight, behavior: 'smooth' })
  }, [messages])

  const send = async () => {
    const text = input.trim()
    if (!text || streaming || !model) return
    const history: Message[] = [...messages, { role: 'user', content: text }]
    setMessages([...history, { role: 'assistant', content: '' }])
    setInput('')
    setStreaming(true)
    abort.current = new AbortController()

    try {
      let content = ''
      let stats: Message['stats']
      for await (const chunk of sse(
        `/ai/endpoints/${endpoint.id}/chat`,
        { model, messages: history.map(({ role, content }) => ({ role, content })) },
        abort.current.signal,
      )) {
        if (chunk.error) throw new Error(chunk.error)
        if (chunk.message?.content) {
          content += chunk.message.content
          setMessages([...history, { role: 'assistant', content }])
        }
        if (chunk.done && chunk.eval_count) {
          const seconds = (chunk.eval_duration ?? 1) / 1e9
          stats = {
            tokens: chunk.eval_count,
            tps: chunk.eval_count / (seconds || 1),
            total: (chunk.total_duration ?? 0) / 1e9,
          }
        }
      }
      setMessages([...history, { role: 'assistant', content, stats }])
    } catch (exc: any) {
      if (exc.name !== 'AbortError') toast(exc.message, 'danger')
    } finally {
      setStreaming(false)
      abort.current = null
    }
  }

  const stop = () => abort.current?.abort()

  return (
    <Modal
      open={open}
      onClose={onClose}
      width="max-w-3xl"
      title={
        <div className="flex items-center gap-2.5">
          <Sparkles size={16} className="text-accent" />
          <span>Dialogue</span>
          <select
            value={model}
            onChange={(e) => onModelChange(e.target.value)}
            className="text-xs py-1 font-mono"
            onClick={(e) => e.stopPropagation()}
          >
            {(endpoint.models ?? []).map((m: any) => (
              <option key={m.name} value={m.name}>
                {m.name}
              </option>
            ))}
          </select>
        </div>
      }
      footer={
        <div className="flex items-end gap-2 w-full">
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                send()
              }
            }}
            rows={2}
            placeholder="Écris ton message… (Entrée pour envoyer, Maj+Entrée pour un retour à la ligne)"
            className="flex-1 resize-none text-sm"
          />
          {streaming ? (
            <button className="btn-danger h-[38px]" onClick={stop}>
              <Square size={14} />
              Stop
            </button>
          ) : (
            <button className="btn-primary h-[38px]" onClick={send} disabled={!input.trim()}>
              <Send size={15} />
            </button>
          )}
        </div>
      }
    >
      <div ref={scroller} className="space-y-3 min-h-[38vh] max-h-[52vh] overflow-y-auto">
        {messages.length === 0 && (
          <p className="text-sm text-ink-500 text-center py-14">
            Teste un modèle directement depuis la console, sans quitter le monitoring.
          </p>
        )}
        {messages.map((message, index) => (
          <div key={index} className={clsx('flex', message.role === 'user' ? 'justify-end' : 'justify-start')}>
            <div
              className={clsx(
                'rounded-xl px-3.5 py-2.5 max-w-[85%] text-[13px] leading-relaxed whitespace-pre-wrap break-words',
                message.role === 'user'
                  ? 'bg-accent/12 border border-accent/25 text-mist-100'
                  : 'bg-ink-800 border border-ink-750 text-mist-200',
              )}
            >
              {message.content || <Spinner size={13} className="text-ink-500" />}
              {message.stats && (
                <div className="mt-2 pt-2 border-t border-ink-700 flex items-center gap-3 text-[10px] text-ink-500 font-mono">
                  <span className="flex items-center gap-1">
                    <GaugeIcon size={10} />
                    {message.stats.tps.toFixed(1)} tok/s
                  </span>
                  <span>{message.stats.tokens} tokens</span>
                  <span>{message.stats.total.toFixed(1)} s</span>
                </div>
              )}
            </div>
          </div>
        ))}
      </div>
    </Modal>
  )
}

// ---------------------------------------------------------- téléchargement
function PullModal({ endpointId, onClose }: { endpointId: number | null; onClose: () => void }) {
  const [model, setModel] = useState('')
  const [status, setStatus] = useState('')
  const [progress, setProgress] = useState(0)
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()

  const start = async () => {
    if (!model.trim() || !endpointId) return
    setBusy(true)
    setProgress(0)
    try {
      for await (const chunk of sse(`/ai/endpoints/${endpointId}/pull`, { model: model.trim() })) {
        if (chunk.error) throw new Error(chunk.error)
        if (chunk.status) setStatus(chunk.status)
        if (chunk.total && chunk.completed) setProgress((chunk.completed / chunk.total) * 100)
      }
      toast(`${model} téléchargé`, 'ok')
      queryClient.invalidateQueries({ queryKey: ['ai-overview'] })
      setModel('')
      setStatus('')
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={endpointId !== null}
      onClose={busy ? () => {} : onClose}
      title="Télécharger un modèle"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose} disabled={busy}>
            Fermer
          </button>
          <button className="btn-primary" onClick={start} disabled={busy || !model.trim()}>
            {busy ? <Spinner /> : <Download size={15} />}
            Télécharger
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="space-y-1.5">
          <label>Nom du modèle</label>
          <input
            value={model}
            onChange={(e) => setModel(e.target.value)}
            placeholder="llama3.2:3b"
            className="w-full font-mono"
            disabled={busy}
          />
          <p className="text-[11px] text-ink-500">
            Utilise la nomenclature Ollama, par exemple <code className="text-mist-300">qwen2.5-coder:14b</code> ou{' '}
            <code className="text-mist-300">gemma3:12b</code>.
          </p>
        </div>

        <div className="flex flex-wrap gap-1.5">
          {['llama3.2:3b', 'qwen2.5-coder:7b', 'gemma3:12b', 'mistral-small', 'nomic-embed-text'].map((suggestion) => (
            <button
              key={suggestion}
              onClick={() => setModel(suggestion)}
              disabled={busy}
              className="chip border-ink-700 bg-ink-800 text-mist-400 hover:text-accent hover:border-accent/40 font-mono"
            >
              {suggestion}
            </button>
          ))}
        </div>

        {busy && (
          <div className="space-y-2">
            <div className="flex justify-between text-xs">
              <span className="text-mist-400">{status || 'Préparation…'}</span>
              <span className="metric-value">{progress.toFixed(0)}%</span>
            </div>
            <Bar value={progress} height={6} warn={101} crit={102} />
          </div>
        )}
      </div>
    </Modal>
  )
}

// -------------------------------------------------------------- ajout endpoint
function AddEndpointModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [form, setForm] = useState({ name: '', url: 'http://', host_id: '' })
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()
  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      await post('/ai/endpoints', {
        name: form.name || form.url,
        url: form.url,
        host_id: form.host_id ? Number(form.host_id) : null,
      })
      toast('Endpoint ajouté', 'ok')
      queryClient.invalidateQueries({ queryKey: ['ai-overview'] })
      setForm({ name: '', url: 'http://', host_id: '' })
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
      title="Ajouter un endpoint Ollama"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" form="add-ai" type="submit" disabled={busy}>
            {busy ? <Spinner /> : <Plus size={15} />}
            Ajouter
          </button>
        </>
      }
    >
      <form id="add-ai" onSubmit={submit} className="space-y-4">
        <div className="space-y-1.5">
          <label>URL de l'API</label>
          <input
            value={form.url}
            onChange={(e) => setForm({ ...form, url: e.target.value })}
            placeholder="http://10.0.0.5:11434"
            required
            className="w-full font-mono"
          />
          <p className="text-[11px] text-ink-500">
            Ollama doit écouter sur le réseau : <code className="text-mist-300">OLLAMA_HOST=0.0.0.0:11434</code>.
          </p>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="Strix Halo"
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Machine hôte</label>
            <select value={form.host_id} onChange={(e) => setForm({ ...form, host_id: e.target.value })} className="w-full">
              <option value="">— aucune —</option>
              {hosts.map((host: any) => (
                <option key={host.id} value={host.id}>
                  {host.name}
                </option>
              ))}
            </select>
          </div>
        </div>
        <p className="text-[11px] text-ink-500 flex items-start gap-1.5">
          <Boxes size={13} className="mt-0.5 shrink-0" />
          Lier l'endpoint à une machine permet de corréler l'usage des modèles avec la charge GPU, la VRAM et la
          consommation électrique de cette machine.
        </p>
      </form>
    </Modal>
  )
}
