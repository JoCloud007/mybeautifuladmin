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

    /// Gravité d'un constat d'audit ou d'un risque de sauvegarde. « Élevé » vaut
    /// rouge comme « critique » : à l'écran, la distinction se lit au libellé, et
    /// traiter un constat élevé comme un avertissement le ferait passer inaperçu.
    static func finding(_ severity: FindingSeverity) -> Color {
        switch severity {
        case .critical, .high: danger
        case .medium: warn
        case .low: Color.accentColor
        case .info: idle
        }
    }

    /// Note sur 100 : ici le haut est bon, l'inverse des jauges d'occupation.
    static func score(_ score: Int) -> Color {
        if score >= 85 { return ok }
        if score >= 60 { return warn }
        return danger
    }

    static func freshness(_ freshness: Freshness) -> Color {
        switch freshness {
        case .fresh: ok
        case .stale: warn
        case .critical: danger
        case .unknown: idle
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

extension FindingSeverity {
    var color: Color { Palette.finding(self) }
}

extension Freshness {
    var color: Color { Palette.freshness(self) }
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
