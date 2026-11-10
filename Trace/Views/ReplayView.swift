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
    @State private var loadErrors: [String: String] = [:]
    @State private var fitToken = 0
    @State private var recenterToken = 0
    @State private var showCalendar = false

    private var dayKey: String { DayTrack.dayKey(for: selectedDay) }
    private var track: DayTrack? { tracks[dayKey] }
    private var errorMessage: String? { loadErrors[dayKey] }
    private var isLoading: Bool { track == nil && errorMessage == nil }

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
        GeometryReader { proxy in
            ZStack {
                TraceStyle.background
                mapSection(insets: proxy.safeAreaInsets)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            if hasTrack {
                mapControls
                    .padding(.trailing, 16)
                    .padding(.top, 12)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            dayBar
                .padding(.top, 8)
                .padding(.horizontal, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            scrubberPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .foregroundStyle(TraceStyle.primaryText)
        .environment(\.colorScheme, .dark)
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
        HStack(spacing: 0) {
            stepButton(icon: "chevron.left", label: "Previous day") { step(days: -1) }

            Button { showCalendar = true } label: {
                HStack(spacing: 6) {
                    VStack(spacing: 1) {
                        Text(selectedDay, format: .dateTime.weekday(.wide))
                            .font(.caption)
                            .foregroundStyle(TraceStyle.secondaryText)
                        Text(selectedDay, format: .dateTime.day().month(.abbreviated).year())
                            .font(.headline)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TraceStyle.secondaryText)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens a calendar")
            .popover(isPresented: $showCalendar) {
                DayCalendarPopover(day: $selectedDay)
                    .presentationCompactAdaptation(.popover)
            }

            stepButton(icon: "chevron.right", label: "Next day") { step(days: 1) }
                .disabled(isToday)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }

    private func stepButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(label)
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

    private var hasTrack: Bool { !(track?.isEmpty ?? true) }

    @ViewBuilder
    private func mapSection(insets: EdgeInsets) -> some View {
        if let track, !track.isEmpty {
            ReplayMapView(
                track: track,
                headIndex: track.headIndex(at: secondsIntoDay),
                marker: marker,
                contentInsets: insets,
                fitToken: fitToken,
                recenterToken: recenterToken
            )
        } else if isLoading {
            ProgressView("Loading track…")
                .tint(TraceStyle.secondaryText)
                .foregroundStyle(TraceStyle.secondaryText)
                .padding(insets)
        } else {
            emptyState
                .padding(insets)
        }
    }

    private var mapControls: some View {
        VStack(spacing: 0) {
            mapControlButton(icon: "location.fill", label: "Center on position") {
                recenterToken += 1
            }
            .disabled(marker == nil)
            Divider()
                .frame(width: 28)
            mapControlButton(icon: "arrow.up.left.and.arrow.down.right", label: "Show whole day") {
                fitToken += 1
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func mapControlButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Track", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { Task { await loadIfNeeded() } }
                    .buttonStyle(.glass)
            }
        } else {
            ContentUnavailableView(
                "No Data",
                systemImage: "map",
                description: Text("Nothing was recorded on this day.")
            )
        }
    }

    // MARK: - Scrubber

    private var scrubberPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(clockLabel)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                positionBadge
            }

            ZStack(alignment: .leading) {
                CoverageBand(spans: track?.coverage ?? [], dayLength: dayLength)
                    .frame(height: 6)
                Slider(value: $secondsIntoDay, in: 0...max(dayLength, 1), step: 60)
                    .disabled(!hasTrack)
            }

            HStack {
                Text("00:00")
                Spacer(minLength: 0)
                Text(endOfDayLabel)
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(TraceStyle.tertiaryText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var positionBadge: some View {
        Label(positionLabel, systemImage: positionIcon)
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(TraceStyle.secondaryText)
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
            return "\(StatsFormatting.speedKmh(speed)) km/h"
        case .stale:
            return "No signal"
        case .unknown:
            return "—"
        }
    }

    private var positionIcon: String {
        switch scrubbedPosition {
        case .live: "location.fill"
        case .stale: "location.slash"
        case .unknown: "location"
        }
    }

    private var endOfDayLabel: String {
        String(format: "%02d:00", Int(dayLength) / 3600)
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
        let day = selectedDay
        let key = dayKey
        guard tracks[key] == nil else { return }
        loadErrors[key] = nil
        do {
            let paths = try await apiManager.fetchCoordinates(dayKey: key)
            let newTrack = DayTrack(day: day, paths: paths, calendar: .current)
            tracks[key] = newTrack
            guard key == dayKey else { return }
            resetScrubber(for: newTrack)
            fitToken += 1
        } catch {
            loadErrors[key] = error.localizedDescription
        }
    }

    private struct DayCalendarPopover: View {
        @Binding var day: Date

        @Environment(\.dismiss) private var dismiss
        @State private var draft: Date

        init(day: Binding<Date>) {
            _day = day
            _draft = State(initialValue: day.wrappedValue)
        }

        var body: some View {
            VStack(spacing: 4) {
                DatePicker("Day", selection: $draft, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()

                HStack {
                    Button("Today") { draft = Calendar.current.startOfDay(for: Date()) }
                        .disabled(Calendar.current.isDateInToday(draft))
                    Spacer()
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 8)
            }
            .padding(12)
            .frame(width: 340)
            .preferredColorScheme(.dark)
            .onDisappear { day = Calendar.current.startOfDay(for: draft) }
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
