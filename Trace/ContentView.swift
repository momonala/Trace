//
//  ContentView.swift
//  Trace
//
//  Created by Mohit Nalavadi on 16.04.25.
//

import SwiftUI
import CoreData
import MapKit

// Custom Map View
struct MapView: UIViewRepresentable {
    private static let logger = LoggerUtil(category: "mapView")
    
    let region: MKCoordinateRegion
    let paths: [[MapCoordinate]]
    let isTrackingEnabled: Bool
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
        view.setRegion(region, animated: true)
        view.userTrackingMode = isTrackingEnabled ? .follow : .none
        
        // Only redraw polylines if paths have changed
        let currentHash = calculatePathsHash()
        if context.coordinator.lastCoordinatesHash != currentHash {
            context.coordinator.lastCoordinatesHash = currentHash
            
            // Remove existing overlays
            view.removeOverlays(view.overlays)

            var validPathsCount = 0
            var totalPoints = 0
            for path in paths {
                guard path.count >= 2 else { continue }

                let coordinates = path.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                view.addOverlay(polyline)
                validPathsCount += 1
                totalPoints += coordinates.count
            }

            Self.logger.info("📍 Plotting \(totalPoints) points in \(validPathsCount) paths")

            if !paths.isEmpty, validPathsCount == 0 {
                Self.logger.info("⚠️ Received \(paths.count) paths, but none had enough points to render")
            }

            // Notify that plotting is complete after a short delay to allow rendering
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: NSNotification.Name("PlottingComplete"), object: nil)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var lastCoordinatesHash: Int = 0
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .orange
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer()
        }
    }
} 

struct ContentView: View {
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
                    region: region,
                    paths: displayedPaths,
                    isTrackingEnabled: isMapTrackingEnabled,
                    lookbackDays: locationManager.lookbackDays
                )
                .edgesIgnoringSafeArea(.all)
                
                // Stats Panel overlay
                VStack {
                    HStack {
                        StatsPanel(displayedPaths: $displayedPaths)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(10)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                    }
                    .padding(.top, 8)
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
        }
        .onChange(of: locationManager.currentLocation) { _, _ in
            autoFocusOnStartupIfNeeded()
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
    @State private var currentTime = Date()
    @State private var showUploadError = false
    @State private var showRefreshError = false
    @State private var isLoadingCoordinates = false
    @State private var isPlottingCoordinates = false
    @Binding var displayedPaths: [[MapCoordinate]]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
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
                        await locationManager.refreshMapData()
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
        .onReceive(timer) { _ in
            currentTime = Date()
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
