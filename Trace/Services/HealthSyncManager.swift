import Foundation
import HealthKit

/// Fetches all of today's raw HealthKit samples for the four tracked quantity types
/// and POSTs them as a single batch to /ios-dump.
/// Triggered on foreground, manual upload, and a 10-minute background timer.
@Observable
@MainActor
class HealthSyncManager {
    static let shared = HealthSyncManager()
    private static let logger = LoggerUtil(category: "HealthSyncManager")
    private static let batchIndexKey = "healthSyncBatchIndex"
    private static let autoSyncIntervalSeconds: TimeInterval = 10 * 60

    var lastSyncAt: Date?
    /// When true, UI may show a success toast for the sync that just updated `lastSyncAt`.
    var announceNextSync = false
    /// Sample count from the most recent successful upload; used by the success toast.
    var lastSyncSampleCount: Int = 0

    private let store = HKHealthStore()
    private var isSyncing = false
    private var autoSyncTimer: Timer?

    private var batchIndex: Int {
        get { UserDefaults.standard.integer(forKey: Self.batchIndexKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.batchIndexKey) }
    }

    private init() {
        startAutoSyncTimer()
    }

    private func startAutoSyncTimer() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: Self.autoSyncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performPeriodicHealthUpdate()
            }
        }
    }

    /// Uploads today's samples and pulls the server summary.
    /// HealthKit statistics are intentionally not refreshed here — background HKStatisticsQuery
    /// returns zero data without background delivery registration, which would overwrite the
    /// Live Activity with zeros. Stats are refreshed only when the app is foregrounded.
    private func performPeriodicHealthUpdate() async {
        Self.logger.info("Starting scheduled health sync (every 10m)")
        await syncNow(announce: false)
        await ServerAPIManager.shared.fetchHealthSummary()
    }

    func syncNow(announce: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard HKHealthStore.isHealthDataAvailable() else { return }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now)

        do {
            var allSamples: [FlatSample] = []
            for exportType in HealthKitExportType.allCases {
                let samples = try await fetchSamples(type: exportType, predicate: predicate)
                allSamples.append(contentsOf: samples)
            }

            guard !allSamples.isEmpty else {
                Self.logger.info("No health samples today — skipping upload")
                return
            }

            let completedIndex = batchIndex
            let payload = HealthBatchPayload(batchIndex: completedIndex, samples: allSamples)
            Self.logger.info("Uploading \(allSamples.count) health samples (batch \(completedIndex))")

            try await ServerAPIManager.shared.uploadHealthBatch(payload)

            batchIndex += 1
            lastSyncSampleCount = allSamples.count
            announceNextSync = announce
            lastSyncAt = now
            Self.logger.info("Health sync complete — batch \(completedIndex)")
        } catch {
            Self.logger.error("Health sync failed: \(error.localizedDescription)")
        }
    }

    private func fetchSamples(type: HealthKitExportType, predicate: NSPredicate) async throws -> [FlatSample] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: type.hkQuantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let flat = (samples ?? []).compactMap { FlatSample(from: $0, exportType: type) }
                continuation.resume(returning: flat)
            }
            store.execute(query)
        }
    }
}
