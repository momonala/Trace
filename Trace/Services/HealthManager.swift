import Foundation
import HealthKit

@Observable
@MainActor
class HealthManager {
    static let shared = HealthManager()

    var steps: Int = 0
    var kcal: Int = 0
    var km: Double = 0.0
    var flights: Int = 0
    var isAvailable: Bool = false

    private let store = HKHealthStore()
    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.flightsClimbed),
    ]

    private init() {}

    func requestPermissionsAndLoad() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAvailable = true
            await refresh()
        } catch {
            // Permission denied or health data unavailable
        }
    }

    func refresh() async {
        guard isAvailable else { return }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now)

        async let stepsVal  = querySum(type: HKQuantityType(.stepCount),              unit: .count(),              predicate: predicate)
        async let kcalVal   = querySum(type: HKQuantityType(.activeEnergyBurned),     unit: .kilocalorie(),        predicate: predicate)
        async let kmVal     = querySum(type: HKQuantityType(.distanceWalkingRunning), unit: .meterUnit(with: .kilo), predicate: predicate)
        async let flightsVal = querySum(type: HKQuantityType(.flightsClimbed),        unit: .count(),              predicate: predicate)

        let (s, k, d, f) = await (stepsVal, kcalVal, kmVal, flightsVal)
        steps   = Int(s)
        kcal    = Int(k)
        km      = d
        flights = Int(f)
    }

    private func querySum(type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async -> Double {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }
}
