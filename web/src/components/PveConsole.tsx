import { FitAddon } from '@xterm/addon-fit'
import { Terminal as XTerm } from '@xterm/xterm'
import { useEffect, useRef } from 'react'
import { wsUrl } from '@/lib/api'

const THEME = {
  background: '#0b0e14',
  foreground: '#c2ccdb',
  cursor: '#00d4aa',
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
}

/**
 * Console d'un invité Proxmox, relayée par l'API.
 *
 * Le navigateur ne peut pas parler à Proxmox directement : il n'a ni le jeton
 * d'API, ni un certificat accepté. MBA ouvre donc le canal côté PVE et fait
 * transiter les octets.
 */
export function PveConsole({
  hostId,
  kind,
  vmid,
  node,
  onState,
}: {
  hostId: number
  kind: string
  vmid: number
  node?: string
  onState?: (state: 'connecting' | 'open' | 'closed') => void
}) {
  const holder = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!holder.current) return
    const term = new XTerm({
      theme: THEME,
      fontFamily: '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 13,
      lineHeight: 1.25,
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(holder.current)
    requestAnimationFrame(() => {
      try {
        fit.fit()
      } catch {
        /* conteneur pas encore mesurable */
      }
    })

    onState?.('connecting')
    const socket = new WebSocket(
      wsUrl(`/proxmox/${hostId}/console/${kind}/${vmid}`, node ? { node } : {}),
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
      term.write('\r\n\x1b[38;5;244m── console fermée ──\x1b[0m\r\n')
    }

    const dataSub = term.onData((data) => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ t: 'i', d: data }))
    })
    const resizeSub = term.onResize(() => {
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ t: 'r', cols: term.cols, rows: term.rows }))
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
      term.dispose()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostId, kind, vmid, node])

  return <div ref={holder} className="w-full h-full [&_.xterm]:h-full [&_.xterm-screen]:!bg-transparent" />
}
