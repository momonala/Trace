import SwiftUI

struct SettingsView: View {
    @StateObject private var fileManager = ServerAPIManager.shared
    @StateObject private var locationManager = LocationManager.shared
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isTestingAPI = false
    @State private var currentTime = Date()
    @Binding var displayedCoordinates: [(timestamp: String, latitude: Double, longitude: Double, accuracy: Double)]
    
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let accuracyOptions = [5.0, 10.0, 20.0, 50.0, 80.0, 100.0, 150.0, 200.0, 250.0, 350.0, 500.0, 1000.0]
    private let lookbackOptions = [0.0, 1.0, 2.0, 3.0, 7.0, 14.0, 30.0, 60.0, 90.0, 180.0, 365.0]
    private let pathLengthOptions = [5.0, 10.0, 20.0, 40.0, 50.0, 100.0]
    private let motionDurationOptions = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0, 45.0, 60.0]
    private let maxDistanceOptions = [5, 10, 20, 50, 75, 90, 100, 200, 300, 500]
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Location Settings")) {
                    Picker("Required Motion Duration", selection: .init(
                        get: { locationManager.requiredMotionSeconds },
                        set: { locationManager.setRequiredMotionSeconds($0) }
                    )) {
                        ForEach(motionDurationOptions, id: \.self) { seconds in
                            if seconds == 0 {
                                Text("Immediate")
                                    .tag(seconds)
                            } else {
                                Text("\(Int(seconds))s")
                                    .tag(seconds)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Section(header: Text("Map Settings")) {
                    Picker("Minimum Accuracy", selection: .init(
                        get: { locationManager.minimumAccuracy },
                        set: { locationManager.setMinimumAccuracy($0) }
                    )) {
                        ForEach(accuracyOptions, id: \.self) { meters in
                            Text("\(Int(meters))m")
                                .tag(meters)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker("Maximum Distance", selection: .init(
                        get: { locationManager.maxDistance },
                        set: { locationManager.setMaxDistance($0) }
                    )) {
                        ForEach(maxDistanceOptions, id: \.self) { meters in
                            Text("\(meters)m")
                                .tag(meters)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker("History Lookback", selection: .init(
                        get: { locationManager.lookbackDays },
                        set: { locationManager.setLookbackDays($0) }
                    )) {
                        ForEach(lookbackOptions, id: \.self) { days in
                            let date = Calendar.current.date(byAdding: .day, value: -Int(days), to: currentTime)!
                            let dateStr = date.formatted(.dateTime.day().month(.abbreviated))
                            
                            if days == 0 {
                                Text("Today")
                                    .tag(days)
                            } else if days == 1 {
                                Text("1 day (\(dateStr))")
                                    .tag(days)
                            } else {
                                Text("\(Int(days)) days (\(dateStr))")
                                    .tag(days)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker("Minimum Path Length", selection: .init(
                        get: { locationManager.minimumPointsPerSegment },
                        set: { locationManager.setMinimumPointsPerSegment($0) }
                    )) {
                        ForEach(pathLengthOptions, id: \.self) { points in
                            Text("\(Int(points)) points")
                                .tag(points)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Section(header: Text("Upload Settings")) {
                    Toggle("Auto-Upload at Midnight", isOn: $fileManager.isAutoUploadEnabled)
                    
                    if let lastUpload = fileManager.lastUploadAttempt {
                        HStack {
                            Text("Last Sent")
                            Spacer()
                            Text(lastUpload.formatted(date: .numeric, time: .shortened))
                                .font(.system(.caption, design: .monospaced))
                            Text("(\(timeSinceLastUpload(lastUpload)))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Server Settings")) {
                    HStack {
                        Text(fileManager.serverBaseURL)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: testAPI) {
                        if isTestingAPI {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTestingAPI)
                }
            }
            .navigationTitle("Settings")
            .alert("API Test", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onReceive(timer) { _ in
                currentTime = Date()
            }
        }
    }
    
    private func testAPI() {
        isTestingAPI = true
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: ServerAPIManager.shared.statusURL)
                
                isTestingAPI = false
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    alertMessage = "Invalid server response"
                    showingAlert = true
                    return
                }
                
                if (200...299).contains(httpResponse.statusCode) {
                    if let statusString = String(data: data, encoding: .utf8) {
                        alertMessage = "Connection successful!\nServer status: \(statusString)"
                    } else {
                        alertMessage = "Connection successful!"
                    }
                } else {
                    alertMessage = "Server error: HTTP \(httpResponse.statusCode)"
                }
            } catch {
                alertMessage = "Connection failed: \(error.localizedDescription)"
            }
            
            isTestingAPI = false
            showingAlert = true
        }
    }
    
    private func timeSinceLastUpload(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date, to: currentTime)
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0
        let seconds = components.second ?? 0
        return String(format: "%02d:%02d:%02d ago", hours, minutes, seconds)
    }
} 

#Preview {
    SettingsView(displayedCoordinates: .constant([]))
}
