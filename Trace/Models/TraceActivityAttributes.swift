import ActivityKit
import SwiftUI

public struct TraceWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double
        public var speed: Double
        public var age: Int
        public var lastUpdate: Date
        public var lastHeartbeat: Date?
        public var isTracking: Bool
        
        public init(
            latitude: Double,
            longitude: Double,
            altitude: Double,
            speed: Double,
            age: Int,
            lastUpdate: Date,
            lastHeartbeat: Date?,
            isTracking: Bool
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.speed = speed
            self.age = age
            self.lastUpdate = lastUpdate
            self.lastHeartbeat = lastHeartbeat
            self.isTracking = isTracking
        }
    }

    public var name: String
    
    public init(name: String) {
        self.name = name
    }
} 