import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct LookoutApp: App {
    @StateObject private var settingsManager: SettingsManager
    /// Built once, here, so the camera session and the assistant share a single
    /// view model for the life of the app.
    @StateObject private var host: AssistantHost

    init() {
        let settings = SettingsManager()
        _settingsManager = StateObject(wrappedValue: settings)
        _host = StateObject(wrappedValue: AssistantHost(settings: settings))

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
            Group {
                if settingsManager.assistantEnabled {
                    // Assistant-first: the orb is home, the camera is a mode.
                    AssistantView(host: host)
                } else {
                    // Classic Lookout: straight into the viewfinder. Same view
                    // model either way, so switching doesn't restart the camera.
                    ContentView(viewModel: host.viewModel)
                }
            }
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
