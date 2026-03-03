import SwiftUI
import MapKit

/// Displays a trip route with color-coded overlays showing efficient vs improvable segments.
struct TripImprovementMapView: View {
    let trip: Trip
    let routeRecord: RouteRecord?

    @State private var showLegend = true

    private var segments: [TripImprovementAnalyzer.TripSegment] {
        TripImprovementAnalyzer.analyze(trip: trip, routeRecord: routeRecord)
    }

    private var summary: TripImprovementAnalyzer.TripImprovementSummary {
        TripImprovementAnalyzer.summarize(segments: segments)
    }

    /// Base route coordinates from the route record polyline or trip snapshots.
    private var baseCoordinates: [CLLocationCoordinate2D] {
        if let record = routeRecord, record.polyline.count >= 2 {
            return record.polyline.map { $0.coordinate }
        }
        // Fall back to snapshot GPS data
        return trip.snapshots.compactMap { snapshot in
            guard let lat = snapshot.latitude, let lon = snapshot.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private var mapRegion: MKCoordinateRegion {
        let coords = baseCoordinates
        guard !coords.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
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
        ZStack(alignment: .bottom) {
            Map(initialPosition: .region(mapRegion)) {
                // Base route polyline (faded blue)
                if baseCoordinates.count >= 2 {
                    MapPolyline(coordinates: baseCoordinates)
                        .stroke(.blue.opacity(0.3), lineWidth: 3)
                }

                // Color-coded segments
                ForEach(segments) { segment in
                    if segment.coordinates.count >= 2 {
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(colorForSegment(segment), lineWidth: 5)
                    }
                }

                // Start marker
                if let first = baseCoordinates.first {
                    Annotation("Start", coordinate: first) {
                        Image(systemName: "flag.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .background(Circle().fill(.white).frame(width: 24, height: 24))
                    }
                }

                // End marker
                if let last = baseCoordinates.last, baseCoordinates.count > 1 {
                    Annotation("End", coordinate: last) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .background(Circle().fill(.white).frame(width: 24, height: 24))
                    }
                }
            }
            .mapStyle(.standard)

            // Floating legend card
            if showLegend {
                legendCard
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("Trip Improvement Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { showLegend.toggle() }
                } label: {
                    Image(systemName: showLegend ? "info.circle.fill" : "info.circle")
                }
            }
        }
    }

    // MARK: - Legend Card

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Summary line
            HStack {
                if summary.totalSegments > 0 {
                    Text(String(format: "%.0f%% efficient", summary.efficientPercentage))
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%% could improve", summary.improvementPercentage))
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                } else {
                    Text("No GPS-tagged segments found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Color legend
            HStack(spacing: 16) {
                legendItem(color: .green, label: "EV / Efficient")
                legendItem(color: .orange, label: "Could Improve")
                legendItem(color: .red, label: "Needs Work")
                legendItem(color: .blue.opacity(0.3), label: "Neutral")
            }
            .font(.caption)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Color Mapping

    private func colorForSegment(_ segment: TripImprovementAnalyzer.TripSegment) -> Color {
        switch segment.category {
        case .highRPM, .aggressiveAccel:
            return .red
        case .missedEV, .highSpeed:
            return .orange
        case .goodEV, .efficient:
            return .green
        }
    }
}
