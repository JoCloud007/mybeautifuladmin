import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { Check, EyeOff, Network, Radar, Server, Shield, Square, Zap } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { TailscaleScan } from '@/components/TailscaleScan'
import { Badge, Empty, Modal, Spinner, Tabs, useToast } from '@/components/ui'
import { del, get, post, wsUrl } from '@/lib/api'
import { KIND_LABEL } from '@/lib/format'

interface Candidate {
  address: string
  hostname?: string | null
  open_ports: number[]
  guessed_kind: string
  evidence: Record<string, any>
  known?: boolean
  host_id?: number | null
  adopted?: boolean
}

const KIND_TONE: Record<string, 'ok' | 'info' | 'violet' | 'warn' | 'neutral'> = {
  linux: 'info',
  proxmox: 'violet',
  synology: 'warn',
  docker: 'ok',
  ollama: 'ok',
  generic: 'neutral',
}

export function DiscoveryPage() {
  const [targets, setTargets] = useState('')
  const [scanning, setScanning] = useState(false)
  const [progress, setProgress] = useState({ done: 0, total: 0 })
  const [found, setFound] = useState<Candidate[]>([])
  const [adopt, setAdopt] = useState<Candidate | null>(null)
  const [tab, setTab] = useState<'network' | 'tailscale'>('network')
  const socket = useRef<WebSocket | null>(null)
  const toast = useToast()
  const queryClient = useQueryClient()

  const { data: suggestions } = useQuery({ queryKey: ['discovery-suggestions'], queryFn: () => get('/discovery/suggestions') })
  const { data: previous = [], refetch } = useQuery({
    queryKey: ['discovery-results'],
    queryFn: () => get('/discovery/results'),
  })

  useEffect(() => {
    if (!targets && suggestions?.subnets?.length) setTargets(suggestions.subnets.join(', '))
  }, [suggestions, targets])

  useEffect(() => () => socket.current?.close(), [])

  const start = () => {
    if (!targets.trim() || scanning) return
    setFound([])
    setProgress({ done: 0, total: 0 })
    setScanning(true)

    const ws = new WebSocket(wsUrl('/discovery/ws'))
    socket.current = ws

    ws.onopen = () => ws.send(JSON.stringify({ targets, concurrency: 384 }))
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data)
      if (message.type === 'progress') setProgress({ done: message.done, total: message.total })
      else if (message.type === 'found') setFound((current) => [...current, message.host])
      else if (message.type === 'done') {
        setFound(message.results)
        setScanning(false)
        toast(`Scan terminé — ${message.count} équipement(s) détecté(s)`, 'ok')
        refetch()
        ws.close()
      } else if (message.type === 'error') {
        toast(message.message, 'danger')
        setScanning(false)
        ws.close()
      }
    }
    ws.onerror = () => {
      toast('Connexion au scanner interrompue', 'danger')
      setScanning(false)
    }
    ws.onclose = () => setScanning(false)
  }

  const stop = () => {
    socket.current?.close()
    setScanning(false)
  }

  const ignore = async (candidate: Candidate) => {
    await post(`/discovery/ignore/${candidate.address}`)
    setFound((current) => current.filter((c) => c.address !== candidate.address))
    refetch()
  }

  const clear = async () => {
    await del('/discovery/results')
    setFound([])
    refetch()
  }

  const results: Candidate[] = found.length > 0 ? found : previous
  const percent = progress.total ? (progress.done / progress.total) * 100 : 0

  return (
    <Page>
      <PageHeader
        title="Découverte réseau"
        subtitle="Balayage TCP et empreinte des services pour identifier automatiquement tes équipements"
        actions={
          tab === 'network' &&
          results.length > 0 && (
            <button className="btn-ghost" onClick={clear}>
              Effacer les résultats
            </button>
          )
        }
      />

      <div className="mb-4">
        <Tabs<'network' | 'tailscale'>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'network', label: <span className="flex items-center gap-1.5"><Network size={14} />Réseau IP</span> },
            { id: 'tailscale', label: <span className="flex items-center gap-1.5"><Shield size={14} />Tailscale</span> },
          ]}
        />
      </div>

      {tab === 'tailscale' && <TailscaleScan onAdopt={(candidate) => setAdopt(candidate)} />}

      {tab === 'network' && (<>
      <div className="panel p-4 mb-5">
        <div className="flex flex-wrap items-end gap-3">
          <div className="flex-1 min-w-[280px] space-y-1.5">
            <label>Cibles</label>
            <input
              value={targets}
              onChange={(e) => setTargets(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && start()}
              placeholder="192.168.1.0/24, 10.0.0.5, 10.0.0.10-10.0.0.40"
              className="w-full font-mono"
              disabled={scanning}
            />
          </div>
          {scanning ? (
            <button className="btn-danger" onClick={stop}>
              <Square size={14} />
              Arrêter
            </button>
          ) : (
            <button className="btn-primary" onClick={start} disabled={!targets.trim()}>
              <Radar size={15} />
              Lancer le scan
            </button>
          )}
        </div>

        <div className="flex flex-wrap gap-1.5 mt-3">
          {(suggestions?.subnets ?? []).map((subnet: string) => (
            <button
              key={subnet}
              onClick={() => setTargets(subnet)}
              disabled={scanning}
              className="chip border-ink-700 bg-ink-800 text-mist-400 hover:text-accent hover:border-accent/40 font-mono"
            >
              {subnet}
            </button>
          ))}
          <span className="text-[11px] text-ink-600 self-center ml-1">
            CIDR, IP simple ou plage — les ports SSH, Proxmox (8006), DSM (5000/5001), Ollama (11434), Docker et web
            sont sondés.
          </span>
        </div>

        {scanning && (
          <div className="mt-4 space-y-1.5">
            <div className="flex justify-between text-xs">
              <span className="text-mist-400 flex items-center gap-2">
                <Spinner size={12} />
                Balayage en cours… {found.length} détecté(s)
              </span>
              <span className="metric-value">
                {progress.done} / {progress.total}
              </span>
            </div>
            <div className="h-1.5 bg-ink-800 rounded-full overflow-hidden">
              <div
                className="h-full bg-accent rounded-full transition-[width] duration-300"
                style={{ width: `${percent}%` }}
              />
            </div>
          </div>
        )}
      </div>

      {results.length === 0 && !scanning && (
        <div className="panel">
          <Empty
            icon={<Radar size={38} />}
            title="Aucun résultat"
            hint="Lance un scan sur ton sous-réseau : MBA identifie serveurs SSH, hyperviseurs Proxmox, NAS Synology, endpoints Ollama et services web, puis te propose de les adopter en un clic."
          />
        </div>
      )}

      {results.length > 0 && (
        <>
          <SectionTitle right={<span className="text-xs text-ink-500">{results.length} équipement(s)</span>}>
            Équipements détectés
          </SectionTitle>
          <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(320px,1fr))]">
            {results.map((candidate) => (
              <CandidateCard
                key={candidate.address}
                candidate={candidate}
                onAdopt={() => setAdopt(candidate)}
                onIgnore={() => ignore(candidate)}
              />
            ))}
          </div>
        </>
      )}
      </>)}

      <AdoptModal
        candidate={adopt}
        onClose={() => setAdopt(null)}
        onDone={() => {
          setAdopt(null)
          refetch()
          queryClient.invalidateQueries({ queryKey: ['hosts'] })
          queryClient.invalidateQueries({ queryKey: ['overview'] })
        }}
      />
    </Page>
  )
}

function CandidateCard({
  candidate,
  onAdopt,
  onIgnore,
}: {
  candidate: Candidate
  onAdopt: () => void
  onIgnore: () => void
}) {
  const known = candidate.known || candidate.host_id != null || candidate.adopted
  const banner = candidate.evidence?.ssh
  const title =
    candidate.evidence?.https?.title || candidate.evidence?.http?.title || candidate.evidence?.dsm?.title

  return (
    <div className={clsx('panel p-3.5 space-y-2.5', known && 'opacity-65')}>
      <div className="flex items-start gap-2.5">
        <div className="w-8 h-8 rounded-lg bg-ink-800 border border-ink-700 grid place-items-center shrink-0">
          {candidate.guessed_kind === 'ollama' ? (
            <Zap size={15} className="text-accent" />
          ) : (
            <Server size={15} className="text-mist-400" />
          )}
        </div>
        <div className="min-w-0 flex-1">
          <div className="font-mono text-[13px] text-mist-100">{candidate.address}</div>
          {candidate.hostname && <div className="text-[11px] text-ink-600 truncate">{candidate.hostname}</div>}
        </div>
        <Badge tone={KIND_TONE[candidate.guessed_kind] ?? 'neutral'}>
          {KIND_LABEL[candidate.guessed_kind] ?? candidate.guessed_kind}
        </Badge>
      </div>

      <div className="flex flex-wrap gap-1">
        {candidate.open_ports.slice(0, 10).map((port) => (
          <span key={port} className="chip border-ink-700 bg-ink-800 text-ink-400 font-mono">
            {port}
          </span>
        ))}
      </div>

      {(banner || title) && (
        <div className="text-[11px] text-ink-500 truncate font-mono bg-ink-800/50 rounded px-2 py-1">
          {banner || title}
        </div>
      )}

      <div className="flex items-center gap-1.5 pt-1 border-t border-ink-800">
        {known ? (
          <span className="text-[11px] text-accent flex items-center gap-1 flex-1">
            <Check size={12} />
            Déjà supervisé
          </span>
        ) : (
          <>
            <button className="btn-primary flex-1 py-1 text-xs" onClick={onAdopt}>
              Adopter
            </button>
            <button className="btn-icon" onClick={onIgnore} title="Ignorer">
              <EyeOff size={14} />
            </button>
          </>
        )}
      </div>
    </div>
  )
}

const DEFAULT_PORTS: Record<string, number> = {
  linux: 22,
  proxmox: 8006,
  synology: 5001,
  docker: 22,
  ollama: 11434,
  generic: 80,
}

function AdoptModal({
  candidate,
  onClose,
  onDone,
}: {
  candidate: Candidate | null
  onClose: () => void
  onDone: () => void
}) {
  const [form, setForm] = useState({ name: '', kind: 'linux', port: 22, credential_id: '',
                                     tags: '', category: '' })
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  const { data: credentials = [] } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
    enabled: !!candidate,
  })

  useEffect(() => {
    if (!candidate) return
    const kind = candidate.guessed_kind
    setForm({
      name: (candidate.hostname ?? candidate.address).split('.')[0],
      kind,
      port: DEFAULT_PORTS[kind] ?? 22,
      credential_id: '',
      tags: ((candidate as any).tags ?? []).join(', '),
      category: '',
    })
  }, [candidate])

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    if (!candidate) return
    setBusy(true)
    try {
      await post('/discovery/adopt', {
        address: candidate.address,
        name: form.name,
        kind: form.kind,
        port: Number(form.port),
        credential_id: form.credential_id ? Number(form.credential_id) : null,
        tags: form.tags.split(',').map((t) => t.trim()).filter(Boolean),
        category: form.category.trim() || null,
      })
      toast(`${form.name} adopté — la collecte démarre`, 'ok')
      onDone()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const needsCredential = ['linux', 'docker', 'proxmox', 'synology'].includes(form.kind)

  return (
    <Modal
      open={!!candidate}
      onClose={onClose}
      title={`Adopter ${candidate?.address ?? ''}`}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" form="adopt" type="submit" disabled={busy}>
            {busy ? <Spinner /> : <Check size={15} />}
            Adopter
          </button>
        </>
      }
    >
      <form id="adopt" onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} className="w-full" required />
          </div>
          <div className="space-y-1.5">
            <label>Type détecté</label>
            <select
              value={form.kind}
              onChange={(e) => setForm({ ...form, kind: e.target.value, port: DEFAULT_PORTS[e.target.value] ?? 22 })}
              className="w-full"
            >
              <option value="linux">Serveur Linux</option>
              <option value="proxmox">Proxmox VE</option>
              <option value="synology">NAS Synology</option>
              <option value="docker">Hôte Docker</option>
              <option value="ollama">Endpoint Ollama</option>
              <option value="generic">Générique</option>
            </select>
          </div>
        </div>

        {form.kind !== 'ollama' && (
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <label>Port</label>
              <input
                type="number"
                value={form.port}
                onChange={(e) => setForm({ ...form, port: Number(e.target.value) })}
                className="w-full"
              />
            </div>
            <div className="space-y-1.5">
              <label>Étiquettes</label>
              <input
                value={form.tags}
                onChange={(e) => setForm({ ...form, tags: e.target.value })}
                placeholder="prod, baie"
                className="w-full"
              />
            </div>
            <div className="space-y-1.5 col-span-2">
              <label>Catégorie</label>
              <input
                value={form.category}
                onChange={(e) => setForm({ ...form, category: e.target.value })}
                placeholder="Serveurs, Stockage, Réseau…"
                className="w-full"
              />
            </div>
          </div>
        )}

        {needsCredential && (
          <div className="space-y-1.5">
            <label>Identifiants</label>
            <select
              value={form.credential_id}
              onChange={(e) => setForm({ ...form, credential_id: e.target.value })}
              className="w-full"
            >
              <option value="">— à définir plus tard —</option>
              {credentials.map((cred: any) => (
                <option key={cred.id} value={cred.id}>
                  {cred.name} ({cred.kind}
                  {cred.username ? ` · ${cred.username}` : ''})
                </option>
              ))}
            </select>
            <p className="text-[11px] text-ink-500">
              Sans identifiants, l'hôte est ajouté mais la collecte détaillée ne démarrera pas.
            </p>
          </div>
        )}

        {candidate && (
          <div className="bg-ink-800/50 rounded-lg p-2.5 space-y-1">
            <div className="metric-label">Empreinte</div>
            <div className="text-[11px] text-ink-500 font-mono">Ports : {candidate.open_ports.join(', ')}</div>
            {Object.entries(candidate.evidence ?? {}).map(([key, value]: [string, any]) => (
              <div key={key} className="text-[11px] text-ink-500 font-mono truncate">
                {key} : {typeof value === 'string' ? value : (value.title || value.server || value.product || JSON.stringify(value).slice(0, 70))}
              </div>
            ))}
          </div>
        )}
      </form>
    </Modal>
  )
}
