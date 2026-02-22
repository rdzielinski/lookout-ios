import Foundation
import Combine
import AVFoundation
import UIKit
import Speech

#if canImport(MWDATCore)
import MWDATCore
#endif

#if canImport(MWDATCamera)
import MWDATCamera
#endif

// MARK: - Glasses Connection State
enum GlassesConnectionState: String {
    case disconnected = "Disconnected"
    case searching = "Searching..."
    case connecting = "Connecting..."
    case connected = "Connected"
    case streaming = "Ready"
    case error = "Error"
}

// MARK: - Glasses Service
/// Bridges Meta Ray-Ban smart glasses to Lookout's existing AI pipeline.
/// Handles: connection, photo capture, voice trigger, audio output via Bluetooth.
/// Voice trigger also works on phone mic without glasses connected.
@MainActor
class GlassesService: ObservableObject {

    // MARK: - Published State
    @Published var connectionState: GlassesConnectionState = .disconnected
    @Published var isGlassesConnected = false
    @Published var isListeningForTrigger = false
    @Published var lastError: String?
    @Published var deviceName: String?

    // MARK: - Callbacks
    var onPhotoCaptured: ((Data) -> Void)?
    var onVoiceTriggerDetected: (() -> Void)?

    // MARK: - Private — SDK objects
    #if canImport(MWDATCore)
    private let wearables = Wearables.shared
    private var streamSession: StreamSession?
    private var deviceSelector: AutoDeviceSelector?

    private var stateListenerToken: AnyListenerToken?
    private var videoFrameListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private var photoDataListenerToken: AnyListenerToken?
    #endif

    private var registrationTask: Task<Void, Never>?
    private var deviceStreamTask: Task<Void, Never>?

    // Voice trigger — own audio engine separate from VoiceInputService
    private var triggerAudioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var triggerRestartTask: Task<Void, Never>?

    // Track consecutive errors to avoid infinite restart loops
    private var consecutiveErrors = 0
    private let maxConsecutiveErrors = 5

    // Connection timeout & retry
    private var connectionTimeoutTask: Task<Void, Never>?
    private var connectionRetryCount = 0
    private let maxConnectionRetries = 3
    private let connectionTimeoutSeconds: UInt64 = 15  // seconds before retry
    @Published var connectionAttemptInfo: String?  // status detail for UI

    // Voice trigger config
    var triggerPhrase = "lookout"
    var triggerEnabled = true

    // Mock notification observers
    private var mockObservers: [Any] = []

    // Foreground observer for post-OAuth registration check
    private var foregroundObserver: Any?

    // MARK: - Initialization

    init() {
        #if DEBUG
        setupMockNotificationListeners()
        #endif
    }

    deinit {
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
        connectionTimeoutTask?.cancel()
        triggerRestartTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        #if DEBUG
        mockObservers.forEach { NotificationCenter.default.removeObserver($0) }
        #endif
    }

    // MARK: - Mock Notification Listeners (DEBUG only)

    #if DEBUG
    private func setupMockNotificationListeners() {
        let voiceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("mockGlassesVoiceTrigger"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("🕶️ Mock voice trigger received")
                self.onVoiceTriggerDetected?()
            }
        }
        mockObservers.append(voiceObserver)

        let photoObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("mockGlassesPhotoCapture"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      let imageData = notification.userInfo?["imageData"] as? Data else { return }
                print("🕶️ Mock photo capture received (\(imageData.count) bytes)")
                self.onPhotoCaptured?(imageData)
            }
        }
        mockObservers.append(photoObserver)
    }
    #endif

    // MARK: - Connection Management

    func connect() {
        #if canImport(MWDATCore)
        connectionState = .searching
        lastError = nil
        connectionAttemptInfo = nil

        // Listen on the registration stream for async state changes
        registrationTask = Task { @MainActor in
            for await regState in wearables.registrationStateStream() {
                switch regState {
                case .registered:
                    connectionState = .connecting
                    setupDeviceStream()
                case .registering:
                    connectionState = .searching
                @unknown default:
                    break
                }
            }
        }

        if wearables.registrationState == .registered {
            // Already paired — go straight to device discovery
            connectionState = .connecting
            setupDeviceStream()
        } else {
            // Not yet paired — launch Meta AI for OAuth pairing.
            // When the user finishes pairing and is redirected back, iOS calls
            // LookoutApp.onOpenURL → Wearables.shared.handleUrl(url).
            // The registrationStateStream above should then emit .registered,
            // BUT in practice the stream event can be missed when the app is
            // backgrounded. We therefore also install a foreground observer
            // that synchronously re-checks registrationState the moment the
            // app becomes active again — this reliably catches the post-OAuth
            // return trip.
            installForegroundRegistrationCheck()

            Task {
                do {
                    try await wearables.startRegistration()
                } catch {
                    connectionState = .error
                    lastError = error.localizedDescription
                }
            }
        }
        #else
        connectionState = .error
        lastError = "Meta Wearables SDK not available"
        #endif
    }

    #if canImport(MWDATCore)
    /// Installs a one-shot UIApplication.didBecomeActiveNotification observer
    /// so that if the registrationStateStream misses the .registered event while
    /// the app was backgrounded (the typical OAuth redirect scenario), we still
    /// advance the state machine as soon as the user returns to Lookout.
    private func installForegroundRegistrationCheck() {
        // Remove any previous observer to avoid duplicates
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
            foregroundObserver = nil
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // Tear down synchronously so subsequent foreground events don't re-fire.
            // (The Task below is async; removing here prevents duplicate executions.)
            if let obs = self.foregroundObserver {
                NotificationCenter.default.removeObserver(obs)
                self.foregroundObserver = nil
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                #if DEBUG
                print("🕶️ App became active — checking registration state: \(self.wearables.registrationState)")
                #endif

                // Only act if we are still waiting (searching) and now registered
                guard self.connectionState == .searching,
                      self.wearables.registrationState == .registered else { return }

                // We are registered — advance to device discovery
                self.connectionState = .connecting
                self.setupDeviceStream()
            }
        }
    }
    #endif

    func disconnect() {
        // Remove the foreground registration observer if it's still pending
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }

        #if canImport(MWDATCore)
        Task {
            if let session = streamSession {
                await session.stop()
            }
            streamSession = nil
            stateListenerToken = nil
            videoFrameListenerToken = nil
            errorListenerToken = nil
            photoDataListenerToken = nil
        }
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
        connectionTimeoutTask?.cancel()
        #endif

        stopVoiceTriggerListening()
        connectionState = .disconnected
        isGlassesConnected = false
        deviceName = nil
        connectionAttemptInfo = nil
    }

    // MARK: - Device Discovery

    #if canImport(MWDATCore)
    private func setupDeviceStream() {
        deviceStreamTask?.cancel()
        connectionTimeoutTask?.cancel()

        // Start a timeout that will retry the connection if no device is found
        startConnectionTimeout()

        deviceStreamTask = Task { @MainActor in
            for await devices in wearables.devicesStream() {
                if let firstDeviceId = devices.first {
                    if let device = wearables.deviceForIdentifier(firstDeviceId) {
                        deviceName = device.nameOrId()
                    } else {
                        deviceName = firstDeviceId
                    }
                    connectionState = .connected
                    isGlassesConnected = true
                    connectionRetryCount = 0
                    connectionAttemptInfo = nil
                    connectionTimeoutTask?.cancel()

                    #if DEBUG
                    print("🕶️ Glasses connected: \(deviceName ?? "unknown")")
                    #endif
                } else {
                    // Empty device list — glasses not yet in range (or just disconnected).
                    // Don't retreat to .searching (which re-launches the Meta AI OAuth flow);
                    // stay at .connecting so we keep waiting for the glasses to appear.
                    if isGlassesConnected {
                        // Was connected, now lost — stay in connecting to allow fast reconnect
                        isGlassesConnected = false
                        deviceName = nil
                        connectionState = .connecting
                        connectionRetryCount = 0
                        startConnectionTimeout()
                        #if DEBUG
                        print("🕶️ Glasses lost — waiting to reconnect...")
                        #endif
                    } else {
                        // Still waiting for the first connection after pairing
                        connectionState = .connecting
                    }
                }
            }
        }
    }

    /// Fires after `connectionTimeoutSeconds` if no device is found.
    /// Tears down the device stream and retries, or gives up with an actionable error.
    private func startConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let attempt = self.connectionRetryCount + 1
            let total = self.maxConnectionRetries + 1
            self.connectionAttemptInfo = "Attempt \(attempt) of \(total)"

            #if DEBUG
            print("🕶️ Connection timeout started — attempt \(attempt), waiting \(self.connectionTimeoutSeconds)s")
            #endif

            try? await Task.sleep(nanoseconds: self.connectionTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }

            // Still not connected after timeout
            guard self.connectionState == .connecting else { return }

            if self.connectionRetryCount < self.maxConnectionRetries {
                self.connectionRetryCount += 1
                #if DEBUG
                print("🕶️ Connection timed out — retrying (\(self.connectionRetryCount)/\(self.maxConnectionRetries))")
                #endif

                // Tear down and restart device stream
                self.deviceStreamTask?.cancel()
                self.setupDeviceStream()
            } else {
                // Out of retries — surface an error so the user can act
                #if DEBUG
                print("🕶️ Connection failed after \(total) attempts")
                #endif
                self.connectionState = .error
                self.lastError = "Could not find glasses. Make sure they are powered on, unfolded, and nearby."
                self.connectionAttemptInfo = nil
            }
        }
    }
    #endif

    /// Opens iOS Bluetooth settings so the user can verify pairing at the OS level.
    static func openBluetoothSettings() {
        if let url = URL(string: "App-Prefs:root=Bluetooth") {
            UIApplication.shared.open(url)
        }
    }

    /// Manually retry the glasses connection (called from UI retry button)
    func retryConnection() {
        connectionRetryCount = 0
        connectionAttemptInfo = nil
        lastError = nil
        connect()
    }

    // MARK: - Photo Capture

    func capturePhoto() {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        Task { @MainActor in
            do {
                let status = try await wearables.checkPermissionStatus(.camera)
                if status != .granted {
                    let requestStatus = try await wearables.requestPermission(.camera)
                    guard requestStatus == .granted else {
                        lastError = "Camera permission denied"
                        return
                    }
                }

                let selector = AutoDeviceSelector(wearables: wearables)
                let config = StreamSessionConfig(
                    videoCodec: .raw,
                    resolution: .low,
                    frameRate: 24
                )
                let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
                self.streamSession = session
                self.deviceSelector = selector

                photoDataListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let image = UIImage(data: photoData.data),
                           let jpegData = image.jpegData(compressionQuality: 0.7) {
                            self.onPhotoCaptured?(jpegData)
                        } else {
                            self.onPhotoCaptured?(photoData.data)
                        }
                        await session.stop()
                    }
                }

                stateListenerToken = session.statePublisher.listen { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch state {
                        case .streaming:
                            session.capturePhoto(format: .jpeg)
                            self.connectionState = .streaming
                        case .stopped:
                            self.connectionState = self.isGlassesConnected ? .connected : .disconnected
                        default:
                            break
                        }
                    }
                }

                errorListenerToken = session.errorPublisher.listen { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.lastError = "Streaming error"
                        #if DEBUG
                        print("🕶️ Stream error: \(error)")
                        #endif
                    }
                }

                await session.start()

            } catch {
                lastError = error.localizedDescription
                #if DEBUG
                print("🕶️ Capture error: \(error)")
                #endif
            }
        }
        #else
        lastError = "Meta Wearables SDK not available"
        #endif
    }

    func startStreaming(onFrame: @escaping (Data) -> Void) {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        Task { @MainActor in
            do {
                let status = try await wearables.checkPermissionStatus(.camera)
                if status != .granted {
                    let requestStatus = try await wearables.requestPermission(.camera)
                    guard requestStatus == .granted else {
                        lastError = "Camera permission denied"
                        return
                    }
                }

                let selector = AutoDeviceSelector(wearables: wearables)
                let config = StreamSessionConfig(
                    videoCodec: .raw,
                    resolution: .low,
                    frameRate: 5
                )
                let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
                self.streamSession = session
                self.deviceSelector = selector

                var frameCount = 0
                videoFrameListenerToken = session.videoFramePublisher.listen { videoFrame in
                    frameCount += 1
                    guard frameCount % 5 == 0 else { return }

                    if let image = videoFrame.makeUIImage(),
                       let jpegData = image.jpegData(compressionQuality: 0.5) {
                        onFrame(jpegData)
                    }
                }

                stateListenerToken = session.statePublisher.listen { [weak self] state in
                    Task { @MainActor [weak self] in
                        if case .streaming = state {
                            self?.connectionState = .streaming
                        }
                    }
                }

                errorListenerToken = session.errorPublisher.listen { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.lastError = "Streaming error"
                    }
                }

                await session.start()
                connectionState = .streaming

            } catch {
                lastError = error.localizedDescription
            }
        }
        #endif
    }

    func stopStreaming() {
        #if canImport(MWDATCore)
        Task {
            if let session = streamSession {
                await session.stop()
            }
            streamSession = nil
            stateListenerToken = nil
            videoFrameListenerToken = nil
            errorListenerToken = nil
            photoDataListenerToken = nil
            connectionState = isGlassesConnected ? .connected : .disconnected
        }
        #endif
    }

    // MARK: - Voice Trigger Detection

    /// Start listening for the trigger phrase.
    /// Works on phone mic (no glasses required) OR glasses mic when connected.
    func startVoiceTriggerListening() {
        guard triggerEnabled else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            #if DEBUG
            print("🎤 Speech recognizer unavailable")
            #endif
            return
        }

        // Don't restart if already listening
        guard !isListeningForTrigger else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == .authorized {
                    self.consecutiveErrors = 0
                    self.startRecognitionEngine()
                } else {
                    #if DEBUG
                    print("🎤 Speech recognition not authorized: \(status.rawValue)")
                    #endif
                }
            }
        }
    }

    /// Stop listening for voice trigger.
    func stopVoiceTriggerListening() {
        triggerRestartTask?.cancel()
        triggerRestartTask = nil

        if triggerAudioEngine.isRunning {
            triggerAudioEngine.stop()
        }
        triggerAudioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListeningForTrigger = false
    }

    /// Temporarily pause voice trigger (e.g., during a scan to avoid audio conflicts)
    func pauseVoiceTrigger() {
        guard isListeningForTrigger else { return }
        stopVoiceTriggerListening()
        #if DEBUG
        print("🎤 Voice trigger paused")
        #endif
    }

    /// Resume voice trigger after a pause
    func resumeVoiceTrigger() {
        guard triggerEnabled, !isListeningForTrigger else { return }

        triggerRestartTask?.cancel()
        triggerRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
            guard let self, self.triggerEnabled, !self.isListeningForTrigger else { return }
            self.startRecognitionEngine()
        }
    }

    // MARK: - Private — Speech Recognition Engine

    private func startRecognitionEngine() {
        // Clean up any previous session
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        if triggerAudioEngine.isRunning {
            triggerAudioEngine.stop()
        }
        triggerAudioEngine.inputNode.removeTap(onBus: 0)

        // Create fresh audio engine to avoid stale state
        triggerAudioEngine = AVAudioEngine()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // Prefer on-device recognition (lower latency, no network needed)
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }


        recognitionRequest = request

        do {
            // Configure audio session — use playAndRecord so TTS can still play
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = triggerAudioEngine.inputNode

            // Use nil format to match hardware automatically
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            triggerAudioEngine.prepare()
            try triggerAudioEngine.start()
            isListeningForTrigger = true
            consecutiveErrors = 0  // reset on successful start

            #if DEBUG
            print("🎤 Listening for trigger: \"\(triggerPhrase)\" (on-device: \(request.requiresOnDeviceRecognition))")
            #endif
        } catch {
            #if DEBUG
            print("🎤 Audio engine start error: \(error)")
            #endif
            scheduleRestart(delay: 3.0)
            return
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let transcript = result.bestTranscription.formattedString.lowercased()

                    // Check for trigger phrase
                    if transcript.contains(self.triggerPhrase.lowercased()) {
                        #if DEBUG
                        print("🎤 🔥 Trigger detected! \"\(self.triggerPhrase)\" in: \"\(transcript)\"")
                        #endif

                        // Fire the callback
                        self.onVoiceTriggerDetected?()

                        // Reset — stop, wait for scan to complete, then restart
                        self.consecutiveErrors = 0
                        self.stopVoiceTriggerListening()

                        // Restart after a delay (gives scan + TTS time to finish)
                        self.scheduleRestart(delay: 12.0)
                        return
                    }
                }

                // Apple's speech recognition has a ~60s limit per session.
                // When it times out, isFinal becomes true or we get an error.
                // Either way, restart to keep listening.
                let isFinal = result?.isFinal ?? false

                if error != nil || isFinal {
                    #if DEBUG
                    if let error {
                        print("🎤 Recognition ended: \(error.localizedDescription)")
                    } else {
                        print("🎤 Recognition session ended (timeout), restarting...")
                    }
                    #endif

                    self.stopVoiceTriggerListening()

                    self.consecutiveErrors += 1
                    if self.consecutiveErrors < self.maxConsecutiveErrors {
                        let delay: Double = (error != nil) ? 3.0 : 0.5
                        self.scheduleRestart(delay: delay)
                    } else {
                        #if DEBUG
                        print("🎤 Too many consecutive errors (\(self.maxConsecutiveErrors)), stopping voice trigger")
                        #endif
                    }
                }
            }
        }
    }

    /// Schedule a restart of the recognition engine
    private func scheduleRestart(delay: Double) {
        triggerRestartTask?.cancel()
        triggerRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.triggerEnabled, !Task.isCancelled else { return }
            guard !self.isListeningForTrigger else { return }

            #if DEBUG
            print("🎤 Restarting voice trigger listener...")
            #endif
            self.startRecognitionEngine()
        }
    }

    // MARK: - URL Handling

    func handleURL(_ url: URL) {
        #if canImport(MWDATCore)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }

        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                lastError = error.localizedDescription
            }
        }
        #endif
    }
}
