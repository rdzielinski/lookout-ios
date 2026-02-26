import Foundation
import AVFoundation
import UIKit
import CoreLocation

// MARK: - Background Keep-Alive Service
/// Ensures Lookout stays alive during long sessions (3+ hours).
///
/// iOS will suspend/kill apps in background after ~30 seconds.
/// This service uses three complementary strategies:
///
/// 1. **Idle Timer Disabled** — Prevents auto-lock while active features run
/// 2. **Silent Audio Loop** — Plays inaudible audio to hold a background audio session
/// 3. **Background Location** — Keeps location updates for proactive narration
///
/// All strategies are activated only when the user explicitly enables a long-running
/// feature (continuous scan, glasses mode, proactive narration). They are torn down
/// when the user disables the feature or the app enters the background without
/// an active session.
class BackgroundKeepAliveService: NSObject {
    static let shared = BackgroundKeepAliveService()

    private var audioPlayer: AVAudioPlayer?
    private var isAudioSessionActive = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Track which features are keeping us alive
    private(set) var activeContinuousScan = false
    private(set) var activeGlassesMode = false
    private(set) var activeProactiveNarration = false

    private var isAnyFeatureActive: Bool {
        activeContinuousScan || activeGlassesMode || activeProactiveNarration
    }

    private override init() {
        super.init()
        // Listen for app lifecycle events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - Feature Activation

    func setContinuousScan(_ active: Bool) {
        activeContinuousScan = active
        updateKeepAlive()
    }

    func setGlassesMode(_ active: Bool) {
        activeGlassesMode = active
        updateKeepAlive()
    }

    func setProactiveNarration(_ active: Bool) {
        activeProactiveNarration = active
        updateKeepAlive()
    }

    // MARK: - Central Update

    private func updateKeepAlive() {
        if isAnyFeatureActive {
            enableIdleTimerPrevention()
            startSilentAudioSession()
        } else {
            disableIdleTimerPrevention()
            stopSilentAudioSession()
            endBackgroundTaskIfNeeded()
        }
    }

    // MARK: - Strategy 1: Prevent Auto-Lock

    private func enableIdleTimerPrevention() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func disableIdleTimerPrevention() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Strategy 2: Silent Audio Session
    /// Playing silent audio keeps the app alive in background.
    /// This is the same technique used by navigation, fitness, and meditation apps.

    private func startSilentAudioSession() {
        guard !isAudioSessionActive else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Generate a tiny silent WAV in memory (1 second of silence)
            let silentData = generateSilentWAV(durationSeconds: 1.0, sampleRate: 8000)
            audioPlayer = try AVAudioPlayer(data: silentData)
            audioPlayer?.numberOfLoops = -1  // Loop forever
            audioPlayer?.volume = 0.0
            audioPlayer?.play()

            isAudioSessionActive = true
            #if DEBUG
            print("🔋 Background keep-alive: silent audio started")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Background keep-alive: failed to start audio — \(error)")
            #endif
        }
    }

    private func stopSilentAudioSession() {
        guard isAudioSessionActive else { return }

        audioPlayer?.stop()
        audioPlayer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isAudioSessionActive = false

        #if DEBUG
        print("🔋 Background keep-alive: silent audio stopped")
        #endif
    }

    /// Generate minimal silent WAV data in memory (no file needed).
    private func generateSilentWAV(durationSeconds: Double, sampleRate: Int = 8000) -> Data {
        let numSamples = Int(durationSeconds * Double(sampleRate))
        let bitsPerSample = 16
        let numChannels = 1
        let bytesPerSample = bitsPerSample / 8
        let dataSize = numSamples * bytesPerSample * numChannels
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // sub-chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        let byteRate = sampleRate * numChannels * bytesPerSample
        data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        let blockAlign = numChannels * bytesPerSample
        data.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data sub-chunk (all zeros = silence)
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(Data(count: dataSize))

        return data
    }

    // MARK: - Strategy 3: Background Task Extension

    @objc private func appDidEnterBackground() {
        guard isAnyFeatureActive else { return }

        // Request extended background execution time
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LookoutKeepAlive") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }

        #if DEBUG
        print("🔋 Background task started (remaining: \(UIApplication.shared.backgroundTimeRemaining)s)")
        #endif
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTaskIfNeeded()
    }

    @objc private func appWillTerminate() {
        stopSilentAudioSession()
        disableIdleTimerPrevention()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Diagnostics

    var statusDescription: String {
        var features: [String] = []
        if activeContinuousScan { features.append("Continuous Scan") }
        if activeGlassesMode { features.append("Glasses Mode") }
        if activeProactiveNarration { features.append("Proactive Narration") }

        if features.isEmpty {
            return "Idle — no keep-alive active"
        }
        let audioStatus = isAudioSessionActive ? "audio session active" : "no audio"
        let idleStatus = UIApplication.shared.isIdleTimerDisabled ? "auto-lock disabled" : "auto-lock enabled"
        return "\(features.joined(separator: ", ")) — \(audioStatus), \(idleStatus)"
    }
}
