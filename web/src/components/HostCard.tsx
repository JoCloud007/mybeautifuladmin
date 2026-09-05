import clsx from 'clsx'
import { ArrowDown, ArrowUp, Boxes, Cpu, HardDrive, MemoryStick, Thermometer, Zap } from 'lucide-react'
import { Link } from 'react-router-dom'
import { Sparkline } from './Chart'
import { Badge, Bar, StatusDot, TagList } from './ui'
import { KIND_LABEL, bitrate, duration, num, percent, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

const KIND_TONE: Record<string, 'ok' | 'info' | 'violet' | 'warn' | 'danger' | 'neutral'> = {
  linux: 'info',
  proxmox: 'violet',
  synology: 'warn',
  docker: 'ok',
  generic: 'neutral',
  ipmi: 'danger',
}

export function HostCard({ host }: { host: any }) {
  // On lit l'échantillon live s'il existe, sinon la dernière valeur connue de l'API.
  useLive((s) => s.bump)
  const live = useLive.getState().samples[host.id] ?? host.live ?? {}
  const status = useLive.getState().status[host.id] ?? host.status

  const cpu = live['cpu.usage'] ?? 0
  const mem = live['mem.percent'] ?? 0
  const disk = live['disk.percent'] ?? 0
  const temp = live['temp.cpu']
  const rx = live['net.rx'] ?? 0
  const tx = live['net.tx'] ?? 0
  const containers = live['docker.containers.running'] ?? live['pve.guests.running']
  const offline = status === 'offline'
  // Un hôte joint uniquement par le socket Docker n'expose pas de métriques
  // système : on bascule alors sur une carte orientée conteneurs.
  const systemMetrics = live['cpu.usage'] !== undefined || live['mem.percent'] !== undefined
  // Un contrôleur hors bande ne connaît ni charge ni conteneurs : ce qu'il sait
  // dire, c'est si le serveur est sous tension et si le matériel va bien.
  const bmc = host.kind === 'ipmi' ? (live.bmc ?? {}) : null

  return (
    <Link
      to={`/hosts/${host.id}`}
      className={clsx(
        'panel panel-hover p-3.5 flex flex-col gap-3 group',
        offline && 'opacity-70 border-danger/20',
      )}
    >
      <div className="flex items-start gap-2.5">
        <StatusDot status={status} />
        <div className="min-w-0 flex-1">
          <div className="font-medium text-mist-100 truncate leading-tight group-hover:text-accent transition-colors">
            {host.name}
          </div>
          <div className="text-[11px] text-ink-500 truncate font-mono">{host.address}</div>
        </div>
        <Badge tone={KIND_TONE[host.kind] ?? 'neutral'}>{KIND_LABEL[host.kind] ?? host.kind}</Badge>
      </div>

      {offline ? (
        <div className="text-xs text-danger bg-danger/8 border border-danger/20 rounded-lg px-2.5 py-2 line-clamp-2">
          {host.last_error || 'Hôte injoignable'}
        </div>
      ) : bmc ? (
        <>
          <div className="grid grid-cols-2 gap-2.5">
            <Readout
              label="Alimentation"
              value={bmc.power_state === 'on' ? 'Allumé' : bmc.power_state === 'off' ? 'Éteint' : '—'}
            />
            <Readout label="Santé" value={bmc.health ?? '—'} />
          </div>
          <div className="flex items-center gap-3 text-[11px] text-ink-500 font-mono pt-0.5 border-t border-ink-800">
            <span className="truncate">
              {bmc.manufacturer ?? 'BMC'}
              {bmc.bmc_firmware ? ` · fw ${bmc.bmc_firmware}` : ''}
            </span>
            <span className="flex-1" />
            {bmc.power_watts != null && (
              <span className="flex items-center gap-1" title="Consommation">
                <Zap size={10} className="text-warn" />
                {num(bmc.power_watts, 0)} W
              </span>
            )}
          </div>
        </>
      ) : (
        <>
          {systemMetrics ? (
            <>
              <div className="grid grid-cols-3 gap-2.5">
                <Metric icon={<Cpu size={11} />} label="CPU" value={percent(cpu, 0)} level={cpu} />
                <Metric icon={<MemoryStick size={11} />} label="RAM" value={percent(mem, 0)} level={mem} />
                <Metric icon={<HardDrive size={11} />} label="Disque" value={percent(disk, 0)} level={disk} />
              </div>
              <div className="-mx-1 -mb-1">
                <Sparkline hostId={host.id} metric="cpu.usage" color={severity(cpu).color} height={30} />
              </div>
            </>
          ) : (
            <>
              <div className="grid grid-cols-2 gap-2.5">
                <Readout
                  label="Conteneurs actifs"
                  value={`${live['docker.containers.running'] ?? 0} / ${live['docker.containers.total'] ?? 0}`}
                />
                <Readout label="CPU cumulé" value={percent(live['docker.cpu.total'], 1)} />
              </div>
              <div className="-mx-1 -mb-1">
                <Sparkline hostId={host.id} metric="docker.cpu.total" color="#00d4aa" height={30} />
              </div>
            </>
          )}

          <div className="flex items-center gap-3 text-[11px] text-ink-500 font-mono pt-0.5 border-t border-ink-800">
            <span className="flex items-center gap-1" title="Réception">
              <ArrowDown size={10} className="text-info" />
              {bitrate(rx)}
            </span>
            <span className="flex items-center gap-1" title="Émission">
              <ArrowUp size={10} className="text-violet" />
              {bitrate(tx)}
            </span>
            <span className="flex-1" />
            {temp !== undefined && (
              <span className="flex items-center gap-1" title="Température CPU">
                <Thermometer size={10} className={temp > 75 ? 'text-danger' : 'text-ink-500'} />
                {num(temp, 0)}°
              </span>
            )}
            {containers !== undefined && (
              <span className="flex items-center gap-1" title="Conteneurs actifs">
                <Boxes size={10} />
                {containers}
              </span>
            )}
          </div>
        </>
      )}

      <div className="flex items-center justify-between gap-2 text-[10px] text-ink-600 -mt-1">
        <TagList tags={host.tags} max={3} />
        <span className="flex-1 truncate">{live.uptime ? `up ${duration(live.uptime)}` : ''}</span>
        {(host.meta?.updates ?? 0) > 0 && (
          <Badge tone="warn">{host.meta.updates} maj</Badge>
        )}
      </div>
    </Link>
  )
}

function Readout({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-ink-800/40 rounded-lg px-2.5 py-1.5">
      <div className="metric-label truncate">{label}</div>
      <div className="metric-value text-sm mt-0.5">{value}</div>
    </div>
  )
}

function Metric({
  icon,
  label,
  value,
  level,
}: {
  icon: React.ReactNode
  label: string
  value: string
  level: number
}) {
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between">
        <span className="metric-label flex items-center gap-1">
          {icon}
          {label}
        </span>
        <span className="metric-value text-[11px]" style={{ color: severity(level).color }}>
          {value}
        </span>
      </div>
      <Bar value={level} height={4} />
    </div>
  )
}

export function HostCardSkeleton() {
  return (
    <div className="panel p-3.5 space-y-3">
      <div className="flex gap-2.5 items-center">
        <div className="skeleton w-2 h-2 rounded-full" />
        <div className="skeleton h-3.5 w-28" />
        <div className="skeleton h-4 w-14 ml-auto rounded-md" />
      </div>
      <div className="grid grid-cols-3 gap-2.5">
        {[0, 1, 2].map((i) => (
          <div key={i} className="space-y-1.5">
            <div className="skeleton h-2.5 w-full" />
            <div className="skeleton h-1 w-full rounded-full" />
          </div>
        ))}
      </div>
      <div className="skeleton h-[30px] w-full" />
    </div>
  )
}
