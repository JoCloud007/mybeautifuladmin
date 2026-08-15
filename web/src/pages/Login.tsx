import { Activity, ArrowRight } from 'lucide-react'
import { useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { post, setToken } from '@/lib/api'
import { Spinner } from '@/components/ui'

export function LoginPage() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const navigate = useNavigate()
  const [params] = useSearchParams()

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      const data = await post('/auth/login', { username, password })
      setToken(data.token)
      navigate(params.get('next') || '/', { replace: true })
    } catch (exc: any) {
      setError(exc.message ?? 'Connexion impossible')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="h-full grid place-items-center px-4 bg-ink-900 relative overflow-hidden">
      <div
        className="absolute inset-0 opacity-[0.35] pointer-events-none"
        style={{
          background:
            'radial-gradient(60rem 40rem at 20% -10%, rgba(0,212,170,0.10), transparent 60%),' +
            'radial-gradient(50rem 30rem at 110% 110%, rgba(59,157,255,0.08), transparent 60%)',
        }}
      />
      <form onSubmit={submit} className="panel w-full max-w-sm p-7 relative animate-slideUp">
        <div className="flex items-center gap-3 mb-6">
          <div className="w-10 h-10 rounded-xl bg-accent/15 border border-accent/30 grid place-items-center">
            <Activity size={19} className="text-accent" />
          </div>
          <div>
            <h1 className="text-lg font-semibold text-mist-100 leading-tight">MyBeautifulAdmin</h1>
            <p className="text-xs text-ink-500">Console d'infrastructure</p>
          </div>
        </div>

        <div className="space-y-3.5">
          <div className="space-y-1.5">
            <label htmlFor="user">Utilisateur</label>
            <input
              id="user"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoComplete="username"
              autoFocus
              required
              className="w-full"
            />
          </div>
          <div className="space-y-1.5">
            <label htmlFor="pass">Mot de passe</label>
            <input
              id="pass"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
              required
              className="w-full"
            />
          </div>
        </div>

        {error && (
          <div className="mt-4 text-sm text-danger bg-danger/10 border border-danger/25 rounded-lg px-3 py-2">
            {error}
          </div>
        )}

        <button type="submit" disabled={busy} className="btn-primary w-full mt-5 py-2">
          {busy ? <Spinner /> : <>Se connecter <ArrowRight size={15} /></>}
        </button>
      </form>
    </div>
  )
}
