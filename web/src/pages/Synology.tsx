import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  ArrowUpCircle,
  Boxes,
  HardDrive,
  Package,
  Play,
  Plus,
  Power,
  RotateCcw,
  Server,
  Share2,
  Square,
} from 'lucide-react'
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { AddHostModal } from '@/components/AddHostModal'
import { LiveChart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Bar, Empty, Gauge, Spinner, StatusDot, Tabs, useConfirm, useToast } from '@/components/ui'
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

function NasPanel({ nas }: { nas: any }) {
  const [tab, setTab] = useState<'storage' | 'packages' | 'shares'>('storage')
  const live = useLive.getState().samples[nas.id] ?? nas.live ?? {}
  const info = live.info ?? nas.info ?? nas.meta ?? {}
  const volumes = live.volumes ?? nas.volumes ?? []
  const disks = live.disks ?? nas.disks ?? []
  const pools = live.pools ?? nas.pools ?? []

  const confirm = useConfirm()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)

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
          { id: 'packages' as const, label: 'Paquets' },
          { id: 'shares' as const, label: 'Partages' },
        ]}
      />

      {tab === 'storage' && <StorageTab volumes={volumes} disks={disks} pools={pools} />}
      {tab === 'packages' && <PackagesTab nas={nas} />}
      {tab === 'shares' && <SharesTab nas={nas} />}
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

function PackagesTab({ nas }: { nas: any }) {
  const queryClient = useQueryClient()
  const toast = useToast()
  const confirm = useConfirm()
  const [busy, setBusy] = useState<string | null>(null)

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
        </div>
      )}

      <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(280px,1fr))]">
        {packages.map((pkg: any) => {
          const running = pkg.status === 'running' || pkg.status === 'start'
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
              <button
                className="btn-icon"
                onClick={() => act(pkg, running ? 'stop' : 'start')}
                title={running ? 'Arrêter' : 'Démarrer'}
                disabled={busy === pkg.id}
              >
                {busy === pkg.id ? <Spinner size={13} /> : running ? <Square size={13} /> : <Play size={14} />}
              </button>
            </div>
          )
        })}
        {packages.length === 0 && (
          <div className="panel col-span-full">
            <Empty icon={<Package size={32} />} title="Aucun paquet installé" />
          </div>
        )}
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
