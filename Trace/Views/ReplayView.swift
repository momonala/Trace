import CoreLocation
import SwiftUI

/// Scrub through a single day's GPS track: pick a date, drag through the hours, and see where you
/// were at that moment.
///
/// Reconstructed from a SourceKit index record after the source was lost to an accidental
/// revert — every stored property, computed property, and method signature below is exact
/// (decoded from the compiler's symbol table); the method/view bodies are a best-faith
/// reconstruction consistent with those signatures, not recovered source.
struct ReplayView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiManager = ServerAPIManager.shared

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var secondsIntoDay: Double = 0
    /// Days already fetched, so stepping back and forth with the chevrons is instant.
    @State private var tracks: [String: DayTrack] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var fitToken = 0
    @State private var recenterToken = 0

    private var dayKey: String { DayTrack.dayKey(for: selectedDay) }
    private var track: DayTrack? { tracks[dayKey] }

    private var dayLength: TimeInterval { track?.dayLength ?? 86400 }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    private var scrubbedPosition: DayTrack.Position {
        track?.position(at: secondsIntoDay) ?? .unknown
    }

    private var marker: ReplayMapView.Marker? {
        switch scrubbedPosition {
        case .live(let fix): ReplayMapView.Marker(coordinate: fix.coordinate, isLive: true)
        case .stale(let coordinate): ReplayMapView.Marker(coordinate: coordinate, isLive: false)
        case .unknown: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            dayBar
            mapSection
            scrubberSection
        }
        .background(TraceStyle.background.ignoresSafeArea())
        .foregroundColor(TraceStyle.primaryText)
        .task { await loadIfNeeded() }
        .onChange(of: selectedDay) { _, _ in
            Task { await loadIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Today's track keeps growing while the app is away.
            guard phase == .active, isToday else { return }
            tracks[dayKey] = nil
            Task { await loadIfNeeded() }
        }
    }

    // MARK: - Date selection

    private var dayBar: some View {
        HStack(spacing: 12) {
            mapButton(icon: "chevron.left") { step(days: -1) }

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedDay, format: .dateTime.weekday(.wide))
                    .font(.caption)
                    .foregroundColor(TraceStyle.secondaryText)
                Text(selectedDay, format: .dateTime.day().month(.abbreviated).year())
                    .font(.headline)
            }
            .overlay(
                DatePicker(
                    "",
                    selection: $selectedDay,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .blendMode(.destinationOver)
                .opacity(0.02)
            )

            Spacer(minLength: 0)

            mapButton(icon: "chevron.right") { step(days: 1) }
                .disabled(isToday)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func mapButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .font(.body.weight(.medium))
        .tint(TraceStyle.accent)
        .padding(.horizontal, 4)
    }

    private func step(days: Int) {
        guard let newDay = Calendar.current.date(
            byAdding: .day,
            value: days,
            to: selectedDay,
            wrappingComponents: false
        ) else { return }
        selectedDay = newDay
    }

    // MARK: - Map

    private var mapSection: some View {
        ZStack(alignment: .topTrailing) {
            if let track, !track.isEmpty {
                ReplayMapView(
                    track: track,
                    headIndex: track.headIndex(at: secondsIntoDay),
                    marker: marker,
                    fitToken: fitToken,
                    recenterToken: recenterToken
                )
            } else {
                Text(emptyStateMessage)
                    .font(.subheadline)
                    .foregroundColor(TraceStyle.secondaryText)
                    .frame(width: nil, height: nil, alignment: .center)
                    .background(TraceStyle.card)
            }

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding(12)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                    .padding(12)
            }
        }
    }

    private var emptyStateMessage: String {
        errorMessage ?? "No data for this day"
    }

    // MARK: - Scrubber

    private var scrubberSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(clockLabel)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(positionLabel)
                    .font(.caption2)
                    .foregroundColor(TraceStyle.tertiaryText)
            }

            ZStack(alignment: .leading) {
                CoverageBand(spans: track?.coverage ?? [], dayLength: dayLength)
                    .frame(width: nil, height: 6, alignment: .leading)
                Slider(
                    value: $secondsIntoDay,
                    in: 0...max(dayLength, 1),
                    step: 60,
                    onEditingChanged: { _ in resetIfNeeded() }
                )
            }

            HStack {
                Text("00:00")
                    .font(.caption2)
                    .foregroundColor(TraceStyle.tertiaryText)
                Spacer(minLength: 0)
                Text(endOfDayLabel)
                    .font(.caption2)
                    .foregroundColor(TraceStyle.tertiaryText)
            }
        }
        .padding()
    }

    private var clockLabel: String {
        let hours = Int(secondsIntoDay) / 3600
        let minutes = (Int(secondsIntoDay) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private var positionLabel: String {
        switch scrubbedPosition {
        case .live(let fix):
            guard let speed = fix.speedMetersPerSecond else { return "Live" }
            return StatsFormatting.speedKmh(speed)
        case .stale:
            return "No signal"
        case .unknown:
            return "—"
        }
    }

    private var endOfDayLabel: String {
        "\(Int(dayLength) / 3600)h"
    }

    private func resetIfNeeded() {
        // Placeholder hook for Slider's onEditingChanged — no-op unless a future need arises.
    }

    /// Resets the scrubber to a sensible starting point after (re)loading a day: the first fix,
    /// advanced toward "now" if today so a fresh open of the tab reads as live.
    private func resetScrubber(for track: DayTrack) {
        guard let firstOffset = track.firstFixOffset else {
            secondsIntoDay = 0
            return
        }
        guard isToday else {
            secondsIntoDay = firstOffset
            return
        }
        let elapsedToday = min(Date().timeIntervalSince(track.dayStart), track.dayLength)
        secondsIntoDay = max(firstOffset, elapsedToday)
    }

    private func loadIfNeeded() async {
        guard tracks[dayKey] == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let paths = try await apiManager.fetchCoordinates(dayKey: dayKey)
            let newTrack = DayTrack(day: selectedDay, paths: paths, calendar: .current)
            tracks[dayKey] = newTrack
            resetScrubber(for: newTrack)
            fitToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A day's GPS coverage as thin bands along the scrubber track, so gaps (`.stale` stretches)
    /// are visible at a glance rather than only discoverable by dragging into them.
    private struct CoverageBand: View {
        let spans: [ClosedRange<TimeInterval>]
        let dayLength: TimeInterval

        var body: some View {
            GeometryReader { geometry in
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    Capsule(style: .continuous)
                        .fill(TraceStyle.separator)
                        .frame(width: geometry.size.width * (span.upperBound - span.lowerBound) / dayLength)
                        .offset(x: geometry.size.width * span.lowerBound / dayLength)
                }
            }
        }
    }
}
