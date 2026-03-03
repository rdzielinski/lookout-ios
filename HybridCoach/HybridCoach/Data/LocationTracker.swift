import Foundation
import CoreLocation

/// Tracks GPS location during trips to build route polylines.
@MainActor
@Observable
final class LocationTracker: NSObject, @unchecked Sendable {

    private(set) var currentLatitude: Double = 0
    private(set) var currentLongitude: Double = 0
    private(set) var currentAltitude: Double = 0
    private(set) var isTracking = false
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private var locationManager: CLLocationManager?
    private var buffer: [RoutePoint] = []

    override init() {
        super.init()
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10  // meters
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        self.locationManager = manager
    }

    // MARK: - Public API

    func requestAuthorization() {
        locationManager?.requestWhenInUseAuthorization()
    }

    func startTracking() {
        guard !isTracking else { return }
        buffer.removeAll()
        isTracking = true
        locationManager?.startUpdatingLocation()
    }

    func stopTracking() -> [RoutePoint] {
        locationManager?.stopUpdatingLocation()
        isTracking = false
        let result = buffer
        buffer.removeAll()
        return result
    }

    /// Current polyline buffer for real-time route display.
    var currentPolyline: [RoutePoint] { buffer }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            self.currentLatitude = location.coordinate.latitude
            self.currentLongitude = location.coordinate.longitude
            self.currentAltitude = location.altitude

            if self.isTracking {
                let speedMph = location.speed >= 0
                    ? location.speed * 2.23694  // m/s → mph
                    : nil

                let point = RoutePoint(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.altitude,
                    timestamp: location.timestamp,
                    speedMph: speedMph
                )
                self.buffer.append(point)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silently ignore location errors — GPS may temporarily lose signal
        print("LocationTracker: \(error.localizedDescription)")
    }
}
