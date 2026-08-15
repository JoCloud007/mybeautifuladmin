const BASE = (import.meta.env.VITE_API_BASE as string) || '/api'
const TOKEN_KEY = 'mba.token'

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}
export function setToken(token: string | null) {
  if (token) localStorage.setItem(TOKEN_KEY, token)
  else localStorage.removeItem(TOKEN_KEY)
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    /** Corps structuré de l'erreur : étapes de diagnostic, pistes… */
    readonly payload?: any,
  ) {
    super(message)
  }
}

type Options = RequestInit & { json?: unknown }

export async function api<T = any>(path: string, options: Options = {}): Promise<T> {
  const { json, headers, ...rest } = options
  const token = getToken()
  const response = await fetch(`${BASE}${path}`, {
    ...rest,
    headers: {
      ...(json !== undefined ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: json !== undefined ? JSON.stringify(json) : rest.body,
    credentials: 'include',
  })

  if (response.status === 401 && !path.startsWith('/auth/login')) {
    setToken(null)
    if (!location.pathname.startsWith('/login')) {
      location.href = `/login?next=${encodeURIComponent(location.pathname)}`
    }
    throw new ApiError('Session expirée', 401)
  }

  if (!response.ok) {
    let detail = `Erreur ${response.status}`
    let payload: any = null
    try {
      const body = await response.json()
      payload = body.detail ?? body
      if (typeof payload === 'string') {
        detail = payload
      } else if (payload && typeof payload === 'object') {
        // Les erreurs riches portent un message, parfois une piste de résolution.
        detail = [payload.message, payload.hint, payload.note].filter(Boolean).join('\n\n')
        if (!detail) detail = JSON.stringify(payload)
      }
    } catch {
      /* réponse non JSON */
    }
    throw new ApiError(detail, response.status, payload)
  }

  if (response.status === 204) return undefined as T
  const text = await response.text()
  return (text ? JSON.parse(text) : undefined) as T
}

export const get = <T = any,>(path: string) => api<T>(path)
export const post = <T = any,>(path: string, json?: unknown) => api<T>(path, { method: 'POST', json })
export const patch = <T = any,>(path: string, json?: unknown) => api<T>(path, { method: 'PATCH', json })
export const del = <T = any,>(path: string) => api<T>(path, { method: 'DELETE' })

/** Récupère un fichier authentifié et déclenche son enregistrement. */
export async function download(path: string, filename: string): Promise<void> {
  const token = getToken()
  const response = await fetch(`${BASE}${path}`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    credentials: 'include',
  })
  if (!response.ok) throw new ApiError(`Erreur ${response.status}`, response.status)
  const url = URL.createObjectURL(await response.blob())
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  link.remove()
  URL.revokeObjectURL(url)
}

/** URL WebSocket absolue, jeton inclus. */
export function wsUrl(path: string, params: Record<string, string | number> = {}): string {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:'
  const base = BASE.startsWith('http')
    ? BASE.replace(/^http/, 'ws')
    : `${proto}//${location.host}${BASE}`
  const query = new URLSearchParams({ token: getToken() ?? '', ...Object.fromEntries(Object.entries(params).map(([k, v]) => [k, String(v)])) })
  return `${base}${path}?${query}`
}

/** POST qui renvoie un flux SSE, consommé ligne par ligne. */
export async function* sse(path: string, json: unknown, signal?: AbortSignal) {
  const token = getToken()
  const response = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(json),
    credentials: 'include',
    signal,
  })
  if (!response.ok || !response.body) throw new ApiError(`Erreur ${response.status}`, response.status)

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    const parts = buffer.split('\n\n')
    buffer = parts.pop() ?? ''
    for (const part of parts) {
      const line = part.trim()
      if (!line.startsWith('data:')) continue
      try {
        yield JSON.parse(line.slice(5).trim())
      } catch {
        /* fragment incomplet */
      }
    }
  }
}
