import Foundation

struct DailyStats: Identifiable {
    let date: String
    let totalKm: Double
    let maxSpeedMS: Double
    let avgSpeedMS: Double
    let timeSpentSeconds: Double
    let altitudeAscendedM: Double
    let altitudeDescendedM: Double
    let motionType: [String: MotionStats.MotionTypeBreakdown]
    let steps: Int?
    let kcals: Double?
    let healthKm: Double?
    let flightsClimbed: Int?

    var id: String { date }

    init(motion: MotionStats, health: HealthSummary?) {
        date = motion.date
        totalKm = motion.totalKm
        maxSpeedMS = motion.maxSpeedMS
        avgSpeedMS = motion.avgSpeedMS
        timeSpentSeconds = motion.timeSpentSeconds
        altitudeAscendedM = motion.altitudeAscendedM
        altitudeDescendedM = motion.altitudeDescendedM
        motionType = motion.motionType
        steps = health?.steps
        kcals = health?.kcals
        healthKm = health?.km
        flightsClimbed = health?.flightsClimbed
    }
}

struct DailyStatsCumulative {
    let totalKm: Double
    let maxSpeedMS: Double
    let avgSpeedMS: Double
    let timeSpentSeconds: Double
    let altitudeAscendedM: Double
    let altitudeDescendedM: Double
    let motionType: [String: MotionStats.MotionTypeBreakdown]
    let steps: Int?
    let kcals: Double?
    let flightsClimbed: Int?

    static func from(rows: [DailyStats]) -> DailyStatsCumulative {
        var motionTotals: [String: (distanceKm: Double, timeSeconds: Double)] = [:]
        var stepsSum = 0
        var hasSteps = false
        var kcalsSum = 0.0
        var hasKcals = false
        var flightsSum = 0
        var hasFlights = false
        var weightedAvgSpeed = 0.0

        for row in rows {
            for (type, breakdown) in row.motionType {
                let existing = motionTotals[type] ?? (0, 0)
                motionTotals[type] = (
                    existing.distanceKm + breakdown.distanceKm,
                    existing.timeSeconds + breakdown.timeSeconds
                )
            }
            if let steps = row.steps {
                stepsSum += steps
                hasSteps = true
            }
            if let kcals = row.kcals {
                kcalsSum += kcals
                hasKcals = true
            }
            if let flights = row.flightsClimbed {
                flightsSum += flights
                hasFlights = true
            }
            weightedAvgSpeed += row.avgSpeedMS * row.timeSpentSeconds
        }

        let totalTime = rows.reduce(0) { $0 + $1.timeSpentSeconds }
        let motionType = motionTotals.mapValues {
            MotionStats.MotionTypeBreakdown(distanceKm: $0.distanceKm, timeSeconds: $0.timeSeconds)
        }

        return DailyStatsCumulative(
            totalKm: rows.reduce(0) { $0 + $1.totalKm },
            maxSpeedMS: rows.map(\.maxSpeedMS).max() ?? 0,
            avgSpeedMS: totalTime > 0 ? weightedAvgSpeed / totalTime : 0,
            timeSpentSeconds: totalTime,
            altitudeAscendedM: rows.reduce(0) { $0 + $1.altitudeAscendedM },
            altitudeDescendedM: rows.reduce(0) { $0 + $1.altitudeDescendedM },
            motionType: motionType,
            steps: hasSteps ? stepsSum : nil,
            kcals: hasKcals ? kcalsSum : nil,
            flightsClimbed: hasFlights ? flightsSum : nil
        )
    }
}

enum StatsTableColumn: Hashable, Identifiable {
    case date
    case totalKm
    case activeTime
    case elevation
    case steps
    case kcal
    case flights
    case motion(String)
    case maxSpeed
    case avgSpeed

    var id: String {
        switch self {
        case .date: return "date"
        case .totalKm: return "totalKm"
        case .activeTime: return "activeTime"
        case .elevation: return "elevation"
        case .steps: return "steps"
        case .kcal: return "kcal"
        case .flights: return "flights"
        case .motion(let type): return "motion.\(type)"
        case .maxSpeed: return "maxSpeed"
        case .avgSpeed: return "avgSpeed"
        }
    }

    var title: String {
        switch self {
        case .date: return "Date"
        case .totalKm: return "Km"
        case .activeTime: return "Active Time"
        case .elevation: return "Elev"
        case .steps: return "Steps"
        case .kcal: return "Kcal"
        case .flights: return "Flights"
        case .motion(let type): return type
        case .maxSpeed: return "Max speed"
        case .avgSpeed: return "Avg speed"
        }
    }

    var width: CGFloat {
        switch self {
        case .date: return 56
        case .totalKm: return 56
        case .activeTime: return 72
        case .elevation: return 64
        case .steps: return 56
        case .kcal: return 48
        case .flights: return 56
        case .motion: return 116
        case .maxSpeed, .avgSpeed: return 72
        }
    }

    static var allColumns: [StatsTableColumn] {
        [
            .date, .totalKm, .steps, .kcal, .flights, .elevation,
        ]
        + MotionTypeDisplay.statsTableMotionTypes.map { .motion($0) }
        + [.maxSpeed, .avgSpeed]
    }

    func sortKey(from row: DailyStats) -> StatsSortKey {
        switch self {
        case .date:
            return .date(row.date)
        case .totalKm:
            return .number(row.totalKm)
        case .activeTime:
            return .number(row.timeSpentSeconds)
        case .elevation:
            return .number(row.altitudeAscendedM - row.altitudeDescendedM)
        case .steps:
            return .optionalNumber(row.steps.map(Double.init))
        case .kcal:
            return .optionalNumber(row.kcals)
        case .flights:
            return .optionalNumber(row.flightsClimbed.map(Double.init))
        case .motion(let type):
            let breakdown = row.motionType[type]
            return .optionalNumber(breakdown?.distanceKm)
        case .maxSpeed:
            return .number(row.maxSpeedMS)
        case .avgSpeed:
            return .number(row.avgSpeedMS)
        }
    }

    var isMotionColumn: Bool {
        if case .motion = self { return true }
        return false
    }

    var motionTypeKey: String? {
        guard case .motion(let type) = self else { return nil }
        return type
    }

    func motionBreakdown(for row: DailyStats) -> MotionStats.MotionTypeBreakdown? {
        guard case .motion(let type) = self else { return nil }
        return row.motionType[type]
    }

    func motionBreakdown(for totals: DailyStatsCumulative) -> MotionStats.MotionTypeBreakdown? {
        guard case .motion(let type) = self else { return nil }
        return totals.motionType[type]
    }

    var usesMonospacedDigits: Bool {
        switch self {
        case .activeTime, .elevation, .motion, .maxSpeed, .avgSpeed:
            return true
        default:
            return false
        }
    }

    func cellText(for row: DailyStats) -> String {
        switch self {
        case .date:
            return StatsFormatting.shortDate(row.date)
        case .totalKm:
            return StatsFormatting.kilometers(row.totalKm)
        case .activeTime:
            return StatsFormatting.durationHMS(row.timeSpentSeconds)
        case .elevation:
            return StatsFormatting.elevationChange(
                ascendedM: row.altitudeAscendedM,
                descendedM: row.altitudeDescendedM
            )
        case .steps:
            return row.steps.map(String.init) ?? "—"
        case .kcal:
            return row.kcals.map { String(Int($0.rounded())) } ?? "—"
        case .flights:
            return row.flightsClimbed.map(String.init) ?? "—"
        case .motion(let type):
            guard let breakdown = row.motionType[type] else { return "—" }
            return StatsFormatting.motionSummary(
                distanceKm: breakdown.distanceKm,
                timeSeconds: breakdown.timeSeconds
            )
        case .maxSpeed:
            return StatsFormatting.speedKmh(row.maxSpeedMS)
        case .avgSpeed:
            return StatsFormatting.speedKmh(row.avgSpeedMS)
        }
    }

    func cumulativeCellText(for totals: DailyStatsCumulative) -> String {
        switch self {
        case .date:
            return "Total"
        case .totalKm:
            return StatsFormatting.kilometers(totals.totalKm)
        case .activeTime:
            return StatsFormatting.durationHMS(totals.timeSpentSeconds)
        case .elevation:
            return StatsFormatting.elevationChange(
                ascendedM: totals.altitudeAscendedM,
                descendedM: totals.altitudeDescendedM
            )
        case .steps:
            return totals.steps.map(String.init) ?? "—"
        case .kcal:
            return totals.kcals.map { String(Int($0.rounded())) } ?? "—"
        case .flights:
            return totals.flightsClimbed.map(String.init) ?? "—"
        case .motion(let type):
            guard let breakdown = totals.motionType[type] else { return "—" }
            return StatsFormatting.motionSummary(
                distanceKm: breakdown.distanceKm,
                timeSeconds: breakdown.timeSeconds
            )
        case .maxSpeed:
            return StatsFormatting.speedKmh(totals.maxSpeedMS)
        case .avgSpeed:
            return StatsFormatting.speedKmh(totals.avgSpeedMS)
        }
    }
}

enum StatsSortKey: Comparable {
    case date(String)
    case number(Double)
    case optionalNumber(Double?)

    static func < (lhs: StatsSortKey, rhs: StatsSortKey) -> Bool {
        switch (lhs, rhs) {
        case let (.date(left), .date(right)):
            return left < right
        case let (.number(left), .number(right)):
            return left < right
        case let (.optionalNumber(left), .optionalNumber(right)):
            switch (left, right) {
            case let (l?, r?):
                return l < r
            case (nil, nil):
                return false
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        default:
            return false
        }
    }
}

enum StatTrace: Identifiable, Hashable {
    case totalKm
    case activeTime
    case maxSpeed
    case avgSpeed
    case ascended
    case descended
    case steps
    case kcal
    case flights
    case motionDistance(String)
    case motionTime(String)

    var id: String {
        switch self {
        case .totalKm: return "totalKm"
        case .activeTime: return "activeTime"
        case .maxSpeed: return "maxSpeed"
        case .avgSpeed: return "avgSpeed"
        case .ascended: return "ascended"
        case .descended: return "descended"
        case .steps: return "steps"
        case .kcal: return "kcal"
        case .flights: return "flights"
        case .motionDistance(let type): return "motionDistance.\(type)"
        case .motionTime(let type): return "motionTime.\(type)"
        }
    }

    var label: String {
        switch self {
        case .totalKm: return "Distance (km)"
        case .activeTime: return "Active time"
        case .maxSpeed: return "Max speed (km/h)"
        case .avgSpeed: return "Avg speed (km/h)"
        case .ascended: return "Ascended (m)"
        case .descended: return "Descended (m)"
        case .steps: return "Steps"
        case .kcal: return "Kcal"
        case .flights: return "Flights"
        case .motionDistance(let type):
            return "\(MotionTypeDisplay.label(for: type)) distance (km)"
        case .motionTime(let type):
            return "\(MotionTypeDisplay.label(for: type)) time"
        }
    }

    var usesLineMark: Bool {
        switch self {
        case .maxSpeed, .avgSpeed: return true
        default: return false
        }
    }

    var compactLabel: String {
        switch self {
        case .totalKm: return "Km"
        case .activeTime: return "Active"
        case .maxSpeed: return "Max spd"
        case .avgSpeed: return "Avg spd"
        case .ascended: return "Up"
        case .descended: return "Down"
        case .steps: return "Steps"
        case .kcal: return "Kcal"
        case .flights: return "Flights"
        case .motionDistance(let type):
            return "\(type) km"
        case .motionTime(let type):
            return "\(type) time"
        }
    }

    static let defaultTrace: StatTrace = .totalKm

    static var allTraces: [StatTrace] {
        var traces: [StatTrace] = [
            .totalKm, .activeTime, .maxSpeed, .avgSpeed,
            .ascended, .descended, .steps, .kcal, .flights,
        ]
        for type in MotionTypeDisplay.knownTypes {
            traces.append(.motionDistance(type))
            traces.append(.motionTime(type))
        }
        return traces
    }

    func value(from stats: DailyStats) -> Double? {
        switch self {
        case .totalKm:
            return stats.totalKm
        case .activeTime:
            return stats.timeSpentSeconds
        case .maxSpeed:
            return stats.maxSpeedMS * 3.6
        case .avgSpeed:
            return stats.avgSpeedMS * 3.6
        case .ascended:
            return stats.altitudeAscendedM
        case .descended:
            return stats.altitudeDescendedM
        case .steps:
            return stats.steps.map(Double.init)
        case .kcal:
            return stats.kcals
        case .flights:
            return stats.flightsClimbed.map(Double.init)
        case .motionDistance(let type):
            return stats.motionType[type]?.distanceKm
        case .motionTime(let type):
            return stats.motionType[type]?.timeSeconds
        }
    }

    func formattedValue(from stats: DailyStats) -> String {
        guard let value = value(from: stats) else { return "—" }
        switch self {
        case .totalKm, .motionDistance:
            return StatsFormatting.kilometers(value)
        case .activeTime, .motionTime:
            return StatsFormatting.durationHMS(value)
        case .maxSpeed, .avgSpeed:
            return String(format: "%.1f", value)
        case .ascended, .descended:
            return StatsFormatting.meters(value)
        case .steps, .flights:
            return String(Int(value))
        case .kcal:
            return String(Int(value.rounded()))
        }
    }
}

struct StatsChartPoint: Identifiable {
    let date: String
    let displayDate: String
    let value: Double

    var id: String { date }
}
