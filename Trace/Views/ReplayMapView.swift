import MapKit
import SwiftUI

/// Renders a day's `DayTrack` as a progress-highlighted polyline (dim ahead, bright travelled)
/// with a single live/stale position marker.
///
/// Reconstructed from a SourceKit index record after the source was lost to an accidental
/// revert — every type, property, and method signature below is exact (decoded from the
/// compiler's symbol table); the method bodies are a best-faith reconstruction consistent with
/// those signatures, not recovered source.
struct ReplayMapView: UIViewRepresentable {
    struct Marker {
        let coordinate: CLLocationCoordinate2D
        let isLive: Bool
    }

    let track: DayTrack
    let headIndex: Int
    let marker: Marker?
    let fitToken: Int
    let recenterToken: Int

    private static let markerIdentifier = "ReplayMarker"

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.markerIdentifier)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.dayKey != track.dayKey {
            coordinator.dayKey = track.dayKey
            mapView.removeOverlays(mapView.overlays)
            let overlay = TrackProgressOverlay(track: track)
            coordinator.overlay = overlay
            coordinator.renderer = nil
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        if let overlay = coordinator.overlay, overlay.headIndex != headIndex {
            let mapPointsPerScreenPoint = mapView.bounds.width > 0
                ? mapView.visibleMapRect.size.width / Double(mapView.bounds.width)
                : 0
            let invalidated = overlay.mapRect(
                between: overlay.headIndex,
                and: headIndex,
                padding: mapPointsPerScreenPoint * Double(TraceStyle.trackTravelledWidth)
            )
            overlay.headIndex = headIndex
            coordinator.renderer?.setNeedsDisplay(invalidated)
        }

        coordinator.apply(marker: marker, in: mapView)

        if coordinator.lastFitToken != fitToken {
            coordinator.lastFitToken = fitToken
            coordinator.fitCamera(to: track, in: mapView)
        }

        if coordinator.lastRecenterToken != recenterToken, let marker {
            coordinator.lastRecenterToken = recenterToken
            mapView.setCenter(marker.coordinate, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var dayKey: String?
        var overlay: TrackProgressOverlay?
        var renderer: TrackProgressRenderer?
        var lastFitToken = 0
        var lastRecenterToken = 0
        private var annotation: ReplayMarkerAnnotation?

        func fitCamera(to track: DayTrack, in mapView: MKMapView) {
            let rect = track.boundingMapRect
            guard !rect.isNull else { return }
            mapView.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                animated: true
            )
        }

        func apply(marker: ReplayMapView.Marker?, in mapView: MKMapView) {
            guard let marker else {
                if let annotation {
                    mapView.removeAnnotation(annotation)
                    self.annotation = nil
                }
                return
            }

            if let annotation {
                annotation.coordinate = marker.coordinate
                annotation.isLive = marker.isLive
                mapView.view(for: annotation)?.image = ReplayMarkerImage.image(isLive: marker.isLive)
            } else {
                let newAnnotation = ReplayMarkerAnnotation()
                newAnnotation.coordinate = marker.coordinate
                newAnnotation.isLive = marker.isLive
                annotation = newAnnotation
                mapView.addAnnotation(newAnnotation)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let trackOverlay = overlay as? TrackProgressOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = TrackProgressRenderer(overlay: trackOverlay)
            self.renderer = renderer
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let markerAnnotation = annotation as? ReplayMarkerAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: ReplayMapView.markerIdentifier,
                for: markerAnnotation
            )
            view.canShowCallout = false
            view.image = ReplayMarkerImage.image(isLive: markerAnnotation.isLive)
            return view
        }
    }
}

/// The track polyline as an `MKOverlay`, tracking how far the scrubber has progressed.
final class TrackProgressOverlay: NSObject, MKOverlay {
    var path: [CLLocationCoordinate2D]
    var segmentStarts: Set<Int>
    var headIndex: Int
    private lazy var cachedBoundingMapRect: MKMapRect = Self.boundingRect(for: path)

    init(track: DayTrack) {
        path = track.flatCoordinates
        segmentStarts = track.segmentStarts
        headIndex = -1
    }

    var coordinate: CLLocationCoordinate2D { path.first ?? CLLocationCoordinate2D() }
    var boundingMapRect: MKMapRect { cachedBoundingMapRect }

    /// Bounding rect spanning two vertex indices, padded by the stroke width, so a
    /// head-index change only invalidates the stretch of track whose highlight actually moved.
    func mapRect(between oldHead: Int, and newHead: Int, padding: Double) -> MKMapRect {
        let lastIndex = path.count - 1
        guard lastIndex >= 0 else { return .null }
        let low = max(0, min(oldHead, newHead))
        let high = min(lastIndex, max(oldHead, newHead))
        guard low <= high else { return .null }
        let rect = path[low...high].reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    private static func boundingRect(for path: [CLLocationCoordinate2D]) -> MKMapRect {
        path.reduce(MKMapRect.null) { rect, coordinate in
            rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
    }
}

/// Draws `TrackProgressOverlay` as two passes: the full path dim, then the travelled portion
/// (up to `headIndex`) bright — never bridging a segment gap in either pass.
final class TrackProgressRenderer: MKOverlayRenderer {
    override init(overlay: MKOverlay) {
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TrackProgressOverlay else { return }

        context.setLineCap(.round)
        context.setLineJoin(.round)

        stroke(
            overlay: overlay,
            upTo: overlay.path.count - 1,
            color: TraceStyle.trackDim,
            width: TraceStyle.trackDimWidth / zoomScale,
            in: context
        )
        if overlay.headIndex > 0 {
            stroke(
                overlay: overlay,
                upTo: overlay.headIndex,
                color: TraceStyle.trackTravelled,
                width: TraceStyle.trackTravelledWidth / zoomScale,
                in: context
            )
        }
    }

    private func stroke(
        overlay: TrackProgressOverlay,
        upTo lastIndex: Int,
        color: UIColor,
        width: CGFloat,
        in context: CGContext
    ) {
        guard lastIndex > 0, lastIndex < overlay.path.count else { return }

        context.setLineWidth(width)
        context.setStrokeColor(color.cgColor)

        var runStart = 0
        for index in 1...lastIndex {
            if overlay.segmentStarts.contains(index) {
                strokeRun(overlay.path[runStart...(index - 1)], in: context)
                runStart = index
            }
        }
        strokeRun(overlay.path[runStart...lastIndex], in: context)
    }

    private func strokeRun(_ run: ArraySlice<CLLocationCoordinate2D>, in context: CGContext) {
        guard run.count > 1 else { return }
        var iterator = run.makeIterator()
        guard let first = iterator.next() else { return }
        context.move(to: point(for: MKMapPoint(first)))
        while let coordinate = iterator.next() {
            context.addLine(to: point(for: MKMapPoint(coordinate)))
        }
        context.strokePath()
    }
}

/// The scrubber's position marker on the map.
final class ReplayMarkerAnnotation: MKPointAnnotation {
    var isLive = false
}

/// Small filled-circle marker images: solid for a live fix, hollow for a stale one.
private enum ReplayMarkerImage {
    static var live: UIImage = make(filled: true)
    static var stale: UIImage = make(filled: false)

    static func image(isLive: Bool) -> UIImage {
        isLive ? live : stale
    }

    private static func make(filled: Bool) -> UIImage {
        let size = CGSize(width: 14, height: 14)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.cgContext.setFillColor((filled ? TraceStyle.trackTravelled : UIColor.clear).cgColor)
            context.cgContext.fillEllipse(in: rect)
            context.cgContext.setStrokeColor(UIColor.white.cgColor)
            context.cgContext.strokeEllipse(in: rect)
        }
    }
}
