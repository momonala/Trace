import Foundation
import CoreData

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

@MainActor
class ServerAPIManager: ObservableObject {
    static let shared = ServerAPIManager()
    private static let logger = LoggerUtil(category: "serverAPIManager")

    
    // API Configuration
    // private static let baseURL = "https://full-primarily-weevil.ngrok-free.app/incognita"
    // private static let baseURL = "http://192.168.0.183:5003"
    private static let baseURL = "https://trace.mnalavadi.org/"

    var serverBaseURL: String { Self.baseURL }
    private var apiEndpoint: String { "\(Self.baseURL)/dump" }
    private var statusEndpoint: String { "\(Self.baseURL)/status" }
    private var heartbeatEndpoint: String { "\(Self.baseURL)/heartbeat" }
    var statusURL: URL { URL(string: statusEndpoint)! }
    private let heartbeatIntervalSeconds: TimeInterval = 30.0
    
    @Published var currentHourlyFile: HourlyFile?
    @Published var queuedFiles: Int = 0
    @Published var bufferSize: Int = 0
    @Published var uploadError: Error?
    @Published var isUploading = false
    @Published var lastPointTime: Date?
    @Published var lastUploadAttempt: Date? {
        didSet {
            if let date = lastUploadAttempt {
                UserDefaults.standard.set(date, forKey: "lastUploadAttempt")
            }
        }
    }
    @Published var isAutoUploadEnabled: Bool {
        didSet {
            if isAutoUploadEnabled {
                setupMidnightUpload()
            } else {
                midnightUploadTimer?.invalidate()
                midnightUploadTimer = nil
            }
            UserDefaults.standard.set(isAutoUploadEnabled, forKey: "isAutoUploadEnabled")
        }
    }
    @Published var nextScheduledUpload: Date?
    
    private let calendar = Calendar.current
    private var midnightUploadTimer: Timer?
    private var heartbeatTimer: Timer?
    
    private init() {
        // Initialize from UserDefaults
        self.isAutoUploadEnabled = UserDefaults.standard.bool(forKey: "isAutoUploadEnabled")
        if let date = UserDefaults.standard.object(forKey: "lastUploadAttempt") as? Date {
            self.lastUploadAttempt = date
        }
        
        Task { 
            await loadQueuedFilesCount()
            if isAutoUploadEnabled {
                setupMidnightUpload()
            }
        }
        
        startHeartbeat()
    }
    
    
    private func setupMidnightUpload() {
        // Cancel any existing timer
        midnightUploadTimer?.invalidate()
        
        // Calculate time until next midnight
        let now = Date()
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              let nextMidnight = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow) else {
            Self.logger.error("❌ Failed to calculate next midnight")
            return
        }
        
        let timeUntilMidnight = nextMidnight.timeIntervalSince(now)
        nextScheduledUpload = nextMidnight
        Self.logger.info("🕛 Scheduled next auto-upload in \(String(format: "%.1f", timeUntilMidnight/3600)) hours")
        
        // Schedule timer for next midnight
        midnightUploadTimer = Timer.scheduledTimer(withTimeInterval: timeUntilMidnight, repeats: false) { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                
                // Perform upload
                if self.queuedFiles > 0 {
                    Self.logger.info("🌙 Starting scheduled midnight upload")
                    await self.uploadAllFiles()
                }
                
                // Setup next day's timer
                self.setupMidnightUpload()
            }
        }
    }
    
    private func startHeartbeat() {
        Self.logger.info("💓 Starting heartbeat timer")
        // Send initial heartbeat
        Task {
            await sendHeartbeat()
        }
        
        // Setup timer for subsequent heartbeats
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
                Self.logger.info("💓 Heartbeat sent successfully")
            } else {
                Self.logger.warning("⚠️ Heartbeat failed with status: \(httpResponse.statusCode)")
            }
        } catch {
            Self.logger.error("❌ Heartbeat error: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func createNewHourlyFile(context: NSManagedObjectContext, for date: Date) async {
        // Get start of the minute for this date
        let startOfMinute = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date))!
        let endOfMinute = calendar.date(byAdding: .minute, value: 1, to: startOfMinute)!
        
        // Check if we already have a file for this minute
        let request: NSFetchRequest<HourlyFile> = HourlyFile.fetchRequest()
        request.predicate = NSPredicate(format: "startTime == %@", startOfMinute as NSDate)
        request.fetchLimit = 1
        
        do {
            // If file exists for this minute, use it
            if let existingFile = try context.fetch(request).first {
                currentHourlyFile = existingFile
                await updateBufferSize()
                Self.logger.info("📂 Using existing file for minute: \(String(describing: existingFile.fileName))")
                return
            }
        } catch {
            Self.logger.error("❌ Error checking for existing file: \(String(describing: error.localizedDescription))")
        }
        
        // Create new file if none exists
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
            // Self.logger.info("📁 Created new minute file: \(String(describing: hourlyFile.fileName))")
        } catch {
            Self.logger.error("❌ Error creating minute file: \(String(describing: error.localizedDescription))")
        }
    }
    
    @MainActor
    func getFileForDate(_ date: Date) async -> HourlyFile {
        let context = PersistenceController.shared.container.viewContext
        
        // If we have a current file, check if the date belongs in it
        if let current = currentHourlyFile,
           let startTime = current.startTime,
           let endTime = current.endTime,
           date >= startTime && date < endTime {
            return current
        }
        
        // No current file or date doesn't belong in it - create new file
        await createNewHourlyFile(context: context, for: date)
        return currentHourlyFile!
    }
    
    private func updateBufferSize() async {
        guard let currentFile = currentHourlyFile,
              let points = currentFile.points else {
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
        // Only count files that have points and aren't completed
        request.predicate = NSPredicate(format: "uploadStatus != %@ AND self != %@ AND points.@count > 0", "completed", currentHourlyFile ?? 0)
        
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
        
        Self.logger.info("📤 Starting upload of completed files")
        
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<HourlyFile> = HourlyFile.fetchRequest()
        request.predicate = NSPredicate(format: "uploadStatus != %@ AND self != %@ AND points.@count > 0", "completed", currentHourlyFile ?? 0)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \HourlyFile.startTime, ascending: true)]
        
        do {
            let filesToUpload = try context.fetch(request)
            Self.logger.info("📦 Found \(String(describing: filesToUpload.count)) files with points to upload")
            
            if filesToUpload.isEmpty {
                uploadError = NSError(
                    domain: "com.trace",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No files ready for upload."]
                )
                Self.logger.info("ℹ️ No files to upload")
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
                    
                    // Clear points after successful upload
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
                Self.logger.info("✅ Successfully processed all files")
                lastUploadAttempt = Date()  // Only update last attempt time after successful upload
            }
        } catch {
            Self.logger.error("❌ Error during upload: \(String(describing: error.localizedDescription))")
            uploadError = NSError(
                domain: "com.trace",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 500"]
            )
        }
    }
    
    private func uploadFile(_ file: HourlyFile) async -> Error? {
        guard let url = URL(string: apiEndpoint) else {
            return NSError(
                domain: "com.trace",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 400"]
            )
        }
        
        let points = file.points?.allObjects as? [LocationPoint] ?? []
        if points.isEmpty {
            Self.logger.info("⚠️ Skipping file with no points")
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        guard let jsonData = try? encoder.encode(payload) else {
            return NSError(
                domain: "com.trace",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 400"]
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return NSError(
                    domain: "com.trace",
                    code: 502,
                    userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 502"]
                )
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                return nil
            } else {
                return NSError(
                    domain: "com.trace",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP \(httpResponse.statusCode)"]
                )
            }
        } catch {
            return NSError(
                domain: "com.trace",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 503"]
            )
        }
    }
} 
