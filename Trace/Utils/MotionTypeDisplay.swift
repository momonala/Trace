import Foundation
import SwiftUI

/// Display helpers for CoreMotion / Overland motion type strings used across the app.
enum MotionTypeDisplay {
    /// Canonical keys written to uploads and returned by `/motion-stats` (order used in breakdown lists).
    static let knownTypes = ["automotive", "cycling", "running", "walking", "stationary", "unknown"]

    /// Motion types in stats table column order (after health / elevation columns).
    static let statsTableMotionTypes = [
        "walking", "running", "cycling", "automotive", "stationary", "unknown",
    ]

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

    static func color(for raw: String) -> Color {
        switch normalize(raw) {
        case "walking":    return Color(red: 0.45, green: 0.85, blue: 0.58)
        case "running":    return Color(red: 1.0, green: 0.55, blue: 0.38)
        case "cycling":    return Color(red: 0.42, green: 0.76, blue: 1.0)
        case "automotive": return Color(red: 0.76, green: 0.58, blue: 1.0)
        case "stationary": return Color(red: 0.68, green: 0.68, blue: 0.74)
        case "unknown":    return Color(red: 1.0, green: 0.82, blue: 0.38)
        default:           return Color(red: 1.0, green: 0.82, blue: 0.38)
        }
    }
}
