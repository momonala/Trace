//
//  TraceWidgetsLiveActivity.swift
//  TraceWidgets
//
//  Created by Mohit Nalavadi on 20.05.25.
//

import ActivityKit
import WidgetKit
import SwiftUI

// NOTE: Must stay in sync with Trace/Models/TraceActivityAttributes.swift.
// The correct long-term fix is to add that file to both targets in Xcode
// so there is only one definition shared across the app and widget extension.
struct TraceWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var latitude: Double
        var longitude: Double
        var altitude: Double
        var speed: Double
        var age: Int
        var lastUpdate: Date
        var lastHeartbeat: Date?
        var isTracking: Bool
        var steps: Int
        var kcal: Int
        var km: Double
        var flights: Int
        var healthAvailable: Bool
    }

    var name: String
}

private let traceTeal = Color(red: 0.2, green: 0.78, blue: 0.82)

private enum LiveActivityTypography {
    static let row = Font.system(size: 16, weight: .regular, design: .monospaced)
    static let compact = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let iconSize: CGFloat = 17
}

struct TraceWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TraceWidgetsAttributes.self) { context in
            LiveActivityStatusRow(state: context.state, font: LiveActivityTypography.row)
                .liveActivityChrome()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LiveActivityStatusRow(state: context.state, font: LiveActivityTypography.row)
                        .liveActivityChrome()
                }
            } compactLeading: {
                LiveActivityIcon(
                    systemName: context.state.isTracking ? "location.fill" : "location.slash.fill",
                    font: LiveActivityTypography.compact,
                    color: context.state.isTracking ? .green : .red
                )
            } compactTrailing: {
                if context.state.healthAvailable {
                    LiveActivityHealthMetrics(
                        state: context.state,
                        font: LiveActivityTypography.compact,
                        spacing: 6
                    )
                } else {
                    LiveActivityText(
                        formatTimestamp(context.state.lastUpdate),
                        font: LiveActivityTypography.compact,
                        color: context.state.isTracking ? .green : .red
                    )
                }
            } minimal: {
                LiveActivityIcon(
                    systemName: context.state.isTracking ? "location.fill" : "location.slash.fill",
                    font: LiveActivityTypography.compact,
                    color: context.state.isTracking ? .green : .red
                )
            }
        }
    }
}

private struct LiveActivityStatusRow: View {
    let state: TraceWidgetsAttributes.ContentState
    let font: Font

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                LiveActivityIcon(
                    systemName: state.isTracking ? "location.fill" : "location.slash.fill",
                    font: font,
                    color: state.isTracking ? .green : .red
                )

                LiveActivityText(
                    formatTimestamp(state.lastUpdate),
                    font: font,
                    color: state.isTracking ? .green : .red
                )
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 10)

            if state.healthAvailable {
                LiveActivityHealthMetrics(state: state, font: font, spacing: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveActivityHealthMetrics: View {
    let state: TraceWidgetsAttributes.ContentState
    let font: Font
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            HealthMetricItem(icon: "figure.walk", value: formatStepsForLiveActivity(state.steps), font: font, color: traceTeal)
            HealthMetricItem(icon: "flame.fill", value: "\(state.kcal)", font: font, color: traceTeal)
            HealthMetricItem(icon: "figure.run", value: String(format: "%.1f", state.km), font: font, color: traceTeal)
            HealthMetricItem(icon: "figure.stairs", value: "\(state.flights)", font: font, color: traceTeal)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct HealthMetricItem: View {
    let icon: String
    let value: String
    let font: Font
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            LiveActivityIcon(systemName: icon, font: font, color: color)
            LiveActivityText(value, font: font, color: color)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct LiveActivityIcon: View {
    let systemName: String
    let font: Font
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundColor(color)
            .frame(width: LiveActivityTypography.iconSize, height: LiveActivityTypography.iconSize)
            .contentShape(Rectangle())
    }
}

private struct LiveActivityText: View {
    let text: String
    let font: Font
    let color: Color

    init(_ text: String, font: Font, color: Color) {
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .kerning(-0.5)
            .lineLimit(1)
    }
}

private extension View {
    func liveActivityChrome() -> some View {
        self
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .activityBackgroundTint(.clear)
    }
}

func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

/// Shorter step labels so the Live Activity row does not truncate (e.g. 21k vs 21.1k).
func formatStepsForLiveActivity(_ count: Int) -> String {
    if count >= 10_000 {
        return "\(count / 1000)k"
    }
    if count >= 1_000 {
        return String(format: "%.1fk", Double(count) / 1000)
    }
    return "\(count)"
}

extension TraceWidgetsAttributes {
    fileprivate static var preview: TraceWidgetsAttributes {
        TraceWidgetsAttributes(name: "Trace")
    }
}

extension TraceWidgetsAttributes.ContentState {
    fileprivate static var sample: TraceWidgetsAttributes.ContentState {
        TraceWidgetsAttributes.ContentState(
            latitude: 52.4004,
            longitude: 13.2387,
            altitude: 51.2,
            speed: 2.0/3.6,
            age: 0,
            lastUpdate: Date(),
            lastHeartbeat: nil,
            isTracking: true,
            steps: 21_100,
            kcal: 312,
            km: 5.4,
            flights: 8,
            healthAvailable: true
        )
    }
}

#Preview("Notification", as: .content, using: TraceWidgetsAttributes.preview) {
   TraceWidgetsLiveActivity()
} contentStates: {
    TraceWidgetsAttributes.ContentState.sample
}
