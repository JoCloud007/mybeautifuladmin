import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { Terminal as XTerm } from '@xterm/xterm'
import { useEffect, useRef } from 'react'
import { wsUrl } from '@/lib/api'

const THEME = {
  background: '#0b0e14',
  foreground: '#c2ccdb',
  cursor: '#00d4aa',
  cursorAccent: '#0b0e14',
  selectionBackground: '#00d4aa33',
  black: '#141924',
  red: '#ff4d6d',
  green: '#00d4aa',
  yellow: '#ffb020',
  blue: '#3b9dff',
  magenta: '#a97bff',
  cyan: '#48e5c2',
  white: '#c2ccdb',
  brightBlack: '#4a5567',
  brightRed: '#ff7d95',
  brightGreen: '#48e5c2',
  brightYellow: '#ffc95c',
  brightBlue: '#74bcff',
  brightMagenta: '#c4a3ff',
  brightCyan: '#7df0d8',
  brightWhite: '#e6ecf5',
}

export type TermState = 'connecting' | 'open' | 'closed'

export const FONT_STACKS: Record<string, string> = {
  'JetBrains Mono': '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace',
  'SF Mono': 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace',
  Menlo: 'Menlo, Monaco, "Courier New", monospace',
  'Fira Code': '"Fira Code", "JetBrains Mono", ui-monospace, monospace',
  Système: 'monospace',
}

export interface TermPrefs {
  fontFamily: string
  fontSize: number
  lineHeight: number
  cursorStyle: 'bar' | 'block' | 'underline'
  cursorBlink: boolean
  scrollback: number
  ttl: string
  restore: boolean
}

export const DEFAULT_PREFS: TermPrefs = {
  fontFamily: 'JetBrains Mono',
  fontSize: 13,
  lineHeight: 1.25,
  cursorStyle: 'bar',
  cursorBlink: true,
  scrollback: 8000,
  ttl: '30m',
  restore: true,
}

/**
 * Vue d'une session terminal.
 *
 * Le shell vit côté API : cette vue ne fait que s'y attacher. Fermer l'onglet
 * du navigateur, changer de page ou perdre le réseau détache le client sans
 * tuer le shell — on se rattache ensuite avec `sessionId` et l'API rejoue ce
 * qui a défilé entre-temps.
 */
export function TerminalView({
  hostId,
  container,
  sessionId,
  prefs,
  onState,
  onSession,
}: {
  hostId: number
  container?: string
  sessionId?: string
  prefs: TermPrefs
  onState?: (state: TermState) => void
  onSession?: (id: string, resumed: boolean) => void
}) {
  const holder = useRef<HTMLDivElement>(null)
  const term = useRef<XTerm | null>(null)
  const socketRef = useRef<WebSocket | null>(null)
  // L'identifiant de rattachement ne vaut qu'à l'ouverture : le mémoriser dans
  // une ref évite que l'identifiant renvoyé par le serveur ne relance l'effet.
  const resumeId = useRef(sessionId)

  // Les préférences purement visuelles s'appliquent à chaud : les remettre dans
  // les dépendances de l'effet reconstruirait le terminal à chaque réglage.
  useEffect(() => {
    if (!term.current) return
    term.current.options.fontFamily = FONT_STACKS[prefs.fontFamily] ?? FONT_STACKS['JetBrains Mono']
    term.current.options.fontSize = prefs.fontSize
    term.current.options.lineHeight = prefs.lineHeight
    term.current.options.cursorStyle = prefs.cursorStyle
    term.current.options.cursorBlink = prefs.cursorBlink
    term.current.options.scrollback = prefs.scrollback
  }, [prefs])

  useEffect(() => {
    if (!holder.current) return
    const xterm = new XTerm({
      theme: THEME,
      fontFamily: FONT_STACKS[prefs.fontFamily] ?? FONT_STACKS['JetBrains Mono'],
      fontSize: prefs.fontSize,
      lineHeight: prefs.lineHeight,
      cursorBlink: prefs.cursorBlink,
      cursorStyle: prefs.cursorStyle,
      scrollback: prefs.scrollback,
      allowProposedApi: true,
      macOptionIsMeta: true,
    })
    term.current = xterm
    const fit = new FitAddon()
    xterm.loadAddon(fit)
    xterm.loadAddon(new WebLinksAddon())
    xterm.open(holder.current)

    // Le fit doit attendre que le conteneur ait ses dimensions définitives.
    requestAnimationFrame(() => {
      try {
        fit.fit()
      } catch {
        /* conteneur pas encore mesurable */
      }
    })

    onState?.('connecting')
    const socket = new WebSocket(
      wsUrl(`/ws/terminal/${hostId}`, {
        ...(container ? { container } : {}),
        ...(resumeId.current ? { session: resumeId.current } : {}),
        ttl: prefs.ttl,
        cols: xterm.cols,
        rows: xterm.rows,
      }),
    )
    socketRef.current = socket

    socket.onopen = () => {
      onState?.('open')
      xterm.focus()
    }

    socket.onmessage = (event) => {
      const message = JSON.parse(event.data)
      if (message.t === 'o' || message.t === 'e') xterm.write(message.d)
      else if (message.t === 'session') {
        resumeId.current = message.id
        onSession?.(message.id, message.resumed)
      }
    }

    socket.onclose = () => {
      onState?.('closed')
      xterm.write('\r\n\x1b[38;5;244m── détaché ──\x1b[0m\r\n')
    }

    const dataSub = xterm.onData((data) => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ t: 'i', d: data }))
    })

    const resizeSub = xterm.onResize(() => {
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ t: 'r', cols: xterm.cols, rows: xterm.rows }))
      }
    })

    const observer = new ResizeObserver(() => {
      try {
        fit.fit()
      } catch {
        /* le conteneur est masqué */
      }
    })
    observer.observe(holder.current)

    const keepAlive = window.setInterval(() => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ t: 'ping' }))
    }, 25000)

    return () => {
      window.clearInterval(keepAlive)
      observer.disconnect()
      dataSub.dispose()
      resizeSub.dispose()
      socket.close()
      xterm.dispose()
      term.current = null
      socketRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostId, container])

  // Changer la rétention s'applique aussi aux sessions déjà ouvertes.
  useEffect(() => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      socketRef.current.send(JSON.stringify({ t: 'ttl', value: prefs.ttl }))
    }
  }, [prefs.ttl])

  return (
    <div
      ref={holder}
      className="w-full h-full [&_.xterm]:h-full [&_.xterm-screen]:!bg-transparent"
    />
  )
}
