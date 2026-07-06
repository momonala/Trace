import Foundation
import CoreData

enum HealthUploadError: Error, LocalizedError {
    case clientError(Int)
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .clientError(let code): return "Health upload client error: HTTP \(code)"
        case .serverError(let code): return "Health upload server error: HTTP \(code)"
        }
    }
}

struct HealthSummary: Decodable {
    let date: String
    let steps: Int?
    let kcals: Double?
    let km: Double?
    let flightsClimbed: Int?
    let weight: Double?

    enum CodingKeys: String, CodingKey {
        case date, steps, kcals, km, weight
        case flightsClimbed = "flights_climbed"
    }
}

struct MotionStats: Decodable {
    struct MotionTypeBreakdown: Decodable {
        let distanceKm: Double
        let timeSeconds: Double

        enum CodingKeys: String, CodingKey {
            case distanceKm = "distance_km"
            case timeSeconds = "time_seconds"
        }
    }

    let date: String
    let totalKm: Double
    let maxSpeedMS: Double
    let avgSpeedMS: Double
    let timeSpentSeconds: Double
    let altitudeAscendedM: Double
    let altitudeDescendedM: Double
    let motionType: [String: MotionTypeBreakdown]

    enum CodingKeys: String, CodingKey {
        case date
        case totalKm = "total_km"
        case maxSpeedMS = "max_speed_m_s"
        case avgSpeedMS = "avg_speed_m_s"
        case timeSpentSeconds = "time_spent_seconds"
        case altitudeAscendedM = "altitude_ascended_m"
        case altitudeDescendedM = "altitude_descended_m"
        case motionType = "motion_type"
    }
}

struct MotionStatsRange: Decodable {
    let days: Int
    let stats: [MotionStats]
}

struct HealthSummaryRange: Decodable {
    let days: Int
    let health: [HealthSummary]
}

struct LocationFeature: Encodable {
    struct Geometry: Encodable {
        let type = "Point"
        let coordinates: [Double]
    }

    struct Properties: Encodable {
        let speed: Double
        let motion: [String]
        let timestamp: Date
        let speed_accuracy: Double
        let horizontal_accuracy: Double
        let vertical_accuracy: Double
        let wifi: String
        let course: Double
        let altitude: Double
        let course_accuracy: Double
    }

    let type = "Feature"
    let geometry: Geometry
    let properties: Properties
}

struct LocationsPayload: Encodable {
    let locations: [LocationFeature]
}

@Observable
@MainActor
class ServerAPIManager {
    static let shared = ServerAPIManager()
    private static let logger = LoggerUtil(category: "ServerAPIManager")

    // API Configuration
    private static let baseURL = "https://trace.mnalavadi.org/"

    var serverBaseURL: String { Self.baseURL }
    private var apiEndpoint: String { "\(Self.baseURL)/dump" }
    private var statusEndpoint: String { "\(Self.baseURL)/status" }
    private var heartbeatEndpoint: String { "\(Self.baseURL)/heartbeat" }
    private var healthDataEndpoint: String { "\(Self.baseURL)health-data" }
    private var healthBatchEndpoint: String { "\(Self.baseURL)ios-dump" }
    private var motionStatsEndpoint: String { "\(Self.baseURL)motion-stats" }
    private var motionStatsRangeEndpoint: String { "\(Self.baseURL)motion-stats-range" }
    private var healthDataRangeEndpoint: String { "\(Self.baseURL)health-data-range" }
    private var snoozeEndpoint: String { "\(Self.baseURL)snooze" }
    var statusURL: URL { URL(string: statusEndpoint)! }
    private let heartbeatIntervalSeconds: TimeInterval = 3.0

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    var healthSummary: HealthSummary?
    var currentHourlyFile: HourlyFile?
    var queuedFiles: Int = 0
    var bufferSize: Int = 0
    var uploadError: Error?
    var isUploading = false
    var lastPointTime: Date?
    var lastUploadAttempt: Date? {
        didSet {
            if let date = lastUploadAttempt {
                UserDefaults.standard.set(date, forKey: "lastUploadAttempt")
            }
        }
    }
    var isAutoUploadEnabled: Bool {
        didSet {
            if isAutoUploadEnabled {
                startAutoUploadTimer()
            } else {
                autoUploadTimer?.invalidate()
                autoUploadTimer = nil
            }
            UserDefaults.standard.set(isAutoUploadEnabled, forKey: "isAutoUploadEnabled")
        }
    }
    var nextScheduledUpload: Date?

    private let calendar = Calendar.current
    private var autoUploadTimer: Timer?
    private var heartbeatTimer: Timer?

    private init() {
        self.isAutoUploadEnabled = UserDefaults.standard.bool(forKey: "isAutoUploadEnabled")
        if let date = UserDefaults.standard.object(forKey: "lastUploadAttempt") as? Date {
            self.lastUploadAttempt = date
        }

        Task {
            await loadQueuedFilesCount()
            if isAutoUploadEnabled {
                startAutoUploadTimer()
            }
        }

        startHeartbeat()
    }

    private func startAutoUploadTimer() {
        autoUploadTimer?.invalidate()

        autoUploadTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                if await self.queuedFiles > 0 {
                    await Self.logger.info("Starting scheduled auto-upload")
                    await self.uploadAllFiles()
                }
            }
        }

        Task {
            if queuedFiles > 0 {
                Self.logger.info("Starting initial auto-upload")
                await uploadAllFiles()
            }
        }
    }

    private func startHeartbeat() {
        Self.logger.info("Starting heartbeat timer")
        Task {
            await sendHeartbeat()
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatIntervalSeconds, repeats: true) { [weak self] _ in
            Task {
                await self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard let url = URL(string: heartbeatEndpoint) else {
            Self.logger.error("Invalid heartbeat URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                Self.logger.error("Invalid heartbeat response")
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                // Self.logger.info("💓 Heartbeat sent successfully")
                Task { @MainActor in
                    LocationManager.shared.updateLastHeartbeatTimestamp(Date())
                }
            } else {
                Self.logger.warning("Heartbeat failed with status: \(httpResponse.statusCode)")
            }
        } catch {
            Self.logger.error("Heartbeat error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func createNewHourlyFile(context: NSManagedObjectContext, for date: Date) async {
        let startOfMinute = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date))!
        let endOfMinute = calendar.date(byAdding: .minute, value: 1, to: startOfMinute)!

        let request: NSFetchRequest<HourlyFile> = HourlyFile.fetchRequest()
        request.predicate = NSPredicate(format: "startTime == %@", startOfMinute as NSDate)
        request.fetchLimit = 1

        do {
            if let existingFile = try context.fetch(request).first {
                currentHourlyFile = existingFile
                await updateBufferSize()
                Self.logger.info("Using existing file for minute: \(String(describing: existingFile.fileName))")
                return
            }
        } catch {
            Self.logger.error("Error checking for existing file: \(String(describing: error.localizedDescription))")
        }

        let hourlyFile = HourlyFile(context: context)
        hourlyFile.startTime = startOfMinute
        hourlyFile.endTime = endOfMinute
        hourlyFile.fileName = "trace_\(ISO8601DateFormatter().string(from: startOfMinute)).json"
        hourlyFile.uploadStatus = "pending"
        hourlyFile.retryCount = 0

        do {
            try context.save()
            currentHourlyFile = hourlyFile
            queuedFiles += 1
            bufferSize = 0
        } catch {
            Self.logger.error("Error creating minute file: \(String(describing: error.localizedDescription))")
        }
    }

    @MainActor
    func getFileForDate(_ date: Date) async -> HourlyFile {
        let context = PersistenceController.shared.container.viewContext

        if let current = currentHourlyFile,
           let startTime = current.startTime,
           let endTime = current.endTime,
           date >= startTime && date < endTime {
            return current
        }

        await createNewHourlyFile(context: context, for: date)
        return currentHourlyFile!
    }

    private func updateBufferSize() async {
        guard let currentFile = currentHourlyFile, let points = currentFile.points else {
            bufferSize = 0
            return
        }
        bufferSize = points.count
    }

    func pointAdded() async {
        bufferSize += 1
        lastPointTime = Date()
    }

    private func loadQueuedFilesCount() async {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<HourlyFile> = HourlyFile.fetchRequest()
        if let current = currentHourlyFile {
            request.predicate = NSPredicate(format: "uploadStatus != %@ AND self != %@ AND points.@count > 0", "completed", current)
        } else {
            request.predicate = NSPredicate(format: "uploadStatus != %@ AND points.@count > 0", "completed")
        }

        do {
            queuedFiles = try context.count(for: request)
        } catch {
            Self.logger.error("Error counting queued files: \(error.localizedDescription)")
        }
    }

    func uploadAllFiles() async {
        isUploading = true
        uploadError = nil
        defer { isUploading = false }

        Self.logger.info("Starting upload of completed files")

        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<HourlyFile> = HourlyFile.fetchRequest()
        if let current = currentHourlyFile {
            request.predicate = NSPredicate(format: "uploadStatus != %@ AND self != %@ AND points.@count > 0", "completed", current)
        } else {
            request.predicate = NSPredicate(format: "uploadStatus != %@ AND points.@count > 0", "completed")
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \HourlyFile.startTime, ascending: true)]

        do {
            let filesToUpload = try context.fetch(request)
            Self.logger.info("Found \(String(describing: filesToUpload.count)) files with points to upload")

            if filesToUpload.isEmpty {
                Self.logger.info("No files to upload")
                return
            }

            var hadError = false
            for file in filesToUpload {
                if let error = await uploadFile(file) {
                    uploadError = error
                    hadError = true
                    file.retryCount += 1
                    file.lastUploadAttempt = Date()
                } else {
                    file.uploadStatus = "completed"
                    queuedFiles -= 1

                    if let points = file.points {
                        points.forEach { point in
                            if let point = point as? LocationPoint {
                                context.delete(point)
                            }
                        }
                    }
                }
                try context.save()
            }

            if !hadError {
                Self.logger.info("Successfully processed all files")
                lastUploadAttempt = Date()
            }
        } catch {
            Self.logger.error("Error during upload: \(String(describing: error.localizedDescription))")
            uploadError = NSError(
                domain: "com.trace",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 500"]
            )
        }
    }

    func uploadHealthBatch(_ payload: HealthBatchPayload) async throws {
        guard let url = URL(string: healthBatchEndpoint) else { return }
        let data = try jsonEncoder.encode(payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        do {
            try await performHealthBatchRequest(request)
        } catch HealthUploadError.serverError {
            Self.logger.warning("Health upload server error, retrying once")
            try await performHealthBatchRequest(request)
        } catch is URLError {
            Self.logger.warning("Health upload transport error, retrying once")
            try await performHealthBatchRequest(request)
        }
    }

    private func performHealthBatchRequest(_ request: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HealthUploadError.serverError(502)
        }
        guard (200...299).contains(http.statusCode) else {
            throw http.statusCode >= 500
                ? HealthUploadError.serverError(http.statusCode)
                : HealthUploadError.clientError(http.statusCode)
        }
    }

    func fetchHealthSummary(for date: String = "today") async {
        guard let url = URL(string: "\(healthDataEndpoint)?date=\(date)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            healthSummary = try JSONDecoder().decode(HealthSummary.self, from: data)
            Self.logger.info("Health summary fetched for \(date)")
        } catch {
            Self.logger.error("Failed to fetch health summary: \(error.localizedDescription)")
        }
    }

    func fetchMotionStats(for date: String = "today") async throws -> MotionStats {
        guard let url = URL(string: "\(motionStatsEndpoint)?date=\(date)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "com.trace",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Motion stats request failed (HTTP \(code))"]
            )
        }
        let stats = try JSONDecoder().decode(MotionStats.self, from: data)
        Self.logger.info("Motion stats fetched for \(stats.date)")
        return stats
    }

    func fetchMotionStatsRange(days: Int) async throws -> [MotionStats] {
        guard let url = URL(string: "\(motionStatsRangeEndpoint)?days=\(days)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "com.trace",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Motion stats range request failed (HTTP \(code))"]
            )
        }
        let range = try JSONDecoder().decode(MotionStatsRange.self, from: data)
        Self.logger.info("Motion stats range fetched for \(range.days) days")
        return range.stats
    }

    func fetchHealthSummaryRange(days: Int) async throws -> [HealthSummary] {
        guard let url = URL(string: "\(healthDataRangeEndpoint)?days=\(days)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "com.trace",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Health range request failed (HTTP \(code))"]
            )
        }
        let range = try JSONDecoder().decode(HealthSummaryRange.self, from: data)
        Self.logger.info("Health summary range fetched for \(range.days) days")
        return range.health
    }

    func fetchDailyStats(days: Int) async throws -> [DailyStats] {
        async let motionRows = fetchMotionStatsRange(days: days)
        async let healthRows = fetchHealthSummaryRange(days: days)
        let motion = try await motionRows
        let health = try await healthRows
        let healthByDate = Dictionary(uniqueKeysWithValues: health.map { ($0.date, $0) })
        return motion.map { DailyStats(motion: $0, health: healthByDate[$0.date]) }
    }

    /// Tell the server the phone is intentionally going offline so missing heartbeats
    /// don't trigger Telegram alerts for the next `hours` (1–24).
    func snoozeAlerts(hours: Int) async throws {
        guard let url = URL(string: snoozeEndpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["hours": hours])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "com.trace",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Snooze request failed (HTTP \(code))"]
            )
        }
        Self.logger.info("Alerts snoozed for \(hours)h")
    }

    private func uploadFile(_ file: HourlyFile) async -> Error? {
        guard let url = URL(string: apiEndpoint) else {
            return NSError(domain: "com.trace", code: 400, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 400"])
        }

        let points = file.points?.allObjects as? [LocationPoint] ?? []
        if points.isEmpty {
            Self.logger.warning("Skipping file with no points")
            return nil
        }

        let locationFeatures = points.map { point in
            LocationFeature(
                geometry: .init(coordinates: [point.longitude, point.latitude]),
                properties: .init(
                    speed: point.speed,
                    motion: [point.motionType ?? "unknown"],
                    timestamp: point.timestamp ?? Date(),
                    speed_accuracy: 0.07,
                    horizontal_accuracy: point.horizontalAccuracy,
                    vertical_accuracy: point.verticalAccuracy,
                    wifi: "unknown",
                    course: -1,
                    altitude: point.altitude,
                    course_accuracy: -1
                )
            )
        }

        let payload = LocationsPayload(locations: locationFeatures)

        guard let jsonData = try? jsonEncoder.encode(payload) else {
            return NSError(domain: "com.trace", code: 400, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 400"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return NSError(domain: "com.trace", code: 502, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 502"])
            }

            if (200...299).contains(httpResponse.statusCode) {
                return nil
            } else {
                return NSError(domain: "com.trace", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP \(httpResponse.statusCode)"])
            }
        } catch {
            return NSError(domain: "com.trace", code: 503, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 503"])
        }
    }
}
