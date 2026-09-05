import Charts
import SwiftUI

// MARK: - Statuts

/// Pastille d'état, lisible sans dépendre de la couleur seule : la forme du
/// symbole et le libellé portent la même information, comme le demandent les
/// règles d'accessibilité d'Apple.
struct StatusBadge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            } else {
                Circle().frame(width: 7, height: 7)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct TagChip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

// MARK: - Jauges

/// Jauge circulaire compacte : CPU, mémoire, disque d'une carte de machine.
struct MetricRing: View {
    let value: Double?
    let label: String
    var caption: String?
    var warnAt: Double = 75
    var criticalAt: Double = 90

    private var fraction: Double { min(max((value ?? 0) / 100, 0), 1) }
    private var color: Color { Palette.severity(value, warn: warnAt, critical: criticalAt) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.45), value: fraction)
                Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
            .frame(width: 52, height: 52)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Format.percent(value, digits: 0))
    }
}

/// Note sur 100 — le sens est inversé par rapport à `MetricRing` : l'anneau est
/// plein et vert quand tout va bien, vide et rouge quand rien ne va.
///
/// Sert au score de sécurité comme au taux de couverture des sauvegardes.
struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 48
    var label: String = "Score"

    private var fraction: Double { min(max(Double(score) / 100, 0), 1) }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.score(score),
                        style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.45), value: fraction)
            Text("\(score)")
                .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(score) sur 100")
    }
}

/// Barre horizontale — plus lisible qu'un anneau dès qu'il y a une légende
/// (systèmes de fichiers, volumes, datastores).
struct MetricBar: View {
    let title: String
    let value: Double?
    var detail: String?
    var warnAt: Double = 75
    var criticalAt: Double = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(detail ?? Format.percent(value, digits: 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Palette.severity(value, warn: warnAt, critical: criticalAt))
                        .frame(width: geometry.size.width * min(max((value ?? 0) / 100, 0), 1))
                        .animation(.smooth(duration: 0.45), value: value)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cartes

/// Encadré de section, l'unité visuelle de base des écrans en `ScrollView`.
struct SectionBox<Content: View>: View {
    let title: String?
    var symbol: String?
    var accessory: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, symbol: String? = nil,
         accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }
}

/// Grande valeur + libellé : la ligne de synthèse du tableau de bord.
struct StatTile: View {
    let value: String
    let label: String
    var symbol: String?
    var tint: Color = .primary
    var trailing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) : \(value)")
    }
}

/// Ligne clé/valeur d'une fiche technique.
struct LabeledValue: View {
    let label: String
    let value: String?
    var symbol: String?
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value?.isEmpty == false ? value! : Format.placeholder)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .font(monospaced ? .callout.monospaced() : .callout)
        }
        .font(.callout)
    }
}

// MARK: - Graphiques

/// Courbe minimaliste pour une carte : pas d'axes, pas de légende, juste la forme.
struct Sparkline: View {
    let points: [MetricPoint]
    var tint: Color = .accentColor
    var filled: Bool = true

    var body: some View {
        Chart(points) { point in
            if filled {
                AreaMark(x: .value("Instant", point.date), y: .value("Valeur", point.value))
                    .foregroundStyle(.linearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            LineMark(x: .value("Instant", point.date), y: .value("Valeur", point.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.clear) }
        .accessibilityHidden(true)
    }
}

// MARK: - États

/// Écran vide standard, bâti sur `ContentUnavailableView` pour hériter du style
/// système (et de ses évolutions) plutôt que de le réinventer.
struct EmptyState: View {
    let title: String
    let message: String
    var symbol: String = "tray"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Erreur d'API affichée en place, avec la piste de résolution du serveur —
/// c'est souvent elle qui contient la vraie réponse (jeton Proxmox, port DSM…).
struct ErrorState: View {
    let error: APIError
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(error.message, systemImage: symbol)
        } description: {
            if let hint = error.hint {
                Text(hint)
            }
        } actions: {
            if let retry {
                Button("Réessayer", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var symbol: String {
        switch error.kind {
        case .offline, .transport: "wifi.exclamationmark"
        case .unauthorized: "lock.trianglebadge.exclamationmark"
        case .notFound: "questionmark.folder"
        default: "exclamationmark.triangle"
        }
    }
}

/// Bandeau discret en haut de liste : l'écran garde son contenu, on signale
/// juste que le rafraîchissement a échoué.
struct InlineErrorBanner: View {
    let error: APIError
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.message)
                    .font(.footnote.weight(.medium))
                if let hint = error.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let retry {
                Button("Réessayer", action: retry)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .padding(12)
        .background(Palette.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Divers

/// Liseré de couleur en tête de ligne de liste, pour scanner un état d'un coup
/// d'œil sans lire les libellés.
struct LeadingAccent: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 3)
    }
}

extension View {
    /// Retour haptique aligné sur les conventions système.
    func actionFeedback(_ trigger: some Equatable) -> some View {
        sensoryFeedback(.impact(weight: .light), trigger: trigger)
    }
}
