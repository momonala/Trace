import CoreLocation
import CoreMotion
import SwiftUI
import CoreData
import ActivityKit

struct MapBoundingBox {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
}

enum MotionType: String {
    case walking, running, cycling, automotive, stationary, unknown

    init(_ activity: CMMotionActivity) {
        self = activity.cycling ? .cycling
            : activity.automotive ? .automotive
            : activity.walking ? .walking
            : activity.running ? .running
            : activity.stationary ? .stationary
            : .unknown
    }

    var isMoving: Bool { self != .stationary }
}

private enum TrackingState {
    case idle
    case arming
    case tracking(since: Date)
    case disarming(trackingSince: Date)

    var usesContinuousGPS: Bool {
        switch self {
        case .idle, .arming: false
        case .tracking, .disarming: true
        }
    }

    var trackingSince: Date? {
        switch self {
        case .idle, .arming: nil
        case .tracking(let since), .disarming(let since): since
        }
    }
}

@Observable
@MainActor
class LocationManager: NSObject {
    static let shared = LocationManager()
    private static let logger = LoggerUtil(category: "LocationManager")
    private static let liveActivityMinUpdateInterval: TimeInterval = 3

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let fileManager = ServerAPIManager.shared
    private let audioManager = AudioManager.shared

    // Live Activity
    private var liveActivity: Activity<TraceWidgetsAttributes>?
    private var lastLiveActivityUpdate: Date?

    // Non-persisted properties
    var currentLocation: CLLocation?
    var currentMotionType = MotionType.stationary
    var isTracking: Bool { trackingState.usesContinuousGPS }
    var error: Error?
    var lastHeartbeatTimestamp: Date? = nil
    var todayPath: [[CLLocationCoordinate2D]] = []

    // Persisted settings — didSet writes to UserDefaults
    var minimumAccuracy: Double {
        didSet { UserDefaults.standard.set(minimumAccuracy, forKey: "minimumAccuracy") }
    }
    var lookbackDays: Double {
        didSet { UserDefaults.standard.set(lookbackDays, forKey: "lookbackDays") }
    }
    var requiredMotionSeconds: Double {
        didSet { UserDefaults.standard.set(requiredMotionSeconds, forKey: "requiredMotionSeconds") }
    }
    var regionModeEnabled: Bool {
        didSet { UserDefaults.standard.set(regionModeEnabled, forKey: "regionModeEnabled") }
    }

    private var trackingState = TrackingState.idle {
        didSet {
            guard oldValue.usesContinuousGPS != trackingState.usesContinuousGPS else { return }
            applyGPSMode()
            updateLiveActivity()
        }
    }
    private var pendingTransition: Task<Void, Never>?

    private override init() {
        let savedAccuracy = UserDefaults.standard.double(forKey: "minimumAccuracy")
        minimumAccuracy = savedAccuracy != 0 ? savedAccuracy : 150.0

        let savedLookback = UserDefaults.standard.double(forKey: "lookbackDays")
        lookbackDays = savedLookback != 0 ? savedLookback : 1.0

        let savedMotionSeconds = UserDefaults.standard.double(forKey: "requiredMotionSeconds")
        requiredMotionSeconds = savedMotionSeconds != 0 ? savedMotionSeconds : 3.0

        regionModeEnabled = UserDefaults.standard.bool(forKey: "regionModeEnabled")

        super.init()

        // Setup location manager
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .fitness
        locationManager.showsBackgroundLocationIndicator = true

        // Setup motion manager and start background audio
        if CMMotionActivityManager.isActivityAvailable() {
            setupMotionManager()
            audioManager.startPlayingInBackground()
        }

        applyGPSMode()
        Self.logger.info("Started with significant location changes...")

        // End any orphaned activities from previous sessions before starting a new one
        Task {
            await endAllOrphanedLiveActivities()
            startLiveActivity()
        }

        // End live activity when app is terminated
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppTermination),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    func refreshTodayPath() async {
        let midnight = Calendar.current.startOfDay(for: Date())
        let hoursSinceMidnight = max(1, Int(ceil(Date().timeIntervalSince(midnight) / 3600)))

        guard let url = URL(string: "\(fileManager.serverBaseURL)/coordinates"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "lookback_hours", value: String(hoursSinceMidnight))]
        guard let finalURL = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: finalURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            let payload = try JSONDecoder().decode(CoordinatesResponse.self, from: data)
            guard payload.status == "success" else { return }
            todayPath = payload.paths.map { seg in
                seg.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            }
            Self.logger.info("Today path loaded: \(payload.count) points")
        } catch {
            Self.logger.error("Today path refresh failed: \(error.localizedDescription)")
        }
    }

    @objc private func handleAppTermination() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        // Blocks so the end can land before the process dies. Detached because a main-actor task
        // can't run while this blocks the main thread, and bounded because the watchdog kills at 5s.
        let ended = DispatchSemaphore(value: 0)
        Task.detached {
            await activity.end(nil, dismissalPolicy: .immediate)
            ended.signal()
        }
        _ = ended.wait(timeout: .now() + 2)
    }

    deinit {
        audioManager.stopPlayingInBackground()
        NotificationCenter.default.removeObserver(self)
    }

    private func lookbackHours() -> Int {
        if lookbackDays == 0 {
            let midnight = Calendar.current.startOfDay(for: Date())
            return Int(ceil(Date().timeIntervalSince(midnight) / 3600))
        }
        return Int(lookbackDays * 24)
    }

    func fetchMapPaths(regionBBox: MapBoundingBox? = nil) async throws -> [[MapCoordinate]] {
        let queryItems: [URLQueryItem]
        if let bbox = regionBBox {
            queryItems = [
                URLQueryItem(name: "min_lat", value: String(bbox.minLat)),
                URLQueryItem(name: "max_lat", value: String(bbox.maxLat)),
                URLQueryItem(name: "min_lon", value: String(bbox.minLon)),
                URLQueryItem(name: "max_lon", value: String(bbox.maxLon)),
            ]
        } else {
            queryItems = [URLQueryItem(name: "lookback_hours", value: String(lookbackHours()))]
        }

        guard var components = URLComponents(string: "\(fileManager.serverBaseURL)/coordinates") else {
            throw URLError(.badURL)
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw URLError(.badURL) }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "com.trace", code: code, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP \(code)"])
            }
            let payload = try JSONDecoder().decode(CoordinatesResponse.self, from: data)
            guard payload.status == "success" else {
                throw NSError(domain: "com.trace", code: 6, userInfo: [NSLocalizedDescriptionKey: "Server returned error status"])
            }
            let modeDescription = regionBBox != nil
                ? "region"
                : "lookback: \(payload.lookbackHours.map { "\($0)h" } ?? "?")"
            Self.logger.info(
                "Loaded \(payload.count) points across \(payload.paths.count) paths from API (\(modeDescription))"
            )
            return payload.paths
        } catch {
            Self.logger.error("Map refresh failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func setupMotionManager() {
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            let motionType = MotionType(activity)
            guard motionType != self.currentMotionType else { return }
            self.currentMotionType = motionType
            self.handleMotionTypeChange(motionType)
        }
    }

    private func handleMotionTypeChange(_ motionType: MotionType) {
        pendingTransition?.cancel()
        pendingTransition = nil

        switch (trackingState, motionType.isMoving) {
        case (.idle, true), (.arming, true):
            arm(for: motionType)
        case (.tracking, true):
            break
        case (.disarming(let since), true):
            trackingState = .tracking(since: since)
            Self.logger.info("Motion resumed (\(motionType.rawValue)), staying on continuous updates")
        case (.idle, false):
            break
        case (.arming, false):
            trackingState = .idle
            Self.logger.info("Stationary before motion was sustained, staying on significant changes")
        case (.tracking(let since), false), (.disarming(let since), false):
            disarm(trackingSince: since)
        }
    }

    private func arm(for motionType: MotionType) {
        guard requiredMotionSeconds > 0 else {
            trackingState = .tracking(since: Date())
            Self.logger.info("Motion detected (\(motionType.rawValue)), starting updates immediately")
            return
        }
        trackingState = .arming
        Self.logger.info("Motion detected (\(motionType.rawValue)), waiting \(Int(requiredMotionSeconds))s before tracking")
        schedulePendingTransition()
    }

    private func disarm(trackingSince: Date) {
        guard requiredMotionSeconds > 0 else {
            trackingState = .idle
            Self.logger.info("Motion stopped, switching to significant changes")
            return
        }
        trackingState = .disarming(trackingSince: trackingSince)
        Self.logger.info("Stationary detected, waiting \(Int(requiredMotionSeconds))s before stopping")
        schedulePendingTransition()
    }

    private func schedulePendingTransition() {
        let delay = requiredMotionSeconds
        pendingTransition = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.completePendingTransition()
        }
    }

    private func completePendingTransition() {
        pendingTransition = nil
        switch trackingState {
        case .arming:
            trackingState = .tracking(since: Date())
            Self.logger.info("Motion (\(currentMotionType.rawValue)) sustained, starting updates")
        case .disarming:
            trackingState = .idle
            Self.logger.info("Stationary sustained, switching to significant changes")
        case .idle, .tracking:
            break
        }
    }

    func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    private func applyGPSMode() {
        if trackingState.usesContinuousGPS {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
            Self.logger.info("Location access granted with background updates enabled")
        }
    }

    // MARK: - Live Activity Methods

    private func endAllOrphanedLiveActivities() async {
        for activity in Activity<TraceWidgetsAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            Self.logger.info("Ended orphaned Live Activity: \(activity.id)")
        }
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.warning("Live Activities are not enabled")
            return
        }

        let attributes = TraceWidgetsAttributes(name: "Trace")
        let contentState = makeLiveActivityContentState()

        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: contentState, staleDate: nil),
                pushType: nil
            )
            Self.logger.info("Started Live Activity")
        } catch {
            Self.logger.error("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    private func makeLiveActivityContentState() -> TraceWidgetsAttributes.ContentState {
        let health = HealthManager.shared
        return TraceWidgetsAttributes.ContentState(
            latitude: currentLocation?.coordinate.latitude ?? 0,
            longitude: currentLocation?.coordinate.longitude ?? 0,
            altitude: currentLocation?.altitude ?? 0,
            speed: currentLocation?.speed ?? 0,
            age: Int(Date().timeIntervalSince(trackingState.trackingSince ?? Date())),
            lastUpdate: currentLocation?.timestamp ?? Date(),
            lastHeartbeat: lastHeartbeatTimestamp,
            isTracking: isTracking,
            steps: health.steps,
            kcal: health.kcal,
            km: health.km,
            flights: health.flights,
            healthAvailable: health.isAvailable
        )
    }

    func updateLiveActivity() {
        guard let activity = liveActivity else { return }
        lastLiveActivityUpdate = Date()

        let contentState = makeLiveActivityContentState()

        Task {
            await activity.update(ActivityContent(state: contentState, staleDate: nil), alertConfiguration: nil)
        }
    }

    private func updateLiveActivityIfDue() {
        let sinceLastUpdate = Date().timeIntervalSince(lastLiveActivityUpdate ?? .distantPast)
        guard sinceLastUpdate >= Self.liveActivityMinUpdateInterval else { return }
        updateLiveActivity()
    }

    @MainActor
    func updateLastHeartbeatTimestamp(_ date: Date) {
        lastHeartbeatTimestamp = date
        updateLiveActivityIfDue()
    }

    public func restartLiveActivity() {
        Task {
            await endAllOrphanedLiveActivities()
            liveActivity = nil
            startLiveActivity()
        }
    }
}

extension LocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        currentLocation = location
        updateLiveActivityIfDue()

        guard currentMotionType.isMoving else { return }
        guard location.horizontalAccuracy <= minimumAccuracy else { return }

        let motionType = currentMotionType
        Task {
            let file = await fileManager.getFileForDate(location.timestamp)
            let fileObjectID = file.objectID

            let bgContext = PersistenceController.shared.newBackgroundContext()
            do {
                try await bgContext.perform {
                    guard let fileInBg = try bgContext.existingObject(with: fileObjectID) as? HourlyFile else {
                        throw NSError(domain: "com.trace", code: 0, userInfo: [NSLocalizedDescriptionKey: "File not found in background context"])
                    }
                    let locationPoint = LocationPoint(context: bgContext)
                    locationPoint.timestamp = location.timestamp
                    locationPoint.latitude = location.coordinate.latitude
                    locationPoint.longitude = location.coordinate.longitude
                    locationPoint.altitude = location.altitude
                    locationPoint.speed = location.speed
                    locationPoint.horizontalAccuracy = location.horizontalAccuracy
                    locationPoint.verticalAccuracy = location.verticalAccuracy
                    locationPoint.motionType = motionType.rawValue
                    locationPoint.hourlyFile = fileInBg
                    try bgContext.save()
                }
                await fileManager.pointAdded()
            } catch {
                Self.logger.error("Error saving location: \(String(describing: error))")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = error
        Self.logger.error("Location manager error: \(error.localizedDescription)")
        updateLiveActivityIfDue()
    }
}
