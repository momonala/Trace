import SwiftUI
import UIKit

/// The Live map is the only screen that rotates. Everything else — Replay, Stats, Settings — is
/// portrait-only, so their tables and forms never have to lay out in a 390pt-tall window.
///
/// SwiftUI has no per-view orientation API. UIKit asks the app delegate for the allowed mask on
/// every rotation, so the mask lives there as static state and `OrientationLock.apply(_:)` pushes
/// into it when the selected tab changes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Read by UIKit on every rotation. Portrait until the Live tab says otherwise.
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.supportedOrientations
    }
}

enum OrientationLock {
    /// Restrict the device to `mask`. Narrowing to `.portrait` while the device is held sideways
    /// rotates the UI back; widening only permits landscape, it doesn't force it.
    ///
    /// The Info.plist orientation keys still have to list every orientation used here — the
    /// delegate can only narrow what the plist already allows.
    ///
    /// Setting the mask alone isn't enough: without the geometry request UIKit keeps applying the
    /// orientation it last settled on and ignores the device until something else forces a
    /// re-evaluation. At launch there is no active scene yet to request against, which is why
    /// callers re-apply once the scene becomes active.
    @MainActor
    static func apply(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.supportedOrientations = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
