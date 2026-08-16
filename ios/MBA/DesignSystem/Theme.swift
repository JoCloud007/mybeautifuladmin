import SwiftUI

/// Couleurs sémantiques.
///
/// Tout part des couleurs système : elles s'adaptent seules au mode sombre, au
/// contraste élevé et aux réglages d'accessibilité. Seule la teinte de marque
/// est fixée, dans le catalogue d'assets.
enum Palette {
    static let ok = Color.accentColor
    static let warn = Color.orange
    static let danger = Color.red
    static let idle = Color.secondary

    /// Seuils communs à toutes les jauges : 75 % attention, 90 % danger.
    static func severity(_ value: Double?, warn: Double = 75, critical: Double = 90) -> Color {
        guard let value else { return idle }
        if value >= critical { return danger }
        if value >= warn { return Self.warn }
        return ok
    }

    static func status(_ status: HostStatus) -> Color {
        switch status {
        case .online: ok
        case .offline: danger
        case .warning: warn
        case .unknown: idle
        }
    }

    static func severity(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .critical: danger
        case .warning: warn
        case .info: Color.accentColor
        }
    }

    static func level(_ level: EventLevel) -> Color {
        switch level {
        case .info: Color.secondary
        case .warning: warn
        case .critical, .error: danger
        }
    }

    /// Vert quand le service répond, rouge sinon — même code que la console web.
    static func serviceStatus(_ status: String) -> Color {
        switch status {
        case "up", "running", "online", "success", "ok", "healthy": ok
        case "down", "failed", "error", "offline", "exited": danger
        case "warning", "degraded", "partial", "paused": warn
        default: idle
        }
    }
}

extension HostStatus {
    var color: Color { Palette.status(self) }
}

extension AlertSeverity {
    var color: Color { Palette.severity(self) }
}

extension EventLevel {
    var color: Color { Palette.level(self) }
}

/// Espacements et rayons partagés, pour que les cartes d'un écran à l'autre
/// aient exactement la même assise.
enum Metrics {
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let tightSpacing: CGFloat = 6
    static let spacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    /// 44 pt : la cible tactile minimale recommandée par Apple.
    static let touchTarget: CGFloat = 44
}
