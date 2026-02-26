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
    var onVoiceTriggerDetected: ((String?) -> Void)?
    var onCameraButtonCaptured: ((Data) -> Void)?

    /// When true, the next photo from photoDataPublisher was requested programmatically
    /// (via `capturePhoto()`). When false, it came from the hardware camera button.
    private var expectingProgrammaticCapture = false

    /// Whether the hardware camera button should trigger Lookout scans
    var cameraButtonEnabled = true

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

    // Track whether we've ever reached .registered in this connect() session,
    // so we can distinguish "SDK flickering on startup" from "registration lost"
    private var hasEverRegistered = false
    private var registrationAutoRetryCount = 0
    private let maxRegistrationAutoRetries = 2

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
                self.onVoiceTriggerDetected?(nil)
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

        let cameraButtonObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("mockGlassesCameraButton"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      let imageData = notification.userInfo?["imageData"] as? Data else { return }
                print("🕶️ Mock camera button capture received (\(imageData.count) bytes)")
                if self.cameraButtonEnabled {
                    self.onCameraButtonCaptured?(imageData)
                } else {
                    print("🕶️ Mock camera button ignored (disabled in settings)")
                }
            }
        }
        mockObservers.append(cameraButtonObserver)
    }
    #endif

    // MARK: - Connection Management

    func connect() {
        #if canImport(MWDATCore)
        connectionState = .searching
        lastError = nil
        connectionAttemptInfo = nil
        hasEverRegistered = false
        registrationAutoRetryCount = 0

        // Cancel any previous tasks
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
        connectionTimeoutTask?.cancel()

        // Listen on the registration stream for async state changes.
        // The SDK often flickers through states on startup (0→2→3→0→1),
        // so we track whether we've ever hit .registered and react accordingly.
        registrationTask = Task { @MainActor in
            for await regState in wearables.registrationStateStream() {
                #if DEBUG
                print("🕶️ Registration stream emitted: \(regState) (rawValue: \(regState.rawValue))")
                #endif
                switch regState {
                case .registered:
                    hasEverRegistered = true
                    registrationAutoRetryCount = 0
                    connectionState = .connecting
                    setupDeviceStream()

                case .registering:
                    // SDK is in the process of registering — just wait
                    if connectionState != .connecting {
                        connectionState = .searching
                    }

                case .available:
                    // "Available" means the SDK is ready for registration but not registered.
                    // If we previously were registered and dropped here, or if the SDK
                    // settled here after startup flickering, auto-trigger registration.
                    #if DEBUG
                    print("🕶️ Registration state: available — will auto-trigger startRegistration()")
                    #endif

                    // Cancel device stream if it was running (registration was lost)
                    if hasEverRegistered {
                        deviceStreamTask?.cancel()
                        connectionTimeoutTask?.cancel()
                        isGlassesConnected = false
                        tearDownStreamSession()
                        #if DEBUG
                        print("🕶️ Registration lost after being registered — cancelling device stream")
                        #endif
                    }

                    if registrationAutoRetryCount < maxRegistrationAutoRetries {
                        registrationAutoRetryCount += 1
                        connectionState = .searching
                        #if DEBUG
                        print("🕶️ Auto-retry registration (\(registrationAutoRetryCount)/\(maxRegistrationAutoRetries))")
                        #endif
                        Task {
                            do {
                                try await wearables.startRegistration()
                            } catch {
                                #if DEBUG
                                print("🕶️ startRegistration() error: \(error)")
                                #endif
                            }
                        }
                    } else {
                        connectionState = .error
                        lastError = "Registration did not complete. Open the Meta AI app and make sure your glasses are paired there."
                    }

                case .unavailable:
                    // On startup the SDK briefly emits .unavailable before settling.
                    // Don't immediately error out — give it a chance to advance.
                    #if DEBUG
                    print("🕶️ Registration state: unavailable")
                    #endif

                    if hasEverRegistered {
                        // Was registered, now unavailable — cancel device stream
                        deviceStreamTask?.cancel()
                        connectionTimeoutTask?.cancel()
                        isGlassesConnected = false
                        tearDownStreamSession()
                        connectionState = .searching
                        #if DEBUG
                        print("🕶️ Registration lost (unavailable) — waiting for SDK to recover...")
                        #endif
                    }
                    // If we've never registered, just wait — the SDK is still starting up

                @unknown default:
                    #if DEBUG
                    print("🕶️ Unknown registration state: rawValue \(regState.rawValue)")
                    #endif
                }
            }
        }

        #if DEBUG
        print("🕶️ connect() called — current registration state: \(wearables.registrationState) (rawValue: \(wearables.registrationState.rawValue))")
        #endif

        if wearables.registrationState == .registered {
            // Already paired — go straight to device discovery
            hasEverRegistered = true
            connectionState = .connecting
            setupDeviceStream()
        } else {
            // Not yet paired — launch Meta AI for OAuth pairing.
            // The registrationStateStream above handles state transitions,
            // but we also install a foreground observer as a backup for when
            // the app returns from the Meta AI OAuth flow.
            installForegroundRegistrationCheck()

            Task {
                do {
                    try await wearables.startRegistration()
                } catch {
                    #if DEBUG
                    print("🕶️ startRegistration() error: \(error)")
                    #endif
                    // Don't immediately error — the registration stream may still advance
                }
            }
        }
        #else
        connectionState = .error
        lastError = "Meta Wearables SDK not available"
        #endif
    }

    #if canImport(MWDATCore)
    /// Installs a persistent UIApplication.didBecomeActiveNotification observer
    /// that checks registration state every time the app becomes active.
    /// This catches the post-OAuth redirect AND handles cases where the SDK
    /// is still in `.registering` state and needs a moment to settle.
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

            Task { @MainActor [weak self] in
                guard let self else { return }

                let currentRegState = self.wearables.registrationState

                #if DEBUG
                print("🕶️ App became active — registration state: \(currentRegState) (rawValue: \(currentRegState.rawValue)), connection state: \(self.connectionState)")
                #endif

                // Only act if we are still waiting for registration
                guard self.connectionState == .searching else { return }

                if currentRegState == .registered {
                    // Registered — advance to device discovery
                    self.connectionState = .connecting
                    self.setupDeviceStream()
                    self.removeForegroundObserver()
                } else if currentRegState == .registering {
                    // Still registering — the SDK may need a moment after returning
                    // from Meta AI. Poll a few times with a short delay.
                    #if DEBUG
                    print("🕶️ Still registering — will poll for completion...")
                    #endif
                    self.pollRegistrationState()
                }
            }
        }
    }

    /// Polls the registration state a few times after returning from Meta AI,
    /// since the SDK may take a moment to transition from .registering → .registered.
    private func pollRegistrationState() {
        Task { @MainActor [weak self] in
            for attempt in 1...6 {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s between checks
                guard let self, self.connectionState == .searching else { return }

                let state = self.wearables.registrationState

                #if DEBUG
                print("🕶️ Registration poll \(attempt)/6 — state: \(state) (rawValue: \(state.rawValue))")
                #endif

                if state == .registered {
                    self.connectionState = .connecting
                    self.setupDeviceStream()
                    self.removeForegroundObserver()
                    return
                }
            }

            // After 12 seconds of polling, still not registered
            guard let self, self.connectionState == .searching else { return }
            #if DEBUG
            print("🕶️ Registration polling exhausted — still not registered")
            #endif
            self.connectionState = .error
            self.lastError = "Registration with Meta AI did not complete. Try opening the Meta AI app and pairing your glasses there first."
        }
    }

    /// Removes the foreground observer (called after successful registration)
    private func removeForegroundObserver() {
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
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
        cameraPermissionGranted = false
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

                    // Auto-start the stream session so captures work immediately
                    startStreamSession()
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
        hasEverRegistered = false
        registrationAutoRetryCount = 0
        connect()
    }

    // MARK: - Stream Session Management
    //
    // Following the official Meta sample app pattern:
    // 1. Create the StreamSession once after glasses connect
    // 2. Start it once, keep it running
    // 3. Call capturePhoto() on the existing session when needed
    // 4. Don't stop/recreate the session for each capture

    private var cameraPermissionGranted = false

    /// Ensures camera permission is granted. Returns true if permission is good.
    /// Only opens the Meta AI permission prompt the first time.
    private func ensureCameraPermission() async -> Bool {
        #if canImport(MWDATCore)
        if cameraPermissionGranted { return true }

        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            #if DEBUG
            print("🕶️ Camera permission status: \(status)")
            #endif

            if status == .granted {
                cameraPermissionGranted = true
                return true
            }

            #if DEBUG
            print("🕶️ Requesting camera permission — this may open Meta AI app...")
            #endif
            let requestStatus = try await wearables.requestPermission(.camera)
            #if DEBUG
            print("🕶️ Camera permission request result: \(requestStatus)")
            #endif

            if requestStatus == .granted {
                cameraPermissionGranted = true
                return true
            }

            lastError = "Camera permission denied. Open Meta AI app and grant camera access for Lookout."
            return false
        } catch {
            lastError = "Camera permission needed. Approve camera access in the Meta AI app."
            #if DEBUG
            print("🕶️ Permission error: \(error)")
            #endif
            return false
        }
        #else
        return false
        #endif
    }

    /// Tears down the existing stream session and clears listener tokens.
    /// Call this when registration is lost or the session becomes stale.
    private func tearDownStreamSession() {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        if let session = streamSession {
            Task { await session.stop() }
        }
        streamSession = nil
        deviceSelector = nil
        photoDataListenerToken = nil
        stateListenerToken = nil
        errorListenerToken = nil
        videoFrameListenerToken = nil
        cameraPermissionGranted = false
        #if DEBUG
        print("🕶️ Stream session torn down")
        #endif
        #endif
    }

    /// Sets up and starts the persistent stream session after glasses connect.
    /// Call this once after connection + permission are established.
    func startStreamSession() {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        // Don't start a new session if one is already running
        if streamSession != nil {
            #if DEBUG
            print("🕶️ Stream session already exists — skipping setup")
            #endif
            return
        }

        Task { @MainActor in
            guard await ensureCameraPermission() else { return }

            #if DEBUG
            print("🕶️ Starting persistent stream session...")
            #endif

            let selector = AutoDeviceSelector(wearables: wearables)
            let config = StreamSessionConfig(
                videoCodec: .raw,
                resolution: .low,
                frameRate: 24
            )
            let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
            self.streamSession = session
            self.deviceSelector = selector

            // Listen for photos captured from the glasses
            // Photos can come from two sources:
            // 1. Programmatic: capturePhoto() was called (voice trigger / app-initiated)
            // 2. Hardware: user pressed the camera button on the glasses
            photoDataListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    let wasProgrammatic = self.expectingProgrammaticCapture
                    self.expectingProgrammaticCapture = false

                    let jpegData: Data
                    if let image = UIImage(data: photoData.data),
                       let compressed = image.jpegData(compressionQuality: 0.7) {
                        jpegData = compressed
                    } else {
                        jpegData = photoData.data
                    }

                    if wasProgrammatic {
                        #if DEBUG
                        print("🕶️ Photo captured (programmatic) — \(jpegData.count) bytes")
                        #endif
                        self.onPhotoCaptured?(jpegData)
                    } else {
                        // Hardware camera button press
                        #if DEBUG
                        print("🕶️ Photo captured (camera button) — \(jpegData.count) bytes")
                        #endif
                        if self.cameraButtonEnabled {
                            self.onCameraButtonCaptured?(jpegData)
                        } else {
                            #if DEBUG
                            print("🕶️ Camera button capture ignored (disabled in settings)")
                            #endif
                        }
                    }
                    // Don't stop the session — keep it alive for future captures
                }
            }

            // Track session state
            stateListenerToken = session.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    print("🕶️ Stream session state: \(state)")
                    #endif
                    switch state {
                    case .streaming:
                        self.connectionState = .streaming
                    case .stopped:
                        self.connectionState = self.isGlassesConnected ? .connected : .disconnected
                    default:
                        break
                    }
                }
            }

            // Handle stream errors
            errorListenerToken = session.errorPublisher.listen { [weak self] error in
                Task { @MainActor [weak self] in
                    #if DEBUG
                    print("🕶️ Stream error: \(error)")
                    #endif
                    // Don't overwrite the connection state — just log it
                }
            }

            await session.start()
            #if DEBUG
            print("🕶️ Stream session started — ready for photo captures")
            #endif
        }
        #endif
    }

    // MARK: - Photo Capture

    func capturePhoto() {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        Task { @MainActor in
            // If no stream session, or existing session isn't streaming, (re)create it
            if streamSession == nil || connectionState != .streaming {
                if streamSession != nil {
                    #if DEBUG
                    print("🕶️ Stream session exists but not streaming (state: \(connectionState.rawValue)) — restarting...")
                    #endif
                    tearDownStreamSession()
                }
                #if DEBUG
                print("🕶️ No active stream session — starting one before capture...")
                #endif
                guard await ensureCameraPermission() else { return }
                startStreamSession()
                // Wait for the session to start streaming
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }

            guard let session = streamSession else {
                lastError = "Stream session not available"
                return
            }

            #if DEBUG
            print("🕶️ Capturing photo from glasses (programmatic), connection state: \(connectionState.rawValue)")
            #endif
            expectingProgrammaticCapture = true
            session.capturePhoto(format: .jpeg)
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
                    let trigger = self.triggerPhrase.lowercased()
                    if let triggerRange = transcript.range(of: trigger) {
                        // Extract any words after the trigger phrase as a user question
                        let afterTrigger = transcript[triggerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                        let userQuestion: String? = afterTrigger.isEmpty ? nil : afterTrigger

                        #if DEBUG
                        print("🎤 🔥 Trigger detected! \"\(self.triggerPhrase)\" in: \"\(transcript)\"")
                        if let q = userQuestion { print("🎤 💬 Pre-scan question: \"\(q)\"") }
                        #endif

                        // Fire the callback with optional question
                        self.onVoiceTriggerDetected?(userQuestion)

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
