//
//  ContentView.swift
//  Trace
//
//  Created by Mohit Nalavadi on 16.04.25.
//

import SwiftUI
import CoreData
import MapKit

// Distinct subclass so rendererFor can apply a different style without extra state
final class GhostPolyline: MKPolyline {}

// Overlay carrying the full flattened path for the moving highlight animation
class GhostHighlightOverlay: NSObject, MKOverlay {
    var windowSize: Int { max(20, flatPath.count / 10) }

    let flatPath: [CLLocationCoordinate2D]
    let segmentStarts: Set<Int>  // indices where a new segment begins (skip drawing across gap)
    var progress: Double = 0     // 0.0→1.0; written on main, read on MapKit draw thread (benign race for animation)

    init(segments: [[CLLocationCoordinate2D]], randomOffset: Bool = false) {
        var flat: [CLLocationCoordinate2D] = []
        var starts = Set<Int>([0])
        for segment in segments {
            if !flat.isEmpty { starts.insert(flat.count) }
            flat.append(contentsOf: segment)
        }
        flatPath = flat
        segmentStarts = starts
        super.init()
        if randomOffset { progress = Double.random(in: 0..<1) }
    }

    var coordinate: CLLocationCoordinate2D {
        flatPath.isEmpty ? CLLocationCoordinate2D() : flatPath[flatPath.count / 2]
    }

    var boundingMapRect: MKMapRect {
        guard !flatPath.isEmpty else { return .null }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for coord in flatPath {
            let p = MKMapPoint(coord)
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = 5000.0
        return MKMapRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }

    // Bounding rect of only the current window — used to limit the redraw region so MapKit
    // renders at full resolution rather than tiling the entire overlay coarsely.
    func currentWindowMapRect() -> MKMapRect {
        let total = flatPath.count
        guard total >= 2 else { return .null }
        let headIdx = min(Int(progress * Double(total)), total - 1)
        let tailIdx = max(0, headIdx - windowSize)
        guard headIdx > tailIdx else { return .null }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for coord in flatPath[tailIdx...headIdx] {
            let p = MKMapPoint(coord)
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = 2000.0
        return MKMapRect(x: minX - pad, y: minY - pad,
                         width: maxX - minX + pad * 2,
                         height: maxY - minY + pad * 2)
    }
}

// Renders a fading gradient window (transparent → opaque orange) that sweeps along the highlight path
final class GhostHighlightRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let ghostOverlay = overlay as? GhostHighlightOverlay else { return }
        let path = ghostOverlay.flatPath
        let total = path.count
        guard total >= 2 else { return }

        let headIdx = min(Int(ghostOverlay.progress * Double(total)), total - 1)
        let tailIdx = max(0, headIdx - ghostOverlay.windowSize)
        guard headIdx > tailIdx else { return }

        context.setLineWidth(CGFloat(4.0 / zoomScale))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for i in tailIdx..<headIdx {
            guard !ghostOverlay.segmentStarts.contains(i + 1) else { continue }
            let alpha = CGFloat(i - tailIdx + 1) / CGFloat(headIdx - tailIdx)
            context.setStrokeColor(UIColor(red: 1, green: 0.44, blue: 0, alpha: alpha).cgColor)
            let p1 = point(for: MKMapPoint(path[i]))
            let p2 = point(for: MKMapPoint(path[i + 1]))
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
    }
}

// Custom Map View
struct MapView: UIViewRepresentable {
    private static let logger = LoggerUtil(category: "mapView")

    @Binding var region: MKCoordinateRegion
    @Binding var isTrackingEnabled: Bool
    let paths: [[MapCoordinate]]
    let todayPath: [[CLLocationCoordinate2D]]
    let lookbackDays: Double
    
    private func calculatePathsHash() -> Int {
        let pointCount = paths.reduce(0) { $0 + $1.count }
        guard pointCount > 0, let first = paths.first?.first, let last = paths.last?.last else { return 0 }

        return pointCount
            + Int(first.latitude * 1_000_000)
            + Int(first.longitude * 1_000_000)
            + Int(last.latitude * 1_000_000)
            + Int(last.longitude * 1_000_000)
            + Int(lookbackDays * 10_000)
    }
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        return mapView
    }
    
    func updateUIView(_ view: MKMapView, context: Context) {
        if !context.coordinator.isUserInteracting {
            view.setRegion(region, animated: true)
        }
        view.userTrackingMode = isTrackingEnabled ? .follow : .none
        
        // Ghost trail — today's local path (or server data after Refresh Map)
        // Managed independently so main path redraws don't wipe the ghost and vice-versa.
        let todayPointCount = todayPath.reduce(0) { $0 + $1.count }
        if context.coordinator.lastTodayPointCount != todayPointCount {
            context.coordinator.lastTodayPointCount = todayPointCount

            // Faint base polylines
            view.overlays.filter { $0 is GhostPolyline }.forEach { view.removeOverlay($0) }
            for segment in todayPath where segment.count >= 2 {
                view.addOverlay(GhostPolyline(coordinates: segment, count: segment.count), level: .aboveRoads)
            }

            // Today highlight — remove previous and add fresh
            view.overlays
                .filter { $0 is GhostHighlightOverlay }
                .forEach { view.removeOverlay($0) }
            let todayHighlight = GhostHighlightOverlay(segments: todayPath)
            if !todayHighlight.flatPath.isEmpty {
                view.addOverlay(todayHighlight, level: .aboveRoads)
                context.coordinator.startHighlightAnimationIfNeeded()
            }
        }

        // Server-fetched paths — only redraw when data changes
        let currentHash = calculatePathsHash()
        if context.coordinator.lastCoordinatesHash != currentHash {
            context.coordinator.lastCoordinatesHash = currentHash

            // Remove old server polylines, leave ghost trail in place
            view.overlays.filter { !($0 is GhostPolyline) && !($0 is GhostHighlightOverlay) }.forEach { view.removeOverlay($0) }

            var validPathsCount = 0
            var totalPoints = 0
            for path in paths {
                guard path.count >= 2 else { continue }
                let coordinates = path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                view.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
                validPathsCount += 1
                totalPoints += coordinates.count
            }

            Self.logger.info("📍 Plotting \(totalPoints) points in \(validPathsCount) paths")

            if !paths.isEmpty, validPathsCount == 0 {
                Self.logger.info("⚠️ Received \(paths.count) paths, but none had enough points to render")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: NSNotification.Name("PlottingComplete"), object: nil)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region, isTrackingEnabled: $isTrackingEnabled)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var lastCoordinatesHash: Int = 0
        var lastTodayPointCount: Int = 0
        var isUserInteracting = false
        private var regionBinding: Binding<MKCoordinateRegion>
        private var trackingBinding: Binding<Bool>

        // Weak table so renderers are released automatically when MapKit removes their overlays
        private var highlightRenderers = NSHashTable<GhostHighlightRenderer>.weakObjects()
        private var displayLink: CADisplayLink?

        init(region: Binding<MKCoordinateRegion>, isTrackingEnabled: Binding<Bool>) {
            self.regionBinding = region
            self.trackingBinding = isTrackingEnabled
        }

        deinit {
            displayLink?.invalidate()
        }

        func startHighlightAnimationIfNeeded() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(animationTick))
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            displayLink?.add(to: .main, forMode: .common)
        }

        @objc private func animationTick() {
            guard let link = displayLink else { return }
            for renderer in highlightRenderers.allObjects {
                guard let overlay = renderer.overlay as? GhostHighlightOverlay,
                      !overlay.flatPath.isEmpty else { continue }
                overlay.progress += link.duration / 17.5
                if overlay.progress >= 1.0 { overlay.progress = 0.0 }
                renderer.setNeedsDisplay(overlay.currentWindowMapRect())
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if !animated {
                isUserInteracting = true
                trackingBinding.wrappedValue = false
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isUserInteracting = false
            let current = regionBinding.wrappedValue
            let updated = mapView.region
            let latDiff = abs(updated.center.latitude - current.center.latitude)
            let lonDiff = abs(updated.center.longitude - current.center.longitude)
            if latDiff > 0.00001 || lonDiff > 0.00001 {
                regionBinding.wrappedValue = updated
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let highlight = overlay as? GhostHighlightOverlay {
                let renderer = GhostHighlightRenderer(overlay: highlight)
                highlightRenderers.add(renderer)
                return renderer
            }
            if let ghost = overlay as? GhostPolyline {
                let renderer = MKPolylineRenderer(polyline: ghost)
                renderer.strokeColor = UIColor(red: 1, green: 0.44, blue: 0, alpha: 0.5)
                renderer.lineWidth = 2
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 1, green: 0.44, blue: 0, alpha: 0.85)
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer()
        }
    }
} 

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationManager = LocationManager.shared
    @State private var selectedTab = 0
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.507328, longitude: 13.393625),
        span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
    )
    @State private var isMapTrackingEnabled = false
    @State private var hasAutoFocusedOnStartup = false
    @State private var displayedPaths: [[MapCoordinate]] = []
    
    private func focusOnCurrentLocation() {
        guard let location = locationManager.currentLocation else { return }
        withAnimation {
            region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            isMapTrackingEnabled = true
        }
    }
    
    private func autoFocusOnStartupIfNeeded() {
        guard !hasAutoFocusedOnStartup, locationManager.currentLocation != nil else { return }
        hasAutoFocusedOnStartup = true
        focusOnCurrentLocation()
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Live View Tab with Daily Path
            ZStack {
                // Map as full background with daily path
                MapView(
                    region: $region,
                    isTrackingEnabled: $isMapTrackingEnabled,
                    paths: displayedPaths,
                    todayPath: locationManager.todayPath,
                    lookbackDays: locationManager.lookbackDays
                )
                .edgesIgnoringSafeArea(.all)
                
                // Stats Panel overlay
                VStack {
                    HStack {
                        StatsPanel(displayedPaths: $displayedPaths, region: $region)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(10)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                    }
                    .padding(.top, 2)
                    .padding(.horizontal)
                    
                    Spacer()
                        .frame(height: UIScreen.main.bounds.height * 0.3)
                    
                    // Location tracking button
                    HStack {
                        Spacer()
                        Button(action: focusOnCurrentLocation) {
                            Image(systemName: "location.fill")
                                .foregroundColor(isMapTrackingEnabled ? .blue : .white)
                                .padding(12)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                        .padding(.trailing)
                    }
                    
                    Spacer()
                }
                .edgesIgnoringSafeArea(.bottom)
            }
            .tabItem {
                Label("Live", systemImage: "location.fill")
            }
            .tag(0)
            
            // Settings Tab
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(1)
        }
        .onAppear {
            // Set tab bar appearance
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            
            appearance.stackedLayoutAppearance.selected.iconColor = .white
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
            appearance.stackedLayoutAppearance.normal.iconColor = .white.withAlphaComponent(0.7)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.7)]
            
            UITabBar.appearance().standardAppearance = appearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
            
            locationManager.requestPermissions()
            autoFocusOnStartupIfNeeded()
            Task { await HealthManager.shared.requestPermissionsAndLoad() }
            Task { await locationManager.refreshTodayPath() }
        }
        .onChange(of: locationManager.currentLocation) { _, _ in
            autoFocusOnStartupIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                async let health: Void = HealthManager.shared.refresh()
                async let trail: Void = locationManager.refreshTodayPath()
                _ = await (health, trail)
            }
        }
        // Add gesture recognizer to disable tracking when user interacts with map
        .gesture(
            DragGesture()
                .onChanged { _ in
                    if isMapTrackingEnabled {
                        isMapTrackingEnabled = false
                    }
                }
        )
    }
    
    private var settingsView: some View {
        Form {
            Section(header: Text("Server Status")) {
                if let lastUpload = ServerAPIManager.shared.lastUploadAttempt {
                    HStack {
                        Text("Last Sent")
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(lastUpload.formatted(.dateTime))
                                .font(.footnote)
                            Text(timeSinceLastUpload(lastUpload))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
    
    private func timeSinceLastUpload(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date, to: Date())
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0
        let seconds = components.second ?? 0
        return String(format: "%02d:%02d:%02d ago", hours, minutes, seconds)
    }
}

struct StatsPanel: View {
    @State private var locationManager = LocationManager.shared
    @State private var fileManager = ServerAPIManager.shared
    @State private var healthManager = HealthManager.shared
    @State private var currentTime = Date()
    @State private var showUploadError = false
    @State private var showRefreshError = false
    @State private var isLoadingCoordinates = false
    @State private var isPlottingCoordinates = false
    @Binding var displayedPaths: [[MapCoordinate]]
    @Binding var region: MKCoordinateRegion
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func fmtSteps(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    private func currentRegionBBox() -> MapBoundingBox {
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        return MapBoundingBox(
            minLat: region.center.latitude - halfLat,
            maxLat: region.center.latitude + halfLat,
            minLon: region.center.longitude - halfLon,
            maxLon: region.center.longitude + halfLon
        )
    }
    
    private func formatCoordinates(_ location: CLLocation) -> String {
        let coords = String(format: "%.6f, %.6f", location.coordinate.latitude, location.coordinate.longitude)
        let accuracy = String(format: " ± %.0fm", location.horizontalAccuracy)
        return coords + accuracy
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Coordinates with tracking status
            if let location = locationManager.currentLocation {
                StatsRow(
                    title: "Coordinates",
                    value: formatCoordinates(location),
                    showTrackingStatus: true,
                    isTracking: locationManager.isTracking
                )
            }
            
            Divider()
                .background(Color.white.opacity(0.5))
            
            // Row 2: Speed and Altitude
            if let location = locationManager.currentLocation {
                HStack(spacing: 12) {
                    StatsRow(title: "Speed", value: String(format: "%.1f km/h", location.speed * 3.6))
                    StatsRow(title: "Altitude", 
                            value: String(format: "%.0f ± %.0fm", location.altitude, location.verticalAccuracy))
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.5))
            
            // Row 3: Motion and Age
            HStack(spacing: 12) {
                StatsRow(title: "Motion", value: locationManager.currentMotionType)
                if let lastTime = fileManager.lastPointTime {
                    let timeSince = currentTime.timeIntervalSince(lastTime)
                    StatsRow(title: "Age", value: formatTimeInterval(timeSince))
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.5))
            
            // Row 4: Buffer, Points Today, Files
            HStack(spacing: 12) {
                StatsRow(title: "Buffer", value: "\(fileManager.bufferSize)")
                StatsRow(title: locationManager.pointsLabel, value: "\(locationManager.pointsLast24h)")
                StatsRow(title: "Files Queued", value: "\(fileManager.queuedFiles)")
            }

            // Row 5: Health (today's activity from HealthKit)
            if healthManager.isAvailable {
                Divider()
                    .background(Color.white.opacity(0.5))

                HStack(spacing: 12) {
                    StatsRow(title: "Steps",   value: fmtSteps(healthManager.steps))
                    StatsRow(title: "Kcal",    value: "\(healthManager.kcal)")
                    StatsRow(title: "Km",      value: String(format: "%.1f", healthManager.km))
                    StatsRow(title: "Flights", value: "\(healthManager.flights)")
                }
            }

            // Upload button and error handling
            VStack(spacing: 8) {
                if fileManager.queuedFiles > 0 {
                    Button(action: {
                        Task {
                            await fileManager.uploadAllFiles()
                            showUploadError = fileManager.uploadError != nil
                        }
                    }) {
                        HStack {
                            if fileManager.isUploading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(fileManager.isUploading ? "Uploading..." : "Upload Files")
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .cornerRadius(6)
                    }
                    .disabled(fileManager.isUploading)
                }
                
                Button(action: {
                    Task {
                        isLoadingCoordinates = true
                        let bbox: MapBoundingBox? = locationManager.regionModeEnabled
                            ? currentRegionBBox()
                            : nil
                        await locationManager.refreshMapData(regionBBox: bbox)
                        isLoadingCoordinates = false
                        
                        isPlottingCoordinates = true
                        displayedPaths = locationManager.mapPaths
                        // Add slight delay to allow map to process
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        isPlottingCoordinates = false
                        
                        showRefreshError = locationManager.mapRefreshError != nil
                    }
                }) {
                    Text("Refresh Map")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .cornerRadius(6)
                }
            }
            
            // Status and Error messages
            VStack(spacing: 4) {
                if isLoadingCoordinates {
                    StatusMessage(
                        icon: "loading",
                        message: "Loading coordinates...",
                        color: .blue
                    )
                }
                
                if isPlottingCoordinates {
                    StatusMessage(
                        icon: "loading",
                        message: "Plotting path on map...",
                        color: .orange
                    )
                }
                
                if let error = fileManager.uploadError, showUploadError {
                    ErrorMessage(
                        icon: "arrow.up.circle",
                        message: error.localizedDescription,
                        color: .red,
                        onDismiss: {
                            showUploadError = false
                            fileManager.uploadError = nil
                        }
                    )
                }
                
                if let error = locationManager.mapRefreshError, showRefreshError {
                    ErrorMessage(
                        icon: "arrow.clockwise.circle",
                        message: error.localizedDescription,
                        color: .orange,
                        onDismiss: {
                            showRefreshError = false
                            locationManager.mapRefreshError = nil
                        }
                    )
                }
            }
        }
        .padding(10)
        .foregroundColor(.white)
        .onReceive(timer) { now in
            currentTime = now
        }
    }

    
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        // Handle negative or zero intervals
        if interval <= 0 {
            return "00:00"
        }
        
        let seconds = Int(interval)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        
        if days > 0 {
            // Format: DD:HH:MM:SS
            return String(format: "%d:%02d:%02d:%02d", days, hours, minutes, remainingSeconds)
        } else if hours > 0 {
            // Format: HH:MM:SS
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            // Format: MM:SS
            return String(format: "%02d:%02d", minutes, remainingSeconds)
        }
    }
}

// Updated error message component with auto-dismiss
struct ErrorMessage: View {
    let icon: String
    let message: String
    let color: Color
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(message)
                .font(.caption)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(color.opacity(0.3))
        .cornerRadius(6)
        .transition(.opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(3)) {
                onDismiss()
            }
        }
    }
}

// Add StatusMessage component after ErrorMessage
struct StatusMessage: View {
    let icon: String
    let message: String
    let color: Color
    
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if icon == "loading" {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: color))
                    .scaleEffect(0.8)
            } else {
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(message)
                .font(.caption)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(color.opacity(0.3))
        .cornerRadius(6)
        .transition(.opacity)
    }
}

struct StatsRow: View {
    let title: String
    let value: String
    var showTrackingStatus: Bool = false
    var isTracking: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            HStack {
                Text(value)
                    .font(.callout)
                    .lineLimit(1)
                if showTrackingStatus {
                    Image(systemName: isTracking ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isTracking ? .green : .red)
                        .font(.caption)
                }
            }
        }
    }
}

// Remove commented out Preview
//#Preview {
//    ContentView()
//}
