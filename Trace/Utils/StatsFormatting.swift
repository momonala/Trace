import Foundation

enum StatsFormatting {
    static func durationHMS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func durationHM(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0, m > 0 {
            return "\(h)h \(m)m"
        }
        if h > 0 {
            return "\(h)h"
        }
        return "\(m)m"
    }

    static func speedKmh(_ metersPerSecond: Double) -> String {
        String(format: "%.1f", metersPerSecond * 3.6)
    }

    static func kilometers(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func meters(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    static func elevationChange(ascendedM: Double, descendedM: Double) -> String {
        let up = Int(ascendedM.rounded())
        let down = Int(descendedM.rounded())
        return "+\(up) -\(down)"
    }

    static func motionDistanceText(_ distanceKm: Double) -> String {
        String(format: "%.1fkm", distanceKm)
    }

    static func motionTimeText(_ timeSeconds: Double) -> String {
        "(\(durationHM(timeSeconds)))"
    }

    static func motionSummary(distanceKm: Double, timeSeconds: Double) -> String {
        "\(motionDistanceText(distanceKm)) \(motionTimeText(timeSeconds))"
    }

    static func shortDate(_ isoDate: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: isoDate) else { return isoDate }
        let display = DateFormatter()
        display.dateFormat = "MMM d"
        return display.string(from: date)
    }

    static func parseDate(_ isoDate: String) -> Date? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: isoDate)
    }
}
