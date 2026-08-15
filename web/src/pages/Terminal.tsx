import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import { Minus, Plus, Server, TerminalSquare, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { TerminalView, type TermState } from '@/components/Terminal'
import { Empty, StatusDot, useLocalState } from '@/components/ui'
import { get } from '@/lib/api'
import { KIND_LABEL } from '@/lib/format'

interface Session {
  key: string
  hostId: number
  hostName: string
  container?: string
  state: TermState
}

export function TerminalPage() {
  const [params, setParams] = useSearchParams()
  const [sessions, setSessions] = useState<Session[]>([])
  const [active, setActive] = useState<string | null>(null)
  const [picker, setPicker] = useState(false)
  const [fontSize, setFontSize] = useLocalState('mba.termFont', 13)

  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts') })
  const connectable = hosts.filter((h: any) => ['linux', 'docker', 'proxmox'].includes(h.kind))

  const open = (host: any, container?: string) => {
    const key = `${host.id}:${container ?? ''}:${Date.now()}`
    setSessions((current) => [
      ...current,
      { key, hostId: host.id, hostName: host.name, container, state: 'connecting' },
    ])
    setActive(key)
    setPicker(false)
  }

  const close = (key: string) => {
    setSessions((current) => {
      const next = current.filter((s) => s.key !== key)
      if (active === key) setActive(next.at(-1)?.key ?? null)
      return next
    })
  }

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

  return (
    <div className="h-full flex flex-col">
      <div className="h-11 shrink-0 border-b border-ink-800 bg-ink-950/50 flex items-center gap-1 px-2 overflow-x-auto">
        {sessions.map((session) => (
          <button
            key={session.key}
            onClick={() => setActive(session.key)}
            className={clsx(
              'group flex items-center gap-2 px-3 h-8 rounded-lg text-xs whitespace-nowrap transition-colors border',
              active === session.key
                ? 'bg-ink-800 border-ink-700 text-mist-100'
                : 'border-transparent text-mist-400 hover:bg-ink-850',
            )}
          >
            <StatusDot status={session.state === 'open' ? 'online' : session.state === 'closed' ? 'offline' : 'warning'} size={6} />
            <span>{session.hostName}</span>
            {session.container && <span className="text-ink-500">› {session.container.slice(0, 12)}</span>}
            <span
              onClick={(e) => {
                e.stopPropagation()
                close(session.key)
              }}
              className="opacity-0 group-hover:opacity-60 hover:!opacity-100 -mr-1"
            >
              <X size={12} />
            </span>
          </button>
        ))}

        <button onClick={() => setPicker(true)} className="btn-icon shrink-0" title="Nouvelle session">
          <Plus size={16} />
        </button>

        <div className="flex-1" />

        <div className="flex items-center gap-0.5 shrink-0">
          <button className="btn-icon" onClick={() => setFontSize(Math.max(9, fontSize - 1))} title="Réduire la police">
            <Minus size={13} />
          </button>
          <span className="text-[11px] text-ink-500 font-mono w-6 text-center">{fontSize}</span>
          <button className="btn-icon" onClick={() => setFontSize(Math.min(22, fontSize + 1))} title="Agrandir la police">
            <Plus size={13} />
          </button>
        </div>
      </div>

      <div className="flex-1 relative bg-ink-900 min-h-0">
        {sessions.length === 0 && (
          <Empty
            icon={<TerminalSquare size={40} />}
            title="Aucune session ouverte"
            hint="Ouvre un shell SSH sur un serveur, ou un shell interactif directement dans un conteneur Docker."
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
            className={clsx('absolute inset-0 p-2', active === session.key ? 'block' : 'hidden')}
          >
            <TerminalView
              hostId={session.hostId}
              container={session.container}
              fontSize={fontSize}
              onState={(state) => setState(session.key, state)}
            />
          </div>
        ))}
      </div>

      {picker && (
        <div className="fixed inset-0 z-50 flex items-start justify-center pt-[14vh] px-4">
          <div className="absolute inset-0 bg-ink-950/80 backdrop-blur-sm" onClick={() => setPicker(false)} />
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
    </div>
  )
}
