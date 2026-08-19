import SwiftUI
import UIKit

/// Dark palette and corner radii shared by the full-screen data pages (Replay, Stats).
///
/// Reconstructed from a SourceKit index record after the source was lost to an accidental
/// revert — the property names, types, and `tint(for:)` signature are exact; the literal
/// color/radius values below are a best-faith reconstruction and worth eyeballing in Xcode.
enum TraceStyle {
    static var background: Color = .black
    static var card: Color = Color(white: 0.11)
    static var raisedCard: Color = Color(white: 0.16)
    static var separator: Color = .white.opacity(0.15)
    static var primaryText: Color = .white
    static var secondaryText: Color = .white.opacity(0.7)
    static var tertiaryText: Color = .white.opacity(0.45)
    static var accent: Color = .orange

    static var cardRadius: CGFloat = 16
    static var controlRadius: CGFloat = 10

    /// Chart/legend tint for a stats table column, keyed off its motion type where it has one.
    ///
    /// The index record this was reconstructed from called this parameter type `StatsMetric` —
    /// an uncommitted rename/refactor of `StatsTableColumn` that was lost separately from the
    /// Replay feature and not recovered. Pointed at `StatsTableColumn`, the type that actually
    /// exists in the current (reverted-to-HEAD) `DailyStats.swift`, since it has the same shape.
    static func tint(for metric: StatsTableColumn) -> Color? {
        guard let key = metric.motionTypeKey else { return nil }
        return MotionTypeDisplay.color(for: key)
    }

    /// Untravelled portion of the Replay track polyline.
    static var trackDim: UIColor = UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.35)
    /// Travelled portion of the Replay track polyline, up to the scrubbed head index.
    static var trackTravelled: UIColor = UIColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 0.9)
}
