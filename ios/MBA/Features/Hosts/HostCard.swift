import SwiftUI

/// Carte d'une machine : état, jauges vivantes, courbe CPU.
///
/// Les valeurs viennent du flux temps réel plutôt que de la réponse REST, qui
/// n'est qu'un instantané au moment du chargement de l'écran.
struct HostCard: View {
    let host: Host
    @Environment(LiveStore.self) private var live

    private var status: HostStatus { live.statuses[host.id] ?? host.status }

    private var cpu: Double? { live.metric("cpu.usage", for: host.id) ?? host.cpuUsage }
    private var memory: Double? { live.metric("mem.percent", for: host.id) ?? host.memoryPercent }
    private var disk: Double? {
        live.metric("disk.percent./", for: host.id) ?? host.rootDiskPercent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !host.kind.hasSystemMetrics {
                outOfBandSummary
            } else if status != .online {
                offlineNotice
            } else if hasSystemSample {
                gauges
                if let series = live.series("cpu.usage", for: host.id), series.isPlottable {
                    Sparkline(points: series.points, tint: Palette.severity(cpu))
                        .frame(height: 28)
                }
            } else {
                // Un hôte joint par le seul socket Docker ne remonte aucune
                // métrique système : mieux vaut le dire que dessiner des jauges
                // vides qu'on lirait comme une machine au repos.
                noSystemMetricsNotice
            }

            footer
        }
        .padding(Metrics.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    // MARK: - Morceaux

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: host.kind.symbol)
                .font(.title3)
                .foregroundStyle(status.color)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(host.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            StatusBadge(text: status.label, color: status.color)
        }
    }

    private var gauges: some View {
        HStack(spacing: 18) {
            MetricRing(value: cpu, label: "CPU")
            MetricRing(value: memory, label: "RAM",
                       caption: memoryCaption)
            if let disk {
                MetricRing(value: disk, label: "Disque", warnAt: 80, criticalAt: 92)
            }
            Spacer(minLength: 0)
        }
    }

    private var memoryCaption: String? {
        guard let used = live.metric("mem.used", for: host.id),
              let total = live.metric("mem.total", for: host.id), total > 0 else { return nil }
        return "\(Format.bytes(used, digits: 0)) / \(Format.bytes(total, digits: 0))"
    }

    /// Vrai dès qu'au moins une jauge a une valeur à montrer.
    private var hasSystemSample: Bool { cpu != nil || memory != nil }

    private var noSystemMetricsNotice: some View {
        Label("Supervision par socket Docker — pas de métriques système",
              systemImage: "shippingbox")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var offlineNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle")
            Text(host.lastError ?? "Aucune donnée collectée")
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Un BMC n'a ni CPU ni mémoire à montrer : on affiche ce qu'il sait dire.
    private var outOfBandSummary: some View {
        HStack(spacing: 18) {
            if let power = live.metric("power.state", for: host.id) {
                LabeledValue(label: "Alimentation", value: power > 0 ? "Allumé" : "Éteint",
                             symbol: "power")
            }
            if let watts = live.metric("power.watts", for: host.id) {
                LabeledValue(label: "Consommation", value: Format.watts(watts), symbol: "bolt")
            }
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TagChip(text: host.kind.label, symbol: host.kind.symbol)
            if let updates = host.pendingUpdates, updates > 0 {
                TagChip(text: Format.plural(updates, "mise à jour", "mises à jour"),
                        symbol: "arrow.down.circle")
            }
            ForEach(host.tags.prefix(2), id: \.self) { tag in
                TagChip(text: tag, symbol: "tag")
            }
            Spacer(minLength: 0)
            if let uptime = live.metric("uptime", for: host.id) {
                Text(Format.duration(uptime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let lastSeen = host.lastSeen {
                Text(Format.ago(lastSeen))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Variante compacte pour les listes denses (recherche, sélecteurs).
struct HostRow: View {
    let host: Host
    @Environment(LiveStore.self) private var live

    private var status: HostStatus { live.statuses[host.id] ?? host.status }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.kind.symbol)
                .foregroundStyle(status.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .lineLimit(1)
                Text(host.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if status == .online, let cpu = live.metric("cpu.usage", for: host.id) {
                Text(Format.percent(cpu, digits: 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.severity(cpu))
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.name), \(status.label)")
    }
}
