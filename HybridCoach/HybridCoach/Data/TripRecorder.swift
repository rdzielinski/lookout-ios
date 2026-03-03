import Foundation

/// Records trip data by accumulating distance, fuel usage, and efficiency scores.
/// Persists completed trips to JSON on disk.
@MainActor
@Observable
final class TripRecorder {

    private(set) var currentTrip: Trip?
    private(set) var pastTrips: [Trip] = []
    private(set) var isRecording = false

    /// Optional GPS tracker for route recording.
    var locationTracker: LocationTracker?
    /// Optional route store for clustering completed routes.
    var routeStore: RouteStore?
    /// Optional planned route store for learning/backfill after drives.
    var plannedRouteStore: PlannedRouteStore?

    private var lastSnapshotTime: Date?
    private var lastSpeedMph: Double = 0
    private let snapshotInterval: TimeInterval = 5.0  // Snapshot every 5 seconds
    private let storageURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("trips.json")
        loadTrips()
    }

    // MARK: - Recording

    func startTrip() {
        currentTrip = Trip()
        isRecording = true
        lastSnapshotTime = Date()
        lastSpeedMph = 0
        locationTracker?.startTracking()
    }

    func stopTrip() {
        guard var trip = currentTrip else { return }
        trip.endTime = Date()

        // Finalize GPS route
        let polyline = locationTracker?.stopTracking() ?? []
        if polyline.count >= 2, let routeStore {
            let routeRecord = RouteRecord(
                id: UUID(),
                tripID: trip.id,
                startCoordinate: polyline.first!,
                endCoordinate: polyline.last!,
                polyline: polyline,
                distanceMiles: trip.distanceMiles,
                averageMPG: trip.averageMPG,
                evModePercentage: trip.evModePercentage,
                efficiencyScore: trip.averageEfficiencyScore,
                date: Date()
            )
            routeStore.addRoute(routeRecord)

            // Backfill planned route data with elevation/speed from this drive
            routeStore.backfillPlannedRouteData(routeRecord: routeRecord, plannedRouteStore: plannedRouteStore)
        }

        pastTrips.insert(trip, at: 0)
        currentTrip = nil
        isRecording = false
        saveTrips()
    }

    /// Called on every polling cycle to accumulate trip data.
    func update(data: DrivingDataStore, efficiencyScore: Int) {
        guard isRecording, var trip = currentTrip else { return }

        let now = Date()

        // Accumulate time
        let elapsed = trip.startTime.distance(to: now)
        trip.totalSeconds = elapsed

        // Accumulate EV time
        if data.isEVMode {
            // Approximate: each update is ~0.25s
            trip.evModeSeconds += 0.25
        }

        // Accumulate distance (speed × time increment)
        let speedMph = data.vehicleSpeedMph
        let timeDelta: Double = 0.25 // approximate cycle time
        let distanceDelta = speedMph * (timeDelta / 3600.0) // miles
        trip.distanceMiles += distanceDelta

        // Accumulate fuel (GPH × time)
        let gph = data.gallonsPerHour
        if gph > 0 {
            trip.fuelUsedGallons += gph * (timeDelta / 3600.0)
        }

        // Track maximums
        trip.maxRPM = max(trip.maxRPM, data.engineRPM)
        trip.maxSpeedMph = max(trip.maxSpeedMph, speedMph)

        // Accumulate efficiency score
        trip.efficiencyScoreSum += Double(efficiencyScore)
        trip.efficiencyScoreSamples += 1

        // Periodic snapshots
        if let lastSnapshot = lastSnapshotTime,
           now.timeIntervalSince(lastSnapshot) >= snapshotInterval {
            let snapshot = TripSnapshot(
                timestamp: now,
                speedMph: speedMph,
                rpm: data.engineRPM,
                instantMPG: data.instantMPG,
                isEVMode: data.isEVMode,
                efficiencyScore: efficiencyScore,
                latitude: locationTracker?.currentLatitude,
                longitude: locationTracker?.currentLongitude
            )
            trip.snapshots.append(snapshot)
            lastSnapshotTime = now
        }

        lastSpeedMph = speedMph
        currentTrip = trip
    }

    // MARK: - Trip Management

    func deleteTrips(at offsets: IndexSet) {
        pastTrips.remove(atOffsets: offsets)
        saveTrips()
    }

    func clearAllTrips() {
        pastTrips.removeAll()
        saveTrips()
    }

    // MARK: - Persistence

    private func saveTrips() {
        do {
            let data = try JSONEncoder().encode(pastTrips)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("TripRecorder: Failed to save trips — \(error.localizedDescription)")
        }
    }

    private func loadTrips() {
        do {
            let data = try Data(contentsOf: storageURL)
            pastTrips = try JSONDecoder().decode([Trip].self, from: data)
        } catch {
            // First launch or corrupted file — start fresh
            pastTrips = []
        }
    }
}
