import Foundation

/// Display helpers for CoreMotion / Overland motion type strings used across the app.
enum MotionTypeDisplay {
    /// Canonical keys written to uploads and returned by `/motion-stats` (order used in breakdown lists).
    static let knownTypes = ["automotive", "cycling", "running", "walking", "stationary", "unknown"]

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func emoji(for raw: String) -> String {
        switch normalize(raw) {
        case "walking":    return "🚶🏽"
        case "running":    return "👟"
        case "cycling":    return "🚲"
        case "automotive": return "🚗"
        case "stationary": return "🐒"
        case "unknown":    return "❓"
        default:           return "❓"
        }
    }

    static func label(for raw: String) -> String {
        let key = normalize(raw)
        guard !key.isEmpty else { return "Unknown" }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    static func sortIndex(for raw: String) -> Int {
        knownTypes.firstIndex(of: normalize(raw)) ?? knownTypes.count
    }
}
