import CoreLocation
import CoreMotion
import SwiftUI
import CoreData
import ActivityKit

struct MapCoordinate: Decodable {
    let timestamp: String
    let latitude: Double
    let longitude: Double
}

struct CoordinatesResponse: Decodable {
    let status: String
    let count: Int
    let lookbackHours: Int
    let paths: [[MapCoordinate]]

    private enum CodingKeys: String, CodingKey {
        case status
        case count
        case lookbackHours = "lookback_hours"
        case paths
    }
}

@Observable
@MainActor
class LocationManager: NSObject {
    static let shared = LocationManager()
    private static let logger = LoggerUtil(category: "locationManager")

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let fileManager = ServerAPIManager.shared
    private let audioManager = AudioManager.shared

    // Live Activity
    private var liveActivity: Activity<TraceWidgetsAttributes>?

    // Non-persisted properties
    var currentLocation: CLLocation?
    var isTracking = false
    var currentMotionType: String = "stationary"
    var isTrackingMotionType = false
    var error: Error?
    var mapRefreshError: Error?
    var pointsLast24h: Int = 0
    var pointsLabel = "Points 0d"
    var mapPaths: [[MapCoordinate]] = []
    var lastHeartbeatTimestamp: Date? = nil

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

    // Timer state
    private var startTimeForEstimate: Date?
    private var motionStartTime: Date?
    private var motionCheckTimer: Timer?
    private enum TimerTargetState {
        case motion
        case stationary
    }
    private var targetState: TimerTargetState?

    private override init() {
        let savedAccuracy = UserDefaults.standard.double(forKey: "minimumAccuracy")
        minimumAccuracy = savedAccuracy != 0 ? savedAccuracy : 150.0

        let savedLookback = UserDefaults.standard.double(forKey: "lookbackDays")
        lookbackDays = savedLookback != 0 ? savedLookback : 1.0

        let savedMotionSeconds = UserDefaults.standard.double(forKey: "requiredMotionSeconds")
        requiredMotionSeconds = savedMotionSeconds != 0 ? savedMotionSeconds : 3.0

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

        // Start with significant location changes
        switchToSignificantLocationChanges()
        Self.logger.info("⏳ Started with significant location changes...")

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

    @objc private func handleAppTermination() {
        // Use a semaphore to block briefly so the async end can complete before the process dies
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            if let activity = liveActivity {
                await activity.end(nil, dismissalPolicy: .immediate)
                liveActivity = nil
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    deinit {
        audioManager.stopPlayingInBackground()
        NotificationCenter.default.removeObserver(self)
    }

    func refreshMapData() async {
        mapRefreshError = nil

        let lookbackHours: Int
        if lookbackDays == 0 {
            let calendar = Calendar.current
            let now = Date()
            let midnight = calendar.startOfDay(for: now)
            let hoursSinceMidnight = Int(ceil(now.timeIntervalSince(midnight) / 3600))
            lookbackHours = hoursSinceMidnight
            pointsLabel = "Points Today"
        } else {
            lookbackHours = Int(lookbackDays * 24)
            pointsLabel = "Points \(Int(lookbackDays))d"
        }

        guard let url = URL(string: "\(ServerAPIManager.shared.serverBaseURL)/coordinates") else {
            let error = NSError(domain: "com.trace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 400"])
            Self.logger.error("❌ \(error.localizedDescription)")
            mapRefreshError = error
            return
        }

        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [
            URLQueryItem(name: "lookback_hours", value: String(lookbackHours))
        ]

        guard let finalURL = urlComponents?.url else {
            let error = NSError(domain: "com.trace", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP 400"])
            Self.logger.error("❌ \(error.localizedDescription)")
            mapRefreshError = error
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: finalURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                let error = NSError(domain: "com.trace", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                Self.logger.error("❌ \(error.localizedDescription)")
                mapRefreshError = error
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let error = NSError(domain: "com.trace", code: 4, userInfo: [NSLocalizedDescriptionKey: "Server error: HTTP \(httpResponse.statusCode)"])
                Self.logger.error("❌ \(error.localizedDescription)")
                mapRefreshError = error
                return
            }

            let decoder = JSONDecoder()
            let payload = try decoder.decode(CoordinatesResponse.self, from: data)

            if payload.status != "success" {
                let error = NSError(domain: "com.trace", code: 6, userInfo: [NSLocalizedDescriptionKey: "Server returned error status"])
                Self.logger.error("❌ \(error.localizedDescription)")
                mapRefreshError = error
                return
            }

            pointsLast24h = payload.count
            mapPaths = payload.paths
            Self.logger.info(
                "📍 Loaded \(payload.count) points across \(payload.paths.count) paths from API (lookback: \(payload.lookbackHours)h)"
            )
        } catch {
            Self.logger.error("❌ Map refresh failed: \(error.localizedDescription)")
            mapRefreshError = error
        }
    }

    private func setupMotionManager() {
            motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self = self else { return }
                if let activity = activity {
                let newMotionType = activity.cycling ? "cycling" :
                    activity.automotive ? "automotive" :
                        activity.walking ? "walking" :
                        activity.running ? "running" :
                    activity.stationary ? "stationary" :
                    activity.unknown ? "unknown" : "unknown"

                if newMotionType != self.currentMotionType {
                    self.currentMotionType = newMotionType
                    self.handleMotionTypeChange(newMotionType)
                }
            }
        }
    }

    private func handleMotionTypeChange(_ motionType: String) {
        let shouldTrack = ["cycling", "walking", "automotive", "running", "unknown"].contains(motionType)
        isTrackingMotionType = shouldTrack

        if shouldTrack {
            if requiredMotionSeconds == 0 {
                switchToContinuousUpdates()
                Self.logger.info("🏃‍♂️ Motion detected (\(motionType)), starting updates immediately")
            } else {
                startStateTimer(targetState: .motion, currentState: motionType)
            }
        } else {
            if requiredMotionSeconds == 0 {
                stopMotionTimer()
                switchToSignificantLocationChanges()
                Self.logger.info("🛑 Motion stopped (\(motionType)), switching to significant changes")
            } else {
                startStateTimer(targetState: .stationary, currentState: motionType)
            }
        }
    }

    private func startStateTimer(targetState: TimerTargetState, currentState: String) {
        stopMotionTimer()

        self.targetState = targetState
        motionStartTime = Date()
        motionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self,
                      let startTime = self.motionStartTime,
                      let targetState = self.targetState else {
                    timer.invalidate()
                    return
                }

                let duration = Date().timeIntervalSince(startTime)
                if duration >= self.requiredMotionSeconds {
                    self.stopMotionTimer()

                    switch targetState {
                    case .motion:
                        self.switchToContinuousUpdates()
                        Self.logger.info("🏃‍♂️ Motion (\(currentState)) sustained for \(Int(duration))s, starting updates")
                    case .stationary:
                        self.switchToSignificantLocationChanges()
                        Self.logger.info("🛑 Stationary sustained for \(Int(duration))s, switching to significant changes")
                    }
                }
            }
        }

        switch targetState {
        case .motion:
            Self.logger.info("⏳ Motion detected (\(currentState)), waiting \(Int(self.requiredMotionSeconds))s before tracking")
        case .stationary:
            Self.logger.info("⏳ Stationary detected, waiting \(Int(self.requiredMotionSeconds))s before stopping")
        }
    }

    private func stopMotionTimer() {
        motionStartTime = nil
        targetState = nil
        motionCheckTimer?.invalidate()
        motionCheckTimer = nil
    }

    func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    private func switchToContinuousUpdates() {
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.startUpdatingLocation()
        isTracking = true
        startTimeForEstimate = Date()
    }

    private func switchToSignificantLocationChanges() {
        locationManager.stopUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        isTracking = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
            Self.logger.info("✅ Location access granted with background updates enabled")
        }
    }

    // MARK: - Live Activity Methods

    private func endAllOrphanedLiveActivities() async {
        for activity in Activity<TraceWidgetsAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            Self.logger.info("🧹 Ended orphaned Live Activity: \(activity.id)")
        }
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("❌ Live Activities are not enabled")
            return
        }

        let attributes = TraceWidgetsAttributes(name: "Trace")
        let contentState = TraceWidgetsAttributes.ContentState(
            latitude: currentLocation?.coordinate.latitude ?? 0,
            longitude: currentLocation?.coordinate.longitude ?? 0,
            altitude: currentLocation?.altitude ?? 0,
            speed: currentLocation?.speed ?? 0,
            age: Int(Date().timeIntervalSince(startTimeForEstimate ?? Date())),
            lastUpdate: currentLocation?.timestamp ?? Date(),
            lastHeartbeat: lastHeartbeatTimestamp,
            isTracking: isTracking
        )

        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: contentState, staleDate: nil),
                pushType: nil
            )
            Self.logger.info("✅ Started Live Activity")
        } catch {
            Self.logger.error("❌ Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    private func updateLiveActivity() {
        guard let activity = liveActivity else { return }

        let contentState = TraceWidgetsAttributes.ContentState(
            latitude: currentLocation?.coordinate.latitude ?? 0,
            longitude: currentLocation?.coordinate.longitude ?? 0,
            altitude: currentLocation?.altitude ?? 0,
            speed: currentLocation?.speed ?? 0,
            age: Int(Date().timeIntervalSince(startTimeForEstimate ?? Date())),
            lastUpdate: currentLocation?.timestamp ?? Date(),
            lastHeartbeat: lastHeartbeatTimestamp,
            isTracking: isTracking
        )

        Task {
            await activity.update(ActivityContent(state: contentState, staleDate: nil), alertConfiguration: nil)
            Self.logger.info("📍 Updated Live Activity")
        }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            liveActivity = nil
            Self.logger.info("✅ Ended Live Activity")
        }
    }

    @MainActor
    func triggerLiveActivityUpdate() {
        updateLiveActivity()
    }

    @MainActor
    func updateLastHeartbeatTimestamp(_ date: Date) {
        lastHeartbeatTimestamp = date
        triggerLiveActivityUpdate()
    }

    public func restartLiveActivity() {
        Task {
            await endAllOrphanedLiveActivities()
            liveActivity = nil
            startLiveActivity()
        }
    }
}

@MainActor
extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        currentLocation = location

        guard isTrackingMotionType else { return }
        guard location.horizontalAccuracy <= minimumAccuracy else { return }

        Task {
            let file = await fileManager.getFileForDate(location.timestamp)

            let context = PersistenceController.shared.container.viewContext
            let locationPoint = LocationPoint(context: context)

            locationPoint.timestamp = location.timestamp
            locationPoint.latitude = location.coordinate.latitude
            locationPoint.longitude = location.coordinate.longitude
            locationPoint.altitude = location.altitude
            locationPoint.speed = location.speed
            locationPoint.horizontalAccuracy = location.horizontalAccuracy
            locationPoint.verticalAccuracy = location.verticalAccuracy
            locationPoint.motionType = currentMotionType
            locationPoint.hourlyFile = file

            do {
                try context.save()
                await fileManager.pointAdded()
            } catch {
                Self.logger.error("❌ Error saving location: \(String(describing: error))")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = error
        Self.logger.error("❌ Location manager error: \(error.localizedDescription)")
        updateLiveActivity()
    }
}
