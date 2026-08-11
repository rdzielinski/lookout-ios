import SwiftUI
import AVFoundation
import CoreLocation
import Combine

// MARK: - Glasses Flow State Machine
enum GlassesFlowState: String {
    case idle                    // Listening for trigger phrase
    case scanning                // Photo captured, AI pipeline running
    case speakingResult          // TTS speaking the scan result
    case listeningForFollowUp    // Mic open, waiting for user question
    case processingFollowUp      // Sending follow-up to AI
    case speakingFollowUp        // TTS speaking follow-up answer
    case cooldown                // Brief pause before returning to idle
}

@MainActor
class LookoutViewModel: ObservableObject {
    // MARK: - Published State
    @Published var currentQuery: LookoutQuery?
    @Published var queryHistory: [LookoutQuery] = []
    @Published var isCapturing = false
    @Published var showResult = false
    @Published var errorMessage: String?
    @Published var cameraPermissionGranted = false
    @Published var micPermissionGranted = false

    // Audio-only & hands-free glasses mode
    @Published var isAudioOnlyMode = false
    @Published var glassesFlowState: GlassesFlowState = .idle
    
    // Camera flip
    @Published var isUsingFrontCamera = false
    
    // Conversation
    @Published var conversationMessages: [ConversationMessage] = []
    @Published var isAskingFollowUp = false
    @Published var currentTranscript = ""
    
    // Face matches for current scan
    @Published var currentFaceMatches: [FaceMatch] = []
    @Published var showFaceNaming = false
    @Published var pendingFaceImageData: Data?
    @Published var latestDebugTrace: ScanDebugTrace?
    
    // Offline mode
    @Published var isOfflineMode = false
    
    // MARK: - Services
    let locationManager = LocationManager()
    let speechService = SpeechService()
    let voiceInput = VoiceInputService()
    let faceMemory = FaceMemoryService()
    let placeMemory = PlaceMemoryService()
    let userContext = UserContextStore()
    let glassesService = GlassesService()
    let offlineVision = OfflineVisionService()
    // Internal rather than private: `LookoutViewModel+Assistant` reuses this
    // pipeline from another file, and Swift's `private` is file-scoped.
    let haptics = HapticService.shared
    var conversationService: ConversationService?
    private var smartNarration: SmartNarrationService?
    var skillRouter: SkillRouter?
    var settings: SettingsManager?
    
    // MARK: - Geocoding Cache
    private var geocodingCache: (location: CLLocation, result: (type: PlaceSignalType, evidence: String?), date: Date)?
    
    // Siri scan observer
    private var siriObserver: Any?

    // Audio-only / hands-free state
    private var glassesConnectionCancellable: AnyCancellable?
    private var followUpTimeoutTask: Task<Void, Never>?
    private var silenceDetectionTask: Task<Void, Never>?
    private var conversationTurnCount = 0
    private let maxConversationTurns = 5

    // MARK: - Camera
    let captureSession = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var currentCameraInput: AVCaptureDeviceInput?
    
    /// Idempotent. Before the merge this ran exactly once, from `ContentView`'s
    /// `onAppear`. Now `AssistantHost` configures the view model up front too,
    /// and `ContentView.onAppear` fires again every time the camera mode is
    /// presented — without this guard each visit would re-register the Siri
    /// observer (duplicate scans) and re-run the glasses connect flow.
    private var isConfigured = false

    func configure(settings: SettingsManager) {
        guard !isConfigured else {
            // Settings values may have changed even though wiring hasn't.
            self.settings = settings
            syncVoiceSettings()
            return
        }
        isConfigured = true
        self.settings = settings

        let router = SkillRouter(settings: settings)
        router.faceMemory = faceMemory
        router.placeMemory = placeMemory
        router.userContext = userContext
        self.skillRouter = router
        
        self.conversationService = ConversationService(settings: settings)
        self.smartNarration = SmartNarrationService(settings: settings)
        
        // Sync voice settings
        syncVoiceSettings()
        
        // Setup glasses mode if enabled (includes voice trigger for glasses)
        setupGlassesMode()

        // Auto-enable audio-only mode when glasses connect
        glassesConnectionCancellable = glassesService.$isGlassesConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self, let s = self.settings else { return }
                if s.glassesMode && s.audioOnlyGlasses && connected {
                    if !self.isAudioOnlyMode {
                        self.isAudioOnlyMode = true
                        self.haptics.audioOnlyConfirmed()
                    }
                } else if !connected {
                    self.isAudioOnlyMode = false
                    self.glassesFlowState = .idle
                }
            }
        
        // NOTE: voice trigger is NOT started here.
        // It is started in startVoiceTriggerIfReady(), called from checkPermissions()
        // once mic access is confirmed. Starting it here causes AVAudioEngine to fail
        // silently (mic permission not yet granted), burning through consecutiveErrors
        // and permanently killing the voice trigger before the user ever speaks.
        
        // Listen for Siri scan requests
        siriObserver = NotificationCenter.default.addObserver(
            forName: .siriScanRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.captureAndAnalyze()
            }
        }
    }
    
    deinit {
        if let observer = siriObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Sync voice engine settings to SpeechService
    func syncVoiceSettings() {
        guard let settings = settings else { return }
        speechService.voiceEngine = settings.voiceEngine
        speechService.elevenLabsAPIKey = settings.elevenLabsAPIKey
        speechService.elevenLabsVoiceId = settings.elevenLabsVoiceId
        speechService.selectedVoice = settings.selectedVoiceStyle
    }
    
    // MARK: - Glasses Mode Setup
    
    private func setupGlassesMode() {
        guard let settings = settings, settings.glassesMode else { return }
        
        // Set trigger phrase from settings
        glassesService.triggerPhrase = settings.glassesTriggerPhrase
        
        // Wire photo capture to our pipeline
        glassesService.onPhotoCaptured = { [weak self] imageData in
            Task { @MainActor [weak self] in
                self?.processGlassesPhoto(imageData)
            }
        }
        
        // Wire hardware camera button — fires when user presses camera button on glasses
        glassesService.cameraButtonEnabled = settings.glassesCameraButtonEnabled
        glassesService.onCameraButtonCaptured = { [weak self] imageData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore if already processing a scan
                guard !self.isCapturing else {
                    #if DEBUG
                    print("🕶️ Camera button ignored — already capturing")
                    #endif
                    return
                }
                #if DEBUG
                print("🕶️ Camera button triggered scan")
                #endif
                self.haptics.capturePressed()
                self.processGlassesPhoto(imageData)
            }
        }

        // Wire voice trigger — use glasses camera if connected, phone camera if not
        glassesService.onVoiceTriggerDetected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.haptics.capturePressed()
                if self.glassesService.isGlassesConnected {
                    self.glassesService.capturePhoto()
                } else {
                    // Glasses mode is on but glasses aren't connected — use phone camera
                    self.captureAndAnalyze()
                }
            }
        }
        
        // Connect and start listening
        glassesService.connect()
        if settings.glassesAutoListen {
            glassesService.startVoiceTriggerListening()
        }
    }
    
    // MARK: - Voice Trigger Setup (works on phone mic, no glasses needed)
    
    /// Wire up the voice trigger callbacks and phrase. Does NOT start listening —
    /// call startVoiceTriggerIfReady() once mic permission is confirmed.
    private func setupVoiceTrigger() {
        guard let settings = settings else { return }
        guard !settings.glassesMode else { return }
        guard settings.glassesAutoListen else { return }
        
        glassesService.triggerPhrase = settings.glassesTriggerPhrase
        glassesService.triggerEnabled = true
        
        glassesService.onVoiceTriggerDetected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.haptics.capturePressed()
                self?.captureAndAnalyze()
            }
        }
        // startVoiceTriggerListening() is called from startVoiceTriggerIfReady()
    }
    
    /// Start the voice trigger only if mic + speech permissions are in place.
    /// Safe to call multiple times — GlassesService guards against double-start.
    func startVoiceTriggerIfReady() {
        guard let settings = settings else { return }
        guard !settings.glassesMode, settings.glassesAutoListen else { return }
        guard micPermissionGranted else { return }
        
        // Wire callbacks if not already done
        setupVoiceTrigger()
        glassesService.startVoiceTriggerListening()
    }
    
    /// Process a photo captured from the glasses — runs the same pipeline as the phone camera.
    /// In audio-only mode, skips visual UI updates and just speaks results.
    /// When hands-free is enabled, enters the conversation state machine after speaking.
    private func processGlassesPhoto(_ imageData: Data) {
        guard let settings = settings, let skillRouter = skillRouter else { return }
        guard settings.hasValidAPIKey else { return }

        let audioOnly = isAudioOnlyMode
        isCapturing = true
        errorMessage = nil
        currentFaceMatches = []
        haptics.scanStarted()
        glassesService.pauseVoiceTrigger()
        glassesFlowState = .scanning

        conversationService?.clear()
        conversationMessages = []

        // Glasses photos are wider angle / lower quality — relax face detection threshold
        faceMemory.minimumFaceArea = 0.006

        Task {
            defer { faceMemory.minimumFaceArea = 0.012 }
            do {
                var query = LookoutQuery(imageData: imageData)

                if !audioOnly {
                    query.status = .analyzing
                    currentQuery = query
                    showResult = true
                    pendingFaceImageData = imageData
                }

                haptics.analyzing()

                let environmentSignals = await gatherEnvironmentSignals()

                let processed = try await skillRouter.processImage(
                    imageData,
                    location: locationManager.currentLocation,
                    environment: environmentSignals,
                    onStatusUpdate: audioOnly ? nil : { [weak self] status in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            var q = self.currentQuery ?? LookoutQuery(imageData: imageData)
                            q.status = status
                            self.currentQuery = q
                        }
                    }
                )

                query.aiResponse = processed.aiResponse
                query.skillResult = processed.skillResult
                query.status = .complete
                if !audioOnly {
                    currentQuery = query
                    pendingFaceImageData = imageData
                }
                currentFaceMatches = processed.faceMatches

                // Haptic for recognized faces
                if processed.faceMatches.contains(where: { $0.name != nil }) {
                    haptics.personRecognized()
                }

                haptics.resultReady()
                queryHistory.insert(query, at: 0)
                persistLastScan(result: processed.skillResult)

                let currentItemRepeatCount = userContext.repeatCount(
                    forTitle: processed.skillResult.title,
                    category: processed.aiResponse.category
                )

                let contextString = userContext.buildContextPrompt(
                    personalContext: settings.personalContext,
                    faceContext: faceMemory.contextSummary,
                    placeContext: placeMemory.contextSummary,
                    nearbyContext: placeMemory.nearbyContextSummary(location: locationManager.currentLocation),
                    currentScanTitle: processed.skillResult.title,
                    currentScanCategory: processed.aiResponse.category
                )

                conversationService?.userContextString = contextString
                conversationService?.startConversation(
                    imageData: imageData,
                    aiResponse: processed.aiResponse,
                    skillResult: processed.skillResult,
                    faceMatches: processed.faceMatches,
                    nearbyPlace: processed.nearbyPlace
                )
                conversationMessages = conversationService?.messages ?? []

                // Speak results
                syncVoiceSettings()
                let useHandsFree = settings.handsFreeChatEnabled && audioOnly

                if useHandsFree {
                    glassesFlowState = .speakingResult
                    conversationTurnCount = 0
                }

                if settings.smartNarrationEnabled {
                    let narrationDebug = try? await smartNarration?.generateNarrationDebug(
                        skillResult: processed.skillResult,
                        aiDescription: processed.aiResponse.description,
                        faceMatches: processed.faceMatches,
                        nearbyPlace: processed.nearbyPlace,
                        userContext: contextString,
                        currentItemTitle: processed.skillResult.title,
                        currentItemRepeatCount: currentItemRepeatCount
                    )

                    if let text = narrationDebug?.outputText, !text.isEmpty {
                        if useHandsFree {
                            speechService.speak(text) { [weak self] in
                                Task { @MainActor [weak self] in
                                    self?.startHandsFreeFollowUp()
                                }
                            }
                        } else {
                            speechService.speak(text)
                        }
                    }
                } else {
                    let segments = speechService.buildSpeechText(from: processed.skillResult)
                    if useHandsFree {
                        let combined = segments.joined(separator: " ")
                        speechService.speak(combined) { [weak self] in
                            Task { @MainActor [weak self] in
                                self?.startHandsFreeFollowUp()
                            }
                        }
                    } else {
                        speechService.speakSegments(segments)
                    }
                }

                isCapturing = false
                if !useHandsFree {
                    glassesFlowState = .idle
                    glassesService.resumeVoiceTrigger()
                }

            } catch {
                if !isOfflineMode {
                    isOfflineMode = true
                    if let offlineResult = await offlineVision.analyzeOffline(imageData: imageData) {
                        var query = currentQuery ?? LookoutQuery(imageData: imageData)
                        query.aiResponse = offlineResult.toAIResponse()
                        query.skillResult = offlineResult.toSkillResult()
                        query.status = .complete
                        if !audioOnly { currentQuery = query }

                        haptics.resultReady()
                        queryHistory.insert(query, at: 0)
                        persistLastScan(result: offlineResult.toSkillResult())

                        syncVoiceSettings()
                        let segments = speechService.buildSpeechText(from: offlineResult.toSkillResult())
                        speechService.speakSegments(segments)

                        isCapturing = false
                        endHandsFreeConversation()
                        return
                    }
                }

                if !audioOnly {
                    var query = currentQuery ?? LookoutQuery(imageData: nil)
                    query.status = .error
                    query.errorMessage = error.localizedDescription
                    currentQuery = query
                }
                errorMessage = error.localizedDescription
                isCapturing = false
                haptics.error()

                if audioOnly {
                    speechService.speak("Sorry, something went wrong.")
                }
                endHandsFreeConversation()
            }
        }
    }
    
    // MARK: - Permissions
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionGranted = true
            setupCameraSession(position: .back)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraPermissionGranted = granted
                    if granted { self.setupCameraSession(position: .back) }
                }
            }
        default:
            cameraPermissionGranted = false
        }
        
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
            startVoiceTriggerIfReady()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.micPermissionGranted = granted
                    if granted { self.startVoiceTriggerIfReady() }
                }
            }
        default:
            micPermissionGranted = false
        }
        
        locationManager.requestPermission()
        voiceInput.requestPermission()
    }
    
    // MARK: - Camera Setup
    private func setupCameraSession(position: AVCaptureDevice.Position) {
        captureSession.beginConfiguration()
        
        if let currentInput = currentCameraInput {
            captureSession.removeInput(currentInput)
        }
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            captureSession.commitConfiguration()
            return
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            currentCameraInput = input
        }
        
        if !captureSession.outputs.contains(photoOutput) {
            if captureSession.canAddOutput(photoOutput) {
                captureSession.addOutput(photoOutput)
            }
        }
        
        // Enable continuous autofocus
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isAutoFocusRangeRestrictionSupported {
                camera.autoFocusRangeRestriction = .none
            }
            camera.unlockForConfiguration()
        } catch {
            #if DEBUG
            print("âš ï¸ Camera config error: \(error)")
            #endif
        }
        
        captureSession.commitConfiguration()
        
        if !captureSession.isRunning {
            let session = captureSession
            Task.detached {
                session.startRunning()
            }
        }
    }
    
    // MARK: - Camera Flip
    
    func flipCamera() {
        isUsingFrontCamera.toggle()
        haptics.cameraFlipped()
        let newPosition: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        setupCameraSession(position: newPosition)
    }
    
    // MARK: - Tap to Focus
    func focus(atNormalizedPoint point: CGPoint) {
        guard let device = currentCameraInput?.device else { return }
        do {
            try device.lockForConfiguration()

            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }

            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }

            device.unlockForConfiguration()
        } catch {
            #if DEBUG
            print("Focus configuration error: \(error)")
            #endif
        }
    }

    func focus(atViewPoint tapPoint: CGPoint, in viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        var normalized = CGPoint(x: tapPoint.x / viewSize.width, y: tapPoint.y / viewSize.height)
        if isUsingFrontCamera {
            normalized.x = 1 - normalized.x
        }
        focus(atNormalizedPoint: normalized)
    }

    func forceAutofocusCycle(atNormalizedPoint point: CGPoint) {
        guard let device = currentCameraInput?.device else { return }
        do {
            try device.lockForConfiguration()

            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }

            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }

            device.unlockForConfiguration()
        } catch {
            #if DEBUG
            print("AF cycle config error: \(error)")
            #endif
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let device = self?.currentCameraInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            } catch {
                #if DEBUG
                print("Return to continuous AF error: \(error)")
                #endif
            }
        }
    }

    func focus(using previewLayer: AVCaptureVideoPreviewLayer, layerPoint: CGPoint) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        forceAutofocusCycle(atNormalizedPoint: devicePoint)
    }
    
    // MARK: - Capture & Analyze (Enhanced Pipeline)
    
    func captureAndAnalyze() {
        guard let settings = settings, let skillRouter = skillRouter else {
            errorMessage = "Please configure your API key in Settings"
            return
        }
        guard settings.hasValidAPIKey else {
            switch settings.selectedProvider {
            case .claude:
                errorMessage = "No Claude API key set. Add your key (starts with \"sk-ant-\") in Settings â†' API Keys."
            case .openai:
                errorMessage = "No OpenAI API key set. Add your key (starts with \"sk-\") in Settings â†' API Keys."
            }
            return
        }

        // If glasses are connected, delegate to the glasses camera.
        // capturePhoto() fires onPhotoCaptured → processGlassesPhoto(),
        // which runs the full AI pipeline — no need to continue here.
        if settings.glassesMode && glassesService.isGlassesConnected {
            glassesService.capturePhoto()   // processGlassesPhoto handles haptic + UI
            return
        }

        isCapturing = true
        errorMessage = nil
        currentFaceMatches = []
        haptics.capturePressed()

        // Pause voice trigger during scan to avoid audio session conflicts
        glassesService.pauseVoiceTrigger()
        
        conversationService?.clear()
        conversationMessages = []
        
        Task {
            do {
                var query = LookoutQuery(imageData: nil)
                query.status = .analyzing
                currentQuery = query
                showResult = true
                
                let imageData = try await capturePhoto()
                pendingFaceImageData = imageData
                query = LookoutQuery(imageData: imageData)
                query.status = .analyzing
                currentQuery = query
                
                // Check if offline â€” try on-device first if no network
                let offline = await OfflineVisionService.isOffline()
                
                if offline {
                    isOfflineMode = true
                    query.status = .routing
                    currentQuery = query
                    
                    if let offlineResult = await offlineVision.analyzeOffline(imageData: imageData) {
                        let aiResponse = offlineResult.toAIResponse()
                        let skillResult = offlineResult.toSkillResult()
                        
                        query.aiResponse = aiResponse
                        query.skillResult = skillResult
                        query.status = .complete
                        currentQuery = query
                        
                        haptics.resultReady()
                        queryHistory.insert(query, at: 0)
                        persistLastScan(result: skillResult)
                        
                        syncVoiceSettings()
                        if settings.voiceOutputEnabled {
                            let segments = speechService.buildSpeechText(from: skillResult)
                            speechService.speakSegments(segments)
                        }
                        
                        isCapturing = false
                        glassesService.resumeVoiceTrigger()
                        return
                    } else {
                        throw LookoutError.offlineNoResult
                    }
                }
                
                isOfflineMode = false
                
                query.status = .routing
                currentQuery = query

                let environmentSignals = await gatherEnvironmentSignals()

                let processed = try await skillRouter.processImage(
                    imageData,
                    location: locationManager.currentLocation,
                    environment: environmentSignals,
                    onStatusUpdate: { [weak self] status in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            var q = self.currentQuery ?? LookoutQuery(imageData: imageData)
                            q.status = status
                            self.currentQuery = q
                        }
                    }
                )
                
                query.aiResponse = processed.aiResponse
                query.skillResult = processed.skillResult
                query.status = .complete
                currentQuery = query
                currentFaceMatches = processed.faceMatches

                // Haptic for recognized faces
                if processed.faceMatches.contains(where: { $0.name != nil }) {
                    haptics.personRecognized()
                }

                haptics.resultReady()
                queryHistory.insert(query, at: 0)
                persistLastScan(result: processed.skillResult)

                let currentItemRepeatCount = userContext.repeatCount(
                    forTitle: processed.skillResult.title,
                    category: processed.aiResponse.category
                )

                let contextString = userContext.buildContextPrompt(
                    personalContext: settings.personalContext,
                    faceContext: faceMemory.contextSummary,
                    placeContext: placeMemory.contextSummary,
                    nearbyContext: placeMemory.nearbyContextSummary(location: locationManager.currentLocation),
                    currentScanTitle: processed.skillResult.title,
                    currentScanCategory: processed.aiResponse.category
                )

                var narrationDebug: NarrationDebugResult?

                conversationService?.userContextString = contextString
                conversationService?.startConversation(
                    imageData: imageData,
                    aiResponse: processed.aiResponse,
                    skillResult: processed.skillResult,
                    faceMatches: processed.faceMatches,
                    nearbyPlace: processed.nearbyPlace
                )
                conversationMessages = conversationService?.messages ?? []
                
                syncVoiceSettings()
                if settings.voiceOutputEnabled {
                    if settings.smartNarrationEnabled {
                        narrationDebug = await speakSmartNarration(
                            processed: processed,
                            contextString: contextString,
                            currentItemRepeatCount: currentItemRepeatCount
                        )
                    } else {
                        let segments = speechService.buildSpeechText(from: processed.skillResult)
                        speechService.speakSegments(segments)
                    }
                }
                
                latestDebugTrace = ScanDebugTrace(
                    timestamp: Date(),
                    provider: skillRouter.debugVisionProviderName,
                    imageBytes: imageData.count,
                    locationSummary: formatLocation(locationManager.currentLocation),
                    ambientDecibels: processed.environment?.ambientDecibels,
                    placeSignalType: processed.environment?.placeType.rawValue ?? "unknown",
                    placeSignalEvidence: processed.environment?.placeEvidence,
                    rawAIResponse: processed.rawAIResponse,
                    routedAIResponse: processed.aiResponse,
                    routingReason: processed.routingDecision.reason,
                    routingKeyword: processed.routingDecision.matchedKeyword,
                    selectedSkill: processed.skillResult.category.displayName,
                    skillResultTitle: processed.skillResult.title,
                    userContextPrompt: contextString,
                    visionSystemPrompt: skillRouter.debugVisionSystemPrompt,
                    narrationProvider: narrationDebug?.provider,
                    narrationSystemPrompt: narrationDebug?.systemPrompt,
                    narrationUserPrompt: narrationDebug?.userPrompt,
                    narrationOutput: narrationDebug?.outputText,
                    currentTitleSeenCount: currentItemRepeatCount
                )
                
                let unknownFaces = processed.faceMatches.filter { $0.isNew }
                if !unknownFaces.isEmpty && settings.faceRecognitionEnabled {
                    showFaceNaming = true
                }
                
                isCapturing = false
                glassesService.resumeVoiceTrigger()
                
            } catch {
                if !isOfflineMode, let imageData = currentQuery?.imageData {
                    isOfflineMode = true
                    if let offlineResult = await offlineVision.analyzeOffline(imageData: imageData) {
                        var query = currentQuery ?? LookoutQuery(imageData: imageData)
                        query.aiResponse = offlineResult.toAIResponse()
                        query.skillResult = offlineResult.toSkillResult()
                        query.status = .complete
                        currentQuery = query
                        
                        haptics.resultReady()
                        queryHistory.insert(query, at: 0)
                        persistLastScan(result: offlineResult.toSkillResult())
                        
                        syncVoiceSettings()
                        if settings.voiceOutputEnabled {
                            let segments = speechService.buildSpeechText(from: offlineResult.toSkillResult())
                            speechService.speakSegments(segments)
                        }
                        
                        isCapturing = false
                        glassesService.resumeVoiceTrigger()
                        return
                    }
                }
                
                var query = currentQuery ?? LookoutQuery(imageData: nil)
                query.status = .error
                query.errorMessage = error.localizedDescription
                currentQuery = query
                errorMessage = error.localizedDescription
                isCapturing = false
                glassesService.resumeVoiceTrigger()
                haptics.error()
            }
        }
    }
    
    // MARK: - Smart Narration
    
    private func speakSmartNarration(
        processed: ProcessedResult,
        contextString: String,
        currentItemRepeatCount: Int
    ) async -> NarrationDebugResult? {
        // Build face relationships dictionary for richer narration
        let faceRelationships = Dictionary(
            uniqueKeysWithValues: processed.faceMatches.compactMap { match -> (String, String)? in
                guard let name = match.name else { return nil }
                let rel = faceMemory.relationship(for: name) ?? ""
                return (name, rel)
            }
        )

        do {
            let narrationDebug = try await smartNarration?.generateNarrationDebug(
                skillResult: processed.skillResult,
                aiDescription: processed.aiResponse.description,
                faceMatches: processed.faceMatches,
                nearbyPlace: processed.nearbyPlace,
                userContext: contextString,
                currentItemTitle: processed.skillResult.title,
                currentItemRepeatCount: currentItemRepeatCount,
                faceRelationships: faceRelationships
            )

            if let text = narrationDebug?.outputText, !text.isEmpty {
                speechService.speak(text)
            }
            return narrationDebug
        } catch {
            let segments = speechService.buildSpeechText(from: processed.skillResult)
            speechService.speakSegments(segments)
            return nil
        }
    }

    private func formatLocation(_ location: CLLocation?) -> String {
        guard let location else { return "Unavailable" }
        return String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
    }
    
    func gatherEnvironmentSignals() async -> ScanEnvironmentSignals {
        async let ambientTask = sampleAmbientAudioLevel()
        async let placeTask = inferPlaceSignal(location: locationManager.currentLocation)
        
        let ambient = await ambientTask
        let place = await placeTask
        
        return ScanEnvironmentSignals(
            ambientDecibels: ambient,
            placeType: place.type,
            placeEvidence: place.evidence
        )
    }
    
    private func sampleAmbientAudioLevel() async -> Double? {
        guard micPermissionGranted else { return nil }
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookout_ambient_\(UUID().uuidString).caf")
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleIMA4,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 12_800,
            AVLinearPCMBitDepthKey: 16,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record()
            
            try await Task.sleep(nanoseconds: 350_000_000)
            
            recorder.updateMeters()
            let db = Double(recorder.averagePower(forChannel: 0))
            recorder.stop()
            
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? FileManager.default.removeItem(at: tempURL)
            return db.isFinite ? db : nil
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }
    
    private func inferPlaceSignal(location: CLLocation?) async -> (type: PlaceSignalType, evidence: String?) {
        guard let location else { return (.unknown, nil) }

        if let cache = geocodingCache,
           Date().timeIntervalSince(cache.date) < 300,
           location.distance(from: cache.location) < 100 {
            return cache.result
        }

        if let nearby = placeMemory.findNearbyPlace(location: location) {
            switch nearby.category {
            case .store, .restaurant:
                return (.retailArea, "Saved place: \(nearby.name) (\(nearby.category.rawValue))")
            default:
                break
            }
        }
        
        do {
            let geocoder = CLGeocoder()
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let mark = placemarks.first else { return (.unknown, nil) }

            let joined = [
                mark.name,
                mark.thoroughfare,
                mark.locality,
                mark.subLocality
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            let retailKeywords = ["store", "market", "mall", "plaza", "shop", "target", "walmart", "costco", "grocery"]
            if let kw = retailKeywords.first(where: { joined.contains($0) }) {
                let result = (PlaceSignalType.retailArea, "Placemark keyword: \(kw)" as String?)
                geocodingCache = (location: location, result: result, date: Date())
                return result
            }

            let musicKeywords = ["arena", "theater", "theatre", "amphitheater", "amphitheatre", "stadium", "concert", "music hall", "venue"]
            if let kw = musicKeywords.first(where: { joined.contains($0) }) {
                let result = (PlaceSignalType.musicVenue, "Placemark keyword: \(kw)" as String?)
                geocodingCache = (location: location, result: result, date: Date())
                return result
            }

            if let poi = mark.areasOfInterest?.first?.lowercased() {
                if retailKeywords.contains(where: { poi.contains($0) }) {
                    let result = (PlaceSignalType.retailArea, "POI keyword: \(poi)" as String?)
                    geocodingCache = (location: location, result: result, date: Date())
                    return result
                }
                if musicKeywords.contains(where: { poi.contains($0) }) {
                    let result = (PlaceSignalType.musicVenue, "POI keyword: \(poi)" as String?)
                    geocodingCache = (location: location, result: result, date: Date())
                    return result
                }
            }
        } catch {
            return (.unknown, nil)
        }

        let unknownResult = (PlaceSignalType.unknown, nil as String?)
        geocodingCache = (location: location, result: unknownResult, date: Date())
        return unknownResult
    }
    
    // MARK: - Save Last Scan for Siri
    
    private func persistLastScan(result: SkillResult) {
        ScanResultPersistence.saveLastScan(
            title: result.title,
            subtitle: result.subtitle,
            category: result.category.displayName
        )
    }
    
    // MARK: - Face Naming
    
    func saveNewFace(name: String, relationship: String = "") {
        guard let imageData = pendingFaceImageData else { return }
        
        Task {
            let success = await faceMemory.saveFace(name: name, imageData: imageData, relationship: relationship)
            if success {
                haptics.resultReady()
            }
            showFaceNaming = false
        }
    }
    
    func skipFaceNaming() {
        showFaceNaming = false
    }
    
    // MARK: - Place Saving
    
    func saveCurrentPlace(name: String, category: PlaceCategory = .other) {
        guard let location = locationManager.currentLocation else {
            errorMessage = "Location not available"
            return
        }
        placeMemory.saveCurrentLocation(name: name, location: location, category: category)
        haptics.resultReady()
    }
    
    // MARK: - Follow-up Conversation
    
    func startAskingQuestion() {
        speechService.stop()
        
        // Pause voice trigger so it doesn't interfere with follow-up recording
        glassesService.pauseVoiceTrigger()
        
        haptics.recordingStarted()
        
        do {
            try voiceInput.startListening()
            isAskingFollowUp = true
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            glassesService.resumeVoiceTrigger()
        }
    }
    
    func stopAskingAndSend() {
        let question = voiceInput.stopAndGetTranscript()
        isAskingFollowUp = false
        currentTranscript = ""
        haptics.recordingSent()
        
        // Resume voice trigger after follow-up recording ends
        glassesService.resumeVoiceTrigger()
        
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        sendFollowUp(question)
    }
    
    func sendFollowUp(_ question: String) {
        // Check for face naming intent before sending to AI
        if checkForFaceNaming(question: question) { return }

        guard let conversationService = conversationService, conversationService.hasContext else {
            errorMessage = "Take a photo first to start a conversation"
            return
        }

        checkForPetNaming(question: question)
        
        conversationMessages.append(ConversationMessage(role: .user, text: question))
        
        Task {
            do {
                let response = try await conversationService.askFollowUp(question)
                conversationMessages = conversationService.messages
                haptics.followUpReady()
                
                syncVoiceSettings()
                if let settings = settings, settings.voiceOutputEnabled {
                    speechService.speak(response)
                }
            } catch {
                let errorMsg = "Sorry, I couldn't process that. \(error.localizedDescription)"
                conversationMessages.append(ConversationMessage(role: .assistant, text: errorMsg))
                haptics.error()
            }
        }
    }
    
    func interruptAndAsk() {
        speechService.stop()
        haptics.interrupted()
        startAskingQuestion()
    }

    // MARK: - Hands-Free Conversation (Glasses)

    private func startHandsFreeFollowUp() {
        guard let settings, settings.handsFreeChatEnabled else {
            endHandsFreeConversation()
            return
        }
        guard conversationTurnCount < maxConversationTurns else {
            endHandsFreeConversation()
            return
        }

        glassesFlowState = .listeningForFollowUp
        haptics.listeningForFollowUp()

        do {
            try voiceInput.startListening()
        } catch {
            endHandsFreeConversation()
            return
        }

        // Timeout — if no speech after configured seconds, return to idle
        let timeout = settings?.followUpTimeoutSeconds ?? 12.0
        followUpTimeoutTask?.cancel()
        followUpTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.glassesFlowState == .listeningForFollowUp else { return }

            let transcript = self.voiceInput.stopAndGetTranscript()
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.endHandsFreeConversation()
            } else {
                self.processHandsFreeFollowUp(transcript)
            }
        }

        // Silence detection — poll transcript for 2s of stable content
        startSilenceDetection()
    }

    private func startSilenceDetection() {
        silenceDetectionTask?.cancel()
        silenceDetectionTask = Task { @MainActor [weak self] in
            var lastLength = 0
            var stableCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.glassesFlowState == .listeningForFollowUp else { return }

                let currentLength = self.voiceInput.transcript.count
                if currentLength > 5 && currentLength == lastLength {
                    stableCount += 1
                    if stableCount >= 4 { // 2 seconds of silence after speech
                        let transcript = self.voiceInput.stopAndGetTranscript()
                        self.followUpTimeoutTask?.cancel()
                        self.processHandsFreeFollowUp(transcript)
                        return
                    }
                } else {
                    stableCount = 0
                }
                lastLength = currentLength
            }
        }
    }

    private func processHandsFreeFollowUp(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endHandsFreeConversation()
            return
        }

        glassesFlowState = .processingFollowUp
        conversationTurnCount += 1
        silenceDetectionTask?.cancel()
        followUpTimeoutTask?.cancel()

        // Check for face naming intent
        if checkForFaceNaming(question: question) {
            return // Face saved; confirmation spoken inside the method
        }

        guard let conversationService = conversationService, conversationService.hasContext else {
            endHandsFreeConversation()
            return
        }

        checkForPetNaming(question: question)
        conversationMessages.append(ConversationMessage(role: .user, text: question))

        Task {
            do {
                let response = try await conversationService.askFollowUp(question)
                conversationMessages = conversationService.messages
                haptics.followUpReady()

                glassesFlowState = .speakingFollowUp
                syncVoiceSettings()
                speechService.speak(response) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.startHandsFreeFollowUp()
                    }
                }
            } catch {
                haptics.error()
                speechService.speak("Sorry, I couldn't process that.") { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.endHandsFreeConversation()
                    }
                }
            }
        }
    }

    private func endHandsFreeConversation() {
        glassesFlowState = .cooldown
        followUpTimeoutTask?.cancel()
        silenceDetectionTask?.cancel()
        voiceInput.stopListening()
        conversationTurnCount = 0

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s cooldown
            guard let self else { return }
            self.glassesFlowState = .idle
            self.glassesService.resumeVoiceTrigger()
        }
    }

    // MARK: - Voice-Based Face Naming

    /// Parse follow-up for face-naming intent. Returns true if a face was saved.
    private func checkForFaceNaming(question: String) -> Bool {
        let lower = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let hasUnknownFace = currentFaceMatches.contains { $0.isNew }
        guard hasUnknownFace else { return false }

        // Patterns: "That's [Name]", "His name is [Name]", "Call him/her [Name]", "Remember them as [Name]"
        let patterns: [(regex: String, nameGroup: Int, relationshipGroup: Int?)] = [
            (#"(?:that'?s|this is)\s+(?:my\s+)?(friend|coworker|wife|husband|partner|sister|brother|mom|dad|boss|neighbor|colleague)?\s*(.+)"#, 2, 1),
            (#"(?:his|her|their)\s+name\s+is\s+(.+)"#, 1, nil),
            (#"(?:call|named)\s+(?:him|her|them)\s+(.+)"#, 1, nil),
            (#"(?:remember|save)\s+(?:this face as|them as|him as|her as)\s+(.+)"#, 1, nil),
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive) else { continue }
            let nsRange = NSRange(lower.startIndex..., in: lower)

            if let match = regex.firstMatch(in: lower, range: nsRange),
               let nameRange = Range(match.range(at: pattern.nameGroup), in: lower) {
                var name = String(lower[nameRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))

                guard !name.isEmpty, name.count >= 2, name.count <= 30 else { continue }
                name = name.prefix(1).uppercased() + name.dropFirst()

                let skipWords: Set<String> = ["it", "that", "this", "here", "there", "mine", "someone", "a person"]
                guard !skipWords.contains(name.lowercased()) else { continue }

                var relationship = ""
                if let relGroup = pattern.relationshipGroup,
                   let relRange = Range(match.range(at: relGroup), in: lower) {
                    relationship = String(lower[relRange]).trimmingCharacters(in: .whitespaces)
                }

                // Save the face
                let savedName = name
                let savedRelationship = relationship
                Task {
                    if let imageData = pendingFaceImageData ?? currentQuery?.imageData {
                        let success = await faceMemory.saveFace(name: savedName, imageData: imageData, relationship: savedRelationship)
                        if success {
                            haptics.resultReady()
                            let msg = savedRelationship.isEmpty
                                ? "Got it, I'll remember \(savedName)."
                                : "Got it, I'll remember your \(savedRelationship) \(savedName)."
                            speechService.speak(msg) { [weak self] in
                                Task { @MainActor [weak self] in
                                    self?.startHandsFreeFollowUp()
                                }
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Photo Capture
    
    /// Not private: the assistant layer captures frames through
    /// `LookoutViewModel+Assistant`.
    func capturePhoto() async throws -> Data {
        let photoSettings = AVCapturePhotoSettings()
        photoSettings.flashMode = .off
        
        let delegate = PhotoCaptureDelegate()
        photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
        
        return try await delegate.getPhotoData()
    }
    
    func stopSpeaking() {
        speechService.stop()
    }
    
    func dismissResult() {
        showResult = false
        speechService.stop()
        conversationService?.clear()
        conversationMessages = []
        currentFaceMatches = []
        showFaceNaming = false
        isOfflineMode = false
    }
    
    func toggleSound() {
        settings?.voiceOutputEnabled.toggle()
        haptics.toggle()
    }
    
    // MARK: - Pet Learning
    
    private func checkForPetNaming(question: String) {
        let lower = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        let patterns: [(regex: String, nameGroup: Int)] = [
            (#"(?:that'?s|this is|meet)\s+(?:my\s+)?(?:cat|dog|kitten|puppy|pet|bird|rabbit|hamster|fish)\s+(.+)"#, 1),
            (#"(?:his|her|their|its)\s+name\s+is\s+(.+)"#, 1),
            (#"(?:call|named)\s+(?:him|her|it|them)\s+(.+)"#, 1),
            (#"(?:that'?s|this is)\s+(\w+)(?:\s*[,!.]|$)"#, 1),
        ]
        
        let aiDescription = currentQuery?.aiResponse?.description ?? currentQuery?.skillResult?.title ?? ""
        var species = "pet"
        let speciesKeywords = ["cat", "kitten", "dog", "puppy", "bird", "parrot", "rabbit", "hamster", "fish", "turtle", "lizard", "snake"]
        for keyword in speciesKeywords {
            if aiDescription.lowercased().contains(keyword) || lower.contains(keyword) {
                species = keyword
                break
            }
        }
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive) else { continue }
            let nsRange = NSRange(lower.startIndex..., in: lower)
            
            if let match = regex.firstMatch(in: lower, range: nsRange),
               let nameRange = Range(match.range(at: pattern.nameGroup), in: lower) {
                var name = String(lower[nameRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                
                if !name.isEmpty {
                    name = name.prefix(1).uppercased() + name.dropFirst()
                }
                
                let skipWords: Set<String> = ["it", "that", "this", "here", "there", "mine", "cute", "pretty", "beautiful"]
                guard !skipWords.contains(name.lowercased()), name.count >= 2, name.count <= 30 else { continue }
                
                userContext.savePet(
                    name: name,
                    species: species,
                    description: aiDescription,
                    relationship: lower.contains("my ") ? "owner's pet" : ""
                )
                
                #if DEBUG
                print("ðŸ¾ Learned pet: \(name) (\(species))")
                #endif
                break
            }
        }
    }
}

// MARK: - Photo Capture Delegate
class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var continuation: CheckedContinuation<Data, Error>?
    
    func getPhotoData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        
        guard let data = photo.fileDataRepresentation() else {
            continuation?.resume(throwing: LookoutError.imageProcessingFailed)
            continuation = nil
            return
        }
        
        if let image = UIImage(data: data), let compressed = image.jpegData(compressionQuality: 0.7) {
            continuation?.resume(returning: compressed)
        } else {
            continuation?.resume(returning: data)
        }
        continuation = nil
    }
}
