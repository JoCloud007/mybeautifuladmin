import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import { Activity, Check, Fan, Gauge as GaugeIcon, Thermometer, Zap } from 'lucide-react'
import { useMemo, useState } from 'react'
import { Chart, LiveChart, PALETTE } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Bar, Empty, Spinner, StatTile, StatusDot, Tabs, useLocalState } from '@/components/ui'
import { get } from '@/lib/api'
import { bitrate, percent, severity } from '@/lib/format'
import { useLive } from '@/lib/live'

type Tab = 'live' | 'compare' | 'sensors'

const RANGES = ['15m', '1h', '6h', '24h', '7d', '30d'] as const

/** Formatteur adapté à l'unité déclarée dans le catalogue. */
function formatterFor(unit: string) {
  if (unit === '%') return (v: number) => `${v.toFixed(0)} %`
  if (unit === 'B/s') return (v: number) => bitrate(Math.abs(v))
  if (unit === '°C') return (v: number) => `${v.toFixed(1)} °C`
  if (unit === 'W') return (v: number) => `${v.toFixed(0)} W`
  return (v: number) => (Math.abs(v) >= 100 ? v.toFixed(0) : v.toFixed(2))
}

export function MonitoringPage() {
  const [tab, setTab] = useState<Tab>('live')

  return (
    <Page>
      <PageHeader
        title="Monitoring"
        subtitle="Vue temps réel du parc, comparaison entre machines et relevé des capteurs"
      />
      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'live', label: 'Temps réel' },
            { id: 'compare', label: 'Comparer' },
            { id: 'sensors', label: 'Capteurs' },
          ]}
        />
      </div>
      {tab === 'live' && <LiveWall />}
      {tab === 'compare' && <CompareView />}
      {tab === 'sensors' && <SensorsView />}
    </Page>
  )
}

// ------------------------------------------------------------- mur temps réel
const WALL_METRICS = [
  { metric: 'cpu.usage', label: 'Processeur', unit: '%', max: 100, color: PALETTE[0] },
  { metric: 'mem.percent', label: 'Mémoire', unit: '%', max: 100, color: PALETTE[1] },
  { metric: 'net.rx', label: 'Réseau ↓', unit: 'B/s', color: PALETTE[2] },
  { metric: 'disk.read', label: 'Disque ↓', unit: 'B/s', color: PALETTE[5] },
] as const

function LiveWall() {
  const [density, setDensity] = useLocalState<'compact' | 'detailed'>('mba.monDensity', 'compact')
  const { data: hosts = [] } = useQuery({
    queryKey: ['hosts'],
    queryFn: () => get('/hosts'),
    refetchInterval: 30000,
  })
  useLive((s) => s.bump)
  const samples = useLive.getState().samples

  const online = hosts.filter((h: any) => h.status === 'online')

  if (hosts.length === 0) {
    return (
      <div className="panel">
        <Empty icon={<Activity size={38} />} title="Aucun hôte supervisé" />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
          {(
            [
              ['compact', 'Compact'],
              ['detailed', 'Détaillé'],
            ] as const
          ).map(([value, label]) => (
            <button
              key={value}
              onClick={() => setDensity(value)}
              className={clsx(
                'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                density === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
              )}
            >
              {label}
            </button>
          ))}
        </div>
        <span className="text-xs text-ink-600">
          {online.length} machine(s) en ligne · flux direct
        </span>
      </div>

      <div
        className={clsx(
          'grid gap-3',
          density === 'compact'
            ? 'grid-cols-[repeat(auto-fill,minmax(340px,1fr))]'
            : 'grid-cols-1 xl:grid-cols-2',
        )}
      >
        {hosts.map((host: any) => {
          const sample = samples[host.id] ?? {}
          const offline = host.status === 'offline'
          return (
            <div key={host.id} className={clsx('panel p-3.5 space-y-3', offline && 'opacity-60')}>
              <div className="flex items-center gap-2">
                <StatusDot status={host.status} />
                <span className="text-sm font-medium text-mist-100 truncate flex-1">{host.name}</span>
                <Badge>{host.kind}</Badge>
                {sample['temp.cpu'] !== undefined && (
                  <span
                    className="metric-value text-xs"
                    style={{ color: severity(sample['temp.cpu'], 70, 85).color }}
                  >
                    {sample['temp.cpu'].toFixed(0)}°
                  </span>
                )}
              </div>

              {offline ? (
                <p className="text-xs text-danger py-3 text-center">Hôte injoignable</p>
              ) : (
                <>
                  <div className="grid grid-cols-2 gap-2.5">
                    {(['cpu.usage', 'mem.percent'] as const).map((metric) => (
                      <div key={metric} className="space-y-1">
                        <div className="flex justify-between">
                          <span className="metric-label">{metric === 'cpu.usage' ? 'CPU' : 'RAM'}</span>
                          <span className="metric-value text-[11px]">{percent(sample[metric], 0)}</span>
                        </div>
                        <Bar value={sample[metric] ?? 0} height={3} />
                      </div>
                    ))}
                  </div>

                  <div className={clsx('grid gap-3', density === 'detailed' ? 'grid-cols-2' : 'grid-cols-1')}>
                    {WALL_METRICS.slice(0, density === 'detailed' ? 4 : 1).map((spec) => (
                      <div key={spec.metric}>
                        {density === 'detailed' && (
                          <div className="metric-label mb-0.5">{spec.label}</div>
                        )}
                        <LiveChart
                          hostId={host.id}
                          height={density === 'detailed' ? 90 : 64}
                          showLegend={false}
                          showAxes={density === 'detailed'}
                          format={formatterFor(spec.unit)}
                          yRange={'max' in spec && spec.max ? [0, spec.max] : undefined}
                          specs={[{ label: spec.label, metric: spec.metric, color: spec.color }]}
                        />
                      </div>
                    ))}
                  </div>
                </>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------ comparer
function CompareView() {
  const [selectedHosts, setSelectedHosts] = useLocalState<number[]>('mba.cmpHosts', [])
  const [selectedMetrics, setSelectedMetrics] = useLocalState<string[]>('mba.cmpMetrics', [
    'cpu.usage',
    'mem.percent',
  ])
  const [range, setRange] = useState<(typeof RANGES)[number]>('6h')

  const { data: catalog } = useQuery({ queryKey: ['mon-catalog'], queryFn: () => get('/monitoring/catalog') })
  const hosts = catalog?.hosts ?? []

  // À défaut de choix explicite, on compare tout ce qui est en ligne.
  const activeHosts = selectedHosts.length ? selectedHosts : hosts.map((h: any) => h.id)

  const { data, isFetching } = useQuery({
    queryKey: ['mon-series', activeHosts, selectedMetrics, range],
    queryFn: () =>
      get(
        `/monitoring/series?hosts=${activeHosts.join(',')}&metrics=${selectedMetrics.join(',')}&range=${range}&points=400`,
      ),
    enabled: activeHosts.length > 0 && selectedMetrics.length > 0,
    refetchInterval: 60000,
  })

  const charts = useMemo(() => {
    if (!data) return []
    return selectedMetrics.map((metric) => {
      const entry = (catalog?.catalog ?? []).find((c: any) => c.metric === metric)
      const perHost = activeHosts
        .map((hostId: number) => ({
          hostId,
          name: data.hosts?.[hostId] ?? `#${hostId}`,
          points: data.series?.[`${hostId}:${metric}`] ?? [],
        }))
        .filter((s: any) => s.points.length > 0)

      const timestamps = [...new Set(perHost.flatMap((s: any) => s.points.map((p: any) => p[0])))].sort(
        (a, b) => (a as number) - (b as number),
      ) as number[]

      const columns = perHost.map((s: any) => {
        const lookup = new Map<number, number>(s.points)
        return timestamps.map((t) => lookup.get(t) ?? null)
      })

      return {
        metric,
        label: entry?.label ?? metric,
        unit: entry?.unit ?? '',
        max: entry?.max,
        data: [timestamps, ...columns] as any,
        specs: perHost.map((s: any, index: number) => ({
          label: s.name,
          color: PALETTE[index % PALETTE.length],
          fill: perHost.length === 1,
        })),
      }
    })
  }, [data, selectedMetrics, activeHosts, catalog])

  const toggleHost = (id: number) =>
    setSelectedHosts(
      selectedHosts.includes(id) ? selectedHosts.filter((h) => h !== id) : [...selectedHosts, id],
    )
  const toggleMetric = (metric: string) =>
    setSelectedMetrics(
      selectedMetrics.includes(metric)
        ? selectedMetrics.filter((m) => m !== metric)
        : [...selectedMetrics, metric],
    )

  return (
    <div className="space-y-4">
      <div className="panel p-4 space-y-3">
        <div className="space-y-1.5">
          <label>Machines</label>
          <div className="flex flex-wrap gap-1.5">
            {hosts.map((host: any) => {
              const active = selectedHosts.includes(host.id) || selectedHosts.length === 0
              return (
                <button
                  key={host.id}
                  onClick={() => toggleHost(host.id)}
                  className={clsx(
                    'chip transition-colors flex items-center gap-1.5',
                    selectedHosts.includes(host.id)
                      ? 'border-accent/40 bg-accent/10 text-accent'
                      : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
                  )}
                  title={`${host.metrics.length} métriques disponibles`}
                >
                  <StatusDot status={host.status} size={5} />
                  {host.name}
                  {selectedHosts.includes(host.id) && <Check size={11} />}
                </button>
              )
            })}
            {selectedHosts.length > 0 && (
              <button
                className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-danger"
                onClick={() => setSelectedHosts([])}
              >
                Tout
              </button>
            )}
          </div>
          {selectedHosts.length === 0 && (
            <p className="text-[11px] text-ink-600">Aucune sélection : toutes les machines sont comparées.</p>
          )}
        </div>

        <div className="space-y-1.5">
          <label>Métriques</label>
          <div className="flex flex-wrap gap-1.5">
            {(catalog?.catalog ?? []).map((entry: any) => (
              <button
                key={entry.metric}
                onClick={() => toggleMetric(entry.metric)}
                className={clsx(
                  'chip transition-colors',
                  selectedMetrics.includes(entry.metric)
                    ? 'border-accent/40 bg-accent/10 text-accent'
                    : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
                )}
              >
                {entry.label}
                {entry.unit && <span className="text-ink-500 ml-0.5">{entry.unit}</span>}
              </button>
            ))}
          </div>
        </div>

        <div className="flex items-center gap-2">
          <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
            {RANGES.map((value) => (
              <button
                key={value}
                onClick={() => setRange(value)}
                className={clsx(
                  'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                  range === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                )}
              >
                {value}
              </button>
            ))}
          </div>
          {isFetching && <Spinner size={14} className="text-ink-500" />}
          {data?.bucket && <span className="text-xs text-ink-600">résolution {data.bucket} s</span>}
        </div>
      </div>

      {selectedMetrics.length === 0 && (
        <div className="panel">
          <Empty icon={<GaugeIcon size={34} />} title="Choisis au moins une métrique" />
        </div>
      )}

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
        {charts.map((chart) => (
          <div key={chart.metric} className="panel p-4">
            <div className="flex items-baseline justify-between mb-1">
              <h3 className="text-sm font-semibold text-mist-200">{chart.label}</h3>
              <span className="text-[10px] text-ink-600 font-mono">{chart.unit}</span>
            </div>
            {chart.specs.length === 0 ? (
              <p className="text-xs text-ink-600 py-8 text-center">Pas de données sur cette période.</p>
            ) : (
              <Chart
                height={200}
                data={chart.data}
                specs={chart.specs}
                format={formatterFor(chart.unit)}
                yRange={chart.max ? [0, chart.max] : undefined}
              />
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------ capteurs
function SensorsView() {
  const [kindFilter, setKindFilter] = useState<'all' | 'temperature' | 'fan' | 'power'>('all')
  const [selected, setSelected] = useState<{ hostId: number; metric: string; label: string } | null>(null)
  useLive((s) => s.bump)

  const { data, isLoading } = useQuery({
    queryKey: ['sensors'],
    queryFn: () => get('/monitoring/sensors'),
    refetchInterval: 10000,
  })

  const readings = (data?.readings ?? []).filter(
    (r: any) => kindFilter === 'all' || r.kind === kindFilter,
  )
  const summary = data?.summary ?? {}

  const byHost = useMemo(() => {
    const map = new Map<string, any[]>()
    for (const reading of readings) {
      map.set(reading.host_name, [...(map.get(reading.host_name) ?? []), reading])
    }
    return [...map.entries()]
  }, [readings])

  if (isLoading) {
    return (
      <div className="panel p-12 grid place-items-center">
        <Spinner size={22} />
      </div>
    )
  }

  if ((data?.readings ?? []).length === 0) {
    return (
      <div className="panel">
        <Empty
          icon={<Thermometer size={38} />}
          title="Aucun capteur relevé"
          hint="Les températures sont lues via /sys (thermal_zone, hwmon), SMART sur les disques, l'API DSM sur les NAS et le BMC sur les serveurs équipés d'IPMI."
        />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <StatTile
          label="Point le plus chaud"
          value={summary.hottest ? `${summary.hottest.value.toFixed(0)} °C` : '—'}
          sub={summary.hottest ? `${summary.hottest.label} · ${summary.hottest.host_name}` : undefined}
          tone={
            (summary.hottest?.value ?? 0) >= 85 ? 'danger' : (summary.hottest?.value ?? 0) >= 70 ? 'warn' : 'ok'
          }
          icon={<Thermometer size={20} />}
        />
        <StatTile
          label="Sondes thermiques"
          value={summary.temperatures ?? 0}
          sub={summary.critical ? `${summary.critical} en alerte` : 'toutes nominales'}
          tone={summary.critical ? 'danger' : summary.warning ? 'warn' : 'ok'}
          icon={<GaugeIcon size={20} />}
        />
        <StatTile label="Ventilateurs" value={summary.fans ?? 0} icon={<Fan size={20} />} />
        <StatTile
          label="Consommation"
          value={summary.power_total ? `${summary.power_total} W` : '—'}
          sub="capteurs de puissance"
          icon={<Zap size={20} />}
        />
      </div>

      <div className="flex flex-wrap gap-1.5">
        {(
          [
            ['all', 'Tous'],
            ['temperature', 'Températures'],
            ['fan', 'Ventilateurs'],
            ['power', 'Puissance'],
          ] as const
        ).map(([value, label]) => (
          <button
            key={value}
            onClick={() => setKindFilter(value)}
            className={clsx(
              'chip transition-colors',
              kindFilter === value
                ? 'border-accent/40 bg-accent/10 text-accent'
                : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
            )}
          >
            {label}
          </button>
        ))}
      </div>

      {byHost.map(([hostName, items]) => (
        <section key={hostName}>
          <SectionTitle right={<span className="text-xs text-ink-500">{items.length} capteurs</span>}>
            {hostName}
          </SectionTitle>
          <div className="grid gap-2 grid-cols-[repeat(auto-fill,minmax(190px,1fr))]">
            {items.map((reading: any) => (
              <button
                key={reading.metric}
                onClick={() =>
                  setSelected({ hostId: reading.host_id, metric: reading.metric, label: reading.label })
                }
                className={clsx(
                  'panel panel-hover p-3 text-left space-y-2',
                  reading.critical && 'border-danger/40',
                  reading.warning && 'border-warn/30',
                )}
              >
                <div className="flex items-center gap-1.5">
                  {reading.kind === 'temperature' && <Thermometer size={12} className="text-ink-500" />}
                  {reading.kind === 'fan' && <Fan size={12} className="text-ink-500" />}
                  {reading.kind === 'power' && <Zap size={12} className="text-ink-500" />}
                  <span className="metric-label truncate flex-1">{reading.label}</span>
                </div>
                <div
                  className="metric-value text-xl"
                  style={{
                    color:
                      reading.kind === 'temperature'
                        ? severity(reading.value, 70, 85).color
                        : '#c2ccdb',
                  }}
                >
                  {reading.kind === 'temperature'
                    ? `${reading.value.toFixed(1)} °C`
                    : reading.kind === 'fan'
                      ? `${reading.value.toFixed(0)} rpm`
                      : `${reading.value.toFixed(1)} W`}
                </div>
                {reading.kind === 'temperature' && (
                  <Bar value={Math.min(100, (reading.value / 100) * 100)} height={3} warn={70} crit={85} />
                )}
              </button>
            ))}
          </div>
        </section>
      ))}

      {selected && (
        <div className="panel p-4">
          <SectionTitle
            right={
              <button className="btn-icon" onClick={() => setSelected(null)}>
                ✕
              </button>
            }
          >
            {selected.label} — évolution
          </SectionTitle>
          <LiveChart
            hostId={selected.hostId}
            height={200}
            window={600}
            format={(v) => v.toFixed(1)}
            specs={[{ label: selected.label, metric: selected.metric, color: PALETTE[4] }]}
          />
        </div>
      )}
    </div>
  )
}
