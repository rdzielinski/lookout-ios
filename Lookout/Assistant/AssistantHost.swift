import Foundation
import SwiftUI

// MARK: - Assistant Host

/// Owns the single instance of each half of the app and wires them together.
///
/// Exists because both halves need to be constructed in a specific order —
/// the assistant borrows the view model's `SpeechService` and
/// `VoiceInputService` rather than creating its own. Sharing those matters: two
/// `AVSpeechSynthesizer`s talk over each other, and two speech recognizers
/// fight for the same audio tap.
@MainActor
final class AssistantHost: ObservableObject {

    let viewModel: LookoutViewModel
    let engine: AssistantEngine

    init(settings: SettingsManager) {
        let viewModel = LookoutViewModel()
        viewModel.configure(settings: settings)

        let engine = AssistantEngine(
            settings: settings,
            speech: viewModel.speechService,
            voiceInput: viewModel.voiceInput,
            haptics: HapticService.shared
        )

        engine.attach(
            vision: viewModel,
            locationText: { [weak viewModel] in viewModel?.locationManager.currentLocationString },
            glassesConnected: { [weak viewModel] in viewModel?.glassesService.isGlassesConnected ?? false }
        )

        self.viewModel = viewModel
        self.engine = engine
    }
}
