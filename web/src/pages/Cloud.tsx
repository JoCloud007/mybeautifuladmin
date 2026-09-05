import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import {
  Cloud as CloudIcon,
  Coins,
  Database,
  HardDrive,
  Link2,
  Package,
  Plus,
  RefreshCw,
  Server,
  ShieldCheck,
  Trash2,
  TrendingUp,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Chart } from '@/components/Chart'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import {
  Badge,
  Bar,
  Empty,
  Modal,
  Spinner,
  StatTile,
  StatusDot,
  Tabs,
  useConfirm,
  useToast,
} from '@/components/ui'
import { del, get, patch, post } from '@/lib/api'
import { ago, bytes, datetime, num, percent } from '@/lib/format'

type Tab = 'storage' | 'resources' | 'accounts'

const BUCKET_KINDS = ['bucket', 'container']

const KIND_LABEL: Record<string, string> = {
  bucket: 'Bucket S3',
  container: 'Conteneur Swift',
  instance: 'Instance',
  volume: 'Volume',
}

const ENDPOINTS: Record<string, string> = {
  'ovh-eu': 'OVHcloud Europe',
  'ovh-ca': 'OVHcloud Canada',
  'ovh-us': 'OVHcloud US',
}

/** Montant dans la devise du fournisseur, sans décimales parasites. */
function money(value?: unknown, currency = 'EUR'): string {
  const n = typeof value === 'string' ? Number(value) : (value as number)
  if (typeof n !== 'number' || !Number.isFinite(n)) return '—'
  return n.toLocaleString('fr-FR', { style: 'currency', currency, maximumFractionDigits: 2 })
}

/** Croissance signée, en octets par jour. */
function growth(perDay?: number | null): string {
  if (perDay == null) return '—'
  const sign = perDay >= 0 ? '+' : '−'
  return `${sign}${bytes(Math.abs(perDay))}/j`
}

export function CloudPage() {
  const [tab, setTab] = useState<Tab>('storage')
  const [accountModal, setAccountModal] = useState<any | null | undefined>(undefined)
  const [selected, setSelected] = useState<any | null>(null)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['cloud'],
    queryFn: () => get('/cloud'),
    refetchInterval: 60000,
  })

  const summary = data?.summary ?? {}
  const accounts: any[] = data?.accounts ?? []
  const resources: any[] = data?.resources ?? []
  const currency = summary.currency ?? 'EUR'

  const buckets = useMemo(
    () => resources.filter((r) => BUCKET_KINDS.includes(r.kind)),
    [resources],
  )
  const others = useMemo(
    () => resources.filter((r) => !BUCKET_KINDS.includes(r.kind)),
    [resources],
  )

  const syncAll = useMutation({
    mutationFn: async () => {
      const results = await Promise.allSettled(
        accounts.filter((a) => a.enabled && a.project_id).map((a) => post(`/cloud/accounts/${a.id}/sync`)),
      )
      const failed = results.filter((r) => r.status === 'rejected')
      if (failed.length) throw new Error((failed[0] as PromiseRejectedResult).reason?.message ?? 'Échec')
      return results.length
    },
    onSuccess: (count) => {
      toast(`${count} compte(s) synchronisé(s)`, 'ok')
      queryClient.invalidateQueries({ queryKey: ['cloud'] })
    },
    onError: (exc: any) => toast(exc.message, 'danger'),
  })

  if (isLoading) {
    return (
      <Page>
        <div className="flex items-center gap-2 text-ink-500 text-sm">
          <Spinner /> Chargement…
        </div>
      </Page>
    )
  }

  if (accounts.length === 0) {
    return (
      <Page>
        <PageHeader title="Cloud public" subtitle="Stockage objet, instances et coûts chez ton fournisseur" />
        <div className="panel">
          <Empty
            icon={<CloudIcon size={38} />}
            title="Aucun compte cloud enregistré"
            hint="Enregistre un projet Public Cloud : MBA relève la volumétrie de tes buckets, leur nombre d'objets et la consommation valorisée du mois — par l'API du fournisseur, sans jamais lister les objets d'un bucket (ce qui serait facturé)."
            action={
              <button className="btn-primary" onClick={() => setAccountModal(null)}>
                <Plus size={15} />
                Ajouter un compte
              </button>
            }
          />
        </div>
        <AccountModal
          open={accountModal !== undefined}
          account={accountModal}
          onClose={() => setAccountModal(undefined)}
        />
      </Page>
    )
  }

  return (
    <Page>
      <PageHeader
        title="Cloud public"
        subtitle="Stockage objet, ressources et consommation valorisée"
        actions={
          <>
            <button
              className="btn-ghost"
              onClick={() => syncAll.mutate()}
              disabled={syncAll.isPending}
              title="Interroger l'API du fournisseur maintenant"
            >
              {syncAll.isPending ? <Spinner size={15} /> : <RefreshCw size={15} />}
              Synchroniser
            </button>
            <button className="btn-primary" onClick={() => setAccountModal(null)}>
              <Plus size={15} />
              Compte
            </button>
          </>
        }
      />

      <div className="grid grid-cols-2 lg:grid-cols-5 gap-3 mb-4">
        <StatTile
          label="Stockage objet"
          value={bytes(summary.stored_bytes)}
          sub={`${summary.buckets ?? 0} bucket(s)`}
          icon={<Database size={20} />}
          tone="info"
        />
        <StatTile
          label="Objets"
          value={num(summary.objects)}
          sub="tous buckets confondus"
          icon={<Package size={20} />}
        />
        <StatTile
          label="Mois en cours"
          value={money(summary.cost_current, currency)}
          sub="consommation valorisée"
          icon={<Coins size={20} />}
        />
        <StatTile
          label="Prévision"
          value={money(summary.cost_forecast, currency)}
          sub="fin de mois"
          icon={<TrendingUp size={20} />}
          tone={
            summary.cost_forecast && summary.cost_current && summary.cost_forecast > summary.cost_current * 2
              ? 'warn'
              : 'neutral'
          }
        />
        <StatTile
          label="Adossés à PBS"
          value={`${summary.linked_pbs ?? 0}/${summary.buckets ?? 0}`}
          sub="buckets de sauvegarde"
          icon={<ShieldCheck size={20} />}
          tone={summary.linked_pbs ? 'ok' : 'neutral'}
        />
      </div>

      <Tabs
        tabs={[
          { id: 'storage', label: 'Stockage objet', badge: <Badge>{buckets.length}</Badge> },
          { id: 'resources', label: 'Autres ressources', badge: <Badge>{others.length}</Badge> },
          { id: 'accounts', label: 'Comptes', badge: <Badge>{accounts.length}</Badge> },
        ]}
        active={tab}
        onChange={setTab}
      />

      <div className="mt-4">
        {tab === 'storage' && (
          <StorageView buckets={buckets} currency={currency} onSelect={setSelected} />
        )}
        {tab === 'resources' && <ResourcesView resources={others} />}
        {tab === 'accounts' && (
          <AccountsView accounts={accounts} onEdit={(account) => setAccountModal(account)} />
        )}
      </div>

      <AccountModal
        open={accountModal !== undefined}
        account={accountModal}
        onClose={() => setAccountModal(undefined)}
      />
      <BucketModal resource={selected} currency={currency} onClose={() => setSelected(null)} />
    </Page>
  )
}

// ------------------------------------------------------------ stockage objet
function StorageView({
  buckets,
  currency,
  onSelect,
}: {
  buckets: any[]
  currency: string
  onSelect: (resource: any) => void
}) {
  const queryClient = useQueryClient()
  const toast = useToast()

  const relink = useMutation({
    mutationFn: () => post('/cloud/link-pbs'),
    onSuccess: (result: any) => {
      const found = Object.keys(result.buckets ?? {}).length
      toast(
        found
          ? `${result.linked} lien(s) mis à jour, ${found} bucket(s) déclaré(s) dans les PBS`
          : "Aucun bucket S3 déclaré dans les PBS supervisés — associe le datastore à la main depuis la fiche du bucket.",
        found ? 'ok' : 'info',
      )
      queryClient.invalidateQueries({ queryKey: ['cloud'] })
    },
    onError: (exc: any) => toast(exc.message, 'danger'),
  })

  if (buckets.length === 0) {
    return (
      <div className="panel">
        <Empty
          icon={<Database size={34} />}
          title="Aucun stockage objet relevé"
          hint="Le projet n'expose pas de bucket, ou la clé d'API ne couvre pas /cloud/project/*/region/*/storage."
        />
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <SectionTitle
        right={
          <button
            className="btn-ghost py-1 px-2 text-xs"
            onClick={() => relink.mutate()}
            disabled={relink.isPending}
          >
            {relink.isPending ? <Spinner size={13} /> : <Link2 size={13} />}
            Redétecter les datastores PBS
          </button>
        }
      >
        Buckets et conteneurs
      </SectionTitle>

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-3">
        {buckets.map((bucket) => {
          const quotaPercent = bucket.quota_bytes
            ? (100 * (bucket.size_bytes ?? 0)) / bucket.quota_bytes
            : null
          return (
            <button
              key={bucket.id}
              onClick={() => onSelect(bucket)}
              className="panel panel-hover p-4 text-left w-full"
            >
              <div className="flex items-start justify-between gap-3 mb-3">
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <StatusDot status={bucket.status === 'disparu' ? 'offline' : 'online'} />
                    <span className="font-semibold text-mist-100 truncate">{bucket.name}</span>
                  </div>
                  <div className="text-[11px] text-ink-500 mt-1 flex items-center gap-1.5 flex-wrap">
                    <span>{bucket.account_name}</span>
                    {bucket.region && (
                      <>
                        <span className="text-ink-700">·</span>
                        <span className="font-mono uppercase">{bucket.region}</span>
                      </>
                    )}
                    <span className="text-ink-700">·</span>
                    <span>{KIND_LABEL[bucket.kind] ?? bucket.kind}</span>
                  </div>
                </div>
                {bucket.link_ref ? (
                  <Badge tone="ok" className="shrink-0">
                    <ShieldCheck size={11} />
                    {bucket.link_ref}
                  </Badge>
                ) : (
                  <Badge className="shrink-0">non rattaché</Badge>
                )}
              </div>

              <div className="grid grid-cols-3 gap-3 mb-3">
                <div>
                  <div className="metric-label">Volume</div>
                  <div className="metric-value text-lg">{bytes(bucket.size_bytes)}</div>
                </div>
                <div>
                  <div className="metric-label">Objets</div>
                  <div className="metric-value text-lg">{num(bucket.objects)}</div>
                </div>
                <div>
                  <div className="metric-label">Ce mois</div>
                  <div className="metric-value text-lg">{money(bucket.price_month, currency)}</div>
                </div>
              </div>

              {quotaPercent !== null && (
                <div className="mb-2">
                  <div className="flex items-center justify-between text-[11px] mb-1">
                    <span className="text-ink-500">Seuil {bytes(bucket.quota_bytes)}</span>
                    <span className="metric-value">{percent(quotaPercent, 0)}</span>
                  </div>
                  <Bar value={quotaPercent} />
                </div>
              )}

              <div className="flex items-center justify-between text-[11px] text-ink-500">
                <span className="flex items-center gap-1.5">
                  <TrendingUp size={12} />
                  {growth(bucket.trend?.per_day)}
                </span>
                {bucket.days_to_quota != null ? (
                  <span className={clsx(bucket.days_to_quota < 30 && 'text-warn')}>
                    seuil atteint dans {num(bucket.days_to_quota, 1)} j
                  </span>
                ) : (
                  <span>relevé {ago(bucket.last_seen)}</span>
                )}
              </div>
            </button>
          )
        })}
      </div>
    </div>
  )
}

// -------------------------------------------------------- autres ressources
function ResourcesView({ resources }: { resources: any[] }) {
  if (resources.length === 0) {
    return (
      <div className="panel">
        <Empty
          icon={<Server size={34} />}
          title="Aucune autre ressource"
          hint="Instances et volumes du projet apparaîtront ici dès qu'il y en aura."
        />
      </div>
    )
  }
  return (
    <div className="panel table-scroll">
      <table className="w-full text-sm min-w-[760px]">
        <thead>
          <tr className="text-left border-b border-ink-750">
            {['Nom', 'Type', 'Région', 'État', 'Taille', 'Détail', 'Vu'].map((header) => (
              <th key={header} className="metric-label px-3 py-2 font-semibold">
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {resources.map((resource) => {
            const meta = resource.meta ?? {}
            const detail =
              resource.kind === 'instance'
                ? [meta.flavor, meta.vcpus && `${meta.vcpus} vCPU`, meta.ram_mb && `${Math.round(meta.ram_mb / 1024)} Go`]
                    .filter(Boolean)
                    .join(' · ')
                : [meta.type, (meta.attached_to ?? []).length ? 'attaché' : 'libre'].filter(Boolean).join(' · ')
            return (
              <tr key={resource.id} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
                <td className="px-3 py-2.5 text-mist-100">{resource.name}</td>
                <td className="px-3 py-2.5">
                  <Badge tone={resource.kind === 'instance' ? 'violet' : 'info'}>
                    {KIND_LABEL[resource.kind] ?? resource.kind}
                  </Badge>
                </td>
                <td className="px-3 py-2.5 text-xs font-mono uppercase text-mist-400">
                  {resource.region ?? '—'}
                </td>
                <td className="px-3 py-2.5">
                  <span className="flex items-center gap-1.5 text-xs text-mist-300">
                    <StatusDot status={resource.status === 'active' ? 'online' : resource.status} />
                    {resource.status ?? '—'}
                  </span>
                </td>
                <td className="px-3 py-2.5 metric-value text-xs">{bytes(resource.size_bytes)}</td>
                <td className="px-3 py-2.5 text-xs text-mist-400">{detail || '—'}</td>
                <td className="px-3 py-2.5 text-xs text-ink-500">{ago(resource.last_seen)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

// ------------------------------------------------------------------ comptes
function AccountsView({ accounts, onEdit }: { accounts: any[]; onEdit: (account: any) => void }) {
  const queryClient = useQueryClient()
  const toast = useToast()
  const confirm = useConfirm()

  const sync = useMutation({
    mutationFn: (id: number) => post(`/cloud/accounts/${id}/sync`),
    onSuccess: (result: any) => {
      toast(
        `${result.resources} ressource(s) relevée(s)` +
          (result.linked_pbs ? `, ${result.linked_pbs} datastore(s) PBS rattaché(s)` : ''),
        'ok',
      )
      queryClient.invalidateQueries({ queryKey: ['cloud'] })
    },
    onError: (exc: any) => toast(exc.message, 'danger'),
  })

  const remove = async (account: any) => {
    const ok = await confirm({
      title: 'Supprimer ce compte ?',
      message: `Les ressources de « ${account.name} » et leur historique de volumétrie seront effacés de MBA. Rien n'est touché chez le fournisseur.`,
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await del(`/cloud/accounts/${account.id}`)
    toast('Compte supprimé', 'ok')
    queryClient.invalidateQueries({ queryKey: ['cloud'] })
  }

  return (
    <div className="space-y-3">
      {accounts.map((account) => (
        <div key={account.id} className="panel p-4">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="flex items-center gap-2">
                <StatusDot status={account.status === 'online' ? 'online' : account.status === 'offline' ? 'offline' : 'unknown'} />
                <span className="font-semibold text-mist-100">{account.name}</span>
                <Badge tone="info">{ENDPOINTS[account.endpoint] ?? account.endpoint}</Badge>
                {!account.enabled && <Badge tone="warn">en pause</Badge>}
              </div>
              <div className="text-[11px] text-ink-500 mt-1 font-mono">{account.project_id ?? '—'}</div>
              <div className="text-[11px] text-ink-500 mt-0.5">
                Identifiants : {account.credential_name ?? '—'} · relevé toutes les{' '}
                {account.sync_minutes} min · dernier {ago(account.last_sync)}
              </div>
            </div>
            <div className="flex items-center gap-1.5">
              <button
                className="btn-ghost py-1 px-2 text-xs"
                onClick={() => sync.mutate(account.id)}
                disabled={sync.isPending}
              >
                {sync.isPending ? <Spinner size={13} /> : <RefreshCw size={13} />}
                Synchroniser
              </button>
              <button className="btn-ghost py-1 px-2 text-xs" onClick={() => onEdit(account)}>
                Modifier
              </button>
              <button className="btn-icon hover:text-danger" onClick={() => remove(account)} title="Supprimer">
                <Trash2 size={14} />
              </button>
            </div>
          </div>

          {account.last_error && (
            <p className="mt-3 text-xs text-danger bg-danger/10 border border-danger/25 rounded-lg px-3 py-2 whitespace-pre-wrap">
              {account.last_error}
            </p>
          )}
        </div>
      ))}
    </div>
  )
}

function AccountModal({
  open,
  account,
  onClose,
}: {
  open: boolean
  account?: any | null
  onClose: () => void
}) {
  const editMode = !!account
  const [form, setForm] = useState({
    name: '',
    endpoint: 'ovh-eu',
    project_id: '',
    credential_id: 0,
    sync_minutes: 30,
    enabled: true,
  })
  const [projects, setProjects] = useState<any[] | null>(null)
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data: credentials } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
    enabled: open,
  })
  const ovhCredentials = (credentials ?? []).filter((c: any) => c.kind === 'ovh_api')

  useEffect(() => {
    if (!open) return
    setProjects(null)
    setForm(
      account
        ? {
            name: account.name ?? '',
            endpoint: account.endpoint ?? 'ovh-eu',
            project_id: account.project_id ?? '',
            credential_id: account.credential_id ?? 0,
            sync_minutes: account.sync_minutes ?? 30,
            enabled: account.enabled ?? true,
          }
        : { name: '', endpoint: 'ovh-eu', project_id: '', credential_id: 0, sync_minutes: 30, enabled: true },
    )
  }, [open, account])

  const probe = async () => {
    setBusy(true)
    try {
      const result = await post('/cloud/probe', {
        credential_id: form.credential_id,
        endpoint: form.endpoint,
      })
      setProjects(result.projects)
      if (result.projects.length === 0) {
        toast("Clés valides, mais aucun projet Public Cloud n'y est accessible.", 'warn')
      } else {
        toast(
          `Compte ${result.identity.nichandle ?? ''} — ${result.projects.length} projet(s) accessible(s)`,
          'ok',
        )
        if (!form.project_id) {
          setForm((current) => ({
            ...current,
            project_id: result.projects[0].id,
            name: current.name || result.projects[0].name,
          }))
        }
      }
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      const payload = { ...form, credential_id: form.credential_id || null }
      if (editMode) await patch(`/cloud/accounts/${account.id}`, payload)
      else await post('/cloud/accounts', payload)
      toast(editMode ? 'Compte mis à jour' : 'Compte enregistré', 'ok')
      queryClient.invalidateQueries({ queryKey: ['cloud'] })
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={editMode ? `Modifier « ${account?.name} »` : 'Nouveau compte cloud'}
      width="max-w-xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button
            className="btn-primary"
            form="cloud-account-form"
            type="submit"
            disabled={busy || !form.name || !form.project_id}
          >
            {busy ? <Spinner /> : <Plus size={15} />}
            {editMode ? 'Enregistrer' : 'Créer'}
          </button>
        </>
      }
    >
      <form id="cloud-account-form" onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Identifiants</label>
            <select
              value={form.credential_id}
              onChange={(e) => setForm({ ...form, credential_id: Number(e.target.value) })}
              className="w-full"
            >
              <option value={0}>— choisir —</option>
              {ovhCredentials.map((cred: any) => (
                <option key={cred.id} value={cred.id}>
                  {cred.name}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <label>Endpoint</label>
            <select
              value={form.endpoint}
              onChange={(e) => setForm({ ...form, endpoint: e.target.value })}
              className="w-full"
            >
              {Object.entries(ENDPOINTS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </div>
        </div>

        {ovhCredentials.length === 0 && (
          <p className="text-[11px] text-warn">
            Aucun identifiant de type « API OVHcloud ». Crée-le d'abord dans{' '}
            <Link to="/settings" className="underline">
              Réglages → Identifiants
            </Link>{' '}
            : clé d'application, clé secrète et clé de consommateur, obtenues en une fois sur
            api.ovh.com/createToken/.
          </p>
        )}

        <div className="flex items-end gap-2">
          <div className="flex-1 space-y-1.5">
            <label>Projet Public Cloud</label>
            {projects && projects.length > 0 ? (
              <select
                value={form.project_id}
                onChange={(e) => setForm({ ...form, project_id: e.target.value })}
                className="w-full"
              >
                {projects.map((project: any) => (
                  <option key={project.id} value={project.id}>
                    {project.name} ({project.id})
                  </option>
                ))}
              </select>
            ) : (
              <input
                value={form.project_id}
                onChange={(e) => setForm({ ...form, project_id: e.target.value })}
                placeholder="identifiant du projet (32 caractères)"
                className="w-full font-mono"
              />
            )}
          </div>
          <button
            type="button"
            className="btn-ghost"
            onClick={probe}
            disabled={busy || !form.credential_id}
            title="Vérifier les clés et lister les projets"
          >
            {busy ? <Spinner size={15} /> : <RefreshCw size={15} />}
            Tester
          </button>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="Sauvegardes OVH"
              required
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Relève (minutes)</label>
            <input
              type="number"
              min={5}
              max={1440}
              value={form.sync_minutes}
              onChange={(e) => setForm({ ...form, sync_minutes: Number(e.target.value) })}
              className="w-full"
            />
          </div>
        </div>

        <label className="flex items-center gap-2 text-sm text-mist-300 normal-case tracking-normal font-normal">
          <input
            type="checkbox"
            checked={form.enabled}
            onChange={(e) => setForm({ ...form, enabled: e.target.checked })}
          />
          Relever ce compte automatiquement
        </label>

        <p className="text-[11px] text-ink-500">
          La volumétrie vient de l'API OVHcloud, pas de l'API S3 : aucune requête <code>ListObjects</code>{' '}
          n'est émise sur tes buckets, donc aucune opération facturée.
        </p>
      </form>
    </Modal>
  )
}

// ------------------------------------------------------------- fiche bucket
const RANGES: { id: number; label: string }[] = [
  { id: 7, label: '7 j' },
  { id: 30, label: '30 j' },
  { id: 90, label: '90 j' },
  { id: 365, label: '1 an' },
]

function BucketModal({
  resource,
  currency,
  onClose,
}: {
  resource: any | null
  currency: string
  onClose: () => void
}) {
  const [days, setDays] = useState(30)
  const [quota, setQuota] = useState('')
  const [notes, setNotes] = useState('')
  const [link, setLink] = useState('')
  const [hostId, setHostId] = useState(0)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data } = useQuery({
    queryKey: ['cloud-resource', resource?.id, days],
    queryFn: () => get(`/cloud/resources/${resource.id}?days=${days}`),
    enabled: !!resource,
  })
  const { data: hosts } = useQuery({
    queryKey: ['hosts'],
    queryFn: () => get('/hosts'),
    enabled: !!resource,
  })
  const pbsHosts = (hosts ?? []).filter((h: any) => h.kind === 'pbs')

  useEffect(() => {
    if (!resource) return
    // En Tio : personne ne raisonne en octets pour un seuil de stockage objet.
    setQuota(resource.quota_bytes ? String(resource.quota_bytes / 1024 ** 4) : '')
    setNotes(resource.notes ?? '')
    setLink(resource.link_ref ?? '')
    setHostId(resource.host_id ?? 0)
  }, [resource])

  const chart = useMemo(() => {
    const points: any[] = data?.history ?? []
    const times = Array.from(new Set(points.map((p) => p.t))).sort((a, b) => a - b)
    const index = new Map(times.map((t, i) => [t, i]))
    const stored = new Array(times.length).fill(null)
    const objects = new Array(times.length).fill(null)
    for (const point of points) {
      const i = index.get(point.t)!
      if (point.metric === 'storage.bytes') stored[i] = point.value
      if (point.metric === 'storage.objects') objects[i] = point.value
    }
    return { times, stored, objects, empty: times.length < 2 }
  }, [data])

  const save = useMutation({
    mutationFn: () =>
      patch(`/cloud/resources/${resource.id}`, {
        quota_bytes: quota ? Number(quota) * 1024 ** 4 : null,
        notes: notes || null,
        link_ref: link || null,
        host_id: hostId || null,
      }),
    onSuccess: () => {
      toast('Fiche enregistrée', 'ok')
      queryClient.invalidateQueries({ queryKey: ['cloud'] })
      onClose()
    },
    onError: (exc: any) => toast(exc.message, 'danger'),
  })

  if (!resource) return null
  const trend7 = data?.trend_7d ?? {}
  const trend30 = data?.trend_30d ?? {}

  return (
    <Modal
      open={!!resource}
      onClose={onClose}
      title={
        <span className="flex items-center gap-2">
          <HardDrive size={16} className="text-ink-500" />
          {resource.name}
        </span>
      }
      width="max-w-3xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Fermer
          </button>
          <button className="btn-primary" onClick={() => save.mutate()} disabled={save.isPending}>
            {save.isPending ? <Spinner /> : null}
            Enregistrer
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div>
            <div className="metric-label">Volume</div>
            <div className="metric-value text-lg">{bytes(resource.size_bytes)}</div>
          </div>
          <div>
            <div className="metric-label">Objets</div>
            <div className="metric-value text-lg">{num(resource.objects)}</div>
          </div>
          <div>
            <div className="metric-label">Croissance 7 j</div>
            <div className="metric-value text-lg">{growth(trend7.per_day)}</div>
          </div>
          <div>
            <div className="metric-label">Croissance 30 j</div>
            <div className="metric-value text-lg">{growth(trend30.per_day)}</div>
          </div>
        </div>

        <div className="panel p-3">
          <div className="flex items-center justify-between mb-2">
            <h3 className="text-sm font-semibold text-mist-200">Volumétrie</h3>
            <div className="flex items-center gap-1 bg-ink-850 border border-ink-750 rounded-lg p-0.5">
              {RANGES.map((range) => (
                <button
                  key={range.id}
                  onClick={() => setDays(range.id)}
                  className={clsx(
                    'px-2.5 py-1 rounded-md text-xs font-medium transition-colors',
                    days === range.id ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
                  )}
                >
                  {range.label}
                </button>
              ))}
            </div>
          </div>
          {chart.empty ? (
            <p className="text-xs text-ink-600 py-10 text-center">
              Pas encore assez de relevés sur cette période — la courbe se remplit à chaque
              synchronisation.
            </p>
          ) : (
            // Deux graphiques plutôt qu'un : des téraoctets et un nombre d'objets
            // sur la même échelle écraseraient la seconde courbe contre l'axe.
            <>
              <Chart
                height={170}
                data={[chart.times, chart.stored] as any}
                specs={[{ label: 'Volume', color: '#00d4aa', fill: true }]}
                format={(value) => bytes(value)}
              />
              <Chart
                height={120}
                data={[chart.times, chart.objects] as any}
                specs={[{ label: 'Objets', color: '#7c8cff' }]}
                format={(value) => num(value)}
              />
            </>
          )}
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Seuil de surveillance (Tio)</label>
            <input
              type="number"
              step="0.1"
              min="0"
              value={quota}
              onChange={(e) => setQuota(e.target.value)}
              placeholder="ex. 5"
              className="w-full"
            />
            <p className="text-[11px] text-ink-500">
              Au-delà, un évènement est journalisé et la notification « Seuil de stockage cloud
              dépassé » part si elle est activée.
            </p>
          </div>
          <div className="space-y-1.5">
            <label>Datastore PBS adossé</label>
            <div className="flex gap-2">
              <select
                value={hostId}
                onChange={(e) => setHostId(Number(e.target.value))}
                className="w-[45%]"
              >
                <option value={0}>— aucun —</option>
                {pbsHosts.map((host: any) => (
                  <option key={host.id} value={host.id}>
                    {host.name}
                  </option>
                ))}
              </select>
              <input
                value={link}
                onChange={(e) => setLink(e.target.value)}
                placeholder="nom du datastore"
                className="flex-1 font-mono"
              />
            </div>
            <p className="text-[11px] text-ink-500">
              {resource.meta?.link_source === 'pbs'
                ? 'Détecté dans la configuration du PBS.'
                : 'Renseigné à la main : la détection automatique ne l’écrasera plus.'}
            </p>
          </div>
        </div>

        <div className="space-y-1.5">
          <label>Notes</label>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={2}
            className="w-full"
            placeholder="Rétention, politique de cycle de vie, contact fournisseur…"
          />
        </div>

        <div className="text-[11px] text-ink-500 grid grid-cols-2 gap-x-4 gap-y-1 border-t border-ink-800 pt-3">
          <span>
            Compte : <span className="text-mist-300">{resource.account_name}</span>
          </span>
          <span>
            Région : <span className="text-mist-300 font-mono uppercase">{resource.region ?? '—'}</span>
          </span>
          <span>
            Coût du mois : <span className="text-mist-300">{money(resource.price_month, currency)}</span>
          </span>
          <span>
            Vu pour la première fois :{' '}
            <span className="text-mist-300">{datetime(resource.first_seen)}</span>
          </span>
          {resource.pbs_name && (
            <span className="col-span-2">
              Serveur de sauvegarde :{' '}
              <Link to={`/hosts/${resource.host_id}`} className="text-accent hover:underline">
                {resource.pbs_name}
              </Link>
            </span>
          )}
        </div>
      </div>
    </Modal>
  )
}
