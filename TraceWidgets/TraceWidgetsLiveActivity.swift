//
//  TraceWidgetsLiveActivity.swift
//  TraceWidgets
//
//  Created by Mohit Nalavadi on 20.05.25.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct TraceWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var latitude: Double
        var longitude: Double
        var altitude: Double
        var speed: Double
        var lastUpdate: Date
        var isTracking: Bool
    }

    var name: String
}

struct TraceWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TraceWidgetsAttributes.self) { context in
            // Lock screen/banner UI
            ZStack {
                Color.black.opacity(0.85)
                HStack {
                    // Icon: left aligned
                    Image(systemName: context.state.isTracking ? "location.fill" : "location.slash.fill")
                        .foregroundColor(context.state.isTracking ? .green : .red)
                        .frame(width: 25, alignment: .leading)

                    // Center: Current time
                    Text(formatTimestamp(Date()))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(.white)
                        .kerning(-0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Right: Last GPS update time
                    Text(formatTimestamp(context.state.lastUpdate))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(context.state.isTracking ? .green : .red)
                        .kerning(-0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.center) {
                    ZStack {
                        Color.black.opacity(0.85)
                        
                        HStack {
                            // Icon: left aligned
                            Image(systemName: context.state.isTracking ? "location.fill" : "location.slash.fill")
                                .foregroundColor(context.state.isTracking ? .green : .red)
                                .frame(width: 28, alignment: .leading)

                            // Center: Current time
                            Text(formatTimestamp(Date()))
                                .font(.system(.title3, design: .monospaced))
                                .foregroundColor(.white)
                                .kerning(-0.5)
                                .frame(maxWidth: .infinity, alignment: .center)

                            // Right: Last GPS update time
                            Text(formatTimestamp(context.state.lastUpdate))
                                .font(.system(.title3, design: .monospaced))
                                .foregroundColor(context.state.isTracking ? .green : .red)
                                .kerning(-0.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: context.state.isTracking ? "location.fill" : "location.slash.fill")
                        .foregroundColor(context.state.isTracking ? .green : .red)
                    Text(formatTimestamp(context.state.lastUpdate))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.white)
                }
            } compactTrailing: {
                Text(context.state.isTracking ? "Tracking" : "Paused")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(context.state.isTracking ? .green : .red)
            } minimal: {
                Image(systemName: context.state.isTracking ? "location.fill" : "location.slash.fill")
                    .foregroundColor(context.state.isTracking ? .green : .red)
            }
        }
    }
}

func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
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
            speed: 2.0/3.6, // Convert km/h to m/s
            lastUpdate: Date(),
            isTracking: true
        )
    }
}

#Preview("Notification", as: .content, using: TraceWidgetsAttributes.preview) {
   TraceWidgetsLiveActivity()
} contentStates: {
    TraceWidgetsAttributes.ContentState.sample
}
