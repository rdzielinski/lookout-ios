import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct LookoutApp: App {
    @StateObject private var settingsManager = SettingsManager()
    
    init() {
        #if canImport(MWDATCore)
        do {
            try Wearables.configure()
        } catch {
            print("⚠️ Wearables SDK configure failed: \(error)")
        }
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsManager)
                .onOpenURL { url in
                    // Handle Meta AI app callbacks for glasses registration
                    #if canImport(MWDATCore)
                    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                    else { return }
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                        } catch {
                            print("⚠️ Wearables URL handling failed: \(error)")
                        }
                    }
                    #endif
                }
        }
    }
}
