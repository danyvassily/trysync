import SwiftUI
import AppKit
import TriSyncCore

/// Délégué d'application assurant la persistance immédiate lors de la fermeture.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            TriSyncApp.sharedLibrary?.saveNow()
            TriSyncApp.sharedLibrary?.engine.persistPositionsNow()
        }
    }
}

/// Point d'entrée principal de l'application TriSync macOS.
@main
struct TriSyncApp: App {
    @StateObject private var library: VideoLibrary
    @StateObject private var settings = AppSettings()
    @StateObject private var windowController = WindowController()
    @StateObject private var session = SessionState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @MainActor
    public static weak var sharedLibrary: VideoLibrary?

    init() {
        let lib = VideoLibrary()
        _library = StateObject(wrappedValue: lib)
        Self.sharedLibrary = lib
        lib.restoreLibrary()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .environmentObject(settings)
                .environmentObject(windowController)
                .environmentObject(session)
                .environmentObject(library.engine)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
