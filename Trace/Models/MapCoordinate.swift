import Foundation

/// One vertex of a server-returned trip path.
struct MapCoordinate: Decodable {
    let timestamp: String
    let latitude: Double
    let longitude: Double
}

/// Response from `GET /coordinates`. The server echoes back whichever scope was requested —
/// `lookback_hours` for a window ending now, `date` for a single calendar day — so exactly
/// one of those two is present.
struct CoordinatesResponse: Decodable {
    let status: String
    let count: Int
    let lookbackHours: Int?
    let date: String?
    let paths: [[MapCoordinate]]

    private enum CodingKeys: String, CodingKey {
        case status
        case count
        case lookbackHours = "lookback_hours"
        case date
        case paths
    }
}
