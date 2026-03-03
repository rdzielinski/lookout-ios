import UIKit
import CarPlay

/// Handles the CarPlay scene lifecycle.
/// Presents an information template showing live efficiency data.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?
    var carWindow: CPWindow?

    private let dashboardManager = CarPlayDashboardManager()

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.carWindow = window

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            Task { @MainActor in
                dashboardManager.configure(
                    dataStore: appDelegate.dataStore,
                    analyzer: appDelegate.analyzer
                )
                let template = dashboardManager.buildDashboardTemplate()
                interfaceController.setRootTemplate(template, animated: true, completion: nil)
                dashboardManager.startUpdating()
                print("CarPlay: Scene connected")
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        dashboardManager.stopUpdating()
        self.interfaceController = nil
        self.carWindow = nil
        print("CarPlay: Scene disconnected")
    }
}
