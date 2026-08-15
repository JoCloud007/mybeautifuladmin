import { AlertTriangle, RotateCcw } from 'lucide-react'
import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props {
  children: ReactNode
  /** Libellé de la zone protégée, affiché dans le message de repli. */
  label?: string
}

interface State {
  error: Error | null
}

/**
 * Isole les pannes de rendu. Sans ça, une seule erreur — dans un graphique,
 * par exemple — vide toute la page et la console devient injoignable.
 */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('Erreur de rendu', error, info.componentStack)
  }

  render() {
    if (!this.state.error) return this.props.children
    return (
      <div className="panel border-danger/25 bg-danger/[0.04] p-5 m-4">
        <div className="flex items-start gap-3">
          <AlertTriangle size={18} className="text-danger shrink-0 mt-0.5" />
          <div className="min-w-0 flex-1">
            <h2 className="text-sm font-semibold text-mist-100">
              {this.props.label ?? 'Cette section'} n'a pas pu s'afficher
            </h2>
            <p className="text-[13px] text-mist-400 mt-1 break-words font-mono">{this.state.error.message}</p>
            <button className="btn-ghost mt-3" onClick={() => this.setState({ error: null })}>
              <RotateCcw size={14} />
              Réessayer
            </button>
          </div>
        </div>
      </div>
    )
  }
}
