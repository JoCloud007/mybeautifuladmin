import { useEffect, useLayoutEffect, useRef } from 'react'
import uPlot from 'uplot'
import { onSample, series } from '@/lib/live'

export const PALETTE = ['#00d4aa', '#3b9dff', '#a97bff', '#ffb020', '#ff4d6d', '#48e5c2', '#ff8a5c']

/** Curseur partagé : survoler un graphique déplace la ligne sur tous les autres. */
const cursorSync = uPlot.sync('mba')

/**
 * Dégradé vertical pour l'aire sous la courbe.
 * uPlot appelle ce callback dès le premier paint, parfois avant que la boîte de
 * dessin n'ait des dimensions : createLinearGradient rejette alors des valeurs
 * non finies et fait tomber tout le rendu. On retombe sur un aplat.
 */
function areaFill(u: uPlot, color: string): CanvasGradient | string {
  const top = u.bbox?.top ?? 0
  const height = u.bbox?.height ?? 0
  if (!Number.isFinite(top) || !Number.isFinite(height) || height <= 0) {
    return color + '22'
  }
  const gradient = u.ctx.createLinearGradient(0, top, 0, top + height)
  gradient.addColorStop(0, color + '55')
  gradient.addColorStop(1, color + '05')
  return gradient
}

export interface SeriesSpec {
  label: string
  metric?: string
  color?: string
  fill?: boolean
  /** Série empilée « négative » (ex. TX réseau tracé vers le bas). */
  negative?: boolean
  width?: number
}

interface BaseProps {
  specs: SeriesSpec[]
  height?: number
  /** Formatteur des valeurs de l'axe Y et de la légende. */
  format?: (value: number) => string
  yRange?: [number | null, number | null]
  className?: string
  showLegend?: boolean
  showAxes?: boolean
}

function buildOptions(
  specs: SeriesSpec[],
  width: number,
  height: number,
  opts: BaseProps,
): uPlot.Options {
  const fmt = opts.format ?? ((v: number) => (v == null ? '—' : v.toFixed(1)))
  const showAxes = opts.showAxes !== false

  return {
    width,
    height,
    padding: [8, 8, showAxes ? 0 : 4, showAxes ? 0 : 4],
    cursor: {
      sync: { key: cursorSync.key, setSeries: false },
      points: { size: 6, width: 1.5 },
      drag: { x: true, y: false, setScale: false },
    },
    legend: { show: opts.showLegend !== false, live: true },
    scales: {
      x: { time: true },
      y: {
        range: (_u, min, max) => {
          const [lo, hi] = opts.yRange ?? [null, null]
          if (lo !== null && hi !== null) return [lo, hi]
          // Série encore vide : uPlot passe null/NaN, on renvoie une échelle neutre.
          if (!Number.isFinite(min) || !Number.isFinite(max)) return [lo ?? 0, hi ?? 1]
          const pad = Math.max((max - min) * 0.12, Math.abs(max) * 0.05, 0.5)
          return [lo ?? Math.min(min - pad, 0), hi ?? max + pad]
        },
      },
    },
    axes: [
      {
        show: showAxes,
        stroke: '#4a5567',
        grid: { stroke: 'rgba(255,255,255,0.035)', width: 1 },
        ticks: { stroke: 'rgba(255,255,255,0.06)', size: 4 },
        font: '10px ui-monospace, monospace',
        size: 28,
        space: 70,
      },
      {
        show: showAxes,
        stroke: '#4a5567',
        grid: { stroke: 'rgba(255,255,255,0.035)', width: 1 },
        ticks: { show: false },
        font: '10px ui-monospace, monospace',
        size: 46,
        gap: 4,
        values: (_u, ticks) => ticks.map((t) => fmt(t)),
      },
    ],
    series: [
      { label: 'Heure', value: (_u, v) => (v == null ? '—' : new Date(v * 1000).toLocaleTimeString('fr-FR')) },
      ...specs.map((spec, index) => {
        const color = spec.color ?? PALETTE[index % PALETTE.length]
        return {
          label: spec.label,
          stroke: color,
          width: spec.width ?? 1.6,
          fill: spec.fill === false ? undefined : (u: uPlot) => areaFill(u, color),
          points: { show: false },
          value: (_u: uPlot, v: number | null) => (v == null ? '—' : fmt(Math.abs(v))),
          spanGaps: true,
        } as uPlot.Series
      }),
    ],
    hooks: {
      setSize: [
        (u: uPlot) => {
          u.root.style.setProperty('--mba-chart-h', `${u.height}px`)
        },
      ],
    },
  }
}

/** Graphique piloté par des données fournies (historique API). */
export function Chart({ data, ...props }: BaseProps & { data: uPlot.AlignedData }) {
  const holder = useRef<HTMLDivElement>(null)
  const plot = useRef<uPlot | null>(null)
  const propsRef = useRef(props)
  propsRef.current = props

  useLayoutEffect(() => {
    if (!holder.current) return
    const element = holder.current
    const width = element.clientWidth || 600
    const height = props.height ?? 160
    const instance = new uPlot(buildOptions(props.specs, width, height, propsRef.current), data, element)
    plot.current = instance
    cursorSync.sub(instance)

    const observer = new ResizeObserver(([entry]) => {
      instance.setSize({ width: entry.contentRect.width, height })
    })
    observer.observe(element)
    return () => {
      observer.disconnect()
      cursorSync.unsub(instance)
      instance.destroy()
      plot.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.specs.map((s) => s.label).join('|'), props.height])

  useEffect(() => {
    plot.current?.setData(data)
  }, [data])

  return <div ref={holder} className={props.className} />
}

/** Graphique temps réel : lit les tampons du flux, sans re-rendu React. */
export function LiveChart({
  hostId,
  window: windowSeconds = 120,
  ...props
}: BaseProps & { hostId: number; window?: number }) {
  const holder = useRef<HTMLDivElement>(null)
  const plot = useRef<uPlot | null>(null)
  const propsRef = useRef(props)
  propsRef.current = props

  useLayoutEffect(() => {
    if (!holder.current) return
    const element = holder.current
    const height = props.height ?? 150

    const collect = (): uPlot.AlignedData => {
      const columns: number[][] = []
      let timestamps: number[] = []
      for (const spec of propsRef.current.specs) {
        const [t, v] = series.get(hostId, spec.metric ?? spec.label)
        if (t.length > timestamps.length) timestamps = t
        columns.push(spec.negative ? v.map((x) => -x) : v)
      }
      // Toutes les séries d'un hôte partagent le même axe temps (même cycle).
      const aligned = columns.map((column) => {
        if (column.length === timestamps.length) return column
        const padded = new Array(timestamps.length - column.length).fill(null)
        return [...padded, ...column]
      })
      return [timestamps, ...aligned] as uPlot.AlignedData
    }

    const options = buildOptions(props.specs, element.clientWidth || 600, height, propsRef.current)
    const instance = new uPlot(options, collect(), element)
    plot.current = instance
    cursorSync.sub(instance)

    const observer = new ResizeObserver(([entry]) => {
      instance.setSize({ width: entry.contentRect.width, height })
    })
    observer.observe(element)

    // On ne redessine que si l'échantillon concerne cet hôte.
    let frame = 0
    const unsubscribe = onSample((id) => {
      if (id !== hostId || frame) return
      frame = requestAnimationFrame(() => {
        frame = 0
        const data = collect()
        instance.setData(data, false)
        const times = data[0] as number[]
        if (times.length) {
          const end = times[times.length - 1]
          instance.setScale('x', { min: Math.max(times[0], end - windowSeconds), max: end })
        }
      })
    })

    return () => {
      cancelAnimationFrame(frame)
      unsubscribe()
      observer.disconnect()
      cursorSync.unsub(instance)
      instance.destroy()
      plot.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostId, props.specs.map((s) => s.metric ?? s.label).join('|'), props.height, windowSeconds])

  return <div ref={holder} className={props.className} />
}

/** Micro-courbe sans axes ni légende, pour les cartes de la vue d'ensemble. */
export function Sparkline({
  hostId,
  metric,
  color = '#00d4aa',
  height = 34,
}: {
  hostId: number
  metric: string
  color?: string
  height?: number
}) {
  const canvas = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const element = canvas.current
    if (!element) return
    const ctx = element.getContext('2d')!

    const draw = () => {
      const dpr = window.devicePixelRatio || 1
      const width = element.clientWidth
      if (element.width !== width * dpr || element.height !== height * dpr) {
        element.width = width * dpr
        element.height = height * dpr
        ctx.scale(dpr, dpr)
      }
      ctx.clearRect(0, 0, width, height)

      const [, values] = series.get(hostId, metric)
      if (values.length < 2) return
      const slice = values.slice(-90)
      const max = Math.max(...slice, 1)
      const min = Math.min(...slice, 0)
      const span = max - min || 1
      const step = width / (slice.length - 1)

      ctx.beginPath()
      slice.forEach((value, index) => {
        const x = index * step
        const y = height - 2 - ((value - min) / span) * (height - 4)
        index === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
      })

      const gradient = ctx.createLinearGradient(0, 0, 0, height)
      gradient.addColorStop(0, color + '40')
      gradient.addColorStop(1, color + '00')
      ctx.lineTo(width, height)
      ctx.lineTo(0, height)
      ctx.closePath()
      ctx.fillStyle = gradient
      ctx.fill()

      ctx.beginPath()
      slice.forEach((value, index) => {
        const x = index * step
        const y = height - 2 - ((value - min) / span) * (height - 4)
        index === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
      })
      ctx.strokeStyle = color
      ctx.lineWidth = 1.5
      ctx.lineJoin = 'round'
      ctx.stroke()
    }

    draw()
    let frame = 0
    const unsubscribe = onSample((id) => {
      if (id !== hostId || frame) return
      frame = requestAnimationFrame(() => {
        frame = 0
        draw()
      })
    })
    const observer = new ResizeObserver(draw)
    observer.observe(element)
    return () => {
      cancelAnimationFrame(frame)
      unsubscribe()
      observer.disconnect()
    }
  }, [hostId, metric, color, height])

  return <canvas ref={canvas} style={{ width: '100%', height }} />
}
