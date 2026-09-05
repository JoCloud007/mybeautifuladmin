import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  ArrowUpCircle,
  Boxes,
  CalendarClock,
  CirclePlay,
  CircleStop,
  Download,
  HardDrive,
  LayoutGrid,
  Package,
  Plus,
  Power,
  RotateCcw,
  Rows3,
  Search,
  Server,
  Share2,
  ToggleLeft,
  ToggleRight,
  Users,
  Zap,
} from 'lucide-react'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { AddHostModal } from '@/components/AddHostModal'
import { LiveChart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Bar,
  Empty,
  Gauge,
  Spinner,
  StatusDot,
  Tabs,
  useConfirm,
  useLocalState,
  useToast,
} from '@/components/ui'
import { get, post } from '@/lib/api'
import { bitrate, bytes, percent, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

export function SynologyPage() {
  const { data: nas = [], isLoading } = useQuery({
    queryKey: ['syno-hosts'],
    queryFn: () => get('/synology/hosts'),
    refetchInterval: 20000,
  })
  const [selected, setSelected] = useState<number | null>(null)
  const [addOpen, setAddOpen] = useState(false)
  useLive((s) => s.bump)

  const current = nas.find((n: any) => n.id === (selected ?? nas[0]?.id))

  if (isLoading) {
    return (
      <Page>
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      </Page>
    )
  }

  if (nas.length === 0) {
    return (
      <Page>
        <PageHeader
          title="Synology"
          actions={
            <button className="btn-primary" onClick={() => setAddOpen(true)}>
              <Plus size={15} />
              Ajouter un NAS
            </button>
          }
        />
        <div className="panel">
          <Empty
            icon={<HardDrive size={38} />}
            title="Aucun NAS Synology enregistré"
            hint="Ajoute ton DiskStation avec un compte DSM disposant des droits d'administration. MBA remonte alors volumes, disques, SMART, paquets et partages."
            action={
              <div className="flex gap-2">
                <button className="btn-primary" onClick={() => setAddOpen(true)}>
                  <Plus size={15} />
                  Ajouter un NAS
                </button>
                <Link to="/discovery" className="btn-ghost">
                  Scanner le réseau
                </Link>
              </div>
            }
          />
        </div>
        <AddHostModal
          open={addOpen}
          onClose={() => setAddOpen(false)}
          kind="synology"
          title="Ajouter un NAS Synology"
        />
      </Page>
    )
  }

  return (
    <Page>
      <PageHeader
        title="Synology"
        subtitle={`${nas.length} NAS supervisé(s)`}
        actions={
          <>
            {nas.length > 1 && (
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {nas.map((item: any) => (
                <button
                  key={item.id}
                  onClick={() => setSelected(item.id)}
                  className={clsx(
                    'px-3 py-1 rounded-md text-xs font-medium transition-colors flex items-center gap-1.5',
                    current?.id === item.id ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                >
                  <StatusDot status={item.status} size={6} />
                  {item.name}
                </button>
              ))}
            </div>
            )}
            <button className="btn-primary" onClick={() => setAddOpen(true)}>
              <Plus size={15} />
              Ajouter un NAS
            </button>
          </>
        }
      />
      {current && <NasPanel nas={current} />}
      <AddHostModal
        open={addOpen}
        onClose={() => setAddOpen(false)}
        kind="synology"
        title="Ajouter un NAS Synology"
      />
    </Page>
  )
}

type NasTab = 'storage' | 'packages' | 'system' | 'tasks' | 'shares' | 'access'

function NasPanel({ nas }: { nas: any }) {
  const [tab, setTab] = useState<NasTab>('storage')
  const live = useLive.getState().samples[nas.id] ?? nas.live ?? {}
  const info = live.info ?? nas.info ?? nas.meta ?? {}
  const volumes = live.volumes ?? nas.volumes ?? []
  const disks = live.disks ?? nas.disks ?? []
  const pools = live.pools ?? nas.pools ?? []

  const confirm = useConfirm()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)

  // Sondés ici pour pastiller les onglets ; les onglets réutilisent les mêmes
  // clés, React Query ne rejoue donc pas les requêtes.
  const { data: packageData } = useQuery({
    queryKey: ['syno-packages', nas.id],
    queryFn: () => get(`/synology/${nas.id}/packages`),
    retry: false,
  })
  const { data: dsm } = useQuery({
    queryKey: ['syno-dsm', nas.id],
    queryFn: () => get(`/synology/${nas.id}/dsm-update`),
    retry: false,
  })
  const updates: number = packageData?.updates?.length ?? 0

  const power = async (action: 'reboot' | 'shutdown') => {
    const ok = await confirm({
      title: action === 'reboot' ? 'Redémarrer le NAS ?' : 'Éteindre le NAS ?',
      message: (
        <>
          <b className="text-mist-100">{nas.name}</b> ({info.model ?? nas.address}) va{' '}
          {action === 'reboot' ? 'redémarrer' : "s'éteindre"}. Tous les partages et paquets seront interrompus.
        </>
      ),
      confirmLabel: action === 'reboot' ? 'Redémarrer' : 'Éteindre',
      danger: true,
    })
    if (!ok) return
    setBusy(action)
    try {
      await post(`/hosts/${nas.id}/power/${action}`)
      toast(action === 'reboot' ? 'Redémarrage demandé' : 'Extinction demandée', 'ok')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="space-y-4">
      <div className="panel p-4">
        <div className="flex flex-wrap items-start gap-4">
          <div className="flex items-start gap-3 min-w-0 flex-1">
            <div className="w-10 h-10 rounded-lg bg-warn/12 border border-warn/25 grid place-items-center shrink-0">
              <Server size={19} className="text-warn" />
            </div>
            <div className="min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <StatusDot status={nas.status} />
                <h2 className="font-semibold text-mist-100">{nas.name}</h2>
                {info.model && <Badge tone="warn">{info.model}</Badge>}
                {info.temp_warn && <Badge tone="danger">Alerte thermique</Badge>}
              </div>
              <p className="text-[12px] text-ink-500 font-mono mt-1">
                {nas.address}
                {info.dsm_version && ` · DSM ${info.dsm_version}`}
                {info.serial && ` · ${info.serial}`}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <button className="btn-ghost" onClick={() => power('reboot')} disabled={busy === 'reboot'}>
              {busy === 'reboot' ? <Spinner size={14} /> : <RotateCcw size={15} />}
              Redémarrer
            </button>
            <button className="btn-danger" onClick={() => power('shutdown')} disabled={busy === 'shutdown'}>
              <Power size={15} />
              Éteindre
            </button>
          </div>
        </div>

        <div className="flex flex-wrap items-center justify-around gap-5 mt-5 pt-4 border-t border-ink-800">
          <Gauge value={live['cpu.usage'] ?? 0} label="Processeur" />
          <Gauge value={live['mem.percent'] ?? 0} label="Mémoire" sub={bytes(live['mem.used'])} />
          <Gauge value={live['disk.percent'] ?? 0} label="Volume le + plein" />
          <div className="flex flex-col items-center gap-1">
            <div className="h-[92px] flex flex-col items-center justify-center gap-1.5">
              <div className="flex items-center gap-1.5 text-sm">
                <span className="text-info metric-value">{bitrate(live['net.rx'])}</span>
                <span className="text-ink-600">↓</span>
              </div>
              <div className="flex items-center gap-1.5 text-sm">
                <span className="text-violet metric-value">{bitrate(live['net.tx'])}</span>
                <span className="text-ink-600">↑</span>
              </div>
            </div>
            <span className="metric-label">Réseau</span>
          </div>
          {live['temp.cpu'] !== undefined && (
            <div className="flex flex-col items-center gap-1">
              <div className="h-[92px] flex items-center">
                <span className="metric-value text-2xl" style={{ color: severity(live['temp.cpu'], 60, 75).color }}>
                  {live['temp.cpu'].toFixed(0)}°
                </span>
              </div>
              <span className="metric-label">Température</span>
            </div>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
        <div className="panel p-4">
          <SectionTitle>Charge</SectionTitle>
          <LiveChart
            hostId={nas.id}
            height={150}
            format={(v) => `${v.toFixed(0)}%`}
            yRange={[0, 100]}
            specs={[
              { label: 'CPU', metric: 'cpu.usage', color: PALETTE[0] },
              { label: 'RAM', metric: 'mem.percent', color: PALETTE[1] },
            ]}
          />
        </div>
        <div className="panel p-4">
          <SectionTitle>Réseau</SectionTitle>
          <LiveChart
            hostId={nas.id}
            height={150}
            format={(v) => bitrate(Math.abs(v))}
            specs={[
              { label: 'Réception', metric: 'net.rx', color: PALETTE[1] },
              { label: 'Émission', metric: 'net.tx', color: PALETTE[2], negative: true },
            ]}
          />
        </div>
      </div>

      <Tabs
        active={tab}
        onChange={setTab}
        tabs={[
          { id: 'storage' as const, label: 'Stockage' },
          {
            id: 'packages' as const,
            label: 'Paquets',
            badge: updates > 0 ? <Badge tone="info">{updates}</Badge> : undefined,
          },
          {
            id: 'system' as const,
            label: 'Système',
            badge: dsm?.available ? <Badge tone="warn">DSM</Badge> : undefined,
          },
          { id: 'tasks' as const, label: 'Tâches' },
          { id: 'shares' as const, label: 'Partages' },
          { id: 'access' as const, label: 'Accès' },
        ]}
      />

      {tab === 'storage' && <StorageTab volumes={volumes} disks={disks} pools={pools} />}
      {tab === 'packages' && <PackagesTab nas={nas} />}
      {tab === 'system' && <SystemTab nas={nas} />}
      {tab === 'tasks' && <TasksTab nas={nas} />}
      {tab === 'shares' && <SharesTab nas={nas} />}
      {tab === 'access' && <AccessTab nas={nas} />}
    </div>
  )
}

function StorageTab({ volumes, disks, pools }: { volumes: any[]; disks: any[]; pools: any[] }) {
  if (!volumes.length && !disks.length) {
    return (
      <div className="panel">
        <Empty icon={<HardDrive size={32} />} title="Données de stockage en attente" hint="Le premier cycle de collecte est en cours." />
      </div>
    )
  }
  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
      <div className="panel p-4">
        <SectionTitle right={<span className="text-xs text-ink-500">{volumes.length} volumes</span>}>
          Volumes
        </SectionTitle>
        <div className="space-y-3.5">
          {volumes.map((volume: any) => (
            <div key={volume.id} className="space-y-1.5">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[13px] text-mist-100">
                  {volume.name}
                  <span className="text-ink-600 text-[11px] ml-1.5 font-mono">
                    {volume.fs} · {volume.raid}
                  </span>
                </span>
                <span className="metric-value text-xs" style={{ color: severity(volume.percent).color }}>
                  {percent(volume.percent, 1)}
                </span>
              </div>
              <Bar value={volume.percent} height={7} />
              <div className="flex justify-between text-[11px] text-ink-500 font-mono">
                <span>
                  {bytes(volume.used)} / {bytes(volume.total)}
                </span>
                <span>{bytes(volume.total - volume.used)} libres</span>
              </div>
            </div>
          ))}
          {pools.length > 0 && (
            <div className="pt-2 border-t border-ink-800 space-y-1">
              <div className="metric-label">Groupes de stockage</div>
              {pools.map((pool: any) => (
                <div key={pool.id} className="flex items-center justify-between text-[12px]">
                  <span className="text-mist-300 font-mono">{pool.id}</span>
                  <span className="text-ink-500">{pool.raid}</span>
                  <Badge tone={pool.status === 'normal' ? 'ok' : 'warn'}>{pool.status}</Badge>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="panel p-4">
        <SectionTitle right={<span className="text-xs text-ink-500">{disks.length} disques</span>}>Disques</SectionTitle>
        <div className="space-y-0.5">
          {disks.map((disk: any) => (
            <div key={disk.id} className="flex items-center gap-3 py-2 border-b border-ink-800/60 last:border-0">
              <HardDrive size={15} className="text-ink-500 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-100 truncate">
                  {disk.name}
                  <span className="text-ink-600 text-[11px] ml-1.5">
                    {disk.vendor} {disk.model}
                  </span>
                </div>
                <div className="text-[10px] text-ink-600 font-mono">
                  {bytes(disk.size)} · {disk.type ?? 'HDD'}
                </div>
              </div>
              {disk.temp != null && disk.temp > 0 && (
                <span className="metric-value text-xs" style={{ color: severity(disk.temp, 45, 55).color }}>
                  {disk.temp}°C
                </span>
              )}
              <Badge tone={disk.status === 'normal' && disk.smart !== 'critical' ? 'ok' : 'danger'}>
                {disk.smart ?? disk.status}
              </Badge>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

/** DSM emploie « running » ou « start » selon les versions pour un paquet actif. */
const isRunning = (pkg: any) => pkg.status === 'running' || pkg.status === 'start'

function PackagesTab({ nas }: { nas: any }) {
  const queryClient = useQueryClient()
  const toast = useToast()
  const confirm = useConfirm()
  const [busy, setBusy] = useState<string | null>(null)
  const [view, setView] = useLocalState<'list' | 'cards'>('mba.synoPkgView', 'list')
  const [query, setQuery] = useState('')
  const [onlyRunning, setOnlyRunning] = useState(false)

  const { data, isLoading, error } = useQuery({
    queryKey: ['syno-packages', nas.id],
    queryFn: () => get(`/synology/${nas.id}/packages`),
    retry: false,
  })

  const packages: any[] = data?.packages ?? []
  const updates: any[] = data?.updates ?? []
  // Un paquet peut être présent dans le catalogue sans être installé : on ne
  // propose la mise à jour que pour ceux qu'on voit réellement sur le NAS.
  const upgradable = new Map(updates.map((u: any) => [u.id, u]))

  const needle = query.trim().toLowerCase()
  // Ce qui a une mise à jour remonte en tête, puis les paquets actifs.
  const visible = packages
    .filter((pkg) => !onlyRunning || isRunning(pkg))
    .filter((pkg) => !needle || `${pkg.name} ${pkg.id} ${pkg.description ?? ''}`.toLowerCase().includes(needle))
    .sort(
      (a, b) =>
        Number(upgradable.has(b.id)) - Number(upgradable.has(a.id)) ||
        Number(isRunning(b)) - Number(isRunning(a)) ||
        (a.name ?? '').localeCompare(b.name ?? ''),
    )

  const upgrade = async (pkg: any) => {
    const update = upgradable.get(pkg.id)
    const ok = await confirm({
      title: 'Mettre à jour ce paquet ?',
      message: (
        <>
          <b className="text-mist-100">{pkg.name}</b> passera de{' '}
          <code className="font-mono text-mist-300">{pkg.version ?? '?'}</code> à{' '}
          <code className="font-mono text-accent">{update?.version ?? 'la dernière version'}</code>{' '}
          sur {nas.name}. DSM interrompt le paquet le temps de l'installation.
        </>
      ),
      confirmLabel: 'Mettre à jour',
    })
    if (!ok) return
    setBusy(pkg.id)
    try {
      const result = await post(`/synology/${nas.id}/package/upgrade`, { package_id: pkg.id })
      toast(result?.detail ?? `${pkg.name} : mise à jour lancée`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['syno-packages', nas.id] }), 5000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const act = async (pkg: any, action: 'start' | 'stop') => {
    if (action === 'stop') {
      const ok = await confirm({
        title: 'Arrêter ce paquet ?',
        message: (
          <>
            <b className="text-mist-100">{pkg.name}</b> sera arrêté sur {nas.name}.
          </>
        ),
        confirmLabel: 'Arrêter',
        danger: true,
      })
      if (!ok) return
    }
    setBusy(pkg.id)
    try {
      await post(`/synology/${nas.id}/package`, { package_id: pkg.id, action })
      toast(`${pkg.name} : ${action === 'start' ? 'démarré' : 'arrêté'}`, 'ok')
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['syno-packages', nas.id] }), 2000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  if (isLoading) return <div className="panel p-10 grid place-items-center"><Spinner size={20} /></div>
  if (error) {
    return (
      <div className="panel">
        <Empty icon={<Package size={32} />} title="Paquets indisponibles" hint={(error as Error).message} />
      </div>
    )
  }

  // DSM refuse parfois la liste sans lever d'erreur HTTP : la raison est alors
  // dans la réponse, et elle dit quoi corriger.
  if (data?.reason) {
    return (
      <div className="panel">
        <Empty icon={<Package size={32} />} title="Paquets indisponibles" hint={data.reason} />
      </div>
    )
  }

  const upgradeAll = async () => {
    const ok = await confirm({
      title: 'Mettre à jour tous les paquets ?',
      message: (
        <>
          {updates.length} paquet(s) seront mis à jour sur <b className="text-mist-100">{nas.name}</b> :{' '}
          {updates.map((u: any) => u.name).join(', ')}.
          <span className="block mt-2 text-warn">
            DSM interrompt chaque paquet le temps de son installation.
          </span>
        </>
      ),
      confirmLabel: 'Tout mettre à jour',
    })
    if (!ok) return
    setBusy('all')
    try {
      const result = await post(`/synology/${nas.id}/packages/upgrade-all`, {})
      toast(
        result.detail ??
          `${result.done.length} paquet(s) lancé(s)` +
            (result.errors.length ? `, ${result.errors.length} en échec` : ''),
        result.errors.length ? 'warn' : 'ok',
      )
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['syno-packages', nas.id] }), 5000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="space-y-3">
      {updates.length > 0 && (
        <div className="panel p-3 flex items-center gap-3 border-accent/25 bg-accent/[0.05]">
          <ArrowUpCircle size={18} className="text-accent shrink-0" />
          <div className="flex-1 min-w-0 text-[13px] text-mist-200">
            <b className="text-mist-100">
              {updates.length} mise{updates.length > 1 ? 's' : ''} à jour
            </b>{' '}
            proposée{updates.length > 1 ? 's' : ''} par le catalogue Synology —{' '}
            {updates.map((u: any) => u.name).join(', ')}
          </div>
          <button className="btn-primary shrink-0" onClick={upgradeAll} disabled={busy === 'all'}>
            {busy === 'all' ? <Spinner size={14} /> : <ArrowUpCircle size={15} />}
            Tout mettre à jour
          </button>
        </div>
      )}

      <div className="flex flex-wrap items-center gap-2">
        <div className="relative">
          <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Filtrer…"
            className="pl-8 py-1.5 w-44"
          />
        </div>
        <label className="flex items-center gap-2 text-xs text-mist-400 cursor-pointer">
          <input type="checkbox" checked={onlyRunning} onChange={(e) => setOnlyRunning(e.target.checked)} />
          Démarrés seulement
        </label>
        <span className="text-xs text-ink-600">
          {visible.length}/{packages.length} paquet(s)
        </span>
        <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5 ml-auto">
          {(
            [
              ['list', 'Liste', Rows3],
              ['cards', 'Cartes', LayoutGrid],
            ] as const
          ).map(([value, label, Icon]) => (
            <button
              key={value}
              onClick={() => setView(value)}
              className={clsx(
                'px-2 py-1 rounded-md text-xs font-medium transition-colors',
                view === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
              )}
              title={label}
            >
              <Icon size={13} />
            </button>
          ))}
        </div>
      </div>

      {visible.length === 0 && (
        <div className="panel">
          <Empty
            icon={<Package size={32} />}
            title={packages.length ? 'Aucun paquet ne correspond' : 'Aucun paquet installé'}
          />
        </div>
      )}

      {/* Liste : une ligne par paquet, colonnes alignées — c'est ce qui se lit
          quand un NAS en héberge trente. */}
      {view === 'list' && visible.length > 0 && (
        <div className="panel overflow-x-auto">
          <table className="w-full text-sm min-w-[680px]">
            <thead>
              <tr className="text-left border-b border-ink-750">
                {['Paquet', 'Version', 'Disponible', 'État', ''].map((header) => (
                  <th key={header} className="metric-label px-3 py-2 font-semibold">
                    {header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {visible.map((pkg: any) => {
                const running = isRunning(pkg)
                const update = upgradable.get(pkg.id)
                return (
                  <tr
                    key={pkg.id}
                    className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40 transition-colors"
                  >
                    <td className="px-3 py-2">
                      <div className="flex items-center gap-2" title={pkg.description || undefined}>
                        <StatusDot status={running ? 'running' : 'exited'} size={6} />
                        <span className={running ? 'text-mist-100' : 'text-mist-400'}>{pkg.name}</span>
                      </div>
                    </td>
                    <td className="px-3 py-2 text-[11px] text-ink-500 font-mono">{pkg.version ?? '—'}</td>
                    <td className="px-3 py-2 text-[11px] font-mono">
                      {update ? (
                        <span className="text-accent">{update.version}</span>
                      ) : (
                        <span className="text-ink-700">à jour</span>
                      )}
                    </td>
                    <td className="px-3 py-2">
                      <Badge tone={running ? 'ok' : 'neutral'}>{pkg.status}</Badge>
                    </td>
                    <td className="px-3 py-2">
                      <div className="flex items-center justify-end gap-1">
                        {update && (
                          <button
                            className="btn-ghost py-1 px-2 text-xs text-accent"
                            onClick={() => upgrade(pkg)}
                            title={`Mettre à jour vers ${update.version}`}
                            disabled={busy === pkg.id}
                          >
                            {busy === pkg.id ? <Spinner size={12} /> : <ArrowUpCircle size={13} />}
                            Mettre à jour
                          </button>
                        )}
                        <button
                          className={clsx('btn-ghost py-1 px-2 text-xs', running && 'hover:text-danger')}
                          onClick={() => act(pkg, running ? 'stop' : 'start')}
                          title={running ? `Arrêter ${pkg.name}` : `Démarrer ${pkg.name}`}
                          disabled={busy === pkg.id}
                        >
                          {busy === pkg.id ? (
                            <Spinner size={12} />
                          ) : running ? (
                            <CircleStop size={13} />
                          ) : (
                            <CirclePlay size={13} />
                          )}
                          {running ? 'Arrêter' : 'Démarrer'}
                        </button>
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {view === 'cards' && visible.length > 0 && (
        <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(300px,1fr))]">
          {visible.map((pkg: any) => {
            const running = isRunning(pkg)
            const update = upgradable.get(pkg.id)
            return (
              <div
                key={pkg.id}
                className={clsx('panel p-3 flex items-center gap-2.5', !running && 'opacity-70')}
                title={pkg.description || undefined}
              >
                <Boxes size={16} className={running ? 'text-accent' : 'text-ink-500'} />
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-100 truncate">{pkg.name}</div>
                  <div className="text-[10px] text-ink-600 font-mono truncate">
                    {pkg.version}
                    {update && <span className="text-accent"> → {update.version}</span>}
                  </div>
                </div>
                {update ? (
                  <Badge tone="info">à jour dispo.</Badge>
                ) : (
                  <Badge tone={running ? 'ok' : 'neutral'}>{pkg.status}</Badge>
                )}
                {update && (
                  <button
                    className="btn-icon text-accent"
                    onClick={() => upgrade(pkg)}
                    title={`Mettre à jour vers ${update.version}`}
                    disabled={busy === pkg.id}
                  >
                    {busy === pkg.id ? <Spinner size={13} /> : <ArrowUpCircle size={14} />}
                  </button>
                )}
                {/* Un carré seul ne disait pas ce qu'il faisait : l'action est écrite. */}
                <button
                  className={clsx('btn-ghost py-1 px-2 text-xs shrink-0', running && 'hover:text-danger')}
                  onClick={() => act(pkg, running ? 'stop' : 'start')}
                  title={running ? `Arrêter ${pkg.name}` : `Démarrer ${pkg.name}`}
                  disabled={busy === pkg.id}
                >
                  {busy === pkg.id ? (
                    <Spinner size={13} />
                  ) : running ? (
                    <CircleStop size={14} />
                  ) : (
                    <CirclePlay size={14} />
                  )}
                  {running ? 'Arrêter' : 'Démarrer'}
                </button>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

/** Mise à jour de DSM lui-même, et services système exposés par le NAS. */
function SystemTab({ nas }: { nas: any }) {
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)

  const { data: dsm, isLoading } = useQuery({
    queryKey: ['syno-dsm', nas.id],
    queryFn: () => get(`/synology/${nas.id}/dsm-update`),
    retry: false,
  })
  const { data: services } = useQuery({
    queryKey: ['syno-services', nas.id],
    queryFn: () => get(`/synology/${nas.id}/services`),
    retry: false,
  })

  const step = async (action: 'download' | 'install') => {
    if (action === 'install') {
      const ok = await confirm({
        title: 'Installer la mise à jour DSM ?',
        message: (
          <>
            <b className="text-mist-100">{nas.name}</b> installera{' '}
            <code className="font-mono text-accent">{dsm?.version}</code> puis redémarrera. Tous les
            partages, paquets et machines virtuelles hébergés seront interrompus plusieurs minutes.
          </>
        ),
        confirmLabel: 'Installer et redémarrer',
        danger: true,
      })
      if (!ok) return
    }
    setBusy(action)
    try {
      await post(`/synology/${nas.id}/dsm-update/${action}`)
      toast(
        action === 'download' ? 'Téléchargement lancé sur le NAS' : 'Installation lancée — le NAS va redémarrer',
        'ok',
      )
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['syno-dsm', nas.id] }), 4000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  if (isLoading) return <div className="panel p-10 grid place-items-center"><Spinner size={20} /></div>

  const downloaded = dsm?.download?.finished
  return (
    <div className="space-y-4">
      <div className="panel p-4 space-y-3">
        <SectionTitle right={dsm?.current && <span className="text-xs text-ink-500 font-mono">{dsm.current}</span>}>
          Mise à jour DSM
        </SectionTitle>

        {dsm?.reason ? (
          <p className="text-[13px] text-warn">{dsm.reason}</p>
        ) : dsm?.available ? (
          <>
            <div className="flex flex-wrap items-center gap-3">
              <ArrowUpCircle size={18} className="text-accent shrink-0" />
              <div className="min-w-0 flex-1 text-[13px] text-mist-200">
                <b className="text-mist-100">{dsm.version}</b> est disponible
                {dsm.type && <span className="text-ink-500"> · mise à jour {dsm.type}</span>}
                {dsm.reboot && dsm.reboot !== 'none' && (
                  <span className="text-warn"> · redémarrage requis</span>
                )}
              </div>
              {dsm.can_download && !downloaded && (
                <button className="btn-ghost" onClick={() => step('download')} disabled={busy === 'download'}>
                  {busy === 'download' ? <Spinner size={14} /> : <Download size={15} />}
                  Télécharger
                </button>
              )}
              {dsm.can_install && (
                <button className="btn-danger" onClick={() => step('install')} disabled={busy === 'install'}>
                  {busy === 'install' ? <Spinner size={14} /> : <ArrowUpCircle size={15} />}
                  Installer
                </button>
              )}
            </div>
            {dsm.download && (
              <div className="space-y-1.5">
                <div className="flex justify-between text-[11px] text-ink-500">
                  <span>Téléchargement {dsm.download.status ?? ''}</span>
                  <span className="font-mono">{percent(dsm.download.percent, 0)}</span>
                </div>
                <Bar value={Number(dsm.download.percent) || 0} height={5} />
              </div>
            )}
            <p className="text-[11px] text-ink-500">
              Le téléchargement seul n'interrompt rien : tu peux préparer la mise à jour maintenant et
              l'installer plus tard.
            </p>
          </>
        ) : (
          <p className="text-[13px] text-mist-300">
            DSM est à jour{dsm?.current ? ` (${dsm.current})` : ''}.
          </p>
        )}

        {dsm?.auto_update !== undefined && dsm?.auto_update !== null && (
          <div className="text-[11px] text-ink-500 pt-2 border-t border-ink-800">
            Mise à jour automatique DSM : {dsm.auto_update ? 'activée' : 'désactivée'} (réglage géré depuis DSM)
          </div>
        )}
      </div>

      <div className="panel p-4">
        <SectionTitle right={<span className="text-xs text-ink-500">{services?.services?.length ?? 0} services</span>}>
          Services DSM
        </SectionTitle>
        {services?.reason ? (
          <p className="text-[13px] text-ink-500">{services.reason}</p>
        ) : (
          <div className="grid gap-1.5 grid-cols-[repeat(auto-fill,minmax(220px,1fr))]">
            {(services?.services ?? []).map((service: any) => (
              <div
                key={service.id}
                className="flex items-center gap-2 bg-ink-850 border border-ink-800 rounded-lg px-2.5 py-1.5"
              >
                <StatusDot status={service.enabled ? 'running' : 'exited'} size={6} />
                <span className="text-[12px] text-mist-200 truncate flex-1">{service.name}</span>
                <span className="text-[10px] text-ink-600 font-mono truncate">{service.id}</span>
              </div>
            ))}
            {(services?.services ?? []).length === 0 && (
              <span className="text-[13px] text-ink-500">Aucun service remonté par DSM.</span>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

/** Planificateur de tâches DSM : ce que le NAS lance tout seul. */
function TasksTab({ nas }: { nas: any }) {
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()
  const [busy, setBusy] = useState<number | null>(null)

  const { data, isLoading, error } = useQuery({
    queryKey: ['syno-tasks', nas.id],
    queryFn: () => get(`/synology/${nas.id}/tasks`),
    retry: false,
  })

  const act = async (task: any, action: 'run' | 'enable' | 'disable') => {
    if (action === 'run') {
      const ok = await confirm({
        title: 'Exécuter cette tâche maintenant ?',
        message: (
          <>
            <b className="text-mist-100">{task.name}</b> sera lancée immédiatement sur {nas.name}. Sa
            planification habituelle reste inchangée.
          </>
        ),
        confirmLabel: 'Exécuter',
      })
      if (!ok) return
    }
    setBusy(task.id)
    try {
      await post(`/synology/${nas.id}/tasks`, { task_id: task.id, action })
      toast(
        `${task.name} : ${{ run: 'exécution lancée', enable: 'activée', disable: 'désactivée' }[action]}`,
        'ok',
      )
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ['syno-tasks', nas.id] }), 2000)
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  if (isLoading) return <div className="panel p-10 grid place-items-center"><Spinner size={20} /></div>
  if (error || data?.reason) {
    return (
      <div className="panel">
        <Empty
          icon={<CalendarClock size={32} />}
          title="Tâches planifiées indisponibles"
          hint={data?.reason ?? (error as Error).message}
        />
      </div>
    )
  }

  const tasks: any[] = data?.tasks ?? []
  return (
    <div className="panel overflow-x-auto">
      <table className="w-full text-sm min-w-[680px]">
        <thead>
          <tr className="text-left border-b border-ink-750">
            {['Tâche', 'Type', 'Propriétaire', 'Planification', 'Dernier résultat', ''].map((header) => (
              <th key={header} className="metric-label px-3 py-2 font-semibold">
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {tasks.map((task) => (
            <tr key={task.id} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
              <td className="px-3 py-2">
                <div className="flex items-center gap-2">
                  <StatusDot status={task.enabled ? 'running' : 'exited'} size={6} />
                  <span className={task.enabled ? 'text-mist-100' : 'text-mist-400'}>{task.name}</span>
                </div>
              </td>
              <td className="px-3 py-2 text-xs text-ink-500">{task.type ?? '—'}</td>
              <td className="px-3 py-2 text-xs text-ink-500 font-mono">{task.owner ?? '—'}</td>
              <td className="px-3 py-2 text-xs text-mist-400 truncate max-w-[220px]">
                {task.schedule ?? (task.enabled ? 'planifiée' : 'désactivée')}
              </td>
              <td className="px-3 py-2">
                {task.last_status ? (
                  <Badge tone={String(task.last_status).toLowerCase().includes('success') ? 'ok' : 'warn'}>
                    {task.last_status}
                  </Badge>
                ) : (
                  <span className="text-ink-600">—</span>
                )}
              </td>
              <td className="px-3 py-2">
                <div className="flex items-center justify-end gap-1">
                  <button
                    className="btn-ghost py-1 px-2 text-xs"
                    onClick={() => act(task, task.enabled ? 'disable' : 'enable')}
                    title={task.enabled ? 'Désactiver cette tâche' : 'Activer cette tâche'}
                    disabled={busy === task.id}
                  >
                    {busy === task.id ? (
                      <Spinner size={13} />
                    ) : task.enabled ? (
                      <ToggleRight size={15} className="text-accent" />
                    ) : (
                      <ToggleLeft size={15} />
                    )}
                    {task.enabled ? 'Activée' : 'Inactive'}
                  </button>
                  <button
                    className="btn-ghost py-1 px-2 text-xs"
                    onClick={() => act(task, 'run')}
                    title="Exécuter maintenant"
                    disabled={busy === task.id || task.can_run === false}
                  >
                    <Zap size={14} />
                    Exécuter
                  </button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {tasks.length === 0 && <Empty icon={<CalendarClock size={30} />} title="Aucune tâche planifiée" />}
    </div>
  )
}

/** Comptes DSM et sessions ouvertes : qui peut entrer, qui est entré. */
function AccessTab({ nas }: { nas: any }) {
  const { data, isLoading, error } = useQuery({
    queryKey: ['syno-access', nas.id],
    queryFn: () => get(`/synology/${nas.id}/access`),
    retry: false,
  })

  if (isLoading) return <div className="panel p-10 grid place-items-center"><Spinner size={20} /></div>
  if (error) {
    return (
      <div className="panel">
        <Empty icon={<Users size={32} />} title="Accès indisponibles" hint={(error as Error).message} />
      </div>
    )
  }

  const users: any[] = data?.users?.users ?? []
  const connections: any[] = data?.connections?.connections ?? []

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
      <div className="panel p-4">
        <SectionTitle right={<span className="text-xs text-ink-500">{users.length} comptes</span>}>
          Comptes DSM
        </SectionTitle>
        {data?.users?.reason && <p className="text-[12px] text-ink-500 mb-2">{data.users.reason}</p>}
        <div className="space-y-0.5">
          {users.map((user) => (
            <div key={user.name} className="flex items-center gap-2 py-1.5 border-b border-ink-800/60 last:border-0">
              <Users size={13} className="text-ink-500 shrink-0" />
              <span className="text-[13px] text-mist-100">{user.name}</span>
              {user.admin && <Badge tone="warn">admin</Badge>}
              {user.expired && user.expired !== 'normal' && <Badge tone="danger">{user.expired}</Badge>}
              <span className="text-[11px] text-ink-600 truncate ml-auto">{user.description || user.email || ''}</span>
            </div>
          ))}
          {users.length === 0 && <p className="text-[13px] text-ink-500">Aucun compte remonté.</p>}
        </div>
      </div>

      <div className="panel p-4">
        <SectionTitle right={<span className="text-xs text-ink-500">{connections.length} sessions</span>}>
          Connexions en cours
        </SectionTitle>
        {data?.connections?.reason && (
          <p className="text-[12px] text-ink-500 mb-2">{data.connections.reason}</p>
        )}
        <div className="space-y-0.5">
          {connections.map((connection, index) => (
            <div key={index} className="flex items-center gap-2 py-1.5 border-b border-ink-800/60 last:border-0">
              <StatusDot status="running" size={6} />
              <span className="text-[13px] text-mist-100">{connection.who || '—'}</span>
              <span className="text-[11px] text-ink-500 font-mono">{connection.from}</span>
              <Badge className="ml-auto">{connection.type || connection.descr || '—'}</Badge>
            </div>
          ))}
          {connections.length === 0 && <p className="text-[13px] text-ink-500">Aucune session ouverte.</p>}
        </div>
      </div>
    </div>
  )
}

function SharesTab({ nas }: { nas: any }) {
  const { data: shares = [], isLoading, error } = useQuery({
    queryKey: ['syno-shares', nas.id],
    queryFn: () => get(`/synology/${nas.id}/shares`),
    retry: false,
  })

  if (isLoading) return <div className="panel p-10 grid place-items-center"><Spinner size={20} /></div>
  if (error) {
    return (
      <div className="panel">
        <Empty icon={<Share2 size={32} />} title="Partages indisponibles" hint={(error as Error).message} />
      </div>
    )
  }

  return (
    <div className="panel overflow-x-auto">
      <table className="w-full text-sm min-w-[520px]">
        <thead>
          <tr className="text-left border-b border-ink-750">
            {['Partage', 'Volume', 'Chiffré', 'Corbeille', 'Description'].map((header) => (
              <th key={header} className="metric-label px-3 py-2 font-semibold">
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {shares.map((share: any) => (
            <tr key={share.name} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
              <td className="px-3 py-2 text-mist-100">
                <div className="flex items-center gap-2">
                  <Share2 size={13} className="text-ink-500" />
                  {share.name}
                </div>
              </td>
              <td className="px-3 py-2 text-xs text-ink-500 font-mono">{share.vol_path ?? share.volume ?? '—'}</td>
              <td className="px-3 py-2">
                {share.encryption ? <Badge tone="violet">chiffré</Badge> : <span className="text-ink-600">—</span>}
              </td>
              <td className="px-3 py-2">
                {share.enable_recycle_bin ? <Badge tone="ok">activée</Badge> : <span className="text-ink-600">—</span>}
              </td>
              <td className="px-3 py-2 text-xs text-mist-400 truncate max-w-[240px]">{share.desc || '—'}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {shares.length === 0 && <Empty icon={<Share2 size={30} />} title="Aucun partage" />}
    </div>
  )
}
