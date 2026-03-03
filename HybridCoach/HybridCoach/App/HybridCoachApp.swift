import SwiftUI
import UIKit

// MARK: - AppDelegate (shared stores for CarPlay access)

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Shared data store — injected by HybridCoachApp so both phone UI and CarPlay
    /// read from the same instance. Previously these were separate objects, causing
    /// CarPlay to never receive live OBD data.
    var dataStore: DrivingDataStore!
    var analyzer: EfficiencyAnalyzer!

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        // Default phone scene handled by SwiftUI
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        return config
    }
}

@main
struct HybridCoachApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Dependencies

    @State private var dataStore = DrivingDataStore()
    @State private var analyzer = EfficiencyAnalyzer()
    @State private var tripRecorder = TripRecorder()
    @State private var bluetooth = BluetoothManager()
    @State private var obdService = OBDService()
    @State private var analyzerStore = ProtocolAnalyzerStore()
    @State private var settings = AppSettings()
    @State private var evGoalStore = EVGoalStore()
    @State private var locationTracker = LocationTracker()
    @State private var routeStore = RouteStore()
    @State private var plannedRouteStore = PlannedRouteStore()

    @State private var analysisTimer: Timer?
    @State private var useMockData = false
    @State private var mockAdapter: MockOBDAdapter?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dataStore)
                .environment(analyzer)
                .environment(tripRecorder)
                .environment(bluetooth)
                .environment(obdService)
                .environment(analyzerStore)
                .environment(settings)
                .environment(evGoalStore)
                .environment(locationTracker)
                .environment(routeStore)
                .environment(plannedRouteStore)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .onAppear { setupCallbacks() }
                .onChange(of: settings.simulatorMode) { _, isOn in
                    if isOn {
                        startMockMode()
                    } else {
                        stopMockMode()
                    }
                }
                .onChange(of: settings.coachingIntensity) { _, intensity in
                    // Reactively update coaching intensity when user changes it in Settings
                    switch intensity {
                    case .relaxed:    analyzer.intensityMultiplier = 0.8
                    case .normal:     analyzer.intensityMultiplier = 1.0
                    case .aggressive: analyzer.intensityMultiplier = 1.25
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Save trip data when backgrounded — onDisappear is unreliable on iOS
                    if newPhase == .background {
                        cleanup()
                    }
                }
        }
    }

    // MARK: - Wiring

    private func setupCallbacks() {
        // Share the SAME store instances with AppDelegate so CarPlay reads live data
        appDelegate.dataStore = dataStore
        appDelegate.analyzer = analyzer

        // Wire location tracker + route store into trip recorder
        tripRecorder.locationTracker = locationTracker
        tripRecorder.routeStore = routeStore
        tripRecorder.plannedRouteStore = plannedRouteStore
        locationTracker.requestAuthorization()

        // Set coaching intensity multiplier from settings
        switch settings.coachingIntensity {
        case .relaxed:    analyzer.intensityMultiplier = 0.8
        case .normal:     analyzer.intensityMultiplier = 1.0
        case .aggressive: analyzer.intensityMultiplier = 1.25
        }

        bluetooth.protocolAnalyzerStore = analyzerStore

        bluetooth.onAdapterReady = { [self] adapter in
            Task { @MainActor in
                do {
                    try await adapter.initialize()
                    obdService.start(adapter: adapter, dataStore: dataStore)
                    tripRecorder.startTrip()
                    startAnalysisLoop()
                } catch {
                    bluetooth.errorMessage = error.localizedDescription

                    // If AutoPhix adapter failed, activate the protocol analyzer
                    if adapter.adapterType == .autoPhix {
                        analyzerStore.isActive = true
                    }
                }
            }
        }

        // Start mock mode if simulator toggle is on or running in simulator
        #if targetEnvironment(simulator)
        if !settings.simulatorMode {
            settings.simulatorMode = true
        }
        #endif
        if settings.simulatorMode {
            startMockMode()
        }
    }

    private func startAnalysisLoop() {
        analysisTimer?.invalidate()
        nonisolated(unsafe) let analyzer = analyzer
        nonisolated(unsafe) let dataStore = dataStore
        let tripRecorder = tripRecorder
        analysisTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                analyzer.analyze(data: dataStore)
                tripRecorder.update(data: dataStore, efficiencyScore: analyzer.currentEfficiencyScore)
            }
        }
    }

    private func startMockMode() {
        // Stop real OBD polling if active
        obdService.stop()

        useMockData = true
        let mock = MockOBDAdapter()
        mockAdapter = mock
        mock.startMockDataFeed(into: dataStore)
        if !tripRecorder.isRecording {
            tripRecorder.startTrip()
        }
        startAnalysisLoop()
    }

    private func stopMockMode() {
        mockAdapter?.stopMockDataFeed()
        mockAdapter = nil
        useMockData = false
        analysisTimer?.invalidate()
        if tripRecorder.isRecording {
            feedEVGoal()
            tripRecorder.stopTrip()
        }
    }

    private func cleanup() {
        analysisTimer?.invalidate()
        obdService.stop()
        if tripRecorder.isRecording {
            feedEVGoal()
            tripRecorder.stopTrip()
        }
    }

    /// Records the current trip's EV mode data into the goal tracker.
    private func feedEVGoal() {
        guard let trip = tripRecorder.currentTrip else { return }
        evGoalStore.recordDrivingSession(
            evSeconds: trip.evModeSeconds,
            totalSeconds: trip.totalSeconds,
            date: Date(),
            goalPercentage: settings.evGoalPercentage
        )
    }
}
