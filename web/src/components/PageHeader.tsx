import type { ReactNode } from 'react'

export function PageHeader({
  title,
  subtitle,
  actions,
}: {
  title: ReactNode
  subtitle?: ReactNode
  actions?: ReactNode
}) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-3 mb-4 sm:mb-5">
      <div className="min-w-0">
        <h1 className="text-[19px] sm:text-[22px] font-semibold text-mist-100 leading-tight tracking-tight">
          {title}
        </h1>
        {subtitle && <p className="text-sm text-ink-500 mt-0.5">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2 flex-wrap">{actions}</div>}
    </div>
  )
}

export function Page({ children }: { children: ReactNode }) {
  return <div className="p-3 sm:p-5 max-w-[1800px] mx-auto">{children}</div>
}

export function SectionTitle({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="flex items-center justify-between mb-2.5">
      <h2 className="text-sm font-semibold text-mist-200">{children}</h2>
      {right}
    </div>
  )
}
