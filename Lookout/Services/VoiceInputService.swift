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
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
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
