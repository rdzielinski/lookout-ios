import Foundation

// MARK: - Coaching Tip Model

struct CoachingTip: Identifiable {
    let id = UUID()
    let category: TipCategory
    let severity: TipSeverity
    let message: String
    let detail: String
    let timestamp: Date

    enum TipCategory: String {
        case rpm = "RPM"
        case acceleration = "Acceleration"
        case speed = "Speed"
        case warmup = "Warmup"
        case evMode = "EV Mode"
        case braking = "Braking"
        case climate = "Climate"
        case tirePressure = "Tires"
    }

    enum TipSeverity: String {
        case info
        case suggestion
        case warning
    }
}

// MARK: - Efficiency Analyzer

/// Analyzes live driving data and generates real-time coaching tips.
/// Implements 8 coaching rules optimized for RAV4 Hybrid efficiency.
@Observable
final class EfficiencyAnalyzer {

    private(set) var activeTips: [CoachingTip] = []
    private(set) var currentEfficiencyScore: Int = 100
    private(set) var routeCoachingTips: [RouteCoachingTip] = []

    /// Coaching intensity multiplier (lower = more lenient, higher = stricter).
    /// Adjusted via AppSettings.coachingIntensity.
    var intensityMultiplier: Double = 1.0

    private var lastTipTime: [CoachingTip.TipCategory: Date] = [:]
    private var scoreDeductions: [String: Int] = [:]

    /// Cooldown per rule category (seconds) to avoid tip spam.
    private let cooldowns: [CoachingTip.TipCategory: TimeInterval] = [
        .rpm: 30,
        .acceleration: 20,
        .speed: 60,
        .warmup: 45,
        .evMode: 30,
        .braking: 20,
        .climate: 60,
        .tirePressure: 300  // 5 minutes — only on ambient temp change
    ]

    /// Maximum tip age before auto-pruning (seconds).
    private let tipMaxAge: TimeInterval = 120

    // MARK: - Public

    func analyze(data: DrivingDataStore) {
        pruneOldTips()

        // Run all 8 coaching rules
        checkHighRPM(data)
        checkAggressiveAcceleration(data)
        checkOptimalSpeed(data)
        checkEngineWarmup(data)
        checkEVModeOpportunity(data)
        checkCoastingRegen(data)
        checkClimateImpact(data)
        checkTirePressure(data)

        // Recalculate efficiency score
        calculateScore(data)
    }

    func clearTips() {
        activeTips.removeAll()
        scoreDeductions.removeAll()
        routeCoachingTips.removeAll()
    }

    /// Updates route-specific coaching tips for the current route cluster.
    func updateRouteCoaching(cluster: RouteCluster, routes: [RouteRecord]) {
        routeCoachingTips = RouteCoachingEngine.generateTips(for: cluster, routes: routes)
    }

    // MARK: - Rule 1: High RPM Warning

    private func checkHighRPM(_ data: DrivingDataStore) {
        let rpmThreshold = 3000.0 / intensityMultiplier  // relaxed=3750, normal=3000, aggressive=2400
        guard data.vehicleSpeedMph > 5, data.engineRPM > rpmThreshold else {
            scoreDeductions.removeValue(forKey: "rpm")
            return
        }

        scoreDeductions["rpm"] = data.engineRPM > 4000 ? 15 : 10

        addTip(
            category: .rpm,
            severity: data.engineRPM > 4000 ? .warning : .suggestion,
            message: "RPM too high (\(Int(data.engineRPM)))",
            detail: "Ease off the gas. Your RAV4 Hybrid's electric motor assists most efficiently under 3,000 RPM. High RPM wastes fuel and increases engine wear."
        )
    }

    // MARK: - Rule 2: Aggressive Acceleration

    private func checkAggressiveAcceleration(_ data: DrivingDataStore) {
        // Check throttle change rate from history
        let history = data.recentThrottlePositions
        guard history.count >= 4 else { return }

        let recent = Array(history.suffix(4))
        let maxDelta = zip(recent, recent.dropFirst()).map { abs($1 - $0) }.max() ?? 0

        // Each sample is ~0.5s apart, so delta per sample × 2 ≈ %/sec
        let ratePerSecond = maxDelta * 2

        let accelThreshold = 30.0 / intensityMultiplier  // relaxed=37.5, normal=30, aggressive=24
        guard ratePerSecond > accelThreshold else {
            scoreDeductions.removeValue(forKey: "accel")
            return
        }

        scoreDeductions["accel"] = ratePerSecond > 50 ? 15 : 10

        addTip(
            category: .acceleration,
            severity: ratePerSecond > 50 ? .warning : .suggestion,
            message: "Aggressive acceleration detected",
            detail: "Gradual throttle input lets the hybrid system blend electric and gas power optimally. Aim for smooth, steady acceleration."
        )
    }

    // MARK: - Rule 3: Optimal Speed

    private func checkOptimalSpeed(_ data: DrivingDataStore) {
        guard data.vehicleSpeedMph > 55 else {
            scoreDeductions.removeValue(forKey: "speed")
            return
        }

        let overSpeed = data.vehicleSpeedMph - 50
        scoreDeductions["speed"] = min(Int(overSpeed / 5) * 5, 20)

        addTip(
            category: .speed,
            severity: data.vehicleSpeedMph > 70 ? .warning : .info,
            message: "Speed above optimal range",
            detail: "The RAV4 Hybrid's sweet spot is 40-50 mph. Aerodynamic drag increases exponentially above 50 mph — every 10 mph over costs ~15% more fuel."
        )
    }

    // MARK: - Rule 4: Engine Warmup

    private func checkEngineWarmup(_ data: DrivingDataStore) {
        guard data.coolantTemp > 0, data.coolantTemp < 70 else {
            scoreDeductions.removeValue(forKey: "warmup")
            return
        }

        // Only warn if driving aggressively while cold
        guard data.engineRPM > 2500 || data.throttlePosition > 40 else { return }

        scoreDeductions["warmup"] = 10

        addTip(
            category: .warmup,
            severity: .suggestion,
            message: "Engine still warming up (\(Int(data.coolantTemp))°C)",
            detail: "Drive gently until coolant reaches 70°C. Cold engines have more friction and less efficient combustion. The hybrid system will use the electric motor more as the engine warms."
        )
    }

    // MARK: - Rule 5: EV Mode Maximization

    private func checkEVModeOpportunity(_ data: DrivingDataStore) {
        // Conditions for potential EV mode: low speed, warm engine, engine running
        guard !data.isEVMode,
              data.isEngineRunning,
              data.vehicleSpeedMph > 5,
              data.vehicleSpeedMph < 30,
              data.coolantTemp > 70,
              data.engineLoad < 30,
              data.throttlePosition < 20 else {
            return
        }

        addTip(
            category: .evMode,
            severity: .info,
            message: "EV mode opportunity",
            detail: "Try gently lifting off the throttle at this speed. Your RAV4 Hybrid can run on electric power alone at low speeds with light throttle input."
        )
    }

    // MARK: - Rule 6: Coasting & Regen Braking

    private func checkCoastingRegen(_ data: DrivingDataStore) {
        // Detect hard braking: speed dropping rapidly while RPM is low (regen)
        let speedHistory = data.recentSpeeds
        guard speedHistory.count >= 4 else { return }

        let recent = Array(speedHistory.suffix(4))
        let speedDrop = (recent.first ?? 0) - (recent.last ?? 0)

        // Rapid deceleration (>15 mph drop in ~2 seconds)
        guard speedDrop > 15, data.vehicleSpeedMph > 10 else { return }

        scoreDeductions["braking"] = 5

        addTip(
            category: .braking,
            severity: .suggestion,
            message: "Anticipate stops for better regen",
            detail: "Lift off the gas early and coast. Your RAV4 recovers energy through regenerative braking — gentle, early deceleration captures more energy than hard braking."
        )
    }

    // MARK: - Rule 7: Climate Impact

    private func checkClimateImpact(_ data: DrivingDataStore) {
        // DrivingDataStore initializes ambientTemp to -40 (OBD "no reading" sentinel).
        // 0°C is a valid temperature — don't use it as a "no data" check.
        guard data.ambientTemp > -39 else { return }

        if data.ambientTemp > 35 && data.engineLoad > 50 {
            addTip(
                category: .climate,
                severity: .info,
                message: "Hot weather affecting efficiency",
                detail: "A/C draws extra power in hot weather. Consider reducing fan speed or using recirculate mode. Parking in shade helps reduce cabin heat."
            )
        } else if data.ambientTemp < 5 {
            addTip(
                category: .climate,
                severity: .info,
                message: "Cold weather reducing efficiency",
                detail: "Cold temps reduce battery capacity and the heater draws from the hybrid system. Short trips in cold weather are the least efficient — combine errands when possible."
            )
        }
    }

    // MARK: - Rule 8: Tire Pressure Reminder

    private func checkTirePressure(_ data: DrivingDataStore) {
        guard let initial = data.initialAmbientTemp, data.ambientTemp != 0 else { return }

        let tempChange = abs(data.ambientTemp - initial)
        guard tempChange > 10 else { return }

        addTip(
            category: .tirePressure,
            severity: .info,
            message: "Check tire pressure",
            detail: "Ambient temperature changed by \(Int(tempChange))°C since your session started. Tire pressure drops ~1 PSI for every 10°F decrease. Properly inflated tires (36 PSI for RAV4 Hybrid) improve efficiency by 3%."
        )
    }

    // MARK: - Efficiency Score

    private func calculateScore(_ data: DrivingDataStore) {
        // Start at 100, subtract deductions
        var score = 100

        for (_, deduction) in scoreDeductions {
            score -= deduction
        }

        // Bonus for EV mode
        if data.isEVMode {
            score = min(100, score + 5)
        }

        // Bonus for gentle driving (low throttle + moderate speed)
        if data.throttlePosition < 25 && data.vehicleSpeedMph > 20 && data.vehicleSpeedMph < 55 {
            score = min(100, score + 5)
        }

        currentEfficiencyScore = max(0, min(100, score))
    }

    // MARK: - Tip Management

    private func addTip(category: CoachingTip.TipCategory, severity: CoachingTip.TipSeverity, message: String, detail: String) {
        let now = Date()

        // Check cooldown
        if let lastTime = lastTipTime[category],
           now.timeIntervalSince(lastTime) < (cooldowns[category] ?? 30) {
            return
        }

        // Remove existing tip of same category
        activeTips.removeAll { $0.category == category }

        let tip = CoachingTip(
            category: category,
            severity: severity,
            message: message,
            detail: detail,
            timestamp: now
        )

        activeTips.append(tip)
        lastTipTime[category] = now
    }

    private func pruneOldTips() {
        let now = Date()
        activeTips.removeAll { now.timeIntervalSince($0.timestamp) > tipMaxAge }
    }
}
