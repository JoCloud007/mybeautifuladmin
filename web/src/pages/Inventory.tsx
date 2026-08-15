import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Boxes,
  CheckSquare,
  Cpu,
  Download,
  FolderTree,
  HardDrive,
  Layers,
  Plus,
  RefreshCw,
  Search,
  Server,
  Square,
  Tag,
  Trash2,
  X,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { AddHostModal } from '@/components/AddHostModal'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Empty,
  Modal,
  Spinner,
  StatTile,
  StatusDot,
  Tabs,
  useConfirm,
  useLocalState,
  useToast,
} from '@/components/ui'
import { download, get, patch, post } from '@/lib/api'
import { ago, bytes, duration, KIND_LABEL } from '@/lib/format'

const UNCATEGORIZED = 'Sans catégorie'

const CRED_LABELS: Record<string, string> = {
  ssh_key: 'clé SSH',
  ssh_password: 'mot de passe',
  api_token: "jeton d'API",
  token: 'jeton',
  basic: 'HTTP Basic',
}

/** Types d'identifiants acceptés par type d'hôte — miroir du contrôle serveur. */
const EXPECTED_KINDS: Record<string, Set<string>> = {
  linux: new Set(['ssh_key', 'ssh_password']),
  docker: new Set(['ssh_key', 'ssh_password']),
  proxmox: new Set(['api_token', 'token', 'ssh_password']),
  pbs: new Set(['api_token', 'token']),
  synology: new Set(['ssh_password', 'basic']),
  homeassistant: new Set(['token', 'api_token']),
  ipmi: new Set(['ssh_password', 'basic', 'api_token']),
}

const EXPECTED_HINT: Record<string, string> = {
  linux: 'une clé SSH ou un mot de passe',
  docker: 'une clé SSH ou un mot de passe',
  proxmox: "un jeton d'API",
  pbs: "un jeton d'API",
  synology: 'un compte DSM',
  homeassistant: "un jeton d'accès longue durée",
  ipmi: 'un compte du contrôleur BMC',
}

/** Types d'hôtes qui ne collectent rien sans identifiant.
 *  (L'hôte Docker interne passe par le socket monté : il fait exception.) */
const NEEDS_CREDENTIAL = new Set([
  'linux', 'docker', 'proxmox', 'pbs', 'synology', 'homeassistant', 'ipmi',
])

export function InventoryPage() {
  const [query, setQuery] = useState('')
  const [tagFilter, setTagFilter] = useState<string[]>([])
  const [categoryFilter, setCategoryFilter] = useState<string | null>(null)
  const [selection, setSelection] = useState<Set<number>>(new Set())
  const [addOpen, setAddOpen] = useState(false)
  const [editing, setEditing] = useState<any | null>(null)
  const [bulkOpen, setBulkOpen] = useState(false)
  const [groupBy, setGroupBy] = useLocalState<'category' | 'kind' | 'none'>('mba.invGroup', 'category')
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['inventory'],
    queryFn: () => get('/inventory'),
    refetchInterval: 30000,
  })

  const hosts = data?.hosts ?? []
  const summary = data?.summary ?? {}

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return hosts.filter((host: any) => {
      if (categoryFilter && (host.category || UNCATEGORIZED) !== categoryFilter) return false
      if (tagFilter.length && !tagFilter.every((t) => (host.tags ?? []).includes(t))) return false
      if (!needle) return true
      const identity = host.identity ?? {}
      return [
        host.name,
        host.address,
        host.location,
        host.notes,
        identity.model,
        identity.vendor,
        identity.serial,
        identity.cpu_model,
        (host.tags ?? []).join(' '),
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase()
        .includes(needle)
    })
  }, [hosts, query, tagFilter, categoryFilter])

  const groups = useMemo(() => {
    if (groupBy === 'none') return [['Tous les équipements', filtered]] as [string, any[]][]
    const map = new Map<string, any[]>()
    for (const host of filtered) {
      const key =
        groupBy === 'kind' ? (KIND_LABEL[host.kind] ?? host.kind) : host.category || UNCATEGORIZED
      map.set(key, [...(map.get(key) ?? []), host])
    }
    return [...map.entries()].sort((a, b) =>
      a[0] === UNCATEGORIZED ? 1 : b[0] === UNCATEGORIZED ? -1 : a[0].localeCompare(b[0]),
    )
  }, [filtered, groupBy])

  const toggle = (id: number) =>
    setSelection((current) => {
      const next = new Set(current)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })

  const toggleAll = () =>
    setSelection((current) =>
      current.size === filtered.length ? new Set() : new Set(filtered.map((h: any) => h.id)),
    )

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ['inventory'] })
    queryClient.invalidateQueries({ queryKey: ['hosts'] })
  }

  const removeSelected = async () => {
    const names = filtered.filter((h: any) => selection.has(h.id)).map((h: any) => h.name)
    const ok = await confirm({
      title: `Supprimer ${selection.size} équipement(s) ?`,
      message: (
        <>
          <span className="text-mist-100">{names.slice(0, 6).join(', ')}</span>
          {names.length > 6 && ` et ${names.length - 6} autre(s)`} seront retirés de l'inventaire avec
          tout leur historique de métriques. Cette action est irréversible.
        </>
      ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await post('/inventory/bulk/delete', { host_ids: [...selection] })
    toast(`${selection.size} équipement(s) supprimé(s)`, 'ok')
    setSelection(new Set())
    refresh()
  }

  const exportCsv = () =>
    download('/inventory/export', 'inventaire-mba.csv').catch((exc) => toast(exc.message, 'danger'))

  return (
    <Page>
      <PageHeader
        title="Inventaire"
        subtitle={`${summary.total ?? 0} équipement(s) · ${data?.categories?.length ?? 0} catégorie(s) · ${data?.tags?.length ?? 0} étiquette(s)`}
        actions={
          <>
            <div className="relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-ink-500 pointer-events-none" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Modèle, série, IP, note…"
                className="pl-8 py-1.5 w-56"
              />
            </div>
            <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {(
                [
                  ['category', 'Catégorie'],
                  ['kind', 'Type'],
                  ['none', 'Aucun'],
                ] as const
              ).map(([value, label]) => (
                <button
                  key={value}
                  onClick={() => setGroupBy(value)}
                  className={clsx(
                    'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                    groupBy === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                >
                  {label}
                </button>
              ))}
            </div>
            <button className="btn-ghost" onClick={exportCsv} title="Exporter en CSV">
              <Download size={15} />
              CSV
            </button>
            <button className="btn-primary" onClick={() => setAddOpen(true)}>
              <Plus size={15} />
              Ajouter
            </button>
          </>
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-4">
        <StatTile label="Équipements" value={summary.total ?? 0} icon={<Server size={20} />} />
        <StatTile
          label="Sans étiquette"
          value={summary.untagged ?? 0}
          sub="à classer"
          tone={summary.untagged ? 'warn' : 'ok'}
          icon={<Tag size={20} />}
        />
        <StatTile
          label="Mises à jour"
          value={summary.updates ?? 0}
          sub="paquets en attente"
          tone={summary.updates ? 'warn' : 'ok'}
          icon={<Download size={20} />}
        />
        <StatTile
          label="Redémarrage requis"
          value={summary.reboot_required ?? 0}
          tone={summary.reboot_required ? 'danger' : 'ok'}
          icon={<RefreshCw size={20} />}
        />
      </div>

      {/* Filtres catégories + étiquettes */}
      <div className="flex flex-wrap items-center gap-1.5 mb-4">
        <FolderTree size={14} className="text-ink-600" />
        {(data?.categories ?? []).map((entry: any) => (
          <FilterChip
            key={entry.category}
            active={categoryFilter === entry.category}
            onClick={() =>
              setCategoryFilter(categoryFilter === entry.category ? null : entry.category)
            }
            count={entry.count}
          >
            {entry.category}
          </FilterChip>
        ))}
        {summary.by_category?.['—'] > 0 && (
          <FilterChip
            active={categoryFilter === UNCATEGORIZED}
            onClick={() => setCategoryFilter(categoryFilter === UNCATEGORIZED ? null : UNCATEGORIZED)}
            count={summary.by_category['—']}
          >
            {UNCATEGORIZED}
          </FilterChip>
        )}

        {(data?.tags ?? []).length > 0 && <span className="w-px h-4 bg-ink-750 mx-1" />}
        <Tag size={14} className="text-ink-600" />
        {(data?.tags ?? []).map((entry: any) => (
          <FilterChip
            key={entry.tag}
            active={tagFilter.includes(entry.tag)}
            onClick={() =>
              setTagFilter((current) =>
                current.includes(entry.tag)
                  ? current.filter((t) => t !== entry.tag)
                  : [...current, entry.tag],
              )
            }
            count={entry.count}
          >
            {entry.tag}
          </FilterChip>
        ))}
        {(tagFilter.length > 0 || categoryFilter) && (
          <button
            className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-danger"
            onClick={() => {
              setTagFilter([])
              setCategoryFilter(null)
            }}
          >
            <X size={11} />
            Réinitialiser
          </button>
        )}
      </div>

      {/* Barre d'actions groupées */}
      {selection.size > 0 && (
        <div className="panel border-accent/30 bg-accent/[0.05] px-4 py-2.5 mb-4 flex flex-wrap items-center gap-2 sticky top-2 z-20 animate-slideUp">
          <CheckSquare size={16} className="text-accent" />
          <span className="text-sm text-mist-100 font-medium">
            {selection.size} sélectionné(s)
          </span>
          <div className="flex-1" />
          <button className="btn-ghost" onClick={() => setBulkOpen(true)}>
            <Layers size={14} />
            Classer
          </button>
          <button className="btn-danger" onClick={removeSelected}>
            <Trash2 size={14} />
            Supprimer
          </button>
          <button className="btn-icon" onClick={() => setSelection(new Set())} title="Tout désélectionner">
            <X size={15} />
          </button>
        </div>
      )}

      {isLoading && (
        <div className="panel p-12 grid place-items-center">
          <Spinner size={22} />
        </div>
      )}

      {!isLoading && filtered.length === 0 && (
        <div className="panel">
          <Empty
            icon={<Server size={38} />}
            title={hosts.length ? 'Aucun résultat' : 'Inventaire vide'}
            hint={
              hosts.length
                ? 'Aucun équipement ne correspond à ces filtres.'
                : "Ajoute un équipement, ou lance une découverte réseau pour peupler l'inventaire automatiquement."
            }
            action={
              hosts.length ? undefined : (
                <Link to="/discovery" className="btn-primary">
                  Scanner le réseau
                </Link>
              )
            }
          />
        </div>
      )}

      <div className="space-y-5">
        {groups.map(([group, list]) => (
          <section key={group}>
            <SectionTitle
              right={
                <button
                  onClick={toggleAll}
                  className="text-xs text-ink-500 hover:text-mist-200 flex items-center gap-1.5"
                >
                  {selection.size === filtered.length && filtered.length > 0 ? (
                    <CheckSquare size={13} />
                  ) : (
                    <Square size={13} />
                  )}
                  {list.length}
                </button>
              }
            >
              {group}
            </SectionTitle>
            <div className="panel overflow-x-auto">
              <table className="w-full text-sm min-w-[900px]">
                <thead>
                  <tr className="text-left border-b border-ink-750">
                    <th className="w-8 px-3 py-2" />
                    {['Équipement', 'Matériel', 'Système', 'Ressources', 'Étiquettes', 'Identifiants', 'Emplacement', ''].map(
                      (header) => (
                        <th key={header} className="metric-label px-3 py-2 font-semibold">
                          {header}
                        </th>
                      ),
                    )}
                  </tr>
                </thead>
                <tbody>
                  {list.map((host: any) => (
                    <InventoryRow
                      key={host.id}
                      host={host}
                      selected={selection.has(host.id)}
                      onToggle={() => toggle(host.id)}
                      onEdit={() => setEditing(host)}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        ))}
      </div>

      <AddHostModal open={addOpen} onClose={() => setAddOpen(false)} />
      <EditModal host={editing} onClose={() => setEditing(null)} allTags={data?.tags ?? []} onSaved={refresh} />
      <BulkModal
        open={bulkOpen}
        onClose={() => setBulkOpen(false)}
        count={selection.size}
        hostIds={[...selection]}
        categories={data?.categories ?? []}
        allTags={data?.tags ?? []}
        onSaved={() => {
          setSelection(new Set())
          refresh()
        }}
      />
    </Page>
  )
}

function FilterChip({
  children,
  active,
  count,
  onClick,
}: {
  children: React.ReactNode
  active: boolean
  count: number
  onClick: () => void
}) {
  return (
    <button
      onClick={onClick}
      className={clsx(
        'chip transition-colors',
        active
          ? 'border-accent/40 bg-accent/10 text-accent'
          : 'border-ink-700 bg-ink-850 text-mist-400 hover:text-mist-200',
      )}
    >
      {children}
      <span className="text-ink-500 ml-0.5">{count}</span>
    </button>
  )
}

function InventoryRow({
  host,
  selected,
  onToggle,
  onEdit,
}: {
  host: any
  selected: boolean
  onToggle: () => void
  onEdit: () => void
}) {
  const identity = host.identity ?? {}
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  const refreshHardware = async () => {
    setBusy(true)
    try {
      await post(`/inventory/${host.id}/refresh`)
      toast(`Fiche matérielle de ${host.name} rafraîchie`, 'ok')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <tr className={clsx('border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40', selected && 'bg-accent/[0.04]')}>
      <td className="px-3 py-2.5">
        <button onClick={onToggle} className="text-ink-500 hover:text-accent">
          {selected ? <CheckSquare size={15} className="text-accent" /> : <Square size={15} />}
        </button>
      </td>
      <td className="px-3 py-2.5">
        <Link to={`/hosts/${host.id}`} className="flex items-center gap-2 group">
          <StatusDot status={host.status} />
          <div className="min-w-0">
            <div className="text-mist-100 group-hover:text-accent transition-colors truncate">{host.name}</div>
            <div className="text-[11px] text-ink-600 font-mono">
              {host.address} · {KIND_LABEL[host.kind] ?? host.kind}
            </div>
          </div>
        </Link>
      </td>
      <td className="px-3 py-2.5">
        <div className="text-[13px] text-mist-300 truncate max-w-[200px]">{identity.model || '—'}</div>
        <div className="text-[10px] text-ink-600 truncate max-w-[200px]">
          {[identity.vendor, identity.serial].filter(Boolean).join(' · ') || (identity.chassis ?? '')}
        </div>
      </td>
      <td className="px-3 py-2.5">
        <div className="text-[13px] text-mist-300 truncate max-w-[190px]">{identity.version || '—'}</div>
        <div className="text-[10px] text-ink-600 truncate max-w-[190px]">
          {identity.kernel || ''}
          {identity.updates > 0 && (
            <span className="text-warn ml-1">· {identity.updates} maj</span>
          )}
        </div>
      </td>
      <td className="px-3 py-2.5">
        <div className="flex items-center gap-2.5 text-[11px] text-mist-400 font-mono">
          {identity.cpu_count && (
            <span className="flex items-center gap-1" title={identity.cpu_model ?? ''}>
              <Cpu size={11} />
              {identity.cpu_count}
            </span>
          )}
          {identity.mem_total && (
            <span className="flex items-center gap-1">
              <Layers size={11} />
              {bytes(identity.mem_total, 0)}
            </span>
          )}
          {identity.disk_total && (
            <span className="flex items-center gap-1">
              <HardDrive size={11} />
              {bytes(identity.disk_total, 0)}
            </span>
          )}
          {host.containers > 0 && (
            <span className="flex items-center gap-1">
              <Boxes size={11} />
              {host.containers}
            </span>
          )}
        </div>
        {identity.uptime ? (
          <div className="text-[10px] text-ink-600 mt-0.5">up {duration(identity.uptime)}</div>
        ) : (
          <div className="text-[10px] text-ink-600 mt-0.5">vu {ago(host.last_seen)}</div>
        )}
      </td>
      <td className="px-3 py-2.5">
        <div className="flex flex-wrap gap-1 max-w-[180px]">
          {(host.tags ?? []).length === 0 && <span className="text-ink-600 text-xs">—</span>}
          {(host.tags ?? []).map((tag: string) => (
            <Badge key={tag}>{tag}</Badge>
          ))}
        </div>
      </td>
      <td className="px-3 py-2.5">
        {host.credential_name ? (
          <span className="text-xs text-mist-400 truncate block max-w-[130px]" title={host.credential_name}>
            {host.credential_name}
          </span>
        ) : NEEDS_CREDENTIAL.has(host.kind) && host.address !== 'local' ? (
          <Badge tone="warn">manquant</Badge>
        ) : (
          <span className="text-ink-600 text-xs">—</span>
        )}
      </td>
      <td className="px-3 py-2.5 text-xs text-mist-400 truncate max-w-[140px]">{host.location || '—'}</td>
      <td className="px-3 py-2.5">
        <div className="flex items-center justify-end gap-1">
          <button className="btn-icon" onClick={refreshHardware} title="Relire la fiche matérielle">
            {busy ? <Spinner size={13} /> : <RefreshCw size={14} />}
          </button>
          <button className="btn-ghost py-1 px-2 text-xs" onClick={onEdit}>
            Modifier
          </button>
        </div>
      </td>
    </tr>
  )
}

function TagEditor({
  value,
  onChange,
  suggestions,
}: {
  value: string[]
  onChange: (tags: string[]) => void
  suggestions: { tag: string; count: number }[]
}) {
  const [input, setInput] = useState('')

  const add = (tag: string) => {
    const clean = tag.trim().toLowerCase()
    if (clean && !value.includes(clean)) onChange([...value, clean])
    setInput('')
  }

  const unused = suggestions.filter((s) => !value.includes(s.tag)).slice(0, 8)

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-1.5 min-h-[26px]">
        {value.map((tag) => (
          <span key={tag} className="chip border-accent/30 bg-accent/10 text-accent">
            {tag}
            <button onClick={() => onChange(value.filter((t) => t !== tag))} className="hover:text-danger ml-0.5">
              <X size={10} />
            </button>
          </span>
        ))}
        {value.length === 0 && <span className="text-xs text-ink-600">Aucune étiquette</span>}
      </div>
      <input
        value={input}
        onChange={(e) => setInput(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ',') {
            e.preventDefault()
            add(input)
          } else if (e.key === 'Backspace' && !input && value.length) {
            onChange(value.slice(0, -1))
          }
        }}
        placeholder="Saisir puis Entrée…"
        className="w-full"
      />
      {unused.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {unused.map((s) => (
            <button
              key={s.tag}
              onClick={() => add(s.tag)}
              className="chip border-ink-700 bg-ink-850 text-mist-400 hover:text-accent hover:border-accent/40"
            >
              + {s.tag}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

const TECH_FIELDS: { key: string; label: string; type?: 'number' | 'date'; hint?: string }[] = [
  { key: 'vendor', label: 'Constructeur' },
  { key: 'model', label: 'Modèle' },
  { key: 'serial', label: 'Numéro de série' },
  { key: 'asset_tag', label: "Code d'immobilisation" },
  { key: 'chassis', label: 'Format / châssis' },
  { key: 'bios', label: 'Version BIOS' },
  { key: 'version', label: "Système d'exploitation" },
  { key: 'cpu_model', label: 'Processeur' },
  { key: 'cpu_count', label: 'Cœurs', type: 'number' },
  { key: 'mem_total', label: 'Mémoire (octets)', type: 'number', hint: 'Ex. 34359738368 pour 32 Gio' },
  { key: 'disk_total', label: 'Stockage (octets)', type: 'number' },
  { key: 'power_watts', label: 'Consommation (W)', type: 'number' },
  { key: 'rack', label: 'Baie' },
  { key: 'rack_unit', label: 'Position (U)' },
  { key: 'ip_management', label: 'IP de gestion' },
  { key: 'supplier', label: 'Fournisseur' },
  { key: 'cost', label: "Prix d'achat", type: 'number' },
  { key: 'purchased_at', label: "Date d'achat", type: 'date' },
  { key: 'warranty_until', label: 'Garantie jusqu\'au', type: 'date' },
  { key: 'comment', label: 'Commentaire technique' },
]

function EditModal({
  host,
  onClose,
  allTags,
  onSaved,
}: {
  host: any | null
  onClose: () => void
  allTags: { tag: string; count: number }[]
  onSaved: () => void
}) {
  const [tab, setTab] = useState<'fiche' | 'technique'>('fiche')
  const [form, setForm] = useState({
    name: '', address: '', port: '' as string | number, credential_id: '' as string | number,
    category: '', location: '', notes: '', tags: [] as string[],
  })
  const [tech, setTech] = useState<Record<string, any>>({})
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  const { data: credentials = [] } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
    enabled: !!host,
  })
  const expected = host?.kind ? EXPECTED_KINDS[host.kind] : undefined

  useEffect(() => {
    if (host) {
      setForm({
        name: host.name ?? '',
        address: host.address ?? '',
        port: host.port ?? '',
        credential_id: host.credential_id ?? '',
        category: host.category ?? '',
        location: host.location ?? '',
        notes: host.notes ?? '',
        tags: host.tags ?? [],
      })
      // Seules les corrections manuelles pré-remplissent : le reste s'affiche en filigrane.
      setTech({ ...(host.overrides ?? {}) })
      setTab('fiche')
    }
  }, [host])

  const identity = host?.identity ?? {}
  const detected = identity._detected ?? {}
  const overridden: string[] = identity._overridden ?? []

  const save = async () => {
    if (!host) return
    setBusy(true)
    try {
      await patch(`/inventory/${host.id}`, {
        name: form.name,
        address: form.address.trim(),
        port: form.port === '' ? null : Number(form.port),
        credential_id: form.credential_id === '' ? null : Number(form.credential_id),
        category: form.category || null,
        location: form.location || null,
        notes: form.notes || null,
        tags: form.tags,
      })
      // Un champ vidé remet la valeur détectée aux commandes.
      const payload: Record<string, any> = {}
      for (const field of TECH_FIELDS) {
        const value = tech[field.key]
        payload[field.key] = value === '' || value === undefined ? null : value
      }
      await patch(`/inventory/${host.id}/identity`, payload)
      toast('Fiche mise à jour', 'ok')
      onSaved()
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const resetField = (key: string) => setTech({ ...tech, [key]: '' })

  return (
    <Modal
      open={!!host}
      onClose={onClose}
      title={`Fiche · ${host?.name ?? ''}`}
      width="max-w-3xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" onClick={save} disabled={busy}>
            {busy ? <Spinner /> : 'Enregistrer'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <Tabs<'fiche' | 'technique'>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'fiche', label: 'Classement' },
            {
              id: 'technique',
              label: 'Fiche technique',
              badge: overridden.length ? <Badge tone="info">{overridden.length}</Badge> : undefined,
            },
          ]}
        />

        {tab === 'fiche' && (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            <div className="space-y-3.5">
              <div className="space-y-1.5">
                <label>Nom</label>
                <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} className="w-full" />
              </div>
              <div className="grid grid-cols-3 gap-2">
                <div className="space-y-1.5 col-span-2">
                  <label>Adresse IP ou nom DNS</label>
                  <input
                    value={form.address}
                    onChange={(e) => setForm({ ...form, address: e.target.value })}
                    placeholder="192.168.1.20 ou serveur.lan"
                    className="w-full font-mono"
                  />
                </div>
                <div className="space-y-1.5">
                  <label>Port</label>
                  <input
                    type="number"
                    value={form.port}
                    onChange={(e) => setForm({ ...form, port: e.target.value })}
                    className="w-full"
                  />
                </div>
              </div>
              <p className="text-[11px] text-ink-500 -mt-2">
                Changer l'adresse referme la session SSH en cache : la collecte repart sur la nouvelle
                cible au cycle suivant.
              </p>
              <div className="space-y-1.5">
                <label>Identifiants</label>
                <select
                  value={form.credential_id}
                  onChange={(e) => setForm({ ...form, credential_id: e.target.value })}
                  className="w-full"
                >
                  <option value="">— aucun —</option>
                  {credentials.map((cred: any) => {
                    const fits = !expected || expected.has(cred.kind)
                    return (
                      <option key={cred.id} value={cred.id}>
                        {cred.name} ({CRED_LABELS[cred.kind] ?? cred.kind}
                        {cred.username ? ` · ${cred.username}` : ''})
                        {fits ? '' : '  — type inadapté'}
                      </option>
                    )
                  })}
                </select>
                <p className="text-[11px] text-ink-500">
                  {host?.kind && EXPECTED_HINT[host.kind]
                    ? `Un hôte « ${KIND_LABEL[host.kind] ?? host.kind} » attend ${EXPECTED_HINT[host.kind]}.`
                    : ''}{' '}
                  <Link to="/settings" className="text-accent hover:underline">
                    Gérer les identifiants
                  </Link>
                </p>
              </div>
              <div className="space-y-1.5">
                <label>Catégorie</label>
                <input
                  value={form.category}
                  onChange={(e) => setForm({ ...form, category: e.target.value })}
                  placeholder="Serveurs, Stockage, Réseau…"
                  className="w-full"
                />
              </div>
              <div className="space-y-1.5">
                <label>Emplacement</label>
                <input
                  value={form.location}
                  onChange={(e) => setForm({ ...form, location: e.target.value })}
                  placeholder="Baie A, garage, bureau…"
                  className="w-full"
                />
              </div>
              <div className="space-y-1.5">
                <label>Étiquettes</label>
                <TagEditor value={form.tags} onChange={(tags) => setForm({ ...form, tags })} suggestions={allTags} />
              </div>
              <div className="space-y-1.5">
                <label>Notes</label>
                <textarea
                  value={form.notes}
                  onChange={(e) => setForm({ ...form, notes: e.target.value })}
                  rows={3}
                  placeholder="Contrat de support, particularités, câblage…"
                  className="w-full text-sm"
                />
              </div>
            </div>

            <div className="space-y-2">
              <SectionTitle>Relevé automatique</SectionTitle>
              <dl className="divide-y divide-ink-800/70 text-[13px]">
                {(
                  [
                    ['Constructeur', identity.vendor],
                    ['Modèle', identity.model],
                    ['Numéro de série', identity.serial],
                    ['Système', identity.version],
                    ['Noyau', identity.kernel],
                    ['Processeur', identity.cpu_model],
                    ['Cœurs', identity.cpu_count],
                    ['Mémoire', identity.mem_total ? bytes(identity.mem_total) : null],
                    ['Stockage', identity.disk_total ? bytes(identity.disk_total) : null],
                  ] as [string, any][]
                )
                  .filter(([, value]) => value)
                  .map(([label, value]) => (
                    <div key={label} className="flex items-baseline justify-between gap-3 py-1.5">
                      <dt className="text-xs text-ink-500 shrink-0">{label}</dt>
                      <dd className="text-mist-200 text-right truncate">{String(value)}</dd>
                    </div>
                  ))}
              </dl>

              {(identity.disks ?? []).length > 0 && (
                <div className="pt-1">
                  <div className="metric-label mb-1">Disques</div>
                  {identity.disks.map((disk: any) => (
                    <div key={disk.name} className="flex justify-between text-[11px] text-mist-400 font-mono py-0.5">
                      <span>
                        {disk.name} {disk.ssd ? '(SSD)' : ''}
                      </span>
                      <span>{bytes(disk.size)}</span>
                    </div>
                  ))}
                </div>
              )}

              {Object.keys(identity.macs ?? {}).length > 0 && (
                <div className="pt-1">
                  <div className="metric-label mb-1">Interfaces</div>
                  {Object.entries(identity.macs).map(([iface, mac]) => (
                    <div key={iface} className="flex justify-between text-[11px] text-mist-400 font-mono py-0.5">
                      <span>{iface}</span>
                      <span>{String(mac)}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}

        {tab === 'technique' && (
          <div className="space-y-3">
            <p className="text-[12px] text-ink-500 bg-ink-800/40 rounded-lg px-3 py-2">
              Ces champs complètent ou corrigent le relevé automatique. Laisse une case vide pour reprendre
              la valeur détectée — elle est rappelée sous chaque champ.
            </p>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3">
              {TECH_FIELDS.map((field) => {
                const auto = detected[field.key]
                const isOverridden = overridden.includes(field.key)
                return (
                  <div key={field.key} className="space-y-1">
                    <div className="flex items-center justify-between">
                      <label className={clsx(isOverridden && 'text-accent')}>{field.label}</label>
                      {isOverridden && (
                        <button
                          onClick={() => resetField(field.key)}
                          className="text-[10px] text-ink-500 hover:text-danger"
                          title="Revenir à la valeur détectée"
                        >
                          réinitialiser
                        </button>
                      )}
                    </div>
                    <input
                      type={field.type === 'number' ? 'number' : field.type === 'date' ? 'date' : 'text'}
                      value={tech[field.key] ?? ''}
                      onChange={(e) =>
                        setTech({
                          ...tech,
                          [field.key]:
                            field.type === 'number'
                              ? e.target.value === ''
                                ? ''
                                : Number(e.target.value)
                              : e.target.value,
                        })
                      }
                      placeholder={auto != null ? String(auto) : field.hint ?? '—'}
                      className="w-full"
                    />
                    {auto != null && (
                      <p className="text-[10px] text-ink-600 truncate">
                        détecté : {field.key.includes('mem') || field.key.includes('disk')
                          ? bytes(Number(auto))
                          : String(auto)}
                      </p>
                    )}
                  </div>
                )
              })}
            </div>
          </div>
        )}
      </div>
    </Modal>
  )
}

function BulkModal({
  open,
  onClose,
  count,
  hostIds,
  categories,
  allTags,
  onSaved,
}: {
  open: boolean
  onClose: () => void
  count: number
  hostIds: number[]
  categories: { category: string; count: number }[]
  allTags: { tag: string; count: number }[]
  onSaved: () => void
}) {
  const [category, setCategory] = useState('')
  const [location, setLocation] = useState('')
  const [addTags, setAddTags] = useState<string[]>([])
  const [removeTags, setRemoveTags] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const toast = useToast()

  const apply = async () => {
    setBusy(true)
    try {
      await post('/inventory/bulk', {
        host_ids: hostIds,
        ...(category ? { category } : {}),
        ...(location ? { location } : {}),
        add_tags: addTags,
        remove_tags: removeTags,
      })
      toast(`${count} équipement(s) mis à jour`, 'ok')
      setCategory('')
      setLocation('')
      setAddTags([])
      setRemoveTags([])
      onSaved()
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const nothing = !category && !location && addTags.length === 0 && removeTags.length === 0

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Classer ${count} équipement(s)`}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" onClick={apply} disabled={busy || nothing}>
            {busy ? <Spinner /> : 'Appliquer'}
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="space-y-1.5">
          <label>Catégorie</label>
          <input
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            placeholder="Laisser vide pour ne pas modifier"
            list="mba-categories"
            className="w-full"
          />
          <datalist id="mba-categories">
            {categories.map((c) => (
              <option key={c.category} value={c.category} />
            ))}
          </datalist>
        </div>
        <div className="space-y-1.5">
          <label>Emplacement</label>
          <input
            value={location}
            onChange={(e) => setLocation(e.target.value)}
            placeholder="Laisser vide pour ne pas modifier"
            className="w-full"
          />
        </div>
        <div className="space-y-1.5">
          <label>Étiquettes à ajouter</label>
          <TagEditor value={addTags} onChange={setAddTags} suggestions={allTags} />
        </div>
        <div className="space-y-1.5">
          <label>Étiquettes à retirer</label>
          <TagEditor value={removeTags} onChange={setRemoveTags} suggestions={allTags} />
        </div>
      </div>
    </Modal>
  )
}
