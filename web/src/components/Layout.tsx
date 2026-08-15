import clsx from 'clsx'
import {
  Activity,
  Bell,
  Bot,
  Boxes,
  CalendarClock,
  CircuitBoard,
  ChevronsLeft,
  Cpu,
  Gauge,
  Globe,
  House,
  HardDrive,
  LayoutDashboard,
  Library,
  LogOut,
  Radar,
  ScrollText,
  Server,
  ServerCog,
  ShieldAlert,
  ShieldCheck,
  Settings,
  Sparkles,
  TerminalSquare,
  Wifi,
  WifiOff,
} from 'lucide-react'
import { useEffect, useState } from 'react'
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { get, post, setToken } from '@/lib/api'
import { connectLive, useLive } from '@/lib/live'
import { CommandPalette } from './CommandPalette'
import { ErrorBoundary } from './ErrorBoundary'
import { Badge, StatusDot, useLocalState } from './ui'

const NAV = [
  { to: '/', label: "Vue d'ensemble", icon: LayoutDashboard, end: true },
  { to: '/hosts', label: 'Hôtes', icon: Server },
  { to: '/inventory', label: 'Inventaire', icon: Library },
  { to: '/monitoring', label: 'Monitoring', icon: Gauge },
  { to: '/containers', label: 'Conteneurs', icon: Boxes },
  { to: '/services', label: 'Services web', icon: Globe },
  { to: '/ai', label: 'IA & accélérateurs', icon: Sparkles },
  { to: '/agents', label: 'Agents IA', icon: Bot },
  { to: '/proxmox', label: 'Proxmox', icon: ServerCog },
  { to: '/synology', label: 'Synology', icon: HardDrive },
  { to: '/ipmi', label: 'Hors-bande', icon: CircuitBoard },
  { to: '/home', label: 'Domotique', icon: House },
  { to: '/terminal', label: 'Terminal', icon: TerminalSquare },
  { to: '/security', label: 'Sécurité', icon: ShieldAlert },
  { to: '/protection', label: 'Sauvegardes', icon: ShieldCheck },
  { to: '/discovery', label: 'Découverte', icon: Radar },
  { to: '/scheduler', label: 'Planificateur', icon: CalendarClock },
  { to: '/events', label: 'Journal', icon: ScrollText },
  { to: '/settings', label: 'Réglages', icon: Settings },
]

export function Layout() {
  const [collapsed, setCollapsed] = useLocalState('mba.sidebar', false)
  const [paletteOpen, setPaletteOpen] = useState(false)
  const connected = useLive((s) => s.connected)
  const toastAlert = useLive((s) => s.toastAlert)
  const navigate = useNavigate()
  const location = useLocation()
  const queryClient = useQueryClient()

  const { data: overview } = useQuery({
    queryKey: ['overview'],
    queryFn: () => get('/overview'),
    refetchInterval: 15000,
  })

  useEffect(() => {
    connectLive()
  }, [])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setPaletteOpen((open) => !open)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // Une alerte qui vient de tomber invalide la vue d'ensemble.
  useEffect(() => {
    if (toastAlert) queryClient.invalidateQueries({ queryKey: ['overview'] })
  }, [toastAlert, queryClient])

  const { data: security } = useQuery({
    queryKey: ['security'],
    queryFn: () => get('/security'),
    refetchInterval: 120000,
  })
  const criticalFindings =
    (security?.summary?.by_severity?.critical ?? 0) + (security?.summary?.by_severity?.high ?? 0)

  const alertCount = overview?.summary?.alerts_firing ?? 0
  const offline = overview?.summary?.hosts_offline ?? 0

  const logout = async () => {
    await post('/auth/logout').catch(() => {})
    setToken(null)
    navigate('/login')
  }

  return (
    <div className="flex h-full bg-ink-900">
      <aside
        className={clsx(
          'shrink-0 border-r border-ink-800 bg-ink-950/60 flex flex-col transition-[width] duration-200',
          collapsed ? 'w-[62px]' : 'w-[228px]',
        )}
      >
        <div className="h-14 flex items-center gap-2.5 px-4 border-b border-ink-800">
          <div className="w-7 h-7 rounded-lg bg-accent/15 border border-accent/30 grid place-items-center shrink-0">
            <Activity size={15} className="text-accent" />
          </div>
          {!collapsed && (
            <div className="min-w-0">
              <div className="text-sm font-semibold text-mist-100 leading-tight truncate">MyBeautifulAdmin</div>
              <div className="text-[10px] text-ink-500 leading-tight">Infrastructure</div>
            </div>
          )}
        </div>

        <nav className="flex-1 overflow-y-auto py-3 px-2 space-y-0.5">
          {NAV.map(({ to, label, icon: Icon, end }) => (
            <NavLink
              key={to}
              to={to}
              end={end}
              title={collapsed ? label : undefined}
              className={({ isActive }) =>
                clsx(
                  'group flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm transition-all relative',
                  isActive
                    ? 'bg-accent/10 text-accent font-medium'
                    : 'text-mist-400 hover:text-mist-100 hover:bg-ink-800',
                )
              }
            >
              {({ isActive }) => (
                <>
                  {isActive && <span className="absolute left-0 top-1.5 bottom-1.5 w-0.5 rounded-full bg-accent" />}
                  <Icon size={17} className="shrink-0" />
                  {!collapsed && <span className="truncate">{label}</span>}
                  {!collapsed && to === '/events' && alertCount > 0 && (
                    <Badge tone="danger" className="ml-auto">
                      {alertCount}
                    </Badge>
                  )}
                  {!collapsed && to === '/security' && criticalFindings > 0 && (
                    <Badge tone="danger" className="ml-auto">
                      {criticalFindings}
                    </Badge>
                  )}
                  {!collapsed && to === '/hosts' && offline > 0 && (
                    <Badge tone="danger" className="ml-auto">
                      {offline}
                    </Badge>
                  )}
                </>
              )}
            </NavLink>
          ))}
        </nav>

        <div className="p-2 border-t border-ink-800 space-y-0.5">
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="w-full flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm text-mist-400 hover:text-mist-100 hover:bg-ink-800 transition-colors"
          >
            <ChevronsLeft size={17} className={clsx('shrink-0 transition-transform', collapsed && 'rotate-180')} />
            {!collapsed && <span>Réduire</span>}
          </button>
          <button
            onClick={logout}
            className="w-full flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm text-mist-400 hover:text-danger hover:bg-danger/10 transition-colors"
          >
            <LogOut size={17} className="shrink-0" />
            {!collapsed && <span>Déconnexion</span>}
          </button>
        </div>
      </aside>

      <div className="flex-1 flex flex-col min-w-0">
        <header className="h-14 shrink-0 border-b border-ink-800 bg-ink-900/80 backdrop-blur flex items-center gap-3 px-4 sticky top-0 z-30">
          <button
            onClick={() => setPaletteOpen(true)}
            className="flex items-center gap-2 text-sm text-ink-500 bg-ink-850 border border-ink-750 rounded-lg px-3 py-1.5 hover:border-ink-600 hover:text-mist-300 transition-colors min-w-[13rem]"
          >
            <Radar size={14} />
            <span className="flex-1 text-left">Rechercher…</span>
            <kbd className="text-[10px] font-mono bg-ink-800 border border-ink-700 rounded px-1.5 py-0.5">⌘K</kbd>
          </button>

          <div className="flex-1" />

          <div className="hidden md:flex items-center gap-3 text-xs">
            <span className="flex items-center gap-1.5 text-mist-400">
              <Cpu size={13} className="text-ink-500" />
              <span className="metric-value">{(overview?.summary?.cpu_avg ?? 0).toFixed(0)}%</span>
              <span className="text-ink-500">CPU moy.</span>
            </span>
            <span className="w-px h-4 bg-ink-750" />
            <span className="flex items-center gap-1.5 text-mist-400">
              <Server size={13} className="text-ink-500" />
              <span className="metric-value">
                {overview?.summary?.hosts_online ?? 0}/{overview?.summary?.hosts_total ?? 0}
              </span>
            </span>
            <span className="w-px h-4 bg-ink-750" />
            <NavLink to="/events" className="flex items-center gap-1.5 hover:text-mist-100">
              <Bell size={13} className={alertCount ? 'text-danger' : 'text-ink-500'} />
              <span className={clsx('metric-value', alertCount && 'text-danger')}>{alertCount}</span>
            </NavLink>
          </div>

          <span className="w-px h-4 bg-ink-750 hidden md:block" />

          <span
            className={clsx(
              'flex items-center gap-1.5 text-xs px-2 py-1 rounded-md border',
              connected ? 'text-accent border-accent/25 bg-accent/5' : 'text-warn border-warn/25 bg-warn/5',
            )}
            title={connected ? 'Flux temps réel actif' : 'Reconnexion en cours…'}
          >
            {connected ? <Wifi size={13} /> : <WifiOff size={13} />}
            <StatusDot status={connected ? 'online' : 'warning'} size={6} />
          </span>
        </header>

        <main className="flex-1 overflow-y-auto">
          <ErrorBoundary key={location.pathname} label="Cette page">
            <Outlet />
          </ErrorBoundary>
        </main>
      </div>

      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} />
    </div>
  )
}
