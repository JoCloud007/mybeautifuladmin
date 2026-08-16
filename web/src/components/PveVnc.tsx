import RFB from '@novnc/novnc/lib/rfb'
import { Clipboard, Command, Maximize2, MousePointer2, RotateCw } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { get, wsUrl } from '@/lib/api'
import { Badge, Spinner } from './ui'

type VncState = 'connecting' | 'open' | 'closed'

/**
 * Écran graphique d'un invité Proxmox, dessiné dans la page.
 *
 * Le flux RFB est relayé par l'API : le navigateur n'a ni le jeton d'API ni un
 * certificat PVE accepté, et un iframe vers l'interface Proxmox demanderait en
 * plus une session ouverte sur l'hyperviseur. Ici, noVNC dessine dans un canvas
 * de MBA, avec le ticket VNC comme mot de passe RFB.
 */
export function PveVnc({
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
  onState?: (state: VncState) => void
}) {
  const holder = useRef<HTMLDivElement>(null)
  const rfb = useRef<any>(null)
  const [state, setState] = useState<VncState>('connecting')
  const [error, setError] = useState<string | null>(null)
  const [scaled, setScaled] = useState(true)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let cancelled = false
    let client: any = null

    const report = (next: VncState) => {
      if (cancelled) return
      setState(next)
      onState?.(next)
    }

    const connect = async () => {
      report('connecting')
      setError(null)
      let ticket: any
      try {
        // Le ticket est aussi le mot de passe RFB : il ne vit que quelques
        // secondes, on le demande donc juste avant d'ouvrir le canal.
        ticket = await get(`/proxmox/${hostId}/guests/${kind}/${vmid}/vnc`)
      } catch (exc: any) {
        if (!cancelled) {
          setError(exc.message)
          report('closed')
        }
        return
      }
      if (cancelled || !holder.current) return

      client = new RFB(
        holder.current,
        // Le jeton lie ce canal au ticket déjà délivré : sans lui, Proxmox
        // ouvrirait une seconde session VNC dont le mot de passe diffèrerait.
        wsUrl(`/proxmox/${hostId}/vnc/${kind}/${vmid}`, {
          handle: ticket.handle,
          ...(node ? { node } : {}),
        }),
        { credentials: { password: ticket.password }, wsProtocols: ['binary'] },
      )
      client.scaleViewport = true
      client.resizeSession = false
      client.background = 'transparent'
      client.addEventListener('connect', () => report('open'))
      client.addEventListener('disconnect', (event: any) => {
        if (!event.detail?.clean) setError("L'hyperviseur a fermé l'écran graphique.")
        report('closed')
      })
      client.addEventListener('securityfailure', (event: any) => {
        setError(event.detail?.reason || 'Ticket VNC refusé par Proxmox.')
      })
      rfb.current = client
    }

    connect()

    return () => {
      cancelled = true
      try {
        client?.disconnect()
      } catch {
        /* déjà fermé */
      }
      rfb.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostId, kind, vmid, node, attempt])

  useEffect(() => {
    if (rfb.current) rfb.current.scaleViewport = scaled
  }, [scaled])

  const sendCtrlAltDel = () => rfb.current?.sendCtrlAltDel?.()

  return (
    <div className="w-full h-full flex flex-col gap-2">
      <div className="flex items-center gap-1.5 flex-wrap">
        <Badge tone={state === 'open' ? 'ok' : state === 'connecting' ? 'warn' : 'danger'}>
          {state === 'open' ? 'Écran connecté' : state === 'connecting' ? 'Connexion…' : 'Déconnecté'}
        </Badge>
        <div className="flex-1" />
        <button
          className="btn-ghost !px-2 !py-1 !text-[11px]"
          onClick={() => setScaled(!scaled)}
          title={scaled ? 'Afficher à la taille réelle' : "Adapter à la fenêtre"}
        >
          <Maximize2 size={13} />
          {scaled ? 'Ajusté' : '1:1'}
        </button>
        <button
          className="btn-ghost !px-2 !py-1 !text-[11px]"
          onClick={sendCtrlAltDel}
          disabled={state !== 'open'}
          title="Envoyer Ctrl+Alt+Suppr à l'invité"
        >
          <Command size={13} />
          Ctrl+Alt+Suppr
        </button>
        <button
          className="btn-ghost !px-2 !py-1 !text-[11px]"
          onClick={() => rfb.current?.focus()}
          disabled={state !== 'open'}
          title="Rendre le clavier à l'écran distant"
        >
          <MousePointer2 size={13} />
          Focus
        </button>
        <button
          className="btn-ghost !px-2 !py-1 !text-[11px]"
          onClick={() => setAttempt((n) => n + 1)}
          title="Rouvrir l'écran"
        >
          <RotateCw size={13} />
          Reconnecter
        </button>
      </div>

      <div className="relative flex-1 min-h-0 rounded-lg overflow-hidden bg-black">
        <div ref={holder} className="absolute inset-0 [&_canvas]:!outline-none" />

        {state === 'connecting' && (
          <div className="absolute inset-0 grid place-items-center bg-ink-950/70 pointer-events-none">
            <div className="flex flex-col items-center gap-2">
              <Spinner size={20} />
              <span className="text-[12px] text-ink-500">Ouverture de l'écran graphique…</span>
            </div>
          </div>
        )}

        {state === 'closed' && error && (
          <div className="absolute inset-0 grid place-items-center bg-ink-950/85 p-6">
            <div className="text-center max-w-sm space-y-2">
              <p className="text-[13px] text-danger">{error}</p>
              <p className="text-[11px] text-ink-500">
                Un invité éteint n'a pas d'écran. Vérifie aussi que le compte d'API porte{' '}
                <span className="font-mono">VM.Console</span> sur cet invité.
              </p>
              <button className="btn-ghost mx-auto" onClick={() => setAttempt((n) => n + 1)}>
                <RotateCw size={14} />
                Réessayer
              </button>
            </div>
          </div>
        )}
      </div>

      <p className="text-[11px] text-ink-500 flex items-center gap-1.5">
        <Clipboard size={11} className="shrink-0" />
        Le presse-papiers n'est pas partagé avec l'invité : la saisie passe par le clavier.
      </p>
    </div>
  )
}
