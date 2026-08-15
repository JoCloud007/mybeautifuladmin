/**
 * Flux temps réel unique pour toute l'application.
 *
 * Un seul WebSocket alimente des tampons circulaires par (hôte, métrique).
 * Les graphiques s'abonnent *hors du cycle de rendu React* : à 5 points/seconde
 * sur des dizaines de séries, re-rendre l'arbre React coûterait bien plus cher
 * que de pousser les points directement dans uPlot.
 */
import { create } from 'zustand'
import { wsUrl } from './api'

export const BUFFER = 300

export type Sample = Record<string, any>

export interface Point {
  t: Float64Array
  v: Float64Array
  n: number // nombre de points réellement remplis
}

type Listener = (hostId: number, sample: Sample) => void

class Series {
  private store = new Map<string, Point>()

  push(hostId: number, sample: Sample) {
    const t = sample._ts as number
    for (const [metric, value] of Object.entries(sample)) {
      if (typeof value !== 'number' || metric.startsWith('_')) continue
      const key = `${hostId}:${metric}`
      let point = this.store.get(key)
      if (!point) {
        point = { t: new Float64Array(BUFFER), v: new Float64Array(BUFFER), n: 0 }
        this.store.set(key, point)
      }
      if (point.n < BUFFER) {
        point.t[point.n] = t
        point.v[point.n] = value
        point.n++
      } else {
        point.t.copyWithin(0, 1)
        point.v.copyWithin(0, 1)
        point.t[BUFFER - 1] = t
        point.v[BUFFER - 1] = value
      }
    }
  }

  /** Copie compacte prête pour uPlot. */
  get(hostId: number, metric: string): [number[], number[]] {
    const point = this.store.get(`${hostId}:${metric}`)
    if (!point) return [[], []]
    return [Array.from(point.t.subarray(0, point.n)), Array.from(point.v.subarray(0, point.n))]
  }

  has(hostId: number, metric: string) {
    return (this.store.get(`${hostId}:${metric}`)?.n ?? 0) > 1
  }

  clear() {
    this.store.clear()
  }
}

export const series = new Series()

interface LiveState {
  connected: boolean
  samples: Record<number, Sample>
  status: Record<number, string>
  services: Record<number, any>
  ai: Record<number, any>
  events: any[]
  toastAlert: any | null
  bump: number // incrémenté à chaque cycle : sert de tick de rafraîchissement doux
}

export const useLive = create<LiveState>(() => ({
  connected: false,
  samples: {},
  status: {},
  services: {},
  ai: {},
  events: [],
  toastAlert: null,
  bump: 0,
}))

// --- abonnés hors React (graphiques) ---------------------------------------
const listeners = new Set<Listener>()
export function onSample(fn: Listener): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

// --- connexion --------------------------------------------------------------
let socket: WebSocket | null = null
let retry = 0
let retryTimer: number | undefined
let bumpTimer: number | undefined

function handle(topic: string, data: any) {
  if (topic.startsWith('metrics.')) {
    const hostId = data._host_id ?? Number(topic.slice(8))
    series.push(hostId, data)
    useLive.setState((s) => ({ samples: { ...s.samples, [hostId]: data } }))
    listeners.forEach((fn) => fn(hostId, data))
  } else if (topic === 'host.status') {
    useLive.setState((s) => ({ status: { ...s.status, [data.host_id]: data.status } }))
  } else if (topic === 'service') {
    useLive.setState((s) => ({ services: { ...s.services, [data.id]: data } }))
  } else if (topic.startsWith('ai.')) {
    useLive.setState((s) => ({ ai: { ...s.ai, [data.id]: data } }))
  } else if (topic === 'event') {
    useLive.setState((s) => ({ events: [data, ...s.events].slice(0, 200) }))
  } else if (topic === 'alert') {
    useLive.setState({ toastAlert: { ...data, at: Date.now() } })
  }
}

export function connectLive() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return

  socket = new WebSocket(wsUrl('/ws/stream'))

  socket.onopen = () => {
    retry = 0
    useLive.setState({ connected: true })
  }

  socket.onmessage = (event) => {
    const message = JSON.parse(event.data)
    if (message.topic === 'snapshot') {
      for (const [topic, data] of Object.entries(message.data as Record<string, any>)) {
        handle(topic, data)
      }
    } else if (message.topic !== 'ping') {
      handle(message.topic, message.data)
    }
  }

  socket.onclose = () => {
    useLive.setState({ connected: false })
    socket = null
    retry = Math.min(retry + 1, 6)
    window.clearTimeout(retryTimer)
    retryTimer = window.setTimeout(connectLive, 500 * 2 ** retry)
  }

  socket.onerror = () => socket?.close()

  // Tick de re-rendu volontairement lent : les valeurs textuelles se
  // rafraîchissent 2×/s, les courbes restent à la cadence du flux.
  window.clearInterval(bumpTimer)
  bumpTimer = window.setInterval(() => useLive.setState((s) => ({ bump: s.bump + 1 })), 500)
}

export function disconnectLive() {
  window.clearTimeout(retryTimer)
  window.clearInterval(bumpTimer)
  socket?.close()
  socket = null
  series.clear()
  useLive.setState({ connected: false, samples: {}, events: [] })
}

// --- sélecteurs pratiques ---------------------------------------------------
export function useSample(hostId?: number): Sample {
  return useLive((s) => (hostId ? (s.samples[hostId] ?? {}) : {}))
}

export function useMetric(hostId: number | undefined, metric: string): number | undefined {
  useLive((s) => s.bump)
  if (!hostId) return undefined
  return useLive.getState().samples[hostId]?.[metric]
}
