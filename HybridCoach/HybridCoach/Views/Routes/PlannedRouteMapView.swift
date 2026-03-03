import SwiftUI
import MapKit

/// Displays a planned route polyline on a map with start/end markers
/// and optional coaching tip markers.
struct PlannedRouteMapView: View {
    let polyline: [CodableCoordinate]
    let tips: [PlannedRouteTip]

    private var coordinates: [CLLocationCoordinate2D] {
        polyline.map(\.clCoordinate)
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
        let center = CLLocationCoordinate2D(
            latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
            longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.4 + 0.005,
            longitudeDelta: ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.4 + 0.005
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

            // Coaching tip markers
            ForEach(tips.filter { $0.coordinate != nil }) { tip in
                if let coord = tip.coordinate {
                    Annotation("", coordinate: coord.clCoordinate) {
                        Image(systemName: tipIcon(tip.type))
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(tipColor(tip.type)))
                    }
                }
            }
        }
        .mapStyle(.standard)
    }

    private func tipIcon(_ type: PlannedRouteTip.TipType) -> String {
        switch type {
        case .hill: "mountain.2"
        case .speedZone: "speedometer"
        case .sharpTurn: "arrow.turn.right.up"
        case .evOpportunity: "bolt.fill"
        case .trafficSlowdown: "car.2"
        case .longStraight: "road.lanes"
        }
    }

    private func tipColor(_ type: PlannedRouteTip.TipType) -> Color {
        switch type {
        case .hill: .brown
        case .speedZone: .orange
        case .sharpTurn: .red
        case .evOpportunity: .green
        case .trafficSlowdown: .yellow
        case .longStraight: .blue
        }
    }
}
