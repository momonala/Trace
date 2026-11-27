import Foundation
import HealthKit

/// Uploads HealthKit samples added since the last synced anchor to /ios-dump (see README, HealthKit Stats).
@Observable
@MainActor
class HealthSyncManager {
    static let shared = HealthSyncManager()
    private static let logger = LoggerUtil(category: "HealthSyncManager")
    private static let batchIndexKey = "healthSyncBatchIndex"
    private static let autoSyncIntervalSeconds: TimeInterval = 10 * 60
    private static let pageSize = 5_000

    var lastSyncAt: Date?

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

    /// Uploads new samples and pulls the server summary.
    /// HealthKit statistics are intentionally not refreshed here — background HKStatisticsQuery
    /// returns zero data without background delivery registration, which would overwrite the
    /// Live Activity with zeros. Stats are refreshed only when the app is foregrounded.
    private func performPeriodicHealthUpdate() async {
        Self.logger.info("Starting scheduled health sync (every 10m)")
        await syncNow()
        await ServerAPIManager.shared.fetchHealthSummary()
    }

    /// Returns the number of samples uploaded, or nil when nothing was sent.
    @discardableResult
    func syncNow() async -> Int? {
        guard !isSyncing else { return nil }
        isSyncing = true
        defer { isSyncing = false }

        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        var uploadedCount = 0
        do {
            for exportType in HealthKitExportType.allCases {
                uploadedCount += try await syncPages(for: exportType)
            }
        } catch {
            Self.logger.error("Health sync failed after \(uploadedCount) samples: \(error.localizedDescription)")
            return uploadedCount > 0 ? uploadedCount : nil
        }

        lastSyncAt = Date()
        guard uploadedCount > 0 else {
            Self.logger.info("No new health samples")
            return nil
        }
        Self.logger.info("Health sync complete — \(uploadedCount) samples")
        return uploadedCount
    }

    private func syncPages(for exportType: HealthKitExportType) async throws -> Int {
        var uploadedCount = 0
        while true {
            let page = try await fetchPage(type: exportType, anchor: loadAnchor(for: exportType))
            let samples = page.samples
            if !samples.isEmpty {
                let completedIndex = batchIndex
                Self.logger.info("Uploading \(samples.count) \(exportType.rawValue) samples (batch \(completedIndex))")
                try await ServerAPIManager.shared.uploadHealthBatch(
                    HealthBatchPayload(batchIndex: completedIndex, samples: samples)
                )
                batchIndex += 1
                uploadedCount += samples.count
            }
            try saveAnchor(page.anchor, for: exportType)
            if page.objectCount < Self.pageSize { return uploadedCount }
        }
    }

    private func fetchPage(
        type: HealthKitExportType,
        anchor: HKQueryAnchor?
    ) async throws -> AnchoredPage {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type.hkQuantityType,
                predicate: nil,
                anchor: anchor,
                limit: Self.pageSize
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let rawSamples = samples ?? []
                continuation.resume(returning: AnchoredPage(
                    samples: rawSamples.compactMap { FlatSample(from: $0, exportType: type) },
                    objectCount: rawSamples.count + (deletedObjects ?? []).count,
                    anchor: newAnchor
                ))
            }
            store.execute(query)
        }
    }

    private static func anchorKey(for type: HealthKitExportType) -> String {
        "healthSyncAnchor.\(type.rawValue)"
    }

    private func loadAnchor(for type: HealthKitExportType) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKey(for: type)) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            Self.logger.error("Unreadable \(type.rawValue) anchor, re-syncing full history: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveAnchor(_ anchor: HKQueryAnchor?, for type: HealthKitExportType) throws {
        guard let anchor else { return }
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: Self.anchorKey(for: type))
    }
}

private struct AnchoredPage {
    let samples: [FlatSample]
    let objectCount: Int
    let anchor: HKQueryAnchor?
}
