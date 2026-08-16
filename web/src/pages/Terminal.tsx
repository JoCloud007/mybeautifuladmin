import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import { Link2, Minus, Plus, Server, Settings2, TerminalSquare, Unplug, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import {
  DEFAULT_PREFS,
  FONT_STACKS,
  TerminalView,
  type TermPrefs,
  type TermState,
} from '@/components/Terminal'
import { Empty, Modal, StatusDot, useLocalState } from '@/components/ui'
import { del, get } from '@/lib/api'
import { KIND_LABEL } from '@/lib/format'

interface Session {
  key: string
  hostId: number
  hostName: string
  container?: string
  sessionId?: string
  state: TermState
  resumed?: boolean
}

const TTL_LABELS: Record<string, string> = {
  '5m': '5 minutes',
  '30m': '30 minutes',
  '2h': '2 heures',
  '8h': '8 heures',
  '24h': '24 heures',
  keep: "Jusqu'à fermeture explicite",
}

export function TerminalPage() {
  const [params, setParams] = useSearchParams()
  const [sessions, setSessions] = useState<Session[]>([])
  const [active, setActive] = useState<string | null>(null)
  const [picker, setPicker] = useState(false)
  const [settings, setSettings] = useState(false)
  const [restored, setRestored] = useState(false)
  const [prefs, setPrefs] = useLocalState<TermPrefs>('mba.termPrefs', DEFAULT_PREFS)

  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts') })
  const connectable = hosts.filter((h: any) => ['linux', 'docker', 'proxmox'].includes(h.kind))

  const { data: live } = useQuery({
    queryKey: ['term-sessions'],
    queryFn: () => get('/terminal/sessions'),
    refetchInterval: 30000,
  })

  const open = (host: any, container?: string) => {
    const key = `${host.id}:${container ?? ''}:${Date.now()}`
    setSessions((current) => [
      ...current,
      { key, hostId: host.id, hostName: host.name, container, state: 'connecting' },
    ])
    setActive(key)
    setPicker(false)
  }

  /** Détache l'onglet sans tuer le shell : il restera repris plus tard. */
  const detach = (key: string) => {
    setSessions((current) => {
      const next = current.filter((s) => s.key !== key)
      if (active === key) setActive(next.at(-1)?.key ?? null)
      return next
    })
  }

  /** Ferme réellement le shell côté serveur. */
  const terminate = async (session: Session) => {
    if (session.sessionId) await del(`/terminal/sessions/${session.sessionId}`).catch(() => {})
    detach(session.key)
  }

  // Sessions encore vivantes côté API : on rouvre les onglets correspondants.
  useEffect(() => {
    if (restored || !live) return
    setRestored(true)
    if (!prefs.restore) return
    const revived: Session[] = (live.sessions ?? []).map((s: any) => ({
      key: `restored:${s.id}`,
      hostId: s.host_id,
      hostName: s.host_name,
      container: s.container ?? undefined,
      sessionId: s.id,
      state: 'connecting' as TermState,
    }))
    if (revived.length) {
      setSessions(revived)
      setActive(revived[0].key)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [live, restored])

  // Ouverture directe depuis un lien « Terminal » d'une autre page.
  useEffect(() => {
    const hostId = params.get('host')
    if (!hostId || hosts.length === 0) return
    const host = hosts.find((h: any) => String(h.id) === hostId)
    if (host) open(host, params.get('container') ?? undefined)
    params.delete('host')
    params.delete('container')
    setParams(params, { replace: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hosts])

  const setState = (key: string, state: TermState) =>
    setSessions((current) => current.map((s) => (s.key === key ? { ...s, state } : s)))

  const setSession = (key: string, sessionId: string, resumed: boolean) =>
    setSessions((current) =>
      current.map((s) => (s.key === key ? { ...s, sessionId, resumed } : s)),
    )

  return (
    <div className="h-full flex flex-col">
      <div className="h-11 shrink-0 border-b border-ink-800 bg-ink-950/50 flex items-center gap-1 px-2 overflow-x-auto">
        {sessions.map((session) => (
          <button
            key={session.key}
            onClick={() => setActive(session.key)}
            className={clsx(
              'group flex items-center gap-2 px-3 h-8 rounded-lg text-xs whitespace-nowrap transition-colors border shrink-0',
              active === session.key
                ? 'bg-ink-800 border-ink-700 text-mist-100'
                : 'border-transparent text-mist-400 hover:bg-ink-850',
            )}
          >
            <StatusDot
              status={
                session.state === 'open'
                  ? 'online'
                  : session.state === 'closed'
                    ? 'offline'
                    : 'warning'
              }
              size={6}
            />
            <span>{session.hostName}</span>
            {session.container && (
              <span className="text-ink-500">› {session.container.slice(0, 12)}</span>
            )}
            {session.resumed && (
              <Link2 size={11} className="text-accent" aria-label="session reprise" />
            )}
            <span
              onClick={(e) => {
                e.stopPropagation()
                detach(session.key)
              }}
              title="Fermer l'onglet — le shell continue de tourner"
              className="opacity-0 group-hover:opacity-60 hover:!opacity-100 -mr-1"
            >
              <X size={12} />
            </span>
          </button>
        ))}

        <button onClick={() => setPicker(true)} className="btn-icon shrink-0" title="Nouvelle session">
          <Plus size={16} />
        </button>

        <div className="flex-1 min-w-2" />

        <div className="flex items-center gap-0.5 shrink-0">
          <button
            className="btn-icon"
            onClick={() => setPrefs({ ...prefs, fontSize: Math.max(9, prefs.fontSize - 1) })}
            title="Réduire la police"
          >
            <Minus size={13} />
          </button>
          <span className="text-[11px] text-ink-500 font-mono w-6 text-center">{prefs.fontSize}</span>
          <button
            className="btn-icon"
            onClick={() => setPrefs({ ...prefs, fontSize: Math.min(22, prefs.fontSize + 1) })}
            title="Agrandir la police"
          >
            <Plus size={13} />
          </button>
          <button className="btn-icon" onClick={() => setSettings(true)} title="Préférences du terminal">
            <Settings2 size={15} />
          </button>
          {active && (
            <button
              className="btn-icon hover:text-danger"
              onClick={() => {
                const session = sessions.find((s) => s.key === active)
                if (session) terminate(session)
              }}
              title="Terminer la session (ferme le shell distant)"
            >
              <Unplug size={15} />
            </button>
          )}
        </div>
      </div>

      <div className="flex-1 relative bg-ink-900 min-h-0">
        {sessions.length === 0 && (
          <Empty
            icon={<TerminalSquare size={40} />}
            title="Aucune session ouverte"
            hint="Ouvre un shell SSH sur un serveur, ou un shell interactif directement dans un conteneur Docker. Les sessions survivent au changement de page."
            action={
              <button className="btn-primary" onClick={() => setPicker(true)}>
                <Plus size={15} />
                Nouvelle session
              </button>
            }
          />
        )}

        {/* Les sessions inactives restent montées : on ne perd pas le shell en changeant d'onglet. */}
        {sessions.map((session) => (
          <div
            key={session.key}
            className={clsx(
              'absolute inset-0 p-2',
              active === session.key ? 'block' : 'hidden',
            )}
          >
            <TerminalView
              hostId={session.hostId}
              container={session.container}
              sessionId={session.sessionId}
              prefs={prefs}
              onState={(state) => setState(session.key, state)}
              onSession={(id, resumed) => setSession(session.key, id, resumed)}
            />
          </div>
        ))}
      </div>

      {picker && (
        <div className="fixed inset-0 z-50 flex items-start justify-center pt-[14vh] px-4">
          <div
            className="absolute inset-0 bg-ink-950/80 backdrop-blur-sm"
            onClick={() => setPicker(false)}
          />
          <div className="relative panel w-full max-w-md overflow-hidden animate-slideUp">
            <header className="px-4 py-3 border-b border-ink-750 flex items-center justify-between">
              <h2 className="font-semibold text-mist-100 text-sm">Ouvrir un terminal</h2>
              <button className="btn-icon" onClick={() => setPicker(false)}>
                <X size={15} />
              </button>
            </header>
            <div className="max-h-[50vh] overflow-y-auto py-1.5">
              {connectable.length === 0 && (
                <p className="px-4 py-6 text-sm text-ink-500 text-center">
                  Aucun hôte accessible en SSH. Ajoute des identifiants SSH à tes serveurs.
                </p>
              )}
              {connectable.map((host: any) => (
                <button
                  key={host.id}
                  onClick={() => open(host)}
                  disabled={host.status === 'offline'}
                  className="w-full flex items-center gap-2.5 px-4 py-2.5 text-left hover:bg-ink-800 transition-colors disabled:opacity-40"
                >
                  <Server size={15} className="text-ink-500" />
                  <div className="min-w-0 flex-1">
                    <div className="text-sm text-mist-100 truncate">{host.name}</div>
                    <div className="text-[11px] text-ink-600 font-mono">
                      {host.address} · {KIND_LABEL[host.kind]}
                    </div>
                  </div>
                  <StatusDot status={host.status} size={7} />
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      <PrefsModal
        open={settings}
        onClose={() => setSettings(false)}
        prefs={prefs}
        setPrefs={setPrefs}
        sessions={live?.sessions ?? []}
        onKill={async (id: string) => {
          await del(`/terminal/sessions/${id}`).catch(() => {})
          setSessions((current) => current.filter((s) => s.sessionId !== id))
        }}
      />
    </div>
  )
}

function PrefsModal({
  open,
  onClose,
  prefs,
  setPrefs,
  sessions,
  onKill,
}: {
  open: boolean
  onClose: () => void
  prefs: TermPrefs
  setPrefs: (p: TermPrefs) => void
  sessions: any[]
  onKill: (id: string) => void
}) {
  const set = (patch: Partial<TermPrefs>) => setPrefs({ ...prefs, ...patch })

  return (
    <Modal open={open} onClose={onClose} title="Préférences du terminal" width="max-w-2xl">
      <div className="space-y-5">
        <section className="space-y-3">
          <h3 className="text-[11px] uppercase tracking-wider text-ink-500 font-medium">
            Police et affichage
          </h3>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <label>Police</label>
              <select
                value={prefs.fontFamily}
                onChange={(e) => set({ fontFamily: e.target.value })}
                className="w-full"
              >
                {Object.keys(FONT_STACKS).map((name) => (
                  <option key={name} value={name}>
                    {name}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1.5">
              <label>Corps ({prefs.fontSize} px)</label>
              <input
                type="range"
                min={9}
                max={22}
                value={prefs.fontSize}
                onChange={(e) => set({ fontSize: Number(e.target.value) })}
                className="w-full"
              />
            </div>
            <div className="space-y-1.5">
              <label>Interligne ({prefs.lineHeight.toFixed(2)})</label>
              <input
                type="range"
                min={100}
                max={200}
                value={Math.round(prefs.lineHeight * 100)}
                onChange={(e) => set({ lineHeight: Number(e.target.value) / 100 })}
                className="w-full"
              />
            </div>
            <div className="space-y-1.5">
              <label>Curseur</label>
              <select
                value={prefs.cursorStyle}
                onChange={(e) => set({ cursorStyle: e.target.value as TermPrefs['cursorStyle'] })}
                className="w-full"
              >
                <option value="bar">Barre</option>
                <option value="block">Bloc</option>
                <option value="underline">Souligné</option>
              </select>
            </div>
            <div className="space-y-1.5">
              <label>Historique ({prefs.scrollback.toLocaleString('fr-FR')} lignes)</label>
              <input
                type="range"
                min={1000}
                max={50000}
                step={1000}
                value={prefs.scrollback}
                onChange={(e) => set({ scrollback: Number(e.target.value) })}
                className="w-full"
              />
            </div>
            <label className="flex items-center gap-2.5 cursor-pointer self-end pb-1.5">
              <input
                type="checkbox"
                checked={prefs.cursorBlink}
                onChange={(e) => set({ cursorBlink: e.target.checked })}
              />
              <span className="text-[13px] text-mist-200 normal-case tracking-normal font-normal">
                Curseur clignotant
              </span>
            </label>
          </div>

          <div
            className="rounded-lg border border-ink-750 bg-ink-950 px-3 py-2.5 text-mist-200 overflow-x-auto"
            style={{
              fontFamily: FONT_STACKS[prefs.fontFamily],
              fontSize: prefs.fontSize,
              lineHeight: prefs.lineHeight,
            }}
          >
            <div>
              <span className="text-accent">math@proxmox</span>:<span className="text-info">~</span>${' '}
              journalctl -u docker --since &quot;-1h&quot;
            </div>
            <div className="text-ink-500">-- Logs begin at Mon, end at Mon. --</div>
          </div>
        </section>

        <section className="space-y-3">
          <h3 className="text-[11px] uppercase tracking-wider text-ink-500 font-medium">
            Persistance
          </h3>
          <p className="text-[12px] text-mist-400">
            Le shell tourne sur le serveur MBA, pas dans le navigateur. Changer de page, verrouiller
            l'écran ou perdre le réseau détache l'affichage sans interrompre ce qui s'exécute — au
            retour, la sortie manquée est rejouée.
          </p>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <label>Garder une session détachée</label>
              <select
                value={prefs.ttl}
                onChange={(e) => set({ ttl: e.target.value })}
                className="w-full"
              >
                {Object.entries(TTL_LABELS).map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </select>
              <p className="text-[11px] text-ink-500">
                Passé ce délai sans client attaché, le shell est fermé.
              </p>
            </div>
            <label className="flex items-start gap-2.5 cursor-pointer self-start pt-6">
              <input
                type="checkbox"
                checked={prefs.restore}
                onChange={(e) => set({ restore: e.target.checked })}
              />
              <span className="text-[13px] text-mist-200 normal-case tracking-normal font-normal">
                Rouvrir les sessions vivantes à l'arrivée sur la page
              </span>
            </label>
          </div>
        </section>

        {sessions.length > 0 && (
          <section className="space-y-2">
            <h3 className="text-[11px] uppercase tracking-wider text-ink-500 font-medium">
              Sessions ouvertes sur le serveur ({sessions.length})
            </h3>
            <div className="space-y-1.5">
              {sessions.map((session: any) => (
                <div
                  key={session.id}
                  className="flex items-center gap-2.5 bg-ink-850 rounded-lg px-3 py-2"
                >
                  <StatusDot status={session.attached ? 'online' : 'warning'} size={7} />
                  <div className="min-w-0 flex-1">
                    <div className="text-[13px] text-mist-100 truncate">{session.label}</div>
                    <div className="text-[10px] text-ink-600 font-mono">
                      {session.attached
                        ? `${session.attached} client(s) attaché(s)`
                        : 'détachée — tourne en arrière-plan'}
                      {session.buffered > 0 &&
                        ` · ${
                          session.buffered < 1024
                            ? `${session.buffered} o`
                            : `${Math.round(session.buffered / 1024)} Ko`
                        } en tampon`}
                    </div>
                  </div>
                  <button
                    className="btn-icon hover:text-danger"
                    onClick={() => onKill(session.id)}
                    title="Terminer cette session"
                  >
                    <Unplug size={14} />
                  </button>
                </div>
              ))}
            </div>
          </section>
        )}
      </div>
    </Modal>
  )
}
