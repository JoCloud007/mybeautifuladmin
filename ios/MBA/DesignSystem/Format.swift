import Foundation

/// Formatage unifié, calqué sur celui de la console web pour qu'une valeur lue
/// sur iPhone se retrouve à l'identique dans le navigateur.
enum Format {
    static let placeholder = "—"

    private static let byteUnits = ["o", "Ko", "Mo", "Go", "To", "Po"]

    static func bytes(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return placeholder }
        if value == 0 { return "0 o" }
        let exponent = min(Int(log(abs(value)) / log(1024)), byteUnits.count - 1)
        let scaled = value / pow(1024, Double(exponent))
        return "\(number(scaled, digits: exponent == 0 ? 0 : digits)) \(byteUnits[exponent])"
    }

    static func bitrate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return placeholder }
        return bytes(bytesPerSecond) + "/s"
    }

    static func percent(_ value: Double?, digits: Int = 1) -> String {
        guard let value, value.isFinite else { return placeholder }
        return "\(number(value, digits: digits)) %"
    }

    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return placeholder }
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "fr_FR")))
    }

    static func integer(_ value: Int?) -> String {
        guard let value else { return placeholder }
        return value.formatted(.number.locale(Locale(identifier: "fr_FR")))
    }

    /// Durée d'activité : deux unités suffisent, la troisième est du bruit.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0, seconds.isFinite else { return placeholder }
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if days > 0 { return "\(days) j \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(Int(seconds)) s"
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return placeholder }
        return value >= 1000 ? "\(number(value / 1000, digits: 2)) s" : "\(Int(value.rounded())) ms"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return placeholder }
        return "\(number(celsius, digits: 0)) °C"
    }

    static func frequency(_ megahertz: Double?) -> String {
        guard let megahertz, megahertz.isFinite else { return placeholder }
        return megahertz >= 1000
            ? "\(number(megahertz / 1000, digits: 2)) GHz"
            : "\(number(megahertz, digits: 0)) MHz"
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return placeholder }
        return "\(number(value, digits: 0)) W"
    }

    static func rpm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return placeholder }
        return "\(number(value, digits: 0)) tr/min"
    }

    // MARK: - Dates

    static func ago(_ date: Date?) -> String {
        guard let date else { return "jamais" }
        let delta = Date.now.timeIntervalSince(date)
        if delta < 5 { return "à l'instant" }
        if delta < 60 { return "il y a \(Int(delta)) s" }
        if delta < 3600 { return "il y a \(Int(delta / 60)) min" }
        if delta < 86400 { return "il y a \(Int(delta / 3600)) h" }
        return "il y a \(Int(delta / 86400)) j"
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return placeholder }
        return date.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "fr_FR")))
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return placeholder }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute()
            .locale(Locale(identifier: "fr_FR")))
    }

    static func fullDate(_ date: Date?) -> String {
        guard let date else { return placeholder }
        return date.formatted(.dateTime.day().month(.wide).year().hour().minute()
            .locale(Locale(identifier: "fr_FR")))
    }

    /// « 3 machines », « 1 machine » — l'accord se fait partout dans l'app.
    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        let word = count > 1 ? (plural ?? singular + "s") : singular
        return "\(integer(count)) \(word)"
    }
}
