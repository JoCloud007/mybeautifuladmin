import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { Info, KeyRound, Plus, Send, Trash2, UserCog } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Page, PageHeader, SectionTitle } from '@/components/PageHeader'
import { Badge, Empty, Modal, Spinner, Tabs, useConfirm, useToast } from '@/components/ui'
import { api, del, get, patch, post } from '@/lib/api'
import { datetime } from '@/lib/format'

type Tab = 'credentials' | 'notifications' | 'account' | 'about'

export function SettingsPage() {
  const [tab, setTab] = useState<Tab>('credentials')

  return (
    <Page>
      <PageHeader title="Réglages" subtitle="Identifiants, compte et informations système" />
      <div className="mb-4">
        <Tabs<Tab>
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'credentials', label: 'Identifiants' },
            { id: 'notifications', label: 'Notifications' },
            { id: 'account', label: 'Compte' },
            { id: 'about', label: 'À propos' },
          ]}
        />
      </div>
      {tab === 'credentials' && <CredentialsTab />}
      {tab === 'notifications' && <NotificationsTab />}
      {tab === 'account' && <AccountTab />}
      {tab === 'about' && <AboutTab />}
    </Page>
  )
}

// ------------------------------------------------------------- identifiants
function CredentialsTab() {
  const [addOpen, setAddOpen] = useState(false)
  const [editing, setEditing] = useState<any | null>(null)
  const queryClient = useQueryClient()
  const confirm = useConfirm()
  const toast = useToast()

  const { data: credentials = [], isLoading } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
  })

  const remove = async (cred: any) => {
    const ok = await confirm({
      title: 'Supprimer ces identifiants ?',
      message:
        cred.hosts_count > 0 ? (
          <>
            <b className="text-mist-100">{cred.name}</b> est utilisé par {cred.hosts_count} hôte(s). Leur collecte
            s'arrêtera jusqu'à ce que tu leur associes d'autres identifiants.
          </>
        ) : (
          <>
            <b className="text-mist-100">{cred.name}</b> sera supprimé du coffre.
          </>
        ),
      confirmLabel: 'Supprimer',
      danger: true,
    })
    if (!ok) return
    await del(`/credentials/${cred.id}`)
    toast('Identifiants supprimés', 'ok')
    queryClient.invalidateQueries({ queryKey: ['credentials'] })
  }

  return (
    <div className="space-y-4">
      <div className="panel p-3.5 flex items-start gap-2.5 border-info/20 bg-info/[0.03]">
        <Info size={16} className="text-info shrink-0 mt-0.5" />
        <p className="text-[13px] text-mist-300 leading-relaxed">
          Les secrets sont chiffrés (Fernet/AES) avant stockage et ne ressortent jamais de l'API. La clé de
          chiffrement vit dans le volume <code className="text-mist-100 font-mono text-xs">api_keys</code> ou dans la
          variable <code className="text-mist-100 font-mono text-xs">VAULT_KEY</code>.
        </p>
      </div>

      <div className="flex justify-end">
        <button className="btn-primary" onClick={() => setAddOpen(true)}>
          <Plus size={15} />
          Nouveaux identifiants
        </button>
      </div>

      {isLoading && <div className="panel p-10 grid place-items-center"><Spinner size={20} /></div>}

      {!isLoading && credentials.length === 0 && (
        <div className="panel">
          <Empty
            icon={<KeyRound size={34} />}
            title="Aucun identifiant enregistré"
            hint="Ajoute une clé SSH, un mot de passe, ou un jeton d'API Proxmox pour permettre la collecte détaillée et les actions d'administration."
            action={
              <button className="btn-primary" onClick={() => setAddOpen(true)}>
                <Plus size={15} />
                Créer
              </button>
            }
          />
        </div>
      )}

      {credentials.length > 0 && (
        <div className="panel overflow-x-auto">
          <table className="w-full text-sm min-w-[680px]">
            <thead>
              <tr className="text-left border-b border-ink-750">
                {['Nom', 'Type', 'Utilisateur', 'Hôtes', 'Créé', ''].map((header) => (
                  <th key={header} className="metric-label px-3 py-2 font-semibold">
                    {header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {credentials.map((cred: any) => (
                <tr key={cred.id} className="border-b border-ink-800/60 last:border-0 hover:bg-ink-800/40">
                  <td className="px-3 py-2.5 text-mist-100 flex items-center gap-2">
                    <KeyRound size={14} className="text-ink-500" />
                    {cred.name}
                  </td>
                  <td className="px-3 py-2.5">
                    <Badge tone={cred.kind === 'ssh_key' ? 'violet' : cred.kind === 'token' ? 'ok' : 'info'}>
                      {KIND_LABELS[cred.kind] ?? cred.kind}
                    </Badge>
                  </td>
                  <td className="px-3 py-2.5 text-xs font-mono text-mist-400">{cred.username ?? '—'}</td>
                  <td className="px-3 py-2.5 text-xs text-mist-400">{cred.hosts_count}</td>
                  <td className="px-3 py-2.5 text-xs text-ink-500">{datetime(cred.created_at)}</td>
                  <td className="px-3 py-2.5">
                    <div className="flex items-center justify-end gap-1">
                      <button className="btn-ghost py-1 px-2 text-xs" onClick={() => setEditing(cred)}>
                        Modifier
                      </button>
                      <button className="btn-icon hover:text-danger" onClick={() => remove(cred)} title="Supprimer">
                        <Trash2 size={14} />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <CredentialModal open={addOpen} onClose={() => setAddOpen(false)} />
      <CredentialModal open={!!editing} credential={editing} onClose={() => setEditing(null)} />
    </div>
  )
}

const KIND_LABELS: Record<string, string> = {
  ssh_key: 'Clé SSH',
  ssh_password: 'Mot de passe',
  api_token: "Jeton d'API (utilisateur + secret)",
  token: 'Jeton simple',
  basic: 'HTTP Basic',
  ovh_api: 'API OVHcloud (trois clés)',
}

const KIND_HELP: Record<string, string> = {
  ssh_password: 'Mot de passe du compte SSH. Sert aussi aux comptes DSM Synology.',
  ssh_key: 'Clé privée SSH au format OpenSSH — colle le contenu complet du fichier, en-têtes inclus.',
  api_token:
    "Jeton en deux parties. Proxmox : utilisateur « root@pam!mba » et secret = l'UUID. " +
    'PBS : utilisateur « user@pbs!id » et secret. Décoche « Privilege Separation » à la création du jeton.',
  token:
    "Jeton unique, sans utilisateur : Home Assistant (jeton d'accès longue durée), " +
    "Tailscale (tskey-api-…), ou toute API en Bearer.",
  basic: 'Authentification HTTP basique (utilisateur + mot de passe).',
  ovh_api:
    "Les trois clés délivrées d'un coup par api.ovh.com/createToken/ : application, secrète et " +
    "consommateur. Demande au minimum GET sur /cloud/* : c'est ce qui ouvre les buckets, " +
    'les ressources et la consommation du projet.',
}

/** Types dont le secret se suffit à lui-même. */
const SECRET_ONLY = new Set(['token'])

function CredentialModal({
  open,
  credential,
  onClose,
}: {
  open: boolean
  credential?: any | null
  onClose: () => void
}) {
  const editMode = !!credential
  const [form, setForm] = useState({
    name: '',
    kind: 'ssh_key',
    username: 'root',
    secret: '',
    passphrase: '',
  })
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()

  useEffect(() => {
    if (!open) return
    setForm(
      credential
        ? {
            name: credential.name ?? '',
            kind: credential.kind ?? 'ssh_key',
            username: credential.username ?? '',
            // Le secret n'est jamais renvoyé par l'API : vide = inchangé.
            secret: '',
            passphrase: '',
          }
        : { name: '', kind: 'ssh_key', username: 'root', secret: '', passphrase: '' },
    )
  }, [open, credential])

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      const payload = {
        name: form.name,
        kind: form.kind,
        username: SECRET_ONLY.has(form.kind) ? null : form.username || null,
        ...(form.secret ? { secret: form.secret } : {}),
        ...(form.passphrase ? { passphrase: form.passphrase } : {}),
      }
      if (editMode) await patch(`/credentials/${credential.id}`, payload)
      else await post('/credentials', payload)
      toast(editMode ? 'Identifiants mis à jour' : 'Identifiants enregistrés', 'ok')
      queryClient.invalidateQueries({ queryKey: ['credentials'] })
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const isKey = form.kind === 'ssh_key'
  const isOvh = form.kind === 'ovh_api'
  const needsUser = !SECRET_ONLY.has(form.kind)
  const canSubmit = form.name && (editMode || form.secret)

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={editMode ? `Modifier « ${credential?.name} »` : 'Nouveaux identifiants'}
      width="max-w-xl"
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" form="cred-form" type="submit" disabled={busy || !canSubmit}>
            {busy ? <Spinner /> : <Plus size={15} />}
            {editMode ? 'Enregistrer' : 'Créer'}
          </button>
        </>
      }
    >
      <form id="cred-form" onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Nom</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder="clé-admin-infra"
              required
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Type</label>
            <select
              value={form.kind}
              onChange={(e) => setForm({ ...form, kind: e.target.value })}
              className="w-full"
            >
              {Object.entries(KIND_LABELS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </div>
        </div>

        <p className="text-[11px] text-ink-500 -mt-1">{KIND_HELP[form.kind]}</p>

        {needsUser && (
          <div className="space-y-1.5">
            <label>
              {isOvh ? "Clé d'application" : 'Utilisateur'}{' '}
              {!isOvh && (
                <span className="normal-case tracking-normal text-ink-600">(facultatif)</span>
              )}
            </label>
            <input
              value={form.username}
              onChange={(e) => setForm({ ...form, username: e.target.value })}
              placeholder={isOvh ? 'application key' : form.kind === 'api_token' ? 'root@pam!mba' : 'root'}
              className="w-full font-mono"
            />
            {form.kind === 'api_token' && (
              <p className="text-[11px] text-ink-500">
                Identifiant complet du jeton : utilisateur, point d'exclamation, nom du jeton. Tu peux
                aussi laisser ce champ vide et coller « root@pam!mba=uuid » entier dans le secret.
              </p>
            )}
          </div>
        )}

        <div className="space-y-1.5">
          <label>
            {isKey ? 'Clé privée' : isOvh ? 'Clé secrète' : 'Secret'}
            {editMode && (
              <span className="normal-case tracking-normal text-ink-600">
                {' '}
                — laisser vide pour conserver l'actuel
              </span>
            )}
          </label>
          {isKey ? (
            <textarea
              value={form.secret}
              onChange={(e) => setForm({ ...form, secret: e.target.value })}
              rows={7}
              placeholder={
                editMode
                  ? '(inchangée)'
                  : '-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----'
              }
              required={!editMode}
              className="w-full font-mono text-[11px] leading-relaxed"
            />
          ) : (
            <input
              type="password"
              value={form.secret}
              onChange={(e) => setForm({ ...form, secret: e.target.value })}
              placeholder={editMode ? '(inchangé)' : ''}
              required={!editMode}
              className="w-full font-mono"
            />
          )}
        </div>

        {(isKey || isOvh || form.kind === 'ssh_password') && (
          <div className="space-y-1.5">
            <label>
              {isKey
                ? 'Phrase de passe (optionnelle)'
                : isOvh
                  ? 'Clé de consommateur'
                  : 'Code OTP DSM (optionnel)'}
            </label>
            <input
              type="password"
              value={form.passphrase}
              onChange={(e) => setForm({ ...form, passphrase: e.target.value })}
              placeholder={editMode ? '(inchangé)' : ''}
              required={isOvh && !editMode}
              className="w-full font-mono"
            />
          </div>
        )}
      </form>
    </Modal>
  )
}

// ------------------------------------------------------------ notifications
function NotificationsTab() {
  const [form, setForm] = useState<any>(null)
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data, isLoading } = useQuery({
    queryKey: ['notifications'],
    queryFn: () => get('/notifications'),
  })

  useEffect(() => {
    if (data?.config) setForm({ ...data.config, to_addrs: (data.config.to_addrs ?? []).join(', ') })
  }, [data])

  if (isLoading || !form) {
    return (
      <div className="panel p-10 grid place-items-center">
        <Spinner size={20} />
      </div>
    )
  }

  const payload = () => ({
    enabled: form.enabled,
    host: form.host,
    port: Number(form.port),
    security: form.security,
    username: form.username,
    ...(password ? { password } : {}),
    from_addr: form.from_addr,
    to_addrs: String(form.to_addrs)
      .split(/[,;\s]+/)
      .map((a: string) => a.trim())
      .filter(Boolean),
    triggers: form.triggers,
    cooldown_minutes: Number(form.cooldown_minutes),
  })

  const save = async () => {
    setBusy('save')
    try {
      await api('/notifications', { method: 'PUT', json: payload() })
      toast('Notifications enregistrées', 'ok')
      setPassword('')
      queryClient.invalidateQueries({ queryKey: ['notifications'] })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const test = async () => {
    setBusy('test')
    try {
      const result = await post('/notifications/test', payload())
      toast(result.detail, result.ok ? 'ok' : 'danger')
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(null)
    }
  }

  const toggleTrigger = (key: string) =>
    setForm({
      ...form,
      triggers: form.triggers.includes(key)
        ? form.triggers.filter((t: string) => t !== key)
        : [...form.triggers, key],
    })

  return (
    <div className="space-y-4">
      <div className="panel p-4 space-y-4">
        <label className="flex items-center gap-2.5 cursor-pointer">
          <input
            type="checkbox"
            checked={form.enabled}
            onChange={(e) => setForm({ ...form, enabled: e.target.checked })}
          />
          <span className="text-sm text-mist-100 normal-case tracking-normal font-normal">
            Envoyer des notifications par courriel
          </span>
        </label>

        <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
          <div className="space-y-1.5 sm:col-span-2">
            <label>Serveur SMTP</label>
            <input
              value={form.host}
              onChange={(e) => setForm({ ...form, host: e.target.value })}
              placeholder="smtp.gmail.com"
              className="w-full font-mono"
            />
          </div>
          <div className="space-y-1.5">
            <label>Port</label>
            <input
              type="number"
              value={form.port}
              onChange={(e) => setForm({ ...form, port: Number(e.target.value) })}
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Chiffrement</label>
            <select
              value={form.security}
              onChange={(e) =>
                setForm({
                  ...form,
                  security: e.target.value,
                  port: e.target.value === 'ssl' ? 465 : e.target.value === 'none' ? 25 : 587,
                })
              }
              className="w-full"
            >
              <option value="starttls">STARTTLS (587)</option>
              <option value="ssl">SSL/TLS (465)</option>
              <option value="none">Aucun (25)</option>
            </select>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Utilisateur</label>
            <input
              value={form.username}
              onChange={(e) => setForm({ ...form, username: e.target.value })}
              className="w-full font-mono"
            />
          </div>
          <div className="space-y-1.5">
            <label>
              Mot de passe
              {form.has_password && (
                <span className="normal-case tracking-normal text-ink-600"> — vide = inchangé</span>
              )}
            </label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder={form.has_password ? '(enregistré)' : ''}
              className="w-full font-mono"
            />
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Expéditeur</label>
            <input
              value={form.from_addr}
              onChange={(e) => setForm({ ...form, from_addr: e.target.value })}
              placeholder="mba@exemple.fr"
              className="w-full font-mono"
            />
          </div>
          <div className="space-y-1.5">
            <label>Destinataires</label>
            <input
              value={form.to_addrs}
              onChange={(e) => setForm({ ...form, to_addrs: e.target.value })}
              placeholder="moi@exemple.fr, astreinte@exemple.fr"
              className="w-full font-mono"
            />
          </div>
        </div>

        <p className="text-[11px] text-ink-500">
          Gmail, iCloud et Outlook refusent le mot de passe du compte : il faut un mot de passe
          d'application dédié, créé depuis les réglages de sécurité du fournisseur.
        </p>
      </div>

      <div className="panel p-4 space-y-3">
        <SectionTitle>Quand notifier</SectionTitle>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-1.5">
          {Object.entries(data?.triggers ?? {}).map(([key, label]: [string, any]) => (
            <label
              key={key}
              className={clsx(
                'flex items-center gap-2.5 rounded-lg px-3 py-2 cursor-pointer border transition-colors',
                form.triggers.includes(key)
                  ? 'bg-accent/[0.07] border-accent/30'
                  : 'bg-ink-850 border-ink-750 hover:border-ink-600',
              )}
            >
              <input
                type="checkbox"
                checked={form.triggers.includes(key)}
                onChange={() => toggleTrigger(key)}
              />
              <span className="text-[13px] text-mist-200 normal-case tracking-normal font-normal">
                {label}
              </span>
            </label>
          ))}
        </div>

        <div className="space-y-1.5 max-w-xs">
          <label>Silence entre deux messages identiques (min)</label>
          <input
            type="number"
            min={0}
            max={1440}
            value={form.cooldown_minutes}
            onChange={(e) => setForm({ ...form, cooldown_minutes: Number(e.target.value) })}
            className="w-full"
          />
          <p className="text-[11px] text-ink-500">
            Évite qu'une panne persistante ne remplisse ta boîte mail.
          </p>
        </div>
      </div>

      <div className="flex justify-end gap-2">
        <button className="btn-ghost" onClick={test} disabled={busy !== null || !form.host}>
          {busy === 'test' ? <Spinner size={14} /> : <Send size={15} />}
          Envoyer un test
        </button>
        <button className="btn-primary" onClick={save} disabled={busy !== null}>
          {busy === 'save' ? <Spinner /> : 'Enregistrer'}
        </button>
      </div>
    </div>
  )
}

// -------------------------------------------------------------------- compte
function AccountTab() {
  const [form, setForm] = useState({ current_password: '', new_password: '', confirm: '' })
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  const { data: me } = useQuery({ queryKey: ['me'], queryFn: () => get('/auth/me') })

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    if (form.new_password !== form.confirm) {
      toast('Les deux mots de passe ne correspondent pas', 'danger')
      return
    }
    setBusy(true)
    try {
      await post('/auth/password', {
        current_password: form.current_password,
        new_password: form.new_password,
      })
      toast('Mot de passe mis à jour', 'ok')
      setForm({ current_password: '', new_password: '', confirm: '' })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
      <div className="panel p-4">
        <SectionTitle>Compte connecté</SectionTitle>
        <div className="flex items-center gap-3 py-2">
          <div className="w-10 h-10 rounded-full bg-accent/15 border border-accent/30 grid place-items-center">
            <UserCog size={18} className="text-accent" />
          </div>
          <div>
            <div className="text-mist-100 font-medium">{me?.username ?? '—'}</div>
            <div className="text-xs text-ink-500">{me?.role ?? ''}</div>
          </div>
        </div>
      </div>

      <form onSubmit={submit} className="panel p-4 space-y-3.5">
        <SectionTitle>Changer de mot de passe</SectionTitle>
        <div className="space-y-1.5">
          <label>Mot de passe actuel</label>
          <input
            type="password"
            value={form.current_password}
            onChange={(e) => setForm({ ...form, current_password: e.target.value })}
            autoComplete="current-password"
            required
            className="w-full"
          />
        </div>
        <div className="space-y-1.5">
          <label>Nouveau mot de passe</label>
          <input
            type="password"
            value={form.new_password}
            onChange={(e) => setForm({ ...form, new_password: e.target.value })}
            autoComplete="new-password"
            minLength={8}
            required
            className="w-full"
          />
        </div>
        <div className="space-y-1.5">
          <label>Confirmation</label>
          <input
            type="password"
            value={form.confirm}
            onChange={(e) => setForm({ ...form, confirm: e.target.value })}
            autoComplete="new-password"
            required
            className="w-full"
          />
        </div>
        <button type="submit" className="btn-primary w-full" disabled={busy}>
          {busy ? <Spinner /> : 'Mettre à jour'}
        </button>
      </form>
    </div>
  )
}

// ------------------------------------------------------------------ à propos
function AboutTab() {
  const { data: health } = useQuery({ queryKey: ['health'], queryFn: () => get('/health'), refetchInterval: 10000 })

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
      <div className="panel p-4">
        <SectionTitle>État du service</SectionTitle>
        <dl className="divide-y divide-ink-800/70">
          {[
            ['Statut', health?.status ?? '—'],
            ['Base de données', health?.database ? 'connectée' : 'indisponible'],
            ['Collecteurs actifs', health?.workers ?? '—'],
          ].map(([label, value]) => (
            <div key={label} className="flex items-baseline justify-between py-2">
              <dt className="text-xs text-ink-500">{label}</dt>
              <dd className="text-[13px] text-mist-200">{String(value)}</dd>
            </div>
          ))}
        </dl>
      </div>

      <div className="panel p-4 space-y-3">
        <SectionTitle>MyBeautifulAdmin</SectionTitle>
        <p className="text-[13px] text-mist-300 leading-relaxed">
          Console unifiée de supervision et d'administration : serveurs Linux, hyperviseurs Proxmox, NAS Synology,
          conteneurs Docker, services web et endpoints Ollama — en agentless, via SSH et les API natives.
        </p>
        <div className="grid grid-cols-2 gap-2 text-xs">
          {[
            ['Collecte', 'SSH + /proc, API Proxmox, WebAPI DSM'],
            ['Stockage', 'TimescaleDB, rétention 14 j'],
            ['Temps réel', 'WebSocket, tampon 300 points'],
            ['Sécurité', 'JWT + coffre Fernet'],
          ].map(([label, value]) => (
            <div key={label} className="bg-ink-800/50 rounded-lg px-2.5 py-2">
              <div className="metric-label">{label}</div>
              <div className="text-[12px] text-mist-300 mt-0.5">{value}</div>
            </div>
          ))}
        </div>
        <a href="/api/docs" target="_blank" rel="noopener noreferrer" className="btn-ghost w-full">
          Documentation de l'API
        </a>
      </div>
    </div>
  )
}
