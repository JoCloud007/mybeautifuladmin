import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { get, post } from '@/lib/api'
import { Modal, Spinner, useToast } from './ui'

export const DEFAULT_PORTS: Record<string, number> = {
  linux: 22,
  proxmox: 8006,
  synology: 5001,
  docker: 22,
  pbs: 8007,
  homeassistant: 8123,
  ipmi: 443,
  generic: 80,
}

const KIND_HINT: Record<string, string> = {
  linux: 'Nécessite une clé ou un mot de passe SSH.',
  proxmox: "Crée un jeton d'API dans Datacenter → Permissions → API Tokens.",
  synology: 'Compte DSM avec droits administrateur. Port 5001 en HTTPS, 5000 en HTTP.',
  docker: 'Hôte Linux avec Docker : métriques système et conteneurs via SSH.',
  pbs: "Proxmox Backup Server : jeton d'API « user@pbs!id:secret » avec lecture sur les datastores.",
  homeassistant: "Jeton d'accès longue durée, créé depuis ton profil Home Assistant.",
  ipmi: 'Contrôleur hors-bande (BMC). Utilise plutôt la page Hors-bande pour le configurer.',
  generic: 'Surveillance de la disponibilité d’un port TCP uniquement.',
}

export function AddHostModal({
  open,
  onClose,
  kind: lockedKind,
  title,
}: {
  open: boolean
  onClose: () => void
  /** Fige le type d'hôte (ex. depuis la page Synology). */
  kind?: string
  title?: string
}) {
  const [form, setForm] = useState({
    name: '',
    kind: lockedKind ?? 'linux',
    address: '',
    port: DEFAULT_PORTS[lockedKind ?? 'linux'],
    credential_id: '',
    tags: '',
    category: '',
  })
  const [busy, setBusy] = useState(false)
  const queryClient = useQueryClient()
  const toast = useToast()

  const { data: credentials = [] } = useQuery({
    queryKey: ['credentials'],
    queryFn: () => get('/credentials'),
    enabled: open,
  })

  useEffect(() => {
    if (open && lockedKind) {
      setForm((f) => ({ ...f, kind: lockedKind, port: DEFAULT_PORTS[lockedKind] }))
    }
  }, [open, lockedKind])

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      const host = await post('/hosts', {
        name: form.name || form.address,
        kind: form.kind,
        address: form.address,
        port: Number(form.port) || DEFAULT_PORTS[form.kind],
        credential_id: form.credential_id ? Number(form.credential_id) : null,
        tags: form.tags.split(',').map((t) => t.trim()).filter(Boolean),
      })
      if (form.category.trim()) {
        await post(`/inventory/bulk`, { host_ids: [host.id], category: form.category.trim() })
      }
      toast(
        <>
          <b>{host.name}</b> ajouté — première collecte en cours.
        </>,
        'ok',
      )
      for (const key of ['hosts', 'overview', 'inventory', 'syno-hosts']) {
        queryClient.invalidateQueries({ queryKey: [key] })
      }
      setForm({
        name: '',
        kind: lockedKind ?? 'linux',
        address: '',
        port: DEFAULT_PORTS[lockedKind ?? 'linux'],
        credential_id: '',
        tags: '',
        category: '',
      })
      onClose()
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const relevant = credentials.filter((cred: any) => {
    if (form.kind === 'linux' || form.kind === 'docker') return cred.kind.startsWith('ssh')
    if (form.kind === 'pbs') return ['api_token', 'token'].includes(cred.kind)
    if (form.kind === 'homeassistant') return cred.kind === 'token'
    if (form.kind === 'proxmox') return ['api_token', 'token', 'ssh_password'].includes(cred.kind)
    return true
  })

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={title ?? 'Ajouter un hôte'}
      footer={
        <>
          <button className="btn-ghost" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-primary" form="add-host" type="submit" disabled={busy || !form.address}>
            {busy ? <Spinner /> : <Plus size={15} />}
            Ajouter
          </button>
        </>
      }
    >
      <form id="add-host" onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Type</label>
            <select
              value={form.kind}
              onChange={(e) => setForm({ ...form, kind: e.target.value, port: DEFAULT_PORTS[e.target.value] })}
              disabled={!!lockedKind}
              className="w-full disabled:opacity-60"
            >
              <option value="linux">Serveur Linux (SSH)</option>
              <option value="proxmox">Proxmox VE</option>
              <option value="synology">NAS Synology</option>
              <option value="docker">Hôte Docker</option>
              <option value="pbs">Proxmox Backup Server</option>
              <option value="homeassistant">Home Assistant</option>
              <option value="generic">Générique (port TCP)</option>
            </select>
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
        </div>

        <p className="text-[11px] text-ink-500 -mt-1">{KIND_HINT[form.kind]}</p>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Adresse IP ou nom</label>
            <input
              value={form.address}
              onChange={(e) => setForm({ ...form, address: e.target.value })}
              placeholder={form.kind === 'synology' ? '192.168.1.50' : '192.168.1.20'}
              required
              autoFocus
              className="w-full font-mono"
            />
          </div>
          <div className="space-y-1.5">
            <label>Nom affiché</label>
            <input
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              placeholder={form.kind === 'synology' ? 'diskstation' : 'serveur-01'}
              className="w-full"
            />
          </div>
        </div>

        <div className="space-y-1.5">
          <label>Identifiants</label>
          <select
            value={form.credential_id}
            onChange={(e) => setForm({ ...form, credential_id: e.target.value })}
            className="w-full"
          >
            <option value="">— aucun —</option>
            {relevant.map((cred: any) => (
              <option key={cred.id} value={cred.id}>
                {cred.name} ({cred.kind}
                {cred.username ? ` · ${cred.username}` : ''})
              </option>
            ))}
          </select>
          <p className="text-[11px] text-ink-500">
            Aucun identifiant ne convient ?{' '}
            <Link to="/settings" className="text-accent hover:underline">
              Créer un jeu d'identifiants
            </Link>
          </p>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <label>Catégorie</label>
            <input
              value={form.category}
              onChange={(e) => setForm({ ...form, category: e.target.value })}
              placeholder="Stockage"
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label>Étiquettes</label>
            <input
              value={form.tags}
              onChange={(e) => setForm({ ...form, tags: e.target.value })}
              placeholder="prod, baie"
              className="w-full"
            />
          </div>
        </div>
      </form>
    </Modal>
  )
}
