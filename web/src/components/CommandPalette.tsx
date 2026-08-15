import clsx from 'clsx'
import { useQuery } from '@tanstack/react-query'
import { Boxes, CornerDownLeft, Globe, Radar, Search, Server, TerminalSquare } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useNavigate } from 'react-router-dom'
import { get } from '@/lib/api'
import { KIND_LABEL } from '@/lib/format'
import { StatusDot } from './ui'

interface Item {
  id: string
  label: string
  hint?: string
  group: string
  icon: typeof Server
  status?: string
  action: () => void
}

export function CommandPalette({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [query, setQuery] = useState('')
  const [cursor, setCursor] = useState(0)
  const navigate = useNavigate()
  const input = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })
  const { data: containers = [] } = useQuery({
    queryKey: ['containers'],
    queryFn: () => get('/containers'),
    enabled: open,
  })
  const { data: services = [] } = useQuery({
    queryKey: ['services'],
    queryFn: () => get('/services'),
    enabled: open,
  })

  useEffect(() => {
    if (open) {
      setQuery('')
      setCursor(0)
      setTimeout(() => input.current?.focus(), 30)
    }
  }, [open])

  const items = useMemo<Item[]>(() => {
    const go = (path: string) => () => {
      navigate(path)
      onClose()
    }
    const list: Item[] = [
      { id: 'nav-overview', label: "Vue d'ensemble", group: 'Aller à', icon: Radar, action: go('/') },
      { id: 'nav-hosts', label: 'Hôtes', group: 'Aller à', icon: Server, action: go('/hosts') },
      { id: 'nav-containers', label: 'Conteneurs', group: 'Aller à', icon: Boxes, action: go('/containers') },
      { id: 'nav-services', label: 'Services web', group: 'Aller à', icon: Globe, action: go('/services') },
      { id: 'nav-terminal', label: 'Terminal', group: 'Aller à', icon: TerminalSquare, action: go('/terminal') },
      { id: 'nav-discovery', label: 'Scanner le réseau', group: 'Aller à', icon: Radar, action: go('/discovery') },
    ]
    for (const host of hosts) {
      list.push({
        id: `host-${host.id}`,
        label: host.name,
        hint: `${KIND_LABEL[host.kind] ?? host.kind} · ${host.address}`,
        group: 'Hôtes',
        icon: Server,
        status: host.status,
        action: go(`/hosts/${host.id}`),
      })
      if (host.kind === 'linux' || host.kind === 'docker') {
        list.push({
          id: `term-${host.id}`,
          label: `Terminal → ${host.name}`,
          hint: host.address,
          group: 'Terminal',
          icon: TerminalSquare,
          action: go(`/terminal?host=${host.id}`),
        })
      }
    }
    for (const container of containers) {
      list.push({
        id: `ct-${container.id}`,
        label: container.name,
        hint: `${container.host_name} · ${container.image ?? container.kind}`,
        group: 'Conteneurs',
        icon: Boxes,
        status: container.state,
        action: go(`/containers?q=${encodeURIComponent(container.name)}`),
      })
    }
    for (const service of services) {
      list.push({
        id: `svc-${service.id}`,
        label: service.name,
        hint: service.url,
        group: 'Services',
        icon: Globe,
        status: service.status,
        action: () => {
          window.open(service.url, '_blank', 'noopener')
          onClose()
        },
      })
    }
    return list
  }, [hosts, containers, services, navigate, onClose])

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase()
    if (!needle) return items.slice(0, 40)
    return items
      .map((item) => {
        const haystack = `${item.label} ${item.hint ?? ''}`.toLowerCase()
        const index = haystack.indexOf(needle)
        return index === -1 ? null : { item, score: index + (item.label.toLowerCase().startsWith(needle) ? -50 : 0) }
      })
      .filter((x): x is { item: Item; score: number } => x !== null)
      .sort((a, b) => a.score - b.score)
      .slice(0, 40)
      .map((x) => x.item)
  }, [items, query])

  useEffect(() => setCursor(0), [query])

  useEffect(() => {
    listRef.current?.querySelector('[data-active="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [cursor])

  if (!open) return null

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setCursor((c) => Math.min(c + 1, filtered.length - 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setCursor((c) => Math.max(c - 1, 0))
    } else if (event.key === 'Enter') {
      event.preventDefault()
      filtered[cursor]?.action()
    } else if (event.key === 'Escape') {
      onClose()
    }
  }

  let lastGroup = ''

  return createPortal(
    <div className="fixed inset-0 z-[70] flex items-start justify-center pt-[12vh] px-4">
      <div className="absolute inset-0 bg-ink-950/85 backdrop-blur-sm" onClick={onClose} />
      <div className="relative panel w-full max-w-xl overflow-hidden animate-slideUp">
        <div className="flex items-center gap-2.5 px-4 border-b border-ink-750">
          <Search size={16} className="text-ink-500 shrink-0" />
          <input
            ref={input}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder="Hôte, conteneur, service, action…"
            className="flex-1 bg-transparent border-0 px-0 py-3.5 text-[15px] focus:ring-0 placeholder:text-ink-500"
          />
          <kbd className="text-[10px] font-mono text-ink-500 border border-ink-700 rounded px-1.5 py-0.5">esc</kbd>
        </div>

        <div ref={listRef} className="max-h-[52vh] overflow-y-auto py-1.5">
          {filtered.length === 0 && (
            <div className="px-4 py-8 text-center text-sm text-ink-500">Aucun résultat pour « {query} »</div>
          )}
          {filtered.map((item, index) => {
            const header = item.group !== lastGroup ? item.group : null
            lastGroup = item.group
            const Icon = item.icon
            return (
              <div key={item.id}>
                {header && (
                  <div className="metric-label px-4 pt-2.5 pb-1">{header}</div>
                )}
                <button
                  data-active={index === cursor}
                  onMouseEnter={() => setCursor(index)}
                  onClick={item.action}
                  className={clsx(
                    'w-full flex items-center gap-2.5 px-4 py-2 text-left text-sm transition-colors',
                    index === cursor ? 'bg-accent/10 text-mist-100' : 'text-mist-300 hover:bg-ink-800',
                  )}
                >
                  <Icon size={15} className={index === cursor ? 'text-accent' : 'text-ink-500'} />
                  <span className="truncate flex-1">{item.label}</span>
                  {item.status && <StatusDot status={item.status} size={6} />}
                  {item.hint && <span className="text-xs text-ink-500 truncate max-w-[45%]">{item.hint}</span>}
                  {index === cursor && <CornerDownLeft size={13} className="text-ink-500 shrink-0" />}
                </button>
              </div>
            )
          })}
        </div>
      </div>
    </div>,
    document.body,
  )
}
