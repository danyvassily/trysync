import SwiftUI
import AppKit

/// Contrôleur de fenêtre pour le plein écran, la restauration et le multi-écran.
@MainActor
public final class WindowController: ObservableObject {
    @Published public var window: NSWindow?

    public init() {}

    /// Déplace la fenêtre sur le 2e écran (si présent) en mode multi-écran.
    public func moveToExternalScreen() -> Bool {
        guard let window, NSScreen.screens.count > 1 else { return false }
        let target = NSScreen.screens[1]
        window.setFrame(target.visibleFrame, display: true, animate: true)
        return true
    }

    /// Nom de l'écran externe (nil si aucun).
    public var externalScreenName: String? {
        guard NSScreen.screens.count > 1 else { return nil }
        return NSScreen.screens[1].localizedName
    }
}

/// Vue utilitaire permettant d'accéder à la NSWindow hôte depuis SwiftUI.
public struct WindowAccessor: NSViewRepresentable {
    public var onWindow: (NSWindow?) -> Void

    public init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
    }

    public func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}
