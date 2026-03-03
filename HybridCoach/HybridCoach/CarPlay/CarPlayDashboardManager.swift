import Foundation
import CarPlay

/// Bridges live driving data into the CarPlay template UI.
/// Observes DrivingDataStore and EfficiencyAnalyzer, then updates
/// the CarPlay information template labels in real time.
@MainActor
final class CarPlayDashboardManager {

    private var dataStore: DrivingDataStore?
    private var analyzer: EfficiencyAnalyzer?
    private var informationTemplate: CPInformationTemplate?
    private var updateTimer: Timer?

    // MARK: - Setup

    func configure(dataStore: DrivingDataStore, analyzer: EfficiencyAnalyzer) {
        self.dataStore = dataStore
        self.analyzer = analyzer
    }

    // MARK: - Template

    func buildDashboardTemplate() -> CPInformationTemplate {
        let items = [
            CPInformationItem(title: "Efficiency Score", detail: "--/100"),
            CPInformationItem(title: "Instant MPG", detail: "--"),
            CPInformationItem(title: "EV Mode", detail: "Off"),
            CPInformationItem(title: "Coach Tip", detail: "Drive smoothly"),
        ]

        let template = CPInformationTemplate(
            title: "HybridCoach",
            layout: .twoColumn,
            items: items,
            actions: []
        )

        self.informationTemplate = template
        return template
    }

    // MARK: - Live Updates

    func startUpdating() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTemplate()
            }
        }
    }

    func stopUpdating() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func refreshTemplate() {
        guard let dataStore, let analyzer, let template = informationTemplate else { return }

        let score = "\(analyzer.currentEfficiencyScore)/100"
        let mpg: String
        if let instantMPG = dataStore.instantMPG, instantMPG < 999 {
            mpg = String(format: "%.1f", instantMPG)
        } else {
            mpg = "--"
        }
        let evMode = dataStore.isEVMode ? "✓ Active" : "Off"
        let tip = analyzer.activeTips.first?.message ?? "Drive smoothly"

        let items = [
            CPInformationItem(title: "Efficiency Score", detail: score),
            CPInformationItem(title: "Instant MPG", detail: mpg),
            CPInformationItem(title: "EV Mode", detail: evMode),
            CPInformationItem(title: "Coach Tip", detail: tip),
        ]

        template.items = items
    }
}
