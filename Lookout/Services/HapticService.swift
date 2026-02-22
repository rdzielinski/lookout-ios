//
//  HapticService.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/13/26.
//

import UIKit
import CoreHaptics

// MARK: - Haptic Service
class HapticService {

    static let shared = HapticService()

    // MARK: - CoreHaptics Engine
    private var engine: CHHapticEngine?
    private var engineNeedsStart = true

    private var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - UIFeedbackGenerator Fallbacks
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    // MARK: - Lifecycle Observers
    private var foregroundObserver: Any?
    private var backgroundObserver: Any?

    private init() {
        impactLight.prepare()
        impactMedium.prepare()
        notification.prepare()

        if supportsHaptics {
            prepareEngine()
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareEngine()
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopEngine()
        }
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    // MARK: - Engine Management

    private func prepareEngine() {
        guard supportsHaptics else { return }

        do {
            engine = try CHHapticEngine()
            engine?.playsHapticsOnly = true
            engine?.isAutoShutdownEnabled = true

            engine?.stoppedHandler = { [weak self] reason in
                self?.engineNeedsStart = true
            }

            engine?.resetHandler = { [weak self] in
                self?.engineNeedsStart = true
                self?.prepareEngine()
            }

            try engine?.start()
            engineNeedsStart = false
        } catch {
            #if DEBUG
            print("Haptic engine init error: \(error)")
            #endif
        }
    }

    private func stopEngine() {
        engine?.stop()
        engineNeedsStart = true
    }

    private func playPattern(_ events: [CHHapticEvent]) {
        guard supportsHaptics, let engine else { return }

        do {
            if engineNeedsStart {
                try engine.start()
                engineNeedsStart = false
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            #if DEBUG
            print("Haptic play error: \(error)")
            #endif
        }
    }

    private func playPatternWithCurve(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve]) {
        guard supportsHaptics, let engine else { return }

        do {
            if engineNeedsStart {
                try engine.start()
                engineNeedsStart = false
            }
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            #if DEBUG
            print("Haptic play error: \(error)")
            #endif
        }
    }

    // MARK: - Scan Flow Haptics

    /// Quick double-tap when scan starts (voice trigger detected / capture pressed)
    func scanStarted() {
        if supportsHaptics {
            playPattern([
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    ],
                    relativeTime: 0.08
                )
            ])
        } else {
            impactMedium.impactOccurred()
            impactMedium.prepare()
        }
    }

    /// Backward-compatible alias
    func capturePressed() {
        scanStarted()
    }

    /// Gentle ramping buzz while AI is analyzing
    func analyzing() {
        if supportsHaptics {
            let continuous = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.2),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                ],
                relativeTime: 0,
                duration: 1.5
            )
            let curve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.2),
                    CHHapticParameterCurve.ControlPoint(relativeTime: 1.5, value: 0.6)
                ],
                relativeTime: 0
            )
            playPatternWithCurve([continuous], curves: [curve])
        } else {
            impactLight.impactOccurred(intensity: 0.4)
            impactLight.prepare()
        }
    }

    /// Satisfying success: sharp tap then gentle fade
    func resultReady() {
        if supportsHaptics {
            playPattern([
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
                    ],
                    relativeTime: 0.1,
                    duration: 0.25
                )
            ])
        } else {
            notification.notificationOccurred(.success)
            notification.prepare()
        }
    }

    /// Two heavy thuds with pause
    func error() {
        if supportsHaptics {
            playPattern([
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                    ],
                    relativeTime: 0.25
                )
            ])
        } else {
            notification.notificationOccurred(.error)
            notification.prepare()
        }
    }

    // MARK: - People Recognition

    /// Three quick light taps when a known person is recognized
    func personRecognized() {
        if supportsHaptics {
            playPattern([
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                    ],
                    relativeTime: 0.08
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                    ],
                    relativeTime: 0.16
                )
            ])
        } else {
            impactLight.impactOccurred(intensity: 0.5)
            impactLight.prepare()
        }
    }

    // MARK: - Conversation Haptics

    /// Single soft pulse when follow-up listening starts
    func listeningForFollowUp() {
        if supportsHaptics {
            playPattern([
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
                    ],
                    relativeTime: 0
                )
            ])
        } else {
            impactLight.impactOccurred(intensity: 0.3)
            impactLight.prepare()
        }
    }

    /// Double tap descending — confirms audio-only mode activated
    func audioOnlyConfirmed() {
        if supportsHaptics {
            playPattern([
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0.12
                )
            ])
        } else {
            impactMedium.impactOccurred(intensity: 0.5)
            impactMedium.prepare()
        }
    }

    // MARK: - Existing Haptics (unchanged)

    func categorized() {
        impactLight.impactOccurred(intensity: 0.6)
        impactLight.prepare()
    }

    func cameraFlipped() {
        impactLight.impactOccurred(intensity: 0.5)
        impactLight.prepare()
    }

    func recordingStarted() {
        impactMedium.impactOccurred(intensity: 0.7)
        impactMedium.prepare()
    }

    func recordingSent() {
        impactLight.impactOccurred(intensity: 0.5)
        impactLight.prepare()
    }

    func followUpReady() {
        impactLight.impactOccurred(intensity: 0.4)
        impactLight.prepare()
    }

    func toggle() {
        selection.selectionChanged()
        selection.prepare()
    }

    func interrupted() {
        impactHeavy.impactOccurred(intensity: 0.5)
        impactHeavy.prepare()
    }

    func barcodeDetected() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }
}
