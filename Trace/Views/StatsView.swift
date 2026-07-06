import Charts
import SwiftUI

private enum LookbackPreset: Int, CaseIterable, Identifiable {
    case seven = 7
    case fourteen = 14
    case thirty = 30
    case ninety = 90

    var id: Int { rawValue }

    var label: String {
        "\(rawValue) days"
    }
}

private enum StatsStyle {
    static let background = Color.black
    static let card = Color.white.opacity(0.075)
    static let raisedCard = Color.white.opacity(0.12)
    static let separator = Color.white.opacity(0.14)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.48)
    static let accent = Color.orange
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
}

struct StatsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiManager = ServerAPIManager.shared
    @State private var lookbackDays = 7
    @State private var selectedTrace = StatTrace.defaultTrace
    @State private var dailyStats: [DailyStats] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCustomLookbackSheet = false
    @State private var customLookbackInput = "7"
    @State private var selectedRowID: String?
    @State private var wasInBackground = false
    @State private var sortColumn: StatsTableColumn?
    @State private var sortAscending = false

    private var displayedStats: [DailyStats] {
        guard let sortColumn else {
            return Array(dailyStats.reversed())
        }
        return dailyStats.sorted { lhs, rhs in
            let ordered = sortColumn.sortKey(from: lhs) < sortColumn.sortKey(from: rhs)
            return sortAscending ? ordered : !ordered
        }
    }

    private var cumulativeTotals: DailyStatsCumulative {
        DailyStatsCumulative.from(rows: dailyStats)
    }

    private var chartPoints: [StatsChartPoint] {
        dailyStats.compactMap { row in
            guard let value = selectedTrace.value(from: row) else { return nil }
            return StatsChartPoint(
                date: row.date,
                displayDate: StatsFormatting.shortDate(row.date),
                value: value
            )
        }
    }

    private var chartXAxisLabels: [String] {
        let points = chartPoints
        guard points.count > 1 else {
            return points.map(\.displayDate)
        }

        let desiredCount = points.count <= 8 ? points.count : 6
        guard points.count > desiredCount else {
            return points.map(\.displayDate)
        }

        let lastIndex = points.count - 1
        let step = Double(lastIndex) / Double(desiredCount - 1)
        var labels: [String] = []
        var previousIndex = -1

        for tick in 0..<desiredCount {
            let index = min(lastIndex, Int((Double(tick) * step).rounded()))
            guard index != previousIndex else { continue }
            labels.append(points[index].displayDate)
            previousIndex = index
        }

        if labels.last != points[lastIndex].displayDate {
            labels.append(points[lastIndex].displayDate)
        }

        return labels
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    controlsSection
                    chartSection
                    tableSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(StatsStyle.background.ignoresSafeArea())
            .foregroundColor(StatsStyle.primaryText)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await loadStats()
            }
            .sheet(isPresented: $showCustomLookbackSheet) {
                CustomLookbackSheet(
                    value: $customLookbackInput,
                    onApply: applyCustomLookback
                )
            }
            .task {
                await loadStats()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    wasInBackground = true
                }
                guard phase == .active, wasInBackground else { return }
                wasInBackground = false
                Task { await loadStats() }
            }
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(LookbackPreset.allCases) { preset in
                    Button(preset.label) {
                        lookbackDays = preset.rawValue
                        Task { await loadStats() }
                    }
                }
                Button("Custom…") {
                    customLookbackInput = "\(lookbackDays)"
                    showCustomLookbackSheet = true
                }
            } label: {
                compactControlLabel("\(lookbackDays)d", systemImage: "calendar")
            }

            Menu {
                ForEach(StatTrace.allTraces) { trace in
                    Button(trace.label) {
                        selectedTrace = trace
                    }
                }
            } label: {
                compactControlLabel(selectedTrace.compactLabel, systemImage: "chart.xyaxis.line")
            }

            Spacer(minLength: 0)

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: StatsStyle.secondaryText))
                    .scaleEffect(0.7)
            }
        }
        .statsCard(padding: 8)
    }

    private func compactControlLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(StatsStyle.primaryText)
        .background(StatsStyle.raisedCard)
        .clipShape(RoundedRectangle(cornerRadius: StatsStyle.controlRadius, style: .continuous))
    }

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                selectedTrace.label,
                subtitle: "Last \(lookbackDays) days"
            )

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: StatsStyle.primaryText))
                    Spacer()
                }
                .frame(height: 188)
            } else if let errorMessage {
                chartMessage(errorMessage, color: StatsStyle.accent)
            } else if chartPoints.isEmpty {
                chartMessage("No data for this range.", color: StatsStyle.secondaryText)
            } else {
                Chart(chartPoints) { point in
                    if selectedTrace.usesLineMark {
                        LineMark(
                            x: .value("Date", point.displayDate),
                            y: .value(selectedTrace.label, point.value)
                        )
                        .foregroundStyle(StatsStyle.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        PointMark(
                            x: .value("Date", point.displayDate),
                            y: .value(selectedTrace.label, point.value)
                        )
                        .foregroundStyle(StatsStyle.accent)
                        .symbolSize(18)
                    } else {
                        BarMark(
                            x: .value("Date", point.displayDate),
                            y: .value(selectedTrace.label, point.value)
                        )
                        .foregroundStyle(StatsStyle.accent.gradient)
                        .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: chartXAxisLabels) { _ in
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(StatsStyle.secondaryText)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                            .foregroundStyle(StatsStyle.separator)
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(StatsStyle.secondaryText)
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.white.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .frame(height: 188)
            }
        }
        .statsCard()
    }

    @ViewBuilder
    private var tableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Daily breakdown")

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: StatsStyle.primaryText))
            } else if dailyStats.isEmpty {
                Text("No rows to show.")
                    .font(.caption)
                    .foregroundColor(StatsStyle.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        tableHeader
                        tableTotalsRow
                        Divider()
                            .background(StatsStyle.separator)
                        ForEach(displayedStats) { row in
                            tableRow(row)
                            Divider()
                                .background(StatsStyle.separator)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .statsCard()
    }

    private func sectionHeader(
        _ title: String,
        subtitle: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(StatsStyle.secondaryText)
            }
        }
    }

    private func chartMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            ForEach(StatsTableColumn.allColumns) { column in
                sortableHeaderCell(column)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(StatsStyle.raisedCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sortableHeaderCell(_ column: StatsTableColumn) -> some View {
        Button {
            toggleSort(for: column)
        } label: {
            HStack(spacing: 2) {
                Text(column.title)
                    .font(.caption2)
                    .foregroundColor(headerColor(for: column))
                    .fixedSize(horizontal: true, vertical: false)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(headerColor(for: column))
                }
            }
            .frame(minWidth: column.width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func headerColor(for column: StatsTableColumn) -> Color {
        if let motionType = column.motionTypeKey {
            return MotionTypeDisplay.color(for: motionType)
        }
        return sortColumn == column ? StatsStyle.accent : StatsStyle.secondaryText
    }

    private func toggleSort(for column: StatsTableColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = false
        }
    }

    private var tableTotalsRow: some View {
        HStack(spacing: 8) {
            ForEach(StatsTableColumn.allColumns) { column in
                tableCell(
                    for: column,
                    rowText: column.cumulativeCellText(for: cumulativeTotals),
                    motionBreakdown: column.motionBreakdown(for: cumulativeTotals),
                    emphasized: true
                )
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(StatsStyle.accent.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tableRow(_ row: DailyStats) -> some View {
        let isSelected = selectedRowID == row.id

        return HStack(spacing: 8) {
            ForEach(StatsTableColumn.allColumns) { column in
                tableCell(
                    for: column,
                    rowText: column.cellText(for: row),
                    motionBreakdown: column.motionBreakdown(for: row)
                )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(isSelected ? StatsStyle.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = isSelected ? nil : row.id
        }
    }

    @ViewBuilder
    private func tableCell(
        for column: StatsTableColumn,
        rowText: String,
        motionBreakdown: MotionStats.MotionTypeBreakdown?,
        emphasized: Bool = false
    ) -> some View {
        if column.isMotionColumn, let breakdown = motionBreakdown {
            motionTableValueCell(
                motionType: column.motionTypeKey ?? "unknown",
                distanceKm: breakdown.distanceKm,
                timeSeconds: breakdown.timeSeconds,
                width: column.width,
                emphasized: emphasized
            )
        } else if column.isMotionColumn {
            tableValueCell(
                rowText,
                width: column.width,
                monospaced: column.usesMonospacedDigits,
                emphasized: emphasized,
                color: MotionTypeDisplay.color(for: column.motionTypeKey ?? "unknown").opacity(0.45)
            )
        } else {
            tableValueCell(
                rowText,
                width: column.width,
                monospaced: column.usesMonospacedDigits,
                emphasized: emphasized
            )
        }
    }

    private func motionTableValueCell(
        motionType: String,
        distanceKm: Double,
        timeSeconds: Double,
        width: CGFloat,
        emphasized: Bool = false
    ) -> some View {
        let color = MotionTypeDisplay.color(for: motionType)

        return HStack(spacing: 0) {
            Text(StatsFormatting.motionDistanceText(distanceKm))
            Spacer(minLength: 4)
            Text(StatsFormatting.motionTimeText(timeSeconds))
        }
        .font(.caption.monospacedDigit())
        .fontWeight(emphasized ? .semibold : .regular)
        .foregroundColor(color.opacity(emphasized ? 1 : 0.92))
        .frame(minWidth: width, alignment: .leading)
    }

    private func tableValueCell(
        _ value: String,
        width: CGFloat,
        monospaced: Bool = false,
        emphasized: Bool = false,
        color: Color? = nil
    ) -> some View {
        Text(value)
            .font(monospaced ? .caption.monospacedDigit() : .caption)
            .fontWeight(emphasized ? .semibold : .regular)
            .foregroundColor(
                color ?? (emphasized ? StatsStyle.primaryText : StatsStyle.primaryText.opacity(0.9))
            )
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: width, alignment: .leading)
    }

    @MainActor
    private func loadStats() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            dailyStats = try await apiManager.fetchDailyStats(days: lookbackDays)
        } catch {
            dailyStats = []
            errorMessage = error.localizedDescription
        }
    }

    private func applyCustomLookback() {
        guard let days = Int(customLookbackInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...366).contains(days) else {
            errorMessage = "Enter a whole number between 1 and 366."
            return
        }
        lookbackDays = days
        showCustomLookbackSheet = false
        Task { await loadStats() }
    }
}

private struct CustomLookbackSheet: View {
    @Binding var value: String
    let onApply: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Days (1–366)", text: $value)
                    .keyboardType(.numberPad)
                    .focused($isFocused)
            }
            .navigationTitle("Custom lookback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: onApply)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    func statsCard(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(StatsStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: StatsStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StatsStyle.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}
