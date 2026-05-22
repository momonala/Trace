import HealthKit

enum HealthKitExportType: String, CaseIterable {
    case stepCount      = "Step Count"
    case distance       = "Distance"
    case flightsClimbed = "Flights Climbed"
    case activeEnergy   = "Active Energy"

    var hkQuantityType: HKQuantityType {
        switch self {
        case .stepCount:      return HKQuantityType(.stepCount)
        case .distance:       return HKQuantityType(.distanceWalkingRunning)
        case .flightsClimbed: return HKQuantityType(.flightsClimbed)
        case .activeEnergy:   return HKQuantityType(.activeEnergyBurned)
        }
    }

    var defaultUnit: HKUnit {
        switch self {
        case .stepCount:      return .count()
        case .distance:       return .meter()
        case .flightsClimbed: return .count()
        case .activeEnergy:   return .kilocalorie()
        }
    }

    static var readTypes: Set<HKObjectType> { Set(allCases.map(\.hkQuantityType)) }
}
