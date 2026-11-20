import SwiftUI
import UIKit

@main
struct SkiPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Root certificates for the PlayStation Network connection (used for playing away from home).
        if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", ca, 1)
        }
        Chiaki.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(AppStore.shared)
                .environmentObject(Discovery.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    static func lock(_ mask: UIInterfaceOrientationMask) {
        orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

enum Theme {
    static let accent = Color(red: 0.0, green: 0.44, blue: 0.95)
    static let card = Color.white.opacity(0.07)
    static let on = Color.green
    static let rest = Color.orange
}
