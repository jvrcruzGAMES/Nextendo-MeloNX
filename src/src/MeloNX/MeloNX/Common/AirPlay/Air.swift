import SwiftUI
import UIKit
import Combine

public class Air {

    static let shared = Air()

    public var connected: Bool = false {
        didSet {
            connectionCallbacks.forEach({ $0(connected) })
        }
    }
    var connectionCallbacks: [(Bool) -> ()] = []

    var airScreen: UIScreen?
    var airWindow: UIWindow?

    var hostingController: UIHostingController<AnyView>?

    var appIsActive: Bool { UIApplication.shared.applicationState == .active }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidConnect),
                                               name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDisconnect),
                                               name: UIScene.didDisconnectNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(didConnect),
                                               name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didDisconnect),
                                               name: UIScreen.didDisconnectNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    private func check() {
        let scenes = UIApplication.shared.connectedScenes
        let windowScenes = scenes.compactMap { $0 as? UIWindowScene }
        let externalScene = windowScenes.first { scene in
            if #available(iOS 16.0, *) {
                return scene.session.role == .windowExternalDisplay || scene.session.role == .windowExternalDisplayNonInteractive
            } else {
                return scene.session.role == .windowExternalDisplay
            }
        }
        
        if let externalScene {
            add(windowScene: externalScene) { success in
                guard success else { return }
                self.connected = true
            }
        }
    }

    @objc func sceneDidConnect(sender: NSNotification) {
        guard let scene = sender.object as? UIWindowScene,
              scene.session.role == .windowExternalDisplay else { return }
        add(windowScene: scene) { success in
            guard success else { return }
            self.connected = true
        }
    }

    @objc func sceneWillDisconnect(sender: NSNotification) {
        guard let scene = sender.object as? UIWindowScene,
              scene.session.role == .windowExternalDisplay else { return }
        remove()
        connected = false
    }

    public static func play(_ view: AnyView) {
        Air.shared.hostingController = UIHostingController<AnyView>(rootView: view)
        Air.shared.check()
    }

    public static func stop() {
        Air.shared.remove()
        Air.shared.hostingController = nil
    }

    public static func connection(_ callback: @escaping (Bool) -> ()) {
        Air.shared.connectionCallbacks.append(callback)
    }

    @objc func didConnect(sender: NSNotification) {
        print("AirKit - Connect")
        self.connected = true
        guard let screen: UIScreen = sender.object as? UIScreen else { return }
        add(screen: screen) { success in
            guard success else { return }
            self.connected = true
        }
    }

    func add(screen: UIScreen, completion: @escaping (Bool) -> ()) {

        print("AirKit - Add Screen")

        airScreen = screen
        screen.overscanCompensation = .none

        airWindow = UIWindow(frame: screen.bounds)

        guard let viewController: UIViewController = hostingController else {
            print("AirKit - Add - Failed: Hosting Controller Not Found")
            completion(false)
            return
        }

        findWindowScene(for: airScreen!) { windowScene in
            guard let airWindowScene: UIWindowScene = windowScene else {
                print("AirKit - Add - Failed: Window Scene Not Found")
                completion(false)
                return
            }
            self.airWindow?.rootViewController = viewController
            self.airWindow?.windowScene = airWindowScene

            if let _ = viewController as? UIHostingController<AnyView> {
                let traitCollection = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceIdiom: .tv),
                    airWindowScene.traitCollection
                ])
                viewController.setOverrideTraitCollection(traitCollection, forChild: viewController)
            }

            self.airWindow?.isHidden = false
            print("AirKit - Add Screen - Done")
            completion(true)
        }

    }
    
    func add(windowScene: UIWindowScene, completion: @escaping (Bool) -> ()) {
        guard let viewController = hostingController else {
            completion(false)
            return
        }

        airWindow = UIWindow(windowScene: windowScene)
        airWindow?.rootViewController = viewController

        if let _ = viewController as? UIHostingController<AnyView> {
            let traitCollection = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceIdiom: .tv),
                windowScene.traitCollection
            ])
            viewController.setOverrideTraitCollection(traitCollection, forChild: viewController)
        }

        airWindow?.isHidden = false
        completion(true)
    }

    func findWindowScene(for screen: UIScreen, shouldRecurse: Bool = true, completion: @escaping (UIWindowScene?) -> ())  {
        print("AirKit - Find Window Scene")
        var matchingWindowScene: UIWindowScene? = nil
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                if windowScene.screen == screen {
                    matchingWindowScene = windowScene
                    break
                }
            }
        }
        guard let windowScene: UIWindowScene = matchingWindowScene else {
            // Only recurse once to avoid infinite loops
            if shouldRecurse {
               Task { @MainActor in
                    self.findWindowScene(for: screen, shouldRecurse: false) { windowScene in
                        completion(windowScene)
                    }
                }
            } else {
                completion(nil)
            }
            return
        }
        completion(windowScene)
    }

    @objc func didDisconnect() {
        print("AirKit - Disconnect")
        remove()
        connected = false
    }

    func remove() {
        print("AirKit - Remove")
        airWindow = nil
        airScreen = nil
    }

    @objc func didBecomeActive() {
        print("AirKit - App Active")
    }

    @objc func willResignActive() {
        print("AirKit - App Inactive")

    }

}
