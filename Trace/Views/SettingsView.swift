import SwiftUI

struct SettingsView: View {
    @Bindable private var fileManager = ServerAPIManager.shared
    @Bindable private var locationManager = LocationManager.shared
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isTestingAPI = false
    @State private var currentTime = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let accuracyOptions = [5.0, 10.0, 20.0, 50.0, 80.0, 100.0, 150.0, 200.0, 250.0, 350.0, 500.0, 1000.0]
    private let lookbackOptions = [0.0, 1.0, 2.0, 3.0, 7.0, 14.0, 30.0, 60.0, 90.0, 180.0, 365.0]
    private let motionDurationOptions = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0, 45.0, 60.0]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Location Settings")) {
                    Picker("Required Motion Duration", selection: $locationManager.requiredMotionSeconds) {
                        ForEach(motionDurationOptions, id: \.self) { seconds in
                            if seconds == 0 {
                                Text("Immediate").tag(seconds)
                            } else {
                                Text("\(Int(seconds))s").tag(seconds)
                            }
                        }
                    }
                    .pickerStyle(.menu)

                    Button(action: {
                        locationManager.restartLiveActivity()
                        alertMessage = "Live Activity restarted!"
                        showingAlert = true
                    }) {
                        Text("Restart Live Activity")
                            .foregroundColor(.blue)
                    }
                }

                Section(header: Text("Map Settings")) {
                    Picker("Minimum Accuracy", selection: $locationManager.minimumAccuracy) {
                        ForEach(accuracyOptions, id: \.self) { meters in
                            Text("\(Int(meters))m").tag(meters)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("History Lookback", selection: $locationManager.lookbackDays) {
                        ForEach(lookbackOptions, id: \.self) { days in
                            let date = Calendar.current.date(byAdding: .day, value: -Int(days), to: Date())!
                            let dateStr = date.formatted(.dateTime.day().month(.abbreviated))
                            if days == 0 {
                                Text("Today").tag(days)
                            } else if days == 1 {
                                Text("1 day (\(dateStr))").tag(days)
                            } else {
                                Text("\(Int(days)) days (\(dateStr))").tag(days)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(header: Text("Upload Settings")) {
                    Toggle("Auto-Upload Files", isOn: $fileManager.isAutoUploadEnabled)
                        .help("Automatically attempts to upload files every minute when new files are created")

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
        return String(format: "%02d:%02d ago", hours, minutes)
    }
}

#Preview {
    SettingsView()
}
