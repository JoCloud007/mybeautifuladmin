import SwiftUI

/// Les sections de l'application, dans l'ordre où elles sont proposées.
///
/// La console web tient sur une barre latérale ; sur iPhone, quatre onglets
/// suffisent au quotidien et le reste vit sous « Plus », regroupé par thème.
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case dashboard, hosts, containers, alerts
    case monitoring, network, services, inventory
    case security, protection
    case proxmox, synology, ipmi, home, cloud
    case terminal, updates, scheduler, remediation, discovery
    case ai, agents, prompt, mcp
    case events, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Tableau de bord"
        case .hosts: "Machines"
        case .containers: "Conteneurs"
        case .alerts: "Alertes"
        case .monitoring: "Monitoring"
        case .network: "Réseau"
        case .services: "Services web"
        case .inventory: "Inventaire"
        case .security: "Sécurité"
        case .protection: "Sauvegardes"
        case .proxmox: "Proxmox"
        case .synology: "Synology"
        case .ipmi: "Hors-bande"
        case .home: "Domotique"
        case .cloud: "Cloud public"
        case .terminal: "Terminal"
        case .updates: "Mises à jour"
        case .scheduler: "Planificateur"
        case .remediation: "Auto-remédiation"
        case .discovery: "Découverte"
        case .ai: "IA & accélérateurs"
        case .agents: "Agents IA"
        case .prompt: "Prompt Agent"
        case .mcp: "MCP Server"
        case .events: "Journal"
        case .settings: "Réglages"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .hosts: "server.rack"
        case .containers: "shippingbox"
        case .alerts: "bell"
        case .monitoring: "chart.xyaxis.line"
        case .network: "network"
        case .services: "globe"
        case .inventory: "list.clipboard"
        case .security: "shield.lefthalf.filled"
        case .protection: "externaldrive.badge.timemachine"
        case .proxmox: "square.stack.3d.up"
        case .synology: "externaldrive.connected.to.line.below"
        case .ipmi: "cpu"
        case .home: "house"
        case .cloud: "cloud"
        case .terminal: "terminal"
        case .updates: "arrow.down.circle"
        case .scheduler: "calendar.badge.clock"
        case .remediation: "wand.and.sparkles"
        case .discovery: "dot.radiowaves.left.and.right"
        case .ai: "brain"
        case .agents: "person.2.badge.gearshape"
        case .prompt: "bubble.left.and.sparkles"
        case .mcp: "network.badge.shield.half.filled"
        case .events: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }

    /// Les quatre onglets permanents de l'iPhone.
    static let primary: [Destination] = [.dashboard, .hosts, .containers, .alerts]

    /// Regroupement thématique de « Plus » et de la barre latérale iPad.
    static let groups: [(title: String, items: [Destination])] = [
        ("Supervision", [.monitoring, .network, .services, .inventory]),
        ("Sûreté", [.security, .protection]),
        ("Plateformes", [.proxmox, .synology, .ipmi, .home, .cloud]),
        ("Opérations", [.terminal, .updates, .scheduler, .remediation, .discovery]),
        ("Intelligence", [.ai, .agents, .prompt, .mcp]),
        ("Système", [.events, .settings]),
    ]
}
