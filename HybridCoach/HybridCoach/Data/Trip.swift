import Foundation

struct Trip: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    var distanceMiles: Double
    var fuelUsedGallons: Double
    var evModeSeconds: Double
    var totalSeconds: Double
    var maxRPM: Double
    var maxSpeedMph: Double
    var efficiencyScoreSum: Double
    var efficiencyScoreSamples: Int
    var snapshots: [TripSnapshot]

    var averageMPG: Double {
        fuelUsedGallons > 0.001 ? distanceMiles / fuelUsedGallons : 0
    }

    var evModePercentage: Double {
        totalSeconds > 0 ? (evModeSeconds / totalSeconds) * 100.0 : 0
    }

    var averageEfficiencyScore: Int {
        efficiencyScoreSamples > 0 ? Int(efficiencyScoreSum / Double(efficiencyScoreSamples)) : 100
    }

    var durationFormatted: String {
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    init() {
        self.id = UUID()
        self.startTime = Date()
        self.endTime = nil
        self.distanceMiles = 0
        self.fuelUsedGallons = 0
        self.evModeSeconds = 0
        self.totalSeconds = 0
        self.maxRPM = 0
        self.maxSpeedMph = 0
        self.efficiencyScoreSum = 0
        self.efficiencyScoreSamples = 0
        self.snapshots = []
    }
}

struct TripSnapshot: Codable {
    let timestamp: Date
    let speedMph: Double
    let rpm: Double
    let instantMPG: Double?
    let isEVMode: Bool

    // Phase 1: efficiency score at snapshot time (nil for old trips)
    let efficiencyScore: Int?

    // Phase 4: GPS coordinates (nil until route tracking is added)
    let latitude: Double?
    let longitude: Double?

    // Backward-compatible decoding: old trips won't have these fields
    enum CodingKeys: String, CodingKey {
        case timestamp, speedMph, rpm, instantMPG, isEVMode
        case efficiencyScore, latitude, longitude
    }

    init(timestamp: Date, speedMph: Double, rpm: Double, instantMPG: Double?,
         isEVMode: Bool, efficiencyScore: Int? = nil,
         latitude: Double? = nil, longitude: Double? = nil) {
        self.timestamp = timestamp
        self.speedMph = speedMph
        self.rpm = rpm
        self.instantMPG = instantMPG
        self.isEVMode = isEVMode
        self.efficiencyScore = efficiencyScore
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        speedMph = try container.decode(Double.self, forKey: .speedMph)
        rpm = try container.decode(Double.self, forKey: .rpm)
        instantMPG = try container.decodeIfPresent(Double.self, forKey: .instantMPG)
        isEVMode = try container.decode(Bool.self, forKey: .isEVMode)
        efficiencyScore = try container.decodeIfPresent(Int.self, forKey: .efficiencyScore)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    }
}
