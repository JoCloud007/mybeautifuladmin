import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { Terminal as XTerm } from '@xterm/xterm'
import { useEffect, useRef, useState } from 'react'
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

export function TerminalView({
  hostId,
  container,
  onState,
  fontSize = 13,
}: {
  hostId: number
  container?: string
  onState?: (state: TermState) => void
  fontSize?: number
}) {
  const holder = useRef<HTMLDivElement>(null)
  const [, setNonce] = useState(0)

  useEffect(() => {
    if (!holder.current) return
    const term = new XTerm({
      theme: THEME,
      fontFamily: '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize,
      lineHeight: 1.25,
      cursorBlink: true,
      cursorStyle: 'bar',
      scrollback: 8000,
      allowProposedApi: true,
      macOptionIsMeta: true,
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.loadAddon(new WebLinksAddon())
    term.open(holder.current)

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
        cols: term.cols,
        rows: term.rows,
      }),
    )

    socket.onopen = () => {
      onState?.('open')
      term.focus()
    }

    socket.onmessage = (event) => {
      const message = JSON.parse(event.data)
      if (message.t === 'o' || message.t === 'e') term.write(message.d)
    }

    socket.onclose = () => {
      onState?.('closed')
      term.write('\r\n\x1b[38;5;244m── session terminée ──\x1b[0m\r\n')
    }

    const dataSub = term.onData((data) => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ t: 'i', d: data }))
    })

    const sendResize = () => {
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ t: 'r', cols: term.cols, rows: term.rows }))
      }
    }
    const resizeSub = term.onResize(sendResize)

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

    setNonce((n) => n + 1)

    return () => {
      window.clearInterval(keepAlive)
      observer.disconnect()
      dataSub.dispose()
      resizeSub.dispose()
      socket.close()
      term.dispose()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostId, container, fontSize])

  return <div ref={holder} className="w-full h-full [&_.xterm]:h-full [&_.xterm-screen]:!bg-transparent" />
}
