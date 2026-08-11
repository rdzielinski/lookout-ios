import Foundation
import CoreLocation

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Reverse-geocoded placemark for the most recent fix. Refreshed lazily and
    /// throttled — the assistant only needs a human-readable "city, state" to
    /// hand the brain, not a live stream.
    @Published var currentPlacemark: CLPlacemark?

    private let geocoder = CLGeocoder()
    private var lastGeocodedLocation: CLLocation?

    /// Human-readable location for brain context, e.g. "Waukesha, WI".
    /// Nil until a reverse geocode lands.
    var currentLocationString: String? {
        guard let placemark = currentPlacemark else { return nil }
        let parts = [placemark.locality, placemark.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 50
    }
    
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }
    
    func startUpdating() {
        manager.startUpdatingLocation()
    }
    
    func stopUpdating() {
        manager.stopUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        refreshPlacemarkIfNeeded(for: location)
    }

    /// Only re-geocode once we've moved a meaningful distance — reverse
    /// geocoding is rate-limited by CoreLocation and the assistant just needs
    /// a coarse city name.
    private func refreshPlacemarkIfNeeded(for location: CLLocation) {
        if let last = lastGeocodedLocation, location.distance(from: last) < 1000, currentPlacemark != nil {
            return
        }
        guard !geocoder.isGeocoding else { return }

        lastGeocodedLocation = location
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let placemark = placemarks?.first else { return }
            Task { @MainActor in
                self?.currentPlacemark = placemark
            }
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }
}
