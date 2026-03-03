import SwiftUI
import MapKit
import Charts

/// Displays the full pre-analysis results for a planned route,
/// including map, summary, elevation, speed limits, tips, and directions.
struct PlannedRouteAnalysisView: View {
    let route: PlannedRoute
    @Environment(PlannedRouteStore.self) var store

    var body: some View {
        List {
            // MARK: - Route Map
            Section("Route Map") {
                PlannedRouteMapView(polyline: route.polyline, tips: route.preAnalysisTips)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            // MARK: - Route Summary
            Section("Route Summary") {
                HStack {
                    Label("Distance", systemImage: "road.lanes")
                    Spacer()
                    Text(String(format: "%.1f mi", route.distanceMiles))
                        .monospacedDigit()
                }
                HStack {
                    Label("Est. Time", systemImage: "clock")
                    Spacer()
                    Text(formatDuration(route.expectedTravelTimeSeconds))
                        .monospacedDigit()
                }
                if let traffic = route.trafficSummary {
                    HStack {
                        Label("Traffic", systemImage: "car.2")
                        Spacer()
                        Text(traffic.trafficCondition.rawValue.capitalized)
                            .foregroundStyle(trafficColor(traffic.trafficCondition))
                            .fontWeight(.medium)
                    }
                    if let trafficMinutes = traffic.trafficAwareMinutes {
                        HStack {
                            Label("With Traffic", systemImage: "clock.badge.exclamationmark")
                            Spacer()
                            Text(formatDuration(trafficMinutes * 60))
                                .monospacedDigit()
                        }
                    }
                }
                HStack {
                    Label("Turns", systemImage: "arrow.turn.right.up")
                    Spacer()
                    Text("\(route.steps.count)")
                        .monospacedDigit()
                }
            }

            // MARK: - Elevation Profile
            if let elevation = route.elevationProfile {
                Section("Elevation Profile") {
                    elevationChart(elevation)
                        .padding(.vertical, 4)

                    HStack {
                        Label("Total Climb", systemImage: "arrow.up.right")
                        Spacer()
                        Text(String(format: "%.0f m (%.0f ft)", elevation.totalAscentMeters, elevation.totalAscentMeters * 3.281))
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Total Descent", systemImage: "arrow.down.right")
                        Spacer()
                        Text(String(format: "%.0f m (%.0f ft)", elevation.totalDescentMeters, elevation.totalDescentMeters * 3.281))
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Highest Point", systemImage: "mountain.2")
                        Spacer()
                        Text(String(format: "%.0f m", elevation.maxAltitudeMeters))
                            .monospacedDigit()
                    }
                    HStack {
                        Label("Lowest Point", systemImage: "arrow.down")
                        Spacer()
                        Text(String(format: "%.0f m", elevation.minAltitudeMeters))
                            .monospacedDigit()
                    }
                    Text("Source: \(elevation.source.rawValue.replacingOccurrences(of: "fromDrive", with: "GPS from drive"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Elevation Profile") {
                    ContentUnavailableView(
                        "Elevation Pending",
                        systemImage: "mountain.2",
                        description: Text("Drive this route once and elevation data will be recorded from GPS.")
                    )
                }
            }

            // MARK: - Speed Limits
            if let speedProfile = route.speedLimitProfile, !speedProfile.segments.isEmpty {
                Section("Estimated Speed Limits") {
                    ForEach(Array(speedProfile.segments.prefix(10).enumerated()), id: \.offset) { _, seg in
                        if let limit = seg.estimatedSpeedLimitMph {
                            HStack {
                                Image(systemName: "speedometer")
                                    .foregroundStyle(.orange)
                                    .frame(width: 24)
                                Text(String(format: "%.0f mph", limit))
                                    .fontWeight(.medium)
                                Spacer()
                                Text(formatSegmentRange(seg))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Learned from previous drives")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Speed Limits") {
                    ContentUnavailableView(
                        "Speed Data Pending",
                        systemImage: "speedometer",
                        description: Text("Speed limits will be estimated after your first drive on this route.")
                    )
                }
            }

            // MARK: - Road Surface
            Section("Road Surface") {
                ContentUnavailableView(
                    "Surface Data Pending",
                    systemImage: "road.lanes",
                    description: Text("Road surface analysis will be available in a future update.")
                )
            }

            // MARK: - Coaching Tips
            if !route.preAnalysisTips.isEmpty {
                Section("Route Coaching Tips") {
                    ForEach(route.preAnalysisTips) { tip in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: tipIcon(tip.type))
                                    .foregroundStyle(tipColor(tip.type))
                                    .frame(width: 24)
                                Text(tip.message)
                                    .font(.subheadline.bold())
                            }
                            Text(tip.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 32)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // MARK: - Directions
            if !route.steps.isEmpty {
                Section("Turn-by-Turn Directions") {
                    ForEach(route.steps) { step in
                        HStack(alignment: .top) {
                            Image(systemName: "arrow.turn.up.right")
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.instructions)
                                    .font(.subheadline)
                                Text(formatStepDistance(step.distanceMeters))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(route.displayName)
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Elevation Chart

    @ViewBuilder
    private func elevationChart(_ profile: ElevationProfile) -> some View {
        Chart(profile.points, id: \.distanceFromStartMeters) { point in
            AreaMark(
                x: .value("Distance (mi)", point.distanceFromStartMeters / 1609.344),
                y: .value("Altitude (ft)", point.altitudeMeters * 3.281)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [.brown.opacity(0.4), .brown.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Distance (mi)", point.distanceFromStartMeters / 1609.344),
                y: .value("Altitude (ft)", point.altitudeMeters * 3.281)
            )
            .foregroundStyle(.brown)
            .interpolationMethod(.catmullRom)
        }
        .chartYAxisLabel("Elevation (ft)")
        .chartXAxisLabel("Distance (mi)")
        .frame(height: 180)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    private func formatSegmentRange(_ seg: SpeedLimitSegment) -> String {
        let startMi = seg.startDistanceMeters / 1609.344
        let endMi = seg.endDistanceMeters / 1609.344
        return String(format: "mi %.1f–%.1f", startMi, endMi)
    }

    private func formatStepDistance(_ meters: Double) -> String {
        if meters < 160 { return String(format: "%.0f ft", meters * 3.281) }
        return String(format: "%.1f mi", meters / 1609.344)
    }

    private func trafficColor(_ condition: TrafficSummary.TrafficCondition) -> Color {
        switch condition {
        case .light: .green
        case .moderate: .orange
        case .heavy: .red
        case .unknown: .secondary
        }
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
