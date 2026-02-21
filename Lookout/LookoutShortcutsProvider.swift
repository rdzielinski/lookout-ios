//
//  LookoutShortcutsProvider.swift
//  Lookout
//
//  Created by Robby Dzielinski on 2/18/26.
//


import AppIntents
import UIKit

// MARK: - App Shortcuts Provider
/// Registers Lookout shortcuts with Siri and the Shortcuts app.
struct LookoutShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanWithLookoutIntent(),
            phrases: [
                "Scan with \(.applicationName)",
                "What am I looking at with \(.applicationName)",
                "Identify this with \(.applicationName)",
                "\(.applicationName) scan",
                "What is this \(.applicationName)"
            ],
            shortTitle: "Scan",
            systemImageName: "camera.viewfinder"
        )
        
        AppShortcut(
            intent: LastScanResultIntent(),
            phrases: [
                "What did \(.applicationName) see",
                "Last \(.applicationName) result",
                "What was the last scan from \(.applicationName)"
            ],
            shortTitle: "Last Scan",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}

// MARK: - Scan Intent
/// Opens Lookout and immediately triggers a scan.
struct ScanWithLookoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan with Lookout"
    static var description = IntentDescription(
        "Open Lookout and scan what's in front of you using AI vision.",
        categoryName: "Camera"
    )
    static var openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Post notification that ContentView listens for to auto-trigger a scan
        NotificationCenter.default.post(name: .siriScanRequested, object: nil)
        
        return .result(dialog: "Opening Lookout camera...")
    }
}

// MARK: - Last Scan Result Intent
/// Returns the last scan result without opening the app.
struct LastScanResultIntent: AppIntent {
    static var title: LocalizedStringResource = "Last Scan Result"
    static var description = IntentDescription(
        "Get the result of your most recent Lookout scan.",
        categoryName: "Info"
    )
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Read last scan from UserDefaults (shared with main app)
        let title = UserDefaults.standard.string(forKey: "lastScanTitle") ?? "No scans yet"
        let subtitle = UserDefaults.standard.string(forKey: "lastScanSubtitle") ?? ""
        let category = UserDefaults.standard.string(forKey: "lastScanCategory") ?? ""
        let timestamp = UserDefaults.standard.object(forKey: "lastScanTimestamp") as? Date
        
        var response = title
        if !subtitle.isEmpty {
            response += " — \(subtitle)"
        }
        if !category.isEmpty {
            response += " (\(category))"
        }
        if let timestamp {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            response += " · \(formatter.localizedString(for: timestamp, relativeTo: Date()))"
        }
        
        return .result(dialog: "\(response)")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by ScanWithLookoutIntent to trigger an immediate scan when the app opens.
    static let siriScanRequested = Notification.Name("siriScanRequested")
}

// MARK: - Scan Result Persistence Helper
/// Saves the last scan result to UserDefaults so Siri can read it without opening the app.
/// Call this from LookoutViewModel after every successful scan.
enum ScanResultPersistence {
    static func saveLastScan(title: String, subtitle: String, category: String) {
        let defaults = UserDefaults.standard
        defaults.set(title, forKey: "lastScanTitle")
        defaults.set(subtitle, forKey: "lastScanSubtitle")
        defaults.set(category, forKey: "lastScanCategory")
        defaults.set(Date(), forKey: "lastScanTimestamp")
    }
}