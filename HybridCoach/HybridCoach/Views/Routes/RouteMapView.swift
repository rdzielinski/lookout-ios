import SwiftUI
import MapKit

/// Displays a route polyline on a MapKit map with start/end markers.
struct RouteMapView: View {
    let polyline: [RoutePoint]

    private var coordinates: [CLLocationCoordinate2D] {
        polyline.map { $0.coordinate }
    }

    private var mapRegion: MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.005,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.005
        )

        return MKCoordinateRegion(center: center, span: span)
    }

    var body: some View {
        Map(initialPosition: .region(mapRegion)) {
            // Route polyline
            if coordinates.count >= 2 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.blue, lineWidth: 4)
            }

            // Start marker
            if let first = coordinates.first {
                Annotation("Start", coordinate: first) {
                    Image(systemName: "flag.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .background(Circle().fill(.white).frame(width: 24, height: 24))
                }
            }

            // End marker
            if let last = coordinates.last, coordinates.count > 1 {
                Annotation("End", coordinate: last) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .background(Circle().fill(.white).frame(width: 24, height: 24))
                }
            }
        }
        .mapStyle(.standard)
    }
}
