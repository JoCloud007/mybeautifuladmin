const UNITS = ['o', 'Ko', 'Mo', 'Go', 'To', 'Po']

/**
 * Coercition défensive : certaines agrégations SQL (numeric) traversent l'API
 * sous forme de chaîne. Les formateurs ne doivent jamais planter pour autant.
 */
function toNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

export function bytes(value?: unknown, digits = 1): string {
  const n = toNumber(value)
  if (n === null) return '—'
  if (n === 0) return '0 o'
  const exp = Math.min(Math.floor(Math.log(Math.abs(n)) / Math.log(1024)), UNITS.length - 1)
  const scaled = n / Math.pow(1024, exp)
  return `${scaled.toFixed(exp === 0 ? 0 : digits)} ${UNITS[exp]}`
}

export function bitrate(bytesPerSecond?: unknown): string {
  const n = toNumber(bytesPerSecond)
  if (n === null) return '—'
  return `${bytes(n, 1)}/s`
}

export function percent(value?: unknown, digits = 1): string {
  const n = toNumber(value)
  return n === null ? '—' : `${n.toFixed(digits)} %`
}

export function num(value?: unknown, digits = 0): string {
  const n = toNumber(value)
  return n === null ? '—' : n.toLocaleString('fr-FR', { maximumFractionDigits: digits })
}

export function duration(seconds?: unknown): string {
  const n = toNumber(seconds)
  if (n === null || n < 0) return '—'
  const d = Math.floor(n / 86400)
  const h = Math.floor((n % 86400) / 3600)
  const m = Math.floor((n % 3600) / 60)
  if (d > 0) return `${d} j ${h} h`
  if (h > 0) return `${h} h ${m} min`
  if (m > 0) return `${m} min`
  return `${Math.floor(n)} s`
}

export function ago(input?: string | number | Date | null): string {
  if (!input) return 'jamais'
  const date = input instanceof Date ? input : new Date(typeof input === 'number' ? input * 1000 : input)
  const delta = (Date.now() - date.getTime()) / 1000
  if (delta < 5) return "à l'instant"
  if (delta < 60) return `il y a ${Math.floor(delta)} s`
  if (delta < 3600) return `il y a ${Math.floor(delta / 60)} min`
  if (delta < 86400) return `il y a ${Math.floor(delta / 3600)} h`
  return `il y a ${Math.floor(delta / 86400)} j`
}

export function clock(input?: string | number | Date | null): string {
  if (!input) return '—'
  const date = input instanceof Date ? input : new Date(typeof input === 'number' ? input * 1000 : input)
  return date.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

export function datetime(input?: string | number | Date | null): string {
  if (!input) return '—'
  const date = input instanceof Date ? input : new Date(typeof input === 'number' ? input * 1000 : input)
  return date.toLocaleString('fr-FR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })
}

export function ms(value?: unknown): string {
  const n = toNumber(value)
  if (n === null) return '—'
  return n >= 1000 ? `${(n / 1000).toFixed(2)} s` : `${Math.round(n)} ms`
}

/** Palette de sévérité utilisée partout (jauges, barres, badges). */
export function severity(value: unknown, warn = 75, crit = 90) {
  const n = toNumber(value) ?? 0
  if (n >= crit) return { color: '#ff4d6d', tone: 'danger' as const }
  if (n >= warn) return { color: '#ffb020', tone: 'warn' as const }
  return { color: '#00d4aa', tone: 'ok' as const }
}

export const KIND_LABEL: Record<string, string> = {
  linux: 'Linux',
  proxmox: 'Proxmox',
  synology: 'Synology',
  docker: 'Docker',
  generic: 'Générique',
  ollama: 'Ollama',
  ipmi: 'IPMI / BMC',
  homeassistant: 'Home Assistant',
  pbs: 'Proxmox Backup',
}

export const STATUS_STYLE: Record<string, string> = {
  online: 'text-accent border-accent/30 bg-accent/10',
  offline: 'text-danger border-danger/30 bg-danger/10',
  warning: 'text-warn border-warn/30 bg-warn/10',
  unknown: 'text-mist-400 border-ink-600 bg-ink-800',
  up: 'text-accent border-accent/30 bg-accent/10',
  down: 'text-danger border-danger/30 bg-danger/10',
}
