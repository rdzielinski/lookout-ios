import Foundation
import Speech
import AVFoundation

// MARK: - Voice Input Service
class VoiceInputService: ObservableObject {
    
    @Published var isListening = false
    @Published var transcript = ""
    @Published var permissionGranted = false
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    
    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        // Dictation outranks every other mic consumer, but it still registers a
        // teardown handler so `releaseAll()` (backgrounding, entering the
        // viewfinder) can shut it down cleanly.
        AudioSessionCoordinator.shared.register(.dictation) { [weak self] in
            self?.teardownAudio()
        }
    }
    
    // MARK: - Permission
    
    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.permissionGranted = (status == .authorized)
            }
        }
    }
    
    // MARK: - Start Listening
    
    func startListening() throws {
        stopListening()
        
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw LookoutError.apiError("Speech recognition not available")
        }

        // Claim the mic, evicting the wake-word listener or glasses trigger if
        // either is holding it. Dictation has top priority, so this only fails
        // if dictation is already running — which the stopListening() at the top
        // of this method has already handled.
        AudioSessionCoordinator.shared.acquire(.dictation)
        try AudioSessionCoordinator.shared.configureForRecording()

        // Reset the engine to clear any stale state
        audioEngine = AVAudioEngine()
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw LookoutError.apiError("Could not create recognition request")
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = false
        }
        
        let inputNode = audioEngine.inputNode
        
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            
            if error != nil || (result?.isFinal ?? false) {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                Task { @MainActor in
                    self.isListening = false
                }
            }
        }
        
        // Use nil format — this tells installTap to use the hardware's native format
        // automatically, avoiding any sample rate mismatch crashes.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        Task { @MainActor in
            isListening = true
            transcript = ""
        }
    }
    
    // MARK: - Stop Listening
    
    func stopListening() {
        teardownAudio()
        AudioSessionCoordinator.shared.release(.dictation)
    }

    /// Tear down the engine without touching session ownership.
    ///
    /// Split out because this is what the coordinator's revoke handler calls: it
    /// runs *during* another consumer's `acquire`, so releasing from here would
    /// re-enter the coordinator and hand ownership back mid-handoff.
    private func teardownAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        Task { @MainActor in
            isListening = false
        }
    }
    
    /// Stop listening and return the final transcript
    func stopAndGetTranscript() -> String {
        let finalTranscript = transcript
        stopListening()
        return finalTranscript
    }
}
