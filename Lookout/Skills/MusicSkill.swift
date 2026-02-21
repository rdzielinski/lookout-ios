import Foundation
import CoreLocation
import ShazamKit
import AVFAudio

// MARK: - Music Skill
class MusicSkill: NSObject, LookoutSkill {
    let category: SkillCategory = .music
    let displayName: String = "Music Identifier"
    var requiredAPIKey: String? = nil  // ShazamKit is free with Apple Developer account

    private var session: SHSession?
    private var audioEngine: AVAudioEngine?
    private var matchContinuation: CheckedContinuation<SHMatch, Error>?
    private var isIdentifying = false

    func execute(query: String, location: CLLocation?) async throws -> SkillResult {
        return try await executeAndGetResult(query: query, location: location)
    }

    // MARK: - ShazamKit Integration
    private func identifyMusic() async throws -> SHMatch {
        // Cancel any in-flight match before starting a new one
        if isIdentifying {
            matchContinuation?.resume(throwing: CancellationError())
            matchContinuation = nil
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        isIdentifying = true
        defer { isIdentifying = false }

        let session = SHSession()
        self.session = session
        session.delegate = self

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record)
        try audioSession.setActive(true)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Generate signature from audio
        let signatureGenerator = SHSignatureGenerator()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, time in
            try? signatureGenerator.append(buffer, at: time)
        }

        try audioEngine.start()

        // Record for 5 seconds
        try await Task.sleep(nanoseconds: 5_000_000_000)

        audioEngine.stop()
        inputNode.removeTap(onBus: 0)

        let signature = signatureGenerator.signature()

        // Match against Shazam catalog
        return try await withCheckedThrowingContinuation { continuation in
            self.matchContinuation = continuation
            session.match(signature)
        }
    }
    
    // Convenience wrapper returning SkillResult
    func executeAndGetResult(query: String, location: CLLocation?) async throws -> SkillResult {
        do {
            let match = try await identifyMusic()
            
            guard let item = match.mediaItems.first else {
                return createNoMatchResult()
            }
            
            var details: [SkillResult.DetailItem] = []
            
            if let artist = item.artist {
                details.append(.init(label: "Artist", value: artist, iconName: "person"))
            }
            if let album = item.title {
                details.append(.init(label: "Song", value: album, iconName: "music.note"))
            }
            let genres = item.genres.joined(separator: ", ")
            if !genres.isEmpty {
                details.append(.init(label: "Genre", value: genres, iconName: "guitars"))
            }
            if let appleMusicURL = item.appleMusicURL {
                details.append(.init(label: "Listen", value: "Open in Apple Music", iconName: "play.circle"))
            }
            
            return SkillResult(
                category: .music,
                title: item.title ?? "Unknown Track",
                subtitle: item.artist ?? "Unknown Artist",
                details: details,
                sourceApp: "Shazam",
                deepLinkURL: item.appleMusicURL
            )
            
        } catch {
            return createNoMatchResult()
        }
    }
    
    private func createNoMatchResult() -> SkillResult {
        SkillResult(
            category: .music,
            title: "No Match Found",
            subtitle: "Couldn't identify the music",
            details: [
                .init(label: "Tip", value: "Try again in a quieter environment or hold closer to the source", iconName: "info.circle")
            ],
            sourceApp: "Shazam",
            deepLinkURL: URL(string: "shazam://")
        )
    }
}

// MARK: - SHSessionDelegate
extension MusicSkill: SHSessionDelegate {
    func session(_ session: SHSession, didFind match: SHMatch) {
        matchContinuation?.resume(returning: match)
        matchContinuation = nil
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        matchContinuation?.resume(throwing: error ?? LookoutError.apiError("No Shazam match found"))
        matchContinuation = nil
    }
}
