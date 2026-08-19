import CoreLocation
import Foundation
import MapKit

/// One day's GPS track, indexed by time so a scrubber can answer "where was I at 14:37?".
///
/// Server paths arrive as separate segments — split on gaps over 60s or 100m — with
/// Douglas-Peucker simplification already applied, so intermediate vertices no longer exist and
/// positions between kept vertices have to be interpolated. Two rules follow from that, and they
/// live here rather than being implied by rendering code:
///
/// 1. Interpolation never crosses a segment boundary. Bridging two segments would draw the user
///    straight through whatever the coverage gap was hiding.
/// 2. Inside a gap the position is reported as `.stale`, not silently held at the last fix, so the
///    UI can say "no data" instead of implying the user stood still.
struct DayTrack {
    /// A position derived from real fixes.
    struct Fix {
        let coordinate: CLLocationCoordinate2D
        /// Ground speed in m/s across the surrounding pair of fixes, or nil when undefinable.
        let speedMetersPerSecond: Double?
    }

    enum Position {
        /// A real or interpolated position between two fixes of the same segment.
        case live(Fix)
        /// Inside a coverage gap. Carries the last known position so the map can still show
        /// where the user was, drawn hollow to mark it as unconfirmed.
        case stale(CLLocationCoordinate2D)
        /// Before the day's first fix — nothing to show at all.
        case unknown
    }

    /// How long after the final fix a position still counts as live. Only matters at the trailing
    /// edge: within a segment consecutive fixes are at most 60s apart by construction, so
    /// "today, scrubbed to now" reads as live rather than stale.
    static let trailingLiveWindow: TimeInterval = 15 * 60

    private static let timestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `YYYY-MM-DD` for the day this track covers. Doubles as the cache and identity key.
    let dayKey: String
    let dayStart: Date
    /// 24h normally; 23h or 25h across a DST transition.
    let dayLength: TimeInterval

    /// All vertices concatenated in time order — what the map renders.
    let flatCoordinates: [CLLocationCoordinate2D]
    /// Indices in `flatCoordinates` that begin a new segment. Never draw a line *into* one of
    /// these: the preceding vertex is on the far side of a coverage gap.
    let segmentStarts: Set<Int>
    /// Spans of the day, in seconds from `dayStart`, that actually contain fixes.
    let coverage: [ClosedRange<TimeInterval>]

    /// Seconds from `dayStart` for each entry in `flatCoordinates`.
    private let offsets: [TimeInterval]
    /// Segment number for each entry in `flatCoordinates`.
    private let segmentIDs: [Int]

    var isEmpty: Bool { offsets.isEmpty }
    var firstFixOffset: TimeInterval? { offsets.first }
    var lastFixOffset: TimeInterval? { offsets.last }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    init(day: Date, paths: [[MapCoordinate]], calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        dayStart = start
        dayLength = nextDay.timeIntervalSince(start)
        dayKey = Self.dayKey(for: start)

        // Flatten to (offset, coordinate, segment) triples, dropping anything unparseable or
        // outside the day. The server returns segments in time order, but sorting defensively
        // costs nothing and removes a way for bad input to corrupt the binary search.
        var vertices: [(offset: TimeInterval, coordinate: CLLocationCoordinate2D, segment: Int)] = []
        var spans: [ClosedRange<TimeInterval>] = []

        for (segment, path) in paths.enumerated() {
            var segmentOffsets: [TimeInterval] = []
            for point in path {
                guard let date = Self.timestampParser.date(from: point.timestamp) else { continue }
                let offset = date.timeIntervalSince(start)
                guard offset >= 0, offset <= dayLength else { continue }
                vertices.append((
                    offset,
                    CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    segment
                ))
                segmentOffsets.append(offset)
            }
            if let low = segmentOffsets.min(), let high = segmentOffsets.max(), low < high {
                spans.append(low...high)
            }
        }

        vertices.sort { $0.offset < $1.offset }

        var starts = Set<Int>()
        var previousSegment: Int?
        for (index, vertex) in vertices.enumerated() where vertex.segment != previousSegment {
            starts.insert(index)
            previousSegment = vertex.segment
        }

        offsets = vertices.map(\.offset)
        flatCoordinates = vertices.map(\.coordinate)
        segmentIDs = vertices.map(\.segment)
        segmentStarts = starts
        coverage = spans.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Where the user was `offset` seconds into the day.
    func position(at offset: TimeInterval) -> Position {
        guard let first = offsets.first, let last = offsets.last else { return .unknown }
        if offset < first { return .unknown }
        if offset >= last {
            let coordinate = flatCoordinates[flatCoordinates.count - 1]
            return offset - last <= Self.trailingLiveWindow
                ? .live(Fix(coordinate: coordinate, speedMetersPerSecond: nil))
                : .stale(coordinate)
        }

        let index = lastIndex(atOrBefore: offset)
        let next = index + 1
        guard segmentIDs[index] == segmentIDs[next] else {
            // Between two segments, which is exactly where the server saw a gap.
            return .stale(flatCoordinates[index])
        }

        let span = offsets[next] - offsets[index]
        let from = flatCoordinates[index]
        let to = flatCoordinates[next]
        guard span > 0 else { return .live(Fix(coordinate: from, speedMetersPerSecond: nil)) }

        let fraction = (offset - offsets[index]) / span
        let coordinate = CLLocationCoordinate2D(
            latitude: from.latitude + (to.latitude - from.latitude) * fraction,
            longitude: from.longitude + (to.longitude - from.longitude) * fraction
        )
        let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        return .live(Fix(coordinate: coordinate, speedMetersPerSecond: meters / span))
    }

    /// How much of `flatCoordinates` has been travelled by `offset`. -1 before the first fix.
    func headIndex(at offset: TimeInterval) -> Int {
        guard let first = offsets.first else { return -1 }
        guard offset >= first else { return -1 }
        return lastIndex(atOrBefore: offset)
    }

    /// Bounding rect of the whole day, for fitting the camera on load.
    var boundingMapRect: MKMapRect {
        guard !flatCoordinates.isEmpty else { return .null }
        return flatCoordinates.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
    }

    /// Index of the last vertex at or before `offset`. Callers must have ruled out
    /// `offset < offsets.first` and an empty track.
    private func lastIndex(atOrBefore offset: TimeInterval) -> Int {
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
