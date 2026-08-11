import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// État de session de l'application (section active, source parcourue, mode immersif).
@MainActor
public final class SessionState: ObservableObject {
    @Published public var immersiveMode = false
    @Published public var section: AppSection = .library
    @Published public var browsingSource: LibrarySource?
    @Published public var folderPath: [URL] = []
    @Published public var smartFolder: SmartFolder?

    public init() {}
}

/// Vue principale de TriSync intégrant barre latérale, scène, vidéothèque et mode immersif.
public struct ContentView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var engine: SyncEngine

    @State private var isDropTargeted = false
    @State private var showSettings = false
    @State private var controlsVisible = true
    @State private var hideControlsWork: DispatchWorkItem?
    @State private var miniPlayerHidden = false
    @State private var miniOffset: CGSize = .zero

    public init() {}

    public var body: some View {
        Group {
            if session.immersiveMode {
                immersiveLayout
            } else {
                mainLayout
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .preferredColorScheme(.dark)
        .environmentObject(library.engine)
        .onChange(of: library.assets.count) { oldCount, newCount in
            if newCount > oldCount, !session.immersiveMode, !engine.isPlaying {
                session.section = .library
            }
        }
        .background(WindowAccessor { window in
            if let window {
                if windowController.window !== window {
                    windowController.window = window
                }
                if window.isMovableByWindowBackground != true {
                    window.isMovableByWindowBackground = true
                }
                window.setFrameAutosaveName("TriSync.Main")
            }
        })
        .dropDestination(for: URL.self) { urls, _ in
            library.ingest(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isDropTargeted = targeted
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(library.engine)
                .environmentObject(library)
                .environmentObject(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .triSyncIngestVideos)) { note in
            if let urls = note.object as? [URL] {
                library.ingest(urls)
            }
        }
    }

    private var mainLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                SidebarView(
                    onOpenImporter: {
                        let urls = openVideosPanel()
                        if !urls.isEmpty { library.ingest(urls) }
                    },
                    onEnterImmersive: { enterImmersive() },
                    onOpenSettings: { showSettings = true }
                )
                .frame(width: 212)

                Divider().opacity(0.35)

                Group {
                    if session.section == .library {
                        librarySection
                    } else {
                        playbackSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if session.section == .library, !miniPlayerHidden, showMiniPlayer {
                MiniPlayerView(onClose: {
                    withAnimation(.easeOut(duration: 0.2)) { miniPlayerHidden = true }
                })
                .padding(16)
                .offset(miniOffset)
                .gesture(
                    DragGesture()
                        .onChanged { miniOffset = $0.translation }
                        .onEnded { miniOffset = $0.translation }
                )
                .zIndex(10)
            }
        }
        .onChange(of: session.section) { oldSection, newSection in
            if oldSection == .library, newSection != .library {
                miniPlayerHidden = false
                miniOffset = .zero
            }
        }
    }

    private var showMiniPlayer: Bool {
        engine.isPlaying || !library.slots.compactMap({ $0 }).isEmpty
    }

    @ViewBuilder
    private var librarySection: some View {
        if let smart = session.smartFolder {
            SmartGridView(
                title: smart.title,
                assets: smartAssets(for: smart),
                showsResumeBadge: smart == .resume
            ) { _ in
                withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
                library.engine.play()
            }
        } else if session.browsingSource == nil {
            if library.assets.isEmpty {
                EmptyStateView()
            } else {
                LibraryView { _ in
                    withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
                    library.engine.play()
                }
            }
        } else if let source = session.browsingSource {
            FolderBrowserView(source: source)
        }
    }

    private func smartAssets(for smart: SmartFolder) -> [VideoAsset] {
        switch smart {
        case .recent:
            return library.assets.sorted { $0.dateAdded > $1.dateAdded }.prefix(50).map { $0 }
        case .favorites:
            return library.assets.filter { $0.isFavorite }
        case .resume:
            return library.assets.filter { library.playbackPosition(for: $0.url) > 15 }
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        if library.slots.compactMap({ $0 }).isEmpty {
            emptyPlayback
        } else {
            VStack(spacing: 0) {
                StageView()
                TransportBar()
            }
        }
    }

    private var emptyPlayback: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Aucune vidéo en lecture")
                .font(.system(size: 16, weight: .semibold))
            Text("Sélectionnez 1 à \(VideoLibrary.maxSlots) vidéos dans la Vidéothèque\npuis appuyez sur « Lancer ».")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                session.section = .library
            } label: {
                Label("Ouvrir la Vidéothèque", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mode Immersif (« Super Fullscreen »)

    private var immersiveLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            StageView()
            if controlsVisible {
                VStack(spacing: 0) {
                    immersiveTopBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                    TransportBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .environmentObject(library.engine)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        .onExitCommand { exitImmersive() }
        .onAppear { showControls() }
    }

    private var immersiveTopBar: some View {
        HStack(spacing: 10) {
            Button { exitImmersive() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Sortir du mode immersif (Échap)")

            Text("TriSync")
                .font(.system(size: 13, weight: .bold))
            Text("· mode immersif")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func enterImmersive() {
        session.immersiveMode = true
        let window = windowController.window
        if !(window?.styleMask.contains(.fullScreen) ?? false) {
            window?.toggleFullScreen(nil)
        }
        showControls()
    }

    private func exitImmersive() {
        session.immersiveMode = false
        NSCursor.setHiddenUntilMouseMoves(false)
        hideControlsWork?.cancel()
        controlsVisible = true
        let window = windowController.window
        if window?.styleMask.contains(.fullScreen) ?? false {
            window?.toggleFullScreen(nil)
        }
    }

    private func showControls() {
        NSCursor.setHiddenUntilMouseMoves(false)
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        hideControlsWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.25)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideControlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}
