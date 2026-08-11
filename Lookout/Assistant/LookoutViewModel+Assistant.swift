import Foundation
import UIKit

// MARK: - LookoutViewModel as the Assistant's Eyes

/// Adapts Lookout's capture pipeline to the assistant's `VisionProvider`
/// contract.
///
/// `captureAndAnalyze()` is deliberately left alone — it still drives the
/// standalone camera screen, where speaking the skill card immediately is the
/// right behavior. This path is the same pipeline with two differences: it
/// *returns* its result instead of only publishing it, and it stays silent so
/// the assistant owns the voice. Two things speaking at once was the first bug
/// the merge produced.
extension LookoutViewModel: VisionProvider {

    var isVisionReady: Bool {
        if usingGlassesCamera { return true }
        // Readiness is a question about *permission*, not about the current
        // state of the capture session. Gating on `isRunning` made the
        // assistant answer "I can't open the camera" whenever the viewfinder
        // hadn't been visited yet — which, on an orb-first app, is most of the
        // time. `captureFrame()` brings the session up instead.
        return cameraAccessPlausible
    }

    /// True when a frame should come from the glasses rather than the phone.
    var usingGlassesCamera: Bool {
        settings?.glassesMode == true && glassesService.isGlassesConnected
    }

    func runVisionScan(question: String?) async throws -> VisionOutcome {
        guard let settings = settings, let router = skillRouter else {
            throw LookoutError.apiError("Add an API key in Settings before asking me to look at things.")
        }
        guard settings.hasValidAPIKey else {
            throw LookoutError.apiError("No \(settings.selectedProvider == .claude ? "Claude" : "OpenAI") API key set.")
        }

        isCapturing = true
        errorMessage = nil
        currentFaceMatches = []
        defer {
            isCapturing = false
            glassesService.resumeVoiceTrigger()
        }

        // The glasses trigger and the assistant both want the mic; pause it for
        // the duration of the scan.
        glassesService.pauseVoiceTrigger()
        AudioSessionCoordinator.shared.acquire(.visionCapture)
        defer { AudioSessionCoordinator.shared.release(.visionCapture) }

        var query = LookoutQuery(imageData: nil)
        query.status = .analyzing
        currentQuery = query
        showResult = true

        let imageData = try await captureFrame()
        pendingFaceImageData = imageData
        query = LookoutQuery(imageData: imageData)
        query.status = .analyzing
        currentQuery = query

        // Offline: on-device Vision gives a usable answer without a network hop.
        if await OfflineVisionService.isOffline() {
            isOfflineMode = true
            guard let offline = await offlineVision.analyzeOffline(imageData: imageData) else {
                throw LookoutError.offlineNoResult
            }
            let aiResponse = offline.toAIResponse()
            let skillResult = offline.toSkillResult()

            query.aiResponse = aiResponse
            query.skillResult = skillResult
            query.status = .complete
            currentQuery = query
            queryHistory.insert(query, at: 0)

            return VisionOutcome(
                spokenSummary: speechService.buildSpeechText(from: skillResult).joined(separator: " "),
                context: VisionContext(aiResponse: aiResponse, skillResult: skillResult)
            )
        }

        isOfflineMode = false
        query.status = .routing
        currentQuery = query

        let environment = await gatherEnvironmentSignals()

        let processed = try await router.processImage(
            imageData,
            location: locationManager.currentLocation,
            environment: environment,
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
        queryHistory.insert(query, at: 0)

        if processed.faceMatches.contains(where: { $0.name != nil }) {
            haptics.personRecognized()
        }

        // Seed the vision follow-up conversation too, so switching to the camera
        // screen mid-chat picks up where the assistant left off.
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
            nearbyPlace: processed.nearbyPlace,
            // Carry the spoken question through, so switching to the camera
            // screen mid-conversation shows what was actually asked rather than
            // a bare skill card.
            userQuestion: question
        )
        conversationMessages = conversationService?.messages ?? []

        if !processed.faceMatches.filter({ $0.isNew }).isEmpty && settings.faceRecognitionEnabled {
            showFaceNaming = true
        }

        let people = processed.faceMatches.compactMap { $0.name }
        return VisionOutcome(
            spokenSummary: speechService.buildSpeechText(from: processed.skillResult).joined(separator: " "),
            context: VisionContext(
                aiResponse: processed.aiResponse,
                skillResult: processed.skillResult,
                people: people,
                place: processed.nearbyPlace?.name
            )
        )
    }

    /// Pick the right camera. Glasses win when connected — if the user is
    /// wearing them, that's what they're looking at.
    private func captureFrame() async throws -> Data {
        if usingGlassesCamera {
            return try await glassesService.capturePhotoAsync()
        }

        // Configure and start the session if this is the first time anything
        // has asked for a frame, wake it if auto-sleep stopped it, and wait for
        // it to actually produce frames.
        guard await ensureCameraRunning() else {
            throw LookoutError.apiError(
                "I can't get to the camera — check Lookout's camera permission in Settings."
            )
        }
        return try await capturePhoto()
    }
}
