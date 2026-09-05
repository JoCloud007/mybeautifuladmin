import clsx from 'clsx'
import { AlertTriangle, Check, Loader2, Tag, X } from 'lucide-react'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { severity } from '@/lib/format'

// ------------------------------------------------------------------ badges
export function Badge({
  children,
  tone = 'neutral',
  className,
}: {
  children: ReactNode
  tone?: 'ok' | 'warn' | 'danger' | 'info' | 'neutral' | 'violet'
  className?: string
}) {
  const tones = {
    ok: 'text-accent border-accent/30 bg-accent/10',
    warn: 'text-warn border-warn/30 bg-warn/10',
    danger: 'text-danger border-danger/30 bg-danger/10',
    info: 'text-info border-info/30 bg-info/10',
    violet: 'text-violet border-violet/30 bg-violet/10',
    neutral: 'text-mist-400 border-ink-700 bg-ink-800',
  }
  return <span className={clsx('chip', tones[tone], className)}>{children}</span>
}

export function StatusDot({ status, size = 8 }: { status?: string; size?: number }) {
  const color =
    status === 'online' || status === 'up' || status === 'running'
      ? 'bg-accent'
      : status === 'offline' || status === 'down' || status === 'exited'
        ? 'bg-danger'
        : status === 'warning'
          ? 'bg-warn'
          : 'bg-ink-500'
  const live = status === 'online' || status === 'up' || status === 'running'
  return (
    <span className="relative inline-flex shrink-0" style={{ width: size, height: size }}>
      <span className={clsx('absolute inset-0 rounded-full', color)} />
      {live && <span className={clsx('absolute inset-0 rounded-full animate-pulseRing', color)} />}
    </span>
  )
}

// ------------------------------------------------------------------- jauges
export function Gauge({
  value,
  label,
  sub,
  size = 92,
  warn = 75,
  crit = 90,
  format = (v: number) => `${v.toFixed(0)}%`,
}: {
  value: number
  label: string
  sub?: string
  size?: number
  warn?: number
  crit?: number
  format?: (v: number) => string
}) {
  const safe = Math.max(0, Math.min(100, isFinite(value) ? value : 0))
  const { color } = severity(safe, warn, crit)
  const radius = (size - 12) / 2
  const circumference = Math.PI * radius * 1.5 // arc de 270°
  const offset = circumference * (1 - safe / 100)

  return (
    <div className="flex flex-col items-center gap-1">
      <div className="relative" style={{ width: size, height: size }}>
        <svg width={size} height={size} className="-rotate-[225deg]">
          <circle
            cx={size / 2}
            cy={size / 2}
            r={radius}
            fill="none"
            stroke="#1a202d"
            strokeWidth="7"
            strokeLinecap="round"
            strokeDasharray={`${circumference} ${Math.PI * radius * 2}`}
          />
          <circle
            cx={size / 2}
            cy={size / 2}
            r={radius}
            fill="none"
            stroke={color}
            strokeWidth="7"
            strokeLinecap="round"
            strokeDasharray={`${circumference} ${Math.PI * radius * 2}`}
            strokeDashoffset={offset}
            style={{ transition: 'stroke-dashoffset 420ms cubic-bezier(0.4,0,0.2,1), stroke 300ms' }}
          />
        </svg>
        <div className="absolute inset-0 flex flex-col items-center justify-center">
          <span className="metric-value text-lg font-semibold leading-none" style={{ color }}>
            {format(safe)}
          </span>
          {sub && <span className="text-[10px] text-ink-500 mt-0.5">{sub}</span>}
        </div>
      </div>
      <span className="metric-label">{label}</span>
    </div>
  )
}

export function Bar({
  value,
  warn = 75,
  crit = 90,
  height = 6,
  className,
}: {
  value: number
  warn?: number
  crit?: number
  height?: number
  className?: string
}) {
  const safe = Math.max(0, Math.min(100, isFinite(value) ? value : 0))
  const { color } = severity(safe, warn, crit)
  return (
    <div className={clsx('w-full rounded-full bg-ink-800 overflow-hidden', className)} style={{ height }}>
      <div
        className="h-full rounded-full"
        style={{
          width: `${safe}%`,
          background: `linear-gradient(90deg, ${color}99, ${color})`,
          transition: 'width 400ms cubic-bezier(0.4,0,0.2,1), background 300ms',
        }}
      />
    </div>
  )
}

export function StatTile({
  label,
  value,
  sub,
  icon,
  tone = 'neutral',
  onClick,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  icon?: ReactNode
  tone?: 'ok' | 'warn' | 'danger' | 'info' | 'neutral'
  onClick?: () => void
}) {
  const accents = {
    ok: 'text-accent',
    warn: 'text-warn',
    danger: 'text-danger',
    info: 'text-info',
    neutral: 'text-mist-100',
  }
  return (
    <div
      onClick={onClick}
      className={clsx(
        'panel px-4 py-3 flex items-center gap-3',
        onClick && 'cursor-pointer panel-hover',
      )}
    >
      {icon && <div className={clsx('shrink-0 opacity-70', accents[tone])}>{icon}</div>}
      <div className="min-w-0">
        <div className="metric-label truncate">{label}</div>
        <div className={clsx('metric-value text-xl font-semibold leading-tight', accents[tone])}>{value}</div>
        {sub && <div className="text-[11px] text-ink-500 truncate mt-0.5">{sub}</div>}
      </div>
    </div>
  )
}

// ------------------------------------------------------------- étiquettes
/** Filtre par étiquettes, partagé par toutes les vues du parc.
 *
 * Plusieurs étiquettes cochées = union (l'élément porte *au moins* une des
 * étiquettes) : c'est ce qu'on attend quand on coche « prod » puis « nas ».
 */
export function TagFilter({
  tags,
  selected,
  onChange,
  className,
}: {
  tags: { tag: string; count: number }[]
  selected: string[]
  onChange: (tags: string[]) => void
  className?: string
}) {
  if (tags.length === 0) return null
  const toggle = (tag: string) =>
    onChange(selected.includes(tag) ? selected.filter((t) => t !== tag) : [...selected, tag])

  return (
    <div className={clsx('flex flex-wrap items-center gap-1.5', className)}>
      <Tag size={13} className="text-ink-600 mr-0.5" />
      <button
        onClick={() => onChange([])}
        className={clsx(
          'chip transition-colors',
          selected.length === 0
            ? 'border-accent/40 bg-accent/10 text-accent'
            : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
        )}
      >
        Toutes
      </button>
      {tags.map((entry) => (
        <button
          key={entry.tag}
          onClick={() => toggle(entry.tag)}
          className={clsx(
            'chip transition-colors',
            selected.includes(entry.tag)
              ? 'border-accent/40 bg-accent/10 text-accent'
              : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
          )}
        >
          {entry.tag}
          <span className="text-ink-500 ml-0.5">{entry.count}</span>
        </button>
      ))}
    </div>
  )
}

/** Étiquettes d'un hôte en lecture seule, cliquables pour filtrer. */
export function TagList({
  tags,
  onPick,
  max = 4,
}: {
  tags?: string[] | null
  onPick?: (tag: string) => void
  max?: number
}) {
  const items = tags ?? []
  if (items.length === 0) return null
  // Sans `onPick`, on reste sur des `span` : ces étiquettes s'affichent souvent
  // à l'intérieur d'un lien, où un bouton imbriqué serait invalide.
  return (
    <span className="inline-flex flex-wrap items-center gap-1">
      {items.slice(0, max).map((tag) =>
        onPick ? (
          <button
            key={tag}
            onClick={() => onPick(tag)}
            className="chip border-ink-700 bg-ink-800 text-ink-400 py-0 hover:text-accent hover:border-accent/30 transition-colors"
          >
            {tag}
          </button>
        ) : (
          <span key={tag} className="chip border-ink-700 bg-ink-800 text-ink-400 py-0">
            {tag}
          </span>
        ),
      )}
      {items.length > max && (
        <span className="text-[10px] text-ink-600" title={items.join(', ')}>
          +{items.length - max}
        </span>
      )}
    </span>
  )
}

// ------------------------------------------------------------------- modale
export function Modal({
  open,
  onClose,
  title,
  children,
  footer,
  width = 'max-w-lg',
}: {
  open: boolean
  onClose: () => void
  title: ReactNode
  children: ReactNode
  footer?: ReactNode
  width?: string
}) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    document.body.style.overflow = 'hidden'
    return () => {
      window.removeEventListener('keydown', onKey)
      document.body.style.overflow = ''
    }
  }, [open, onClose])

  if (!open) return null
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center p-0 sm:p-4">
      <div className="absolute inset-0 bg-ink-950/80 backdrop-blur-sm" onClick={onClose} />
      {/* Sur téléphone la boîte devient une feuille ancrée en bas : le pouce y
          atteint les boutons, et la hauteur suit le clavier virtuel. */}
      <div
        className={clsx(
          'relative panel w-full animate-slideUp flex flex-col',
          'max-h-[92dvh] rounded-b-none sm:rounded-xl sm:max-h-[88vh]',
          'pb-[env(safe-area-inset-bottom)] sm:pb-0',
          width,
        )}
      >
        <header className="flex items-center justify-between px-4 sm:px-5 py-3.5 border-b border-ink-750 shrink-0">
          <h2 className="font-semibold text-mist-100">{title}</h2>
          <button className="btn-icon" onClick={onClose} aria-label="Fermer">
            <X size={16} />
          </button>
        </header>
        <div className="px-4 sm:px-5 py-4 overflow-y-auto overscroll-contain">{children}</div>
        {footer && (
          <footer className="px-4 sm:px-5 py-3 border-t border-ink-750 flex justify-end gap-2 shrink-0">
            {footer}
          </footer>
        )}
      </div>
    </div>,
    document.body,
  )
}

// -------------------------------------------------------------- confirmation
interface ConfirmRequest {
  title: string
  message: ReactNode
  confirmLabel?: string
  danger?: boolean
  resolve: (ok: boolean) => void
}

const ConfirmContext = createContext<(req: Omit<ConfirmRequest, 'resolve'>) => Promise<boolean>>(
  async () => false,
)
export const useConfirm = () => useContext(ConfirmContext)

// ---------------------------------------------------------------- notifications
export interface Toast {
  id: number
  message: ReactNode
  tone: 'ok' | 'danger' | 'info' | 'warn'
}
const ToastContext = createContext<(message: ReactNode, tone?: Toast['tone']) => void>(() => {})
export const useToast = () => useContext(ToastContext)

export function UiProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const [request, setRequest] = useState<ConfirmRequest | null>(null)
  const counter = useRef(0)

  const notify = useCallback((message: ReactNode, tone: Toast['tone'] = 'info') => {
    const id = ++counter.current
    setToasts((current) => [...current, { id, message, tone }])
    // Un message long mérite plus de temps de lecture.
    const ttl = typeof message === 'string' && message.length > 160 ? 15000 : 5200
    setTimeout(() => setToasts((current) => current.filter((t) => t.id !== id)), ttl)
  }, [])

  const confirm = useCallback(
    (req: Omit<ConfirmRequest, 'resolve'>) =>
      new Promise<boolean>((resolve) => setRequest({ ...req, resolve })),
    [],
  )

  const close = (ok: boolean) => {
    request?.resolve(ok)
    setRequest(null)
  }

  const icons = { ok: <Check size={15} />, danger: <AlertTriangle size={15} />, warn: <AlertTriangle size={15} />, info: null }
  const tones = {
    ok: 'border-accent/40 bg-accent/10 text-accent',
    danger: 'border-danger/40 bg-danger/10 text-danger',
    warn: 'border-warn/40 bg-warn/10 text-warn',
    info: 'border-ink-600 bg-ink-800 text-mist-200',
  }

  return (
    <ToastContext.Provider value={notify}>
      <ConfirmContext.Provider value={confirm}>
        {children}

        <div className="fixed bottom-4 right-4 z-[60] flex flex-col gap-2 w-[min(24rem,calc(100vw-2rem))]">
          {toasts.map((toast) => (
            <div
              key={toast.id}
              className={clsx(
                'panel px-4 py-2.5 text-sm flex items-start gap-2 animate-slideUp border',
                tones[toast.tone],
              )}
            >
              {icons[toast.tone]}
              <span className="flex-1 min-w-0 break-words whitespace-pre-wrap">{toast.message}</span>
              <button
                className="opacity-50 hover:opacity-100 shrink-0"
                onClick={() => setToasts((c) => c.filter((t) => t.id !== toast.id))}
              >
                <X size={14} />
              </button>
            </div>
          ))}
        </div>

        <Modal
          open={!!request}
          onClose={() => close(false)}
          title={request?.title ?? ''}
          width="max-w-md"
          footer={
            <>
              <button className="btn-ghost" onClick={() => close(false)}>
                Annuler
              </button>
              <button
                className={request?.danger ? 'btn-danger' : 'btn-primary'}
                onClick={() => close(true)}
                autoFocus
              >
                {request?.confirmLabel ?? 'Confirmer'}
              </button>
            </>
          }
        >
          <div className="text-sm text-mist-300 leading-relaxed">{request?.message}</div>
        </Modal>
      </ConfirmContext.Provider>
    </ToastContext.Provider>
  )
}

// ------------------------------------------------------------------- divers
export function Spinner({ size = 16, className }: { size?: number; className?: string }) {
  return <Loader2 size={size} className={clsx('animate-spin', className)} />
}

export function Empty({ icon, title, hint, action }: { icon?: ReactNode; title: string; hint?: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center py-14 text-center gap-3">
      {icon && <div className="text-ink-600">{icon}</div>}
      <div>
        <div className="text-mist-200 font-medium">{title}</div>
        {hint && <div className="text-sm text-ink-500 mt-1 max-w-md">{hint}</div>}
      </div>
      {action}
    </div>
  )
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx('skeleton', className)} />
}

export function Tabs<T extends string>({
  tabs,
  active,
  onChange,
}: {
  tabs: { id: T; label: ReactNode; badge?: ReactNode }[]
  active: T
  onChange: (id: T) => void
}) {
  return (
    <div className="flex items-center gap-1 border-b border-ink-750 overflow-x-auto">
      {tabs.map((tab) => (
        <button
          key={tab.id}
          onClick={() => onChange(tab.id)}
          className={clsx(
            'relative px-3 py-2 text-sm font-medium transition-colors whitespace-nowrap flex items-center gap-1.5',
            active === tab.id ? 'text-accent' : 'text-mist-400 hover:text-mist-200',
          )}
        >
          {tab.label}
          {tab.badge}
          {active === tab.id && <span className="absolute inset-x-2 -bottom-px h-0.5 bg-accent rounded-full" />}
        </button>
      ))}
    </div>
  )
}

export function useDebounced<T>(value: T, delay = 250): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])
  return debounced
}

export function useLocalState<T>(key: string, initial: T) {
  const [value, setValue] = useState<T>(() => {
    try {
      const raw = localStorage.getItem(key)
      return raw ? (JSON.parse(raw) as T) : initial
    } catch {
      return initial
    }
  })
  useEffect(() => {
    localStorage.setItem(key, JSON.stringify(value))
  }, [key, value])
  return [value, setValue] as const
}

export const useMemoized = useMemo
