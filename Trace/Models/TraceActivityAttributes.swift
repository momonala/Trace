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
        public var steps: Int
        public var kcal: Int
        public var km: Double
        public var flights: Int
        public var healthAvailable: Bool

        public init(
            latitude: Double,
            longitude: Double,
            altitude: Double,
            speed: Double,
            age: Int,
            lastUpdate: Date,
            lastHeartbeat: Date?,
            isTracking: Bool,
            steps: Int = 0,
            kcal: Int = 0,
            km: Double = 0,
            flights: Int = 0,
            healthAvailable: Bool = false
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.speed = speed
            self.age = age
            self.lastUpdate = lastUpdate
            self.lastHeartbeat = lastHeartbeat
            self.isTracking = isTracking
            self.steps = steps
            self.kcal = kcal
            self.km = km
            self.flights = flights
            self.healthAvailable = healthAvailable
        }
    }

    public var name: String
    
    public init(name: String) {
        self.name = name
    }
} 