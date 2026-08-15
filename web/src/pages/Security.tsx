import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  BellOff,
  CheckCircle2,
  ChevronDown,
  Download,
  RefreshCw,
  Search,
  Shield,
  ShieldAlert,
  ShieldCheck,
  Wrench,
} from 'lucide-react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Spinner, StatTile, Tabs, useConfirm, useLocalState, useToast } from '@/components/ui'
import { get, post } from '@/lib/api'
import { ago } from '@/lib/format'

type Tab = 'findings' | 'hosts' | 'muted' | 'resolved'

const SEVERITY: Record<string, { label: string; tone: 'danger' | 'warn' | 'info' | 'neutral'; rank: number }> = {
  critical: { label: 'Critique', tone: 'danger', rank: 0 },
  high: { label: 'Élevé', tone: 'danger', rank: 1 },
  medium: { label: 'Moyen', tone: 'warn', rank: 2 },
  low: { label: 'Faible', tone: 'info', rank: 3 },
  info: { label: 'Info', tone: 'neutral', rank: 4 },
}

/** Familles de constats, pour regrouper la liste de façon lisible. */
const FAMILY: { prefix: string; label: string }[] = [
  { prefix: 'patch.', label: 'Correctifs et mises à jour' },
  { prefix: 'os.', label: 'Fin de support' },
  { prefix: 'ssh.', label: 'Accès SSH' },
  { prefix: 'net.', label: 'Exposition réseau' },
  { prefix: 'account.', label: 'Comptes' },
  { prefix: 'hw.', label: 'Matériel' },
  { prefix: 'svc.', label: 'Services' },
  { prefix: 'tls.', label: 'Certificats et chiffrement' },
  { prefix: 'docker.', label: 'Conteneurs' },
]

function familyOf(code: string): string {
  return FAMILY.find((f) => code.startsWith(f.prefix))?.label ?? 'Divers'
}

function scoreTone(score: number) {
  if (score >= 85) return { color: '#00d4aa', label: 'Bon' }
  if (score >= 60) return { color: '#ffb020', label: 'À surveiller' }
  return { color: '#ff4d6d', label: 'À traiter' }
}

export function SecurityPage() {
  const [tab, setTab] = useState<Tab>('findings')
  const [query, setQuery] = useState('')
  const [severityFilter, setSeverityFilter] = useState<string[]>([])
  const [collapsed, setCollapsed] = useLocalState<string[]>('mba.secCollapsed', [])
  const [scanning, setScanning] = useState(false)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['security'],
    queryFn: () => get('/security'),
    refetchInterval: 60000,
  })
  const { data: muted = [] } = useQuery({
    queryKey: ['security-muted'],
    queryFn: () => get('/security/muted'),
    enabled: tab === 'muted',
  })
  const { data: resolved = [] } = useQuery({
    queryKey: ['security-history'],
    queryFn: () => get('/security/history'),
    enabled: tab === 'resolved',
  })

  const summary = data?.summary ?? {}
  const findings = data?.findings ?? []

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return findings.filter((f: any) => {
      if (severityFilter.length && !severityFilter.includes(f.severity)) return false
      if (!needle) return true
      return `${f.title} ${f.detail ?? ''} ${f.host_name ?? ''} ${f.service_name ?? ''}`
        .toLowerCase()
        .includes(needle)
    })
  }, [findings, query, severityFilter])

  const groups = useMemo(() => {
    const map = new Map<string, any[]>()
    for (const finding of filtered) {
      const key = familyOf(finding.code)
      map.set(key, [...(map.get(key) ?? []), finding])
    }
    return [...map.entries()].sort(
      (a, b) =>
        (SEVERITY[a[1][0].severity]?.rank ?? 9) - (SEVERITY[b[1][0].severity]?.rank ?? 9),
    )
  }, [filtered])

  const rescan = async () => {
    setScanning(true)
    try {
      await post('/security/scan')
      queryClient.invalidateQueries({ queryKey: ['security'] })
      toast('Analyse terminée', 'ok')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setScanning(false)
    }
  }

  const mute = async (finding: any, value: boolean) => {
    if (value) {
      const ok = await confirm({
        title: 'Ignorer ce constat ?',
        message: (
          <>
            <b className="text-mist-100">{finding.title}</b> n'apparaîtra plus dans la liste
            principale. Tu pourras le réactiver depuis l'onglet « Ignorés ».
          </>
        ),
        confirmLabel: 'Ignorer',
      })
      if (!ok) return
    }
    await post(`/security/findings/${finding.id}/mute`, { muted: value })
    queryClient.invalidateQueries({ queryKey: ['security'] })
    queryClient.invalidateQueries({ queryKey: ['security-muted'] })
    toast(value ? 'Constat ignoré' : 'Constat réactivé', 'ok')
  }

  const toggleGroup = (name: string) =>
    setCollapsed(collapsed.includes(name) ? collapsed.filter((c) => c !== name) : [...collapsed, name])

  const tone = scoreTone(summary.score ?? 100)

  return (
    <Page>
      <PageHeader
        title="Sécurité"
        subtitle="Correctifs manquants, obsolescence, durcissement et exposition réseau"
        actions={
          <>
            <div className="relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Filtrer…"
                className="pl-8 py-1.5 w-48"
              />
            </div>
            <button className="btn-primary" onClick={rescan} disabled={scanning}>
              {scanning ? <Spinner /> : <RefreshCw size={15} />}
              Relancer l'analyse
            </button>
          </>
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-4 xl:grid-cols-6 gap-3 mb-5">
        <div className="panel px-4 py-3 flex items-center gap-3">
          <ScoreRing score={summary.score ?? 100} />
          <div>
            <div className="metric-label">Score global</div>
            <div className="metric-value text-xl font-semibold" style={{ color: tone.color }}>
              {summary.score ?? 100}
              <span className="text-ink-600 text-sm">/100</span>
            </div>
            <div className="text-[11px] text-ink-500">{tone.label}</div>
          </div>
        </div>
        <StatTile
          label="Critiques"
          value={summary.by_severity?.critical ?? 0}
          tone={summary.by_severity?.critical ? 'danger' : 'ok'}
          icon={<ShieldAlert size={20} />}
          onClick={() => setSeverityFilter(['critical'])}
        />
        <StatTile
          label="Élevés"
          value={summary.by_severity?.high ?? 0}
          tone={summary.by_severity?.high ? 'danger' : 'ok'}
          icon={<ShieldAlert size={20} />}
          onClick={() => setSeverityFilter(['high'])}
        />
        <StatTile
          label="Moyens"
          value={summary.by_severity?.medium ?? 0}
          tone={summary.by_severity?.medium ? 'warn' : 'ok'}
          icon={<Shield size={20} />}
          onClick={() => setSeverityFilter(['medium'])}
        />
        <StatTile
          label="Hôtes sains"
          value={`${summary.hosts_clean ?? 0}`}
          sub={`${summary.hosts_affected ?? 0} avec constats`}
          tone="ok"
          icon={<ShieldCheck size={20} />}
        />
        <StatTile
          label="Résolus (7 j)"
          value={summary.resolved_7d ?? 0}
          sub="constats corrigés"
          tone="ok"
          icon={<CheckCircle2 size={20} />}
        />
      </div>

      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'findings', label: 'Constats', badge: <Badge>{filtered.length}</Badge> },
            { id: 'hosts', label: 'Par machine' },
            {
              id: 'muted',
              label: 'Ignorés',
              badge: summary.muted ? <Badge tone="neutral">{summary.muted}</Badge> : undefined,
            },
            { id: 'resolved', label: 'Résolus' },
          ]}
        />
      </div>

      {tab === 'findings' && (
        <>
          <div className="flex flex-wrap gap-1.5 mb-4">
            {Object.entries(SEVERITY).map(([key, meta]) => {
              const count = summary.by_severity?.[key] ?? 0
              if (!count) return null
              const active = severityFilter.includes(key)
              return (
                <button
                  key={key}
                  onClick={() =>
                    setSeverityFilter(
                      active ? severityFilter.filter((s) => s !== key) : [...severityFilter, key],
                    )
                  }
                  className={clsx(
                    'chip transition-colors',
                    active
                      ? 'border-accent/40 bg-accent/10 text-accent'
                      : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
                  )}
                >
                  {meta.label}
                  <span className="text-ink-500 ml-0.5">{count}</span>
                </button>
              )
            })}
            {severityFilter.length > 0 && (
              <button
                className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-danger"
                onClick={() => setSeverityFilter([])}
              >
                Réinitialiser
              </button>
            )}
          </div>

          {isLoading && (
            <div className="panel p-12 grid place-items-center">
              <Spinner size={22} />
            </div>
          )}

          {!isLoading && filtered.length === 0 && (
            <div className="panel">
              <Empty
                icon={<ShieldCheck size={40} />}
                title={findings.length ? 'Aucun constat pour ces filtres' : 'Aucune vulnérabilité détectée'}
                hint={
                  findings.length
                    ? 'Élargis les filtres pour voir le reste.'
                    : "Le parc est à jour et correctement durci. L'analyse tourne automatiquement toutes les 15 minutes."
                }
              />
            </div>
          )}

          <div className="space-y-4">
            {groups.map(([family, items]) => {
              const isCollapsed = collapsed.includes(family)
              return (
                <section key={family} className="panel overflow-hidden">
                  <button
                    onClick={() => toggleGroup(family)}
                    className="w-full flex items-center gap-2.5 px-4 py-2.5 hover:bg-ink-800/40 transition-colors"
                  >
                    <ChevronDown
                      size={15}
                      className={clsx('text-ink-500 transition-transform', isCollapsed && '-rotate-90')}
                    />
                    <span className="text-sm font-semibold text-mist-200">{family}</span>
                    <Badge tone={SEVERITY[items[0].severity]?.tone ?? 'neutral'}>{items.length}</Badge>
                  </button>
                  {!isCollapsed && (
                    <div className="divide-y divide-ink-800/60 border-t border-ink-800">
                      {items.map((finding: any) => (
                        <FindingRow key={finding.id} finding={finding} onMute={() => mute(finding, true)} />
                      ))}
                    </div>
                  )}
                </section>
              )
            })}
          </div>
        </>
      )}

      {tab === 'hosts' && (
        <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(300px,1fr))]">
          {(data?.by_host ?? []).map((host: any) => {
            const hostTone = scoreTone(host.score)
            return (
              <Link key={host.host_id} to={`/hosts/${host.host_id}`} className="panel panel-hover p-4 space-y-3">
                <div className="flex items-start gap-3">
                  <ScoreRing score={host.score} size={44} />
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-medium text-mist-100 truncate">{host.name}</div>
                    <div className="text-[11px] text-ink-600">{host.kind}</div>
                  </div>
                  <Badge tone={SEVERITY[host.worst]?.tone ?? 'neutral'}>
                    {SEVERITY[host.worst]?.label ?? host.worst}
                  </Badge>
                </div>
                <div className="flex items-baseline justify-between">
                  <span className="text-[13px] text-mist-300">
                    {host.count} constat{host.count > 1 ? 's' : ''}
                  </span>
                  <span className="metric-value text-sm" style={{ color: hostTone.color }}>
                    {host.score}/100
                  </span>
                </div>
              </Link>
            )
          })}
          {(data?.by_host ?? []).length === 0 && (
            <div className="panel col-span-full">
              <Empty icon={<ShieldCheck size={34} />} title="Toutes les machines sont saines" />
            </div>
          )}
        </div>
      )}

      {tab === 'muted' && (
        <div className="panel divide-y divide-ink-800/60">
          {muted.length === 0 && <Empty icon={<BellOff size={32} />} title="Aucun constat ignoré" />}
          {muted.map((finding: any) => (
            <FindingRow key={finding.id} finding={finding} muted onMute={() => mute(finding, false)} />
          ))}
        </div>
      )}

      {tab === 'resolved' && (
        <div className="panel divide-y divide-ink-800/60">
          {resolved.length === 0 && (
            <Empty icon={<CheckCircle2 size={32} />} title="Aucun constat résolu sur 30 jours" />
          )}
          {resolved.map((finding: any) => (
            <div key={finding.id} className="flex items-start gap-3 px-4 py-2.5">
              <CheckCircle2 size={15} className="text-accent mt-0.5 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="text-[13px] text-mist-300 line-through decoration-ink-600">{finding.title}</div>
                <div className="text-[11px] text-ink-600">
                  {finding.host_name} · résolu {ago(finding.resolved_at)}
                </div>
              </div>
              <Badge tone="ok">corrigé</Badge>
            </div>
          ))}
        </div>
      )}
    </Page>
  )
}

function FindingRow({
  finding,
  muted,
  onMute,
}: {
  finding: any
  muted?: boolean
  onMute: () => void
}) {
  const meta = SEVERITY[finding.severity] ?? SEVERITY.info
  return (
    <div className="flex items-start gap-3 px-4 py-3 hover:bg-ink-800/30 transition-colors">
      <Badge tone={meta.tone} className="mt-0.5 shrink-0">
        {meta.label}
      </Badge>
      <div className="min-w-0 flex-1">
        <div className="text-[13px] text-mist-100">{finding.title}</div>
        {finding.detail && <div className="text-[12px] text-mist-400 mt-0.5">{finding.detail}</div>}
        {finding.remediation && (
          <div className="text-[12px] text-accent/85 mt-1 flex items-start gap-1.5">
            <Wrench size={12} className="mt-0.5 shrink-0" />
            <span>{finding.remediation}</span>
          </div>
        )}
        <div className="text-[10px] text-ink-600 mt-1 flex items-center gap-2 flex-wrap">
          {finding.host_id ? (
            <Link to={`/hosts/${finding.host_id}`} className="hover:text-accent">
              {finding.host_name}
            </Link>
          ) : (
            <span>{finding.service_name}</span>
          )}
          <span>·</span>
          <span className="font-mono">{finding.code}</span>
          <span>·</span>
          <span>vu {ago(finding.last_seen)}</span>
        </div>
      </div>
      <div className="flex items-center gap-1 shrink-0">
        {finding.code.startsWith('patch.') && finding.host_id && (
          <Link to={`/hosts/${finding.host_id}`} className="btn-ghost py-1 px-2 text-xs">
            <Download size={12} />
            Corriger
          </Link>
        )}
        <button className="btn-icon" onClick={onMute} title={muted ? 'Réactiver' : 'Ignorer'}>
          {muted ? <Shield size={14} /> : <BellOff size={14} />}
        </button>
      </div>
    </div>
  )
}

function ScoreRing({ score, size = 40 }: { score: number; size?: number }) {
  const tone = scoreTone(score)
  const radius = (size - 5) / 2
  const circumference = 2 * Math.PI * radius
  return (
    <svg width={size} height={size} className="-rotate-90 shrink-0">
      <circle cx={size / 2} cy={size / 2} r={radius} fill="none" stroke="#1a202d" strokeWidth="4" />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={radius}
        fill="none"
        stroke={tone.color}
        strokeWidth="4"
        strokeLinecap="round"
        strokeDasharray={circumference}
        strokeDashoffset={circumference * (1 - Math.max(0, Math.min(100, score)) / 100)}
        style={{ transition: 'stroke-dashoffset 500ms ease' }}
      />
    </svg>
  )
}
