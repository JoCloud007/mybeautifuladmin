import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  CalendarClock,
  Download,
  Eraser,
  Pause,
  Play,
  Plus,
  Power,
  RefreshCw,
  RotateCcw,
  Terminal,
  Trash2,
  Zap,
} from 'lucide-react'
import { useEffect, useState } from 'react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Modal, Spinner, useConfirm, useToast } from '@/components/ui'
import { del, get, patch, post } from '@/lib/api'
import { ago, datetime } from '@/lib/format'

const ACTION_ICON: Record<string, typeof Download> = {
  upgrade: Download,
  reboot: RotateCcw,
  shutdown: Power,
  service: RefreshCw,
  container: RefreshCw,
  prune: Eraser,
  command: Terminal,
}

const ACTION_TONE: Record<string, 'ok' | 'warn' | 'danger' | 'info' | 'violet' | 'neutral'> = {
  upgrade: 'info',
  reboot: 'warn',
  shutdown: 'danger',
  service: 'ok',
  container: 'ok',
  prune: 'violet',
  command: 'neutral',
}

/** Presets cron : couvrent l'essentiel sans obliger à connaître la syntaxe. */
const PRESETS: { label: string; cron: string }[] = [
  { label: 'Chaque nuit à 3 h', cron: '0 3 * * *' },
  { label: 'Chaque lundi à 4 h', cron: '0 4 * * 1' },
  { label: 'Chaque dimanche à 4 h', cron: '0 4 * * 0' },
  { label: 'Le 1er du mois à 5 h', cron: '0 5 1 * *' },
  { label: 'Toutes les 6 heures', cron: '0 */6 * * *' },
  { label: 'Toutes les heures', cron: '0 * * * *' },
]

export function SchedulerPage() {
  const [editing, setEditing] = useState<any | null>(null)
  const [creating, setCreating] = useState(false)
  const [output, setOutput] = useState<any | null>(null)
  const [running, setRunning] = useState<number | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['schedules'],
    queryFn: () => get('/schedules'),
    refetchInterval: 15000,
  })

  const schedules = data?.schedules ?? []
  const refresh = () => queryClient.invalidateQueries({ queryKey: ['schedules'] })

  const toggle = async (schedule: any) => {
    await patch(`/schedules/${schedule.id}`, { enabled: !schedule.enabled })
    refresh()
  }

  const remove = async (schedule: any) => {
    const ok = await confirm({
      title: 'Supprimer cette planification ?',
      message: (
        <>
          <b className="text-mist-100">{schedule.name}</b> ne sera plus exécutée.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await del(`/schedules/${schedule.id}`)
    toast('Planification supprimée', 'ok')
    refresh()
  }

  const runNow = async (schedule: any) => {
    const ok = await confirm({
      title: 'Exécuter maintenant ?',
      message: (
        <>
          <b className="text-mist-100">{schedule.name}</b> sera lancée immédiatement sur{' '}
          {schedule.targets} cible(s). Le prochain passage planifié reste inchangé.
        </>
      ),
      confirmLabel: 'Exécuter',
      danger: ['reboot', 'shutdown'].includes(schedule.action),
    })
    if (!ok) return
    setRunning(schedule.id)
    try {
      const result = await post(`/schedules/${schedule.id}/run`)
      toast(`${schedule.name} : ${result.status}`, result.status === 'success' ? 'ok' : 'danger')
      setOutput({ name: schedule.name, ...result })
      refresh()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setRunning(null)
    }
  }

  const active = schedules.filter((s: any) => s.enabled)

  return (
    <Page>
      <PageHeader
        title="Planificateur"
        subtitle={
          schedules.length
            ? `${active.length} planification(s) active(s) sur ${schedules.length} · fuseau ${data?.timezone ?? ''}`
            : 'Automatise la maintenance récurrente de ton parc'
        }
        actions={
          <button className="btn-primary" onClick={() => setCreating(true)}>
            <Plus size={15} />
            Nouvelle planification
          </button>
        }
      />

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && schedules.length === 0 && (
        <div className="panel">
          <Empty
            icon={<CalendarClock size={38} />}
            title="Aucune maintenance planifiée"
            hint="Programme la mise à jour hebdomadaire de tes serveurs, une purge Docker mensuelle, ou le redémarrage d'un service capricieux — MBA s'en occupe et journalise tout."
            action={
              <button className="btn-primary" onClick={() => setCreating(true)}>
                <Plus size={15} />
                Créer une planification
              </button>
            }
          />
        </div>
      )}

      <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(380px,1fr))]">
        {schedules.map((schedule: any) => {
          const Icon = ACTION_ICON[schedule.action] ?? CalendarClock
          return (
            <div
              key={schedule.id}
              className={clsx('panel panel-hover p-4 space-y-3', !schedule.enabled && 'opacity-60')}
            >
              <div className="flex items-start gap-2.5">
                <div
                  className={clsx(
                    'w-8 h-8 rounded-lg grid place-items-center shrink-0 border',
                    schedule.enabled
                      ? 'bg-accent/12 border-accent/25 text-accent'
                      : 'bg-ink-800 border-ink-700 text-ink-500',
                  )}
                >
                  {schedule.running ? <Spinner size={15} /> : <Icon size={16} />}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="text-sm font-medium text-mist-100 truncate">{schedule.name}</div>
                  <div className="text-[11px] text-ink-600 truncate">{schedule.description}</div>
                </div>
                <Badge tone={ACTION_TONE[schedule.action] ?? 'neutral'}>
                  {data?.actions?.[schedule.action] ?? schedule.action}
                </Badge>
              </div>

              <div className="grid grid-cols-3 gap-2 text-center">
                <div>
                  <div className="metric-label">Cibles</div>
                  <div className="metric-value text-sm">{schedule.targets}</div>
                </div>
                <div>
                  <div className="metric-label">Prochaine</div>
                  <div className="metric-value text-sm" title={datetime(schedule.next_run)}>
                    {schedule.enabled ? relative(schedule.next_run) : '—'}
                  </div>
                </div>
                <div>
                  <div className="metric-label">Dernière</div>
                  <div
                    className={clsx(
                      'metric-value text-sm',
                      schedule.last_status === 'success' && 'text-accent',
                      schedule.last_status === 'partial' && 'text-warn',
                      schedule.last_status === 'failed' && 'text-danger',
                    )}
                  >
                    {schedule.last_run ? (schedule.last_status ?? '—') : 'jamais'}
                  </div>
                </div>
              </div>

              <div className="flex items-center justify-between text-[10px] text-ink-600 font-mono">
                <span>{schedule.cron}</span>
                {schedule.last_run && <span>lancée {ago(schedule.last_run)}</span>}
              </div>

              <div className="flex items-center gap-1 pt-1 border-t border-ink-800">
                <button
                  className="btn-icon"
                  onClick={() => toggle(schedule)}
                  title={schedule.enabled ? 'Suspendre' : 'Activer'}
                >
                  {schedule.enabled ? <Pause size={14} /> : <Play size={14} />}
                </button>
                <button
                  className="btn-icon"
                  onClick={() => runNow(schedule)}
                  disabled={running === schedule.id || schedule.running}
                  title="Exécuter maintenant"
                >
                  {running === schedule.id ? <Spinner size={13} /> : <Zap size={14} />}
                </button>
                {schedule.last_output && (
                  <button
                    className="btn-ghost py-1 px-2 text-xs"
                    onClick={() => setOutput({ name: schedule.name, output: schedule.last_output, status: schedule.last_status })}
                  >
                    Journal
                  </button>
                )}
                <div className="flex-1" />
                <button className="btn-ghost py-1 px-2 text-xs" onClick={() => setEditing(schedule)}>
                  Modifier
                </button>
                <button className="btn-icon hover:text-danger" onClick={() => remove(schedule)} title="Supprimer">
                  <Trash2 size={14} />
                </button>
              </div>
            </div>
          )
        })}
      </div>

      <ScheduleModal
        open={creating || !!editing}
        schedule={editing}
        onClose={() => {
          setCreating(false)
          setEditing(null)
        }}
        onSaved={refresh}
      />

      <Modal
        open={!!output}
        onClose={() => setOutput(null)}
        title={`Exécution · ${output?.name ?? ''}`}
        width="max-w-3xl"
      >
        <div className="space-y-3">
          {output?.status && (
            <Badge tone={output.status === 'success' ? 'ok' : output.status === 'partial' ? 'warn' : 'danger'}>
              {output.status}
            </Badge>
          )}
          <pre className="text-[12px] font-mono text-mist-300 whitespace-pre-wrap break-words leading-relaxed max-h-[60vh] overflow-y-auto bg-ink-900 rounded-lg p-3">
            {output?.output || 'Aucune sortie.'}
          </pre>
        </div>
      </Modal>
    </Page>
  )
}

function relative(iso?: string | null): string {
  if (!iso) return '—'
  const delta = (new Date(iso).getTime() - Date.now()) / 1000
  if (delta < 0) return 'imminente'
  if (delta < 3600) return `dans ${Math.round(delta / 60)} min`
  if (delta < 86400) return `dans ${Math.round(delta / 3600)} h`
  return `dans ${Math.round(delta / 86400)} j`
}

function ScheduleModal({
  open,
  schedule,
  onClose,
  onSaved,
}: {
  open: boolean
  schedule: any | null
  onClose: () => void
  onSaved: () => void
}) {
  const empty = {
    name: '',
    action: 'upgrade',
    target_kind: 'all',
    target_value: '',
    cron: '0 3 * * 0',
    enabled: true,
    params: {} as Record<string, any>,
  }
  const [form, setForm] = useState(empty)
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<any | null>(null)
  const toast = useToast()

  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts'), enabled: open })
  const { data: inventory } = useQuery({
    queryKey: ['inventory'],
    queryFn: () => get('/inventory'),
    enabled: open,
  })

  const payloadOf = (f: typeof empty) => ({
    name: f.name || 'Planification',
    action: f.action,
    target_kind: f.target_kind,
    target_value: f.target_kind === 'all' ? null : f.target_value,
    cron: f.cron,
    enabled: f.enabled,
    params: f.params,
  })

  useEffect(() => {
    setForm(schedule ? { ...empty, ...schedule, params: schedule.params ?? {} } : empty)
    setPreview(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [schedule, open])

  // Aperçu en direct : cibles concernées et prochains passages.
  useEffect(() => {
    if (!open) return
    const timer = setTimeout(() => {
      post('/schedules/preview', payloadOf(form))
        .then(setPreview)
        .catch(() => setPreview(null))
    }, 400)
    return () => clearTimeout(timer)
  }, [form, open])

  const save = async () => {
    setBusy(true)
    try {
      if (schedule) await patch(`/schedules/${schedule.id}`, payloadOf(form))
      else await post('/schedules', payloadOf(form))
      toast(schedule ? 'Planification mise à jour' : 'Planification créée', 'ok')
      onSaved()
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const setParam = (key: string, value: any) =>
    setForm({ ...form, params: { ...form.params, [key]: value } })

  const kinds = [...new Set(hosts.map((h: any) => h.kind))] as string[]
  const tags = inventory?.tags ?? []

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={schedule ? 'Modifier la planification' : 'Nouvelle planification'}
      width="max-w-2xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" onClick={save} disabled={busy || !form.name}>
            {busy ? <Spinner /> : schedule ? 'Enregistrer' : 'Créer'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="Mise à jour hebdomadaire"
              className="w-full"
              autoFocus
            />
          </div>
          <div className="space-y-1.5">
            <label>Action</label>
            <select
              value={form.action}
              onChange={(e) => setForm({ ...form, action: e.target.value, params: {} })}
              className="w-full"
            >
              <option value="upgrade">Mise à jour des paquets</option>
              <option value="prune">Purge Docker</option>
              <option value="service">Redémarrer un service</option>
              <option value="container">Action sur un conteneur</option>
              <option value="command">Commande personnalisée</option>
              <option value="reboot">Redémarrage</option>
              <option value="shutdown">Extinction</option>
            </select>
          </div>
        </div>

        {/* Paramètres propres à l'action */}
        {form.action === 'service' && (
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <label>Service systemd</label>
              <input
                value={form.params.service ?? ''}
                onChange={(e) => setParam('service', e.target.value)}
                placeholder="nginx.service"
                className="w-full font-mono"
              />
            </div>
            <div className="space-y-1.5">
              <label>Opération</label>
              <select
                value={form.params.mode ?? 'restart'}
                onChange={(e) => setParam('mode', e.target.value)}
                className="w-full"
              >
                <option value="restart">Redémarrer</option>
                <option value="reload">Recharger</option>
                <option value="start">Démarrer</option>
                <option value="stop">Arrêter</option>
              </select>
            </div>
          </div>
        )}

        {form.action === 'container' && (
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <label>Conteneur (nom ou id)</label>
              <input
                value={form.params.container ?? ''}
                onChange={(e) => setParam('container', e.target.value)}
                placeholder="nextcloud"
                className="w-full font-mono"
              />
            </div>
            <div className="space-y-1.5">
              <label>Opération</label>
              <select
                value={form.params.mode ?? 'restart'}
                onChange={(e) => setParam('mode', e.target.value)}
                className="w-full"
              >
                <option value="restart">Redémarrer</option>
                <option value="start">Démarrer</option>
                <option value="stop">Arrêter</option>
              </select>
            </div>
          </div>
        )}

        {form.action === 'prune' && (
          <div className="space-y-1.5">
            <label>Ressources à purger</label>
            <div className="flex flex-wrap gap-1.5">
              {[
                ['containers', 'Conteneurs arrêtés'],
                ['images', 'Images orphelines'],
                ['images_all', 'Toutes images inutilisées'],
                ['volumes', 'Volumes orphelins'],
                ['networks', 'Réseaux'],
                ['build_cache', 'Cache de build'],
              ].map(([value, label]) => {
                const selected = (form.params.targets ?? ['containers', 'build_cache']).includes(value)
                return (
                  <button
                    key={value}
                    onClick={() => {
                      const current: string[] = form.params.targets ?? ['containers', 'build_cache']
                      setParam(
                        'targets',
                        selected ? current.filter((t) => t !== value) : [...current, value],
                      )
                    }}
                    className={clsx(
                      'chip transition-colors',
                      selected
                        ? 'border-accent/40 bg-accent/10 text-accent'
                        : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
                    )}
                  >
                    {label}
                  </button>
                )
              })}
            </div>
          </div>
        )}

        {form.action === 'command' && (
          <div className="space-y-1.5">
            <label>Commande</label>
            <textarea
              value={form.params.command ?? ''}
              onChange={(e) => setParam('command', e.target.value)}
              rows={3}
              placeholder="/usr/local/bin/backup.sh --quiet"
              className="w-full font-mono text-[12px]"
            />
            <p className="text-[11px] text-ink-500">
              Exécutée via SSH, avec le compte associé à l'hôte. Sortie et code de retour journalisés.
            </p>
          </div>
        )}

        {['reboot', 'shutdown'].includes(form.action) && (
          <p className="text-[12px] text-warn bg-warn/8 border border-warn/25 rounded-lg px-3 py-2">
            Cette action interrompt les services hébergés. Vérifie la portée ci-dessous avant d'enregistrer.
          </p>
        )}

        {/* Portée */}
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Portée</label>
            <select
              value={form.target_kind}
              onChange={(e) => setForm({ ...form, target_kind: e.target.value, target_value: '' })}
              className="w-full"
            >
              <option value="all">Tout le parc</option>
              <option value="host">Un hôte précis</option>
              <option value="tag">Par étiquette</option>
              <option value="kind">Par type</option>
            </select>
          </div>
          <div className="space-y-1.5">
            <label>Cible</label>
            {form.target_kind === 'all' ? (
              <input disabled value="tous les hôtes actifs" className="w-full opacity-60" />
            ) : (
              <select
                value={form.target_value ?? ''}
                onChange={(e) => setForm({ ...form, target_value: e.target.value })}
                className="w-full"
              >
                <option value="">— choisir —</option>
                {form.target_kind === 'host' &&
                  hosts.map((host: any) => (
                    <option key={host.id} value={String(host.id)}>
                      {host.name} ({host.address})
                    </option>
                  ))}
                {form.target_kind === 'tag' &&
                  tags.map((tag: any) => (
                    <option key={tag.tag} value={tag.tag}>
                      {tag.tag} ({tag.count})
                    </option>
                  ))}
                {form.target_kind === 'kind' &&
                  kinds.map((kind) => (
                    <option key={kind} value={kind}>
                      {kind}
                    </option>
                  ))}
              </select>
            )}
          </div>
        </div>

        {/* Récurrence */}
        <div className="space-y-1.5">
          <label>Récurrence</label>
          <div className="flex flex-wrap gap-1.5 mb-2">
            {PRESETS.map((preset) => (
              <button
                key={preset.cron}
                onClick={() => setForm({ ...form, cron: preset.cron })}
                className={clsx(
                  'chip transition-colors',
                  form.cron === preset.cron
                    ? 'border-accent/40 bg-accent/10 text-accent'
                    : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
                )}
              >
                {preset.label}
              </button>
            ))}
          </div>
          <input
            value={form.cron}
            onChange={(e) => setForm({ ...form, cron: e.target.value })}
            className="w-full font-mono"
            placeholder="min heure jour mois jour-semaine"
          />
        </div>

        {/* Aperçu */}
        <div className="panel bg-ink-900/60 p-3 space-y-2">
          <SectionTitle>Aperçu</SectionTitle>
          {!preview ? (
            <p className="text-xs text-ink-500">Expression cron invalide, ou aucune cible.</p>
          ) : (
            <>
              <div className="text-[12px] text-mist-300">
                <span className="text-ink-500">Concerne </span>
                <b className="text-mist-100">{preview.targets.length}</b>
                <span className="text-ink-500"> hôte(s) : </span>
                {preview.targets.slice(0, 5).map((t: any) => t.name).join(', ')}
                {preview.targets.length > 5 && ` +${preview.targets.length - 5}`}
                {preview.targets.length === 0 && <span className="text-warn">aucune correspondance</span>}
              </div>
              <div className="text-[11px] text-ink-500 font-mono">
                Prochains passages : {preview.next_runs.slice(0, 3).map((r: string) => datetime(r)).join(' · ')}
              </div>
            </>
          )}
        </div>
      </div>
    </Modal>
  )
}
