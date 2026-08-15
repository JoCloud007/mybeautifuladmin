import { useQuery, useQueryClient } from '@tanstack/react-query'
import clsx from 'clsx'
import { Check, EyeOff, Globe, KeyRound, Server, Shield, Wifi, WifiOff } from 'lucide-react'
import { useState } from 'react'
import { Badge, Empty, Spinner, useLocalState, useToast } from '@/components/ui'
import { get, post } from '@/lib/api'
import { ago, KIND_LABEL } from '@/lib/format'

interface Device {
  tailscale_id: string
  hostname: string
  dns_name: string
  address: string
  os: string
  version: string
  tags: string[]
  online: boolean
  last_seen: string | null
  user?: string | null
  update_available?: boolean
  guessed_kind: string
  open_ports?: number[]
  reachable?: boolean
  known?: boolean
}

const OS_LABEL: Record<string, string> = {
  linux: 'Linux',
  macOS: 'macOS',
  windows: 'Windows',
  iOS: 'iOS',
  android: 'Android',
  synology: 'Synology',
  tvOS: 'tvOS',
  freebsd: 'FreeBSD',
}

export function TailscaleScan({ onAdopt }: { onAdopt: (candidate: any) => void }) {
  const [source, setSource] = useLocalState<'api' | 'host'>('mba.tsSource', 'api')
  const [apiKey, setApiKey] = useState('')
  const [credentialId, setCredentialId] = useLocalState('mba.tsCred', '')
  const [tailnet, setTailnet] = useLocalState('mba.tsTailnet', '-')
  const [hostId, setHostId] = useLocalState('mba.tsHost', '')
  const [probePorts, setProbePorts] = useState(true)
  const [busy, setBusy] = useState(false)
  const [devices, setDevices] = useState<Device[]>([])
  const [summary, setSummary] = useState<any | null>(null)
  const [onlyOnline, setOnlyOnline] = useState(false)
  const toast = useToast()
  const queryClient = useQueryClient()

  const { data: credentials = [] } = useQuery({ queryKey: ['credentials'], queryFn: () => get('/credentials') })
  const { data: hosts = [] } = useQuery({ queryKey: ['hosts'], queryFn: () => get('/hosts') })

  const tokenCredentials = credentials.filter(
    (c: any) => c.kind === 'token' || c.kind === 'api_token',
  )
  const sshHosts = hosts.filter((h: any) => ['linux', 'docker'].includes(h.kind))

  const payload = () => ({
    source,
    ...(source === 'api'
      ? {
          tailnet: tailnet || '-',
          ...(apiKey ? { api_key: apiKey } : {}),
          ...(credentialId && !apiKey ? { credential_id: Number(credentialId) } : {}),
        }
      : { host_id: hostId ? Number(hostId) : null }),
    probe_ports: probePorts,
  })

  const scan = async () => {
    setBusy(true)
    try {
      const result = await post('/discovery/tailscale', payload())
      setDevices(result.devices)
      setSummary(result.summary)
      toast(
        `${result.summary.total} machine(s) sur le tailnet, ${result.summary.online} en ligne`,
        'ok',
      )
      queryClient.invalidateQueries({ queryKey: ['discovery-results'] })
    } catch (exc: any) {
      toast(exc.message, 'danger')
    } finally {
      setBusy(false)
    }
  }

  const canScan = source === 'host' ? !!hostId : !!(apiKey || credentialId)
  const visible = onlyOnline ? devices.filter((d) => d.online) : devices

  return (
    <div className="space-y-4">
      <div className="panel p-4 space-y-4">
        <div className="flex bg-ink-850 border border-ink-750 rounded-lg p-0.5 w-fit">
          {(
            [
              ['api', "Clé d'API", KeyRound],
              ['host', 'Client local', Server],
            ] as const
          ).map(([value, label, Icon]) => (
            <button
              key={value}
              onClick={() => setSource(value)}
              className={clsx(
                'px-3 py-1.5 rounded-md text-xs font-medium transition-colors flex items-center gap-1.5',
                source === value ? 'bg-ink-750 text-accent' : 'text-ink-500 hover:text-mist-300',
              )}
            >
              <Icon size={13} />
              {label}
            </button>
          ))}
        </div>

        {source === 'api' ? (
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <div className="space-y-1.5 md:col-span-2">
              <label>Clé d'API Tailscale</label>
              {tokenCredentials.length > 0 && (
                <select
                  value={credentialId}
                  onChange={(e) => {
                    setCredentialId(e.target.value)
                    setApiKey('')
                  }}
                  className="w-full mb-2"
                >
                  <option value="">— saisir une clé ci-dessous —</option>
                  {tokenCredentials.map((cred: any) => (
                    <option key={cred.id} value={cred.id}>
                      {cred.name}
                    </option>
                  ))}
                </select>
              )}
              <input
                type="password"
                value={apiKey}
                onChange={(e) => {
                  setApiKey(e.target.value)
                  if (e.target.value) setCredentialId('')
                }}
                placeholder="tskey-api-…"
                className="w-full font-mono"
              />
              <p className="text-[11px] text-ink-500">
                À générer sur{' '}
                <span className="text-mist-300 font-mono">login.tailscale.com/admin/settings/keys</span>{' '}
                avec le périmètre <span className="text-mist-300 font-mono">devices:read</span>. Enregistre-la
                comme identifiant « jeton d'API » pour ne pas la ressaisir.
              </p>
            </div>
            <div className="space-y-1.5">
              <label>Tailnet</label>
              <input
                value={tailnet}
                onChange={(e) => setTailnet(e.target.value)}
                placeholder="-"
                className="w-full font-mono"
              />
              <p className="text-[11px] text-ink-500">
                « - » désigne le tailnet par défaut de la clé.
              </p>
            </div>
          </div>
        ) : (
          <div className="space-y-1.5 max-w-md">
            <label>Machine portant le client Tailscale</label>
            <select value={hostId} onChange={(e) => setHostId(e.target.value)} className="w-full">
              <option value="">— choisir un hôte —</option>
              {sshHosts.map((host: any) => (
                <option key={host.id} value={host.id}>
                  {host.name} ({host.address})
                </option>
              ))}
            </select>
            <p className="text-[11px] text-ink-500">
              MBA exécute <span className="font-mono text-mist-300">tailscale status --json</span> en SSH sur
              cette machine. Aucune clé d'API n'est nécessaire.
            </p>
          </div>
        )}

        <div className="flex flex-wrap items-center gap-3">
          <label className="flex items-center gap-2 text-xs text-mist-400 normal-case tracking-normal font-normal cursor-pointer">
            <input type="checkbox" checked={probePorts} onChange={(e) => setProbePorts(e.target.checked)} />
            Sonder les ports des machines en ligne
          </label>
          <div className="flex-1" />
          <button className="btn-primary" onClick={scan} disabled={busy || !canScan}>
            {busy ? <Spinner /> : <Globe size={15} />}
            Interroger le tailnet
          </button>
        </div>

        {probePorts && (
          <p className="text-[11px] text-ink-600 -mt-2">
            La sonde n'aboutit que si le conteneur MBA est lui-même sur le tailnet. Sinon les machines
            restent listées, simplement sans empreinte de service.
          </p>
        )}
      </div>

      {summary && (
        <div className="flex flex-wrap items-center gap-2">
          <Badge tone="info">{summary.total} machines</Badge>
          <Badge tone="ok">{summary.online} en ligne</Badge>
          {summary.known > 0 && <Badge>{summary.known} déjà supervisées</Badge>}
          {summary.updates > 0 && <Badge tone="warn">{summary.updates} client(s) à mettre à jour</Badge>}
          <div className="flex-1" />
          <label className="flex items-center gap-2 text-xs text-mist-400 normal-case tracking-normal font-normal cursor-pointer">
            <input type="checkbox" checked={onlyOnline} onChange={(e) => setOnlyOnline(e.target.checked)} />
            En ligne seulement
          </label>
        </div>
      )}

      {devices.length === 0 && !busy && (
        <div className="panel">
          <Empty
            icon={<Shield size={38} />}
            title="Tailnet non interrogé"
            hint="Renseigne une clé d'API Tailscale, ou désigne une machine du tailnet déjà supervisée : MBA récupère alors la liste complète des nœuds, y compris ceux qu'il ne peut pas joindre directement."
          />
        </div>
      )}

      {visible.length > 0 && (
        <div className="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(330px,1fr))]">
          {visible.map((device) => (
            <div
              key={device.tailscale_id || device.address}
              className={clsx('panel p-3.5 space-y-2.5', (device.known || !device.online) && 'opacity-70')}
            >
              <div className="flex items-start gap-2.5">
                <div className="w-8 h-8 rounded-lg bg-ink-800 border border-ink-700 grid place-items-center shrink-0">
                  {device.online ? (
                    <Wifi size={15} className="text-accent" />
                  ) : (
                    <WifiOff size={15} className="text-ink-500" />
                  )}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="text-[13px] text-mist-100 truncate">{device.hostname}</div>
                  <div className="text-[11px] text-ink-600 font-mono truncate">{device.address}</div>
                </div>
                <Badge tone={device.online ? 'ok' : 'neutral'}>{OS_LABEL[device.os] ?? device.os}</Badge>
              </div>

              <div className="flex flex-wrap gap-1">
                {device.tags.map((tag) => (
                  <Badge key={tag} tone="violet">
                    {tag}
                  </Badge>
                ))}
                {(device.open_ports ?? []).slice(0, 6).map((port) => (
                  <span key={port} className="chip border-ink-700 bg-ink-800 text-ink-400 font-mono">
                    {port}
                  </span>
                ))}
              </div>

              <div className="text-[11px] text-ink-600 flex flex-wrap items-center gap-x-2">
                {device.version && <span className="font-mono">v{device.version}</span>}
                {device.update_available && <span className="text-warn">mise à jour dispo</span>}
                {device.user && <span>{device.user}</span>}
                <span>{device.online ? 'en ligne' : `vu ${ago(device.last_seen)}`}</span>
              </div>

              <div className="flex items-center gap-1.5 pt-1 border-t border-ink-800">
                {device.known ? (
                  <span className="text-[11px] text-accent flex items-center gap-1 flex-1">
                    <Check size={12} />
                    Déjà supervisée
                  </span>
                ) : (
                  <>
                    <button
                      className="btn-primary flex-1 py-1 text-xs"
                      onClick={() =>
                        onAdopt({
                          address: device.address,
                          hostname: device.dns_name || device.hostname,
                          guessed_kind: device.guessed_kind,
                          open_ports: device.open_ports ?? [],
                          evidence: {},
                          tags: device.tags,
                        })
                      }
                    >
                      Adopter
                    </button>
                    <span className="text-[10px] text-ink-600">
                      {KIND_LABEL[device.guessed_kind] ?? device.guessed_kind}
                    </span>
                  </>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {devices.length > 0 && visible.length === 0 && (
        <div className="panel">
          <Empty icon={<EyeOff size={32} />} title="Toutes les machines sont hors ligne" />
        </div>
      )}
    </div>
  )
}
