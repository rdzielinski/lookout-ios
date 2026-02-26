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
            #if DEBUG
            print("🕶️ Wearables SDK configured — initial registration state: \(Wearables.shared.registrationState) (rawValue: \(Wearables.shared.registrationState.rawValue))")
            #endif
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
                    #if DEBUG
                    print("🕶️ onOpenURL received: \(url.absoluteString)")
                    #endif

                    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                    else {
                        #if DEBUG
                        print("🕶️ URL ignored — no metaWearablesAction param")
                        #endif
                        return
                    }

                    #if DEBUG
                    print("🕶️ Handling wearables URL...")
                    #endif

                    Task {
                        do {
                            let result = try await Wearables.shared.handleUrl(url)
                            #if DEBUG
                            print("🕶️ handleUrl result: \(result)")
                            print("🕶️ Registration state after handleUrl: \(Wearables.shared.registrationState) (rawValue: \(Wearables.shared.registrationState.rawValue))")
                            #endif
                        } catch {
                            print("⚠️ Wearables URL handling failed: \(error)")
                        }
                    }
                    #endif
                }
        }
    }
}
