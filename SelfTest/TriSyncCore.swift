// TriSync — UI & App
// Découpage en modules (v7.1) : même target SwiftPM, aucune visibilité modifiée.
// Sources : ContentView.swift (UI + App), VideoLibrary.swift, EngineAndSettings.swift.

// ============================================================
//  TriSync — ContentView.swift (version finale fusionnée)
//  Vidéothèque jusqu'à 3 vidéos en split-screen synchronisé.
//  Optimisé Apple Silicon M3 (Media Engine / VideoToolbox).
//  Fusion des livrables : Agent Système + Agent AVFoundation + Agent SwiftUI.
// ============================================================
//  System.swift — TriSync
//  Couche système macOS : point d'entrée de l'application, bibliothèque vidéo
//  et accès aux fichiers (NSOpenPanel, sandbox, métadonnées AVFoundation).
//  Commentaires en français, identifiants en anglais.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Délégué d'application

/// Sauvegarde immédiate de la bibliothèque à la sortie de l'application
/// (en plus de la sauvegarde différée à chaque modification).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            sharedLibrary?.saveNow()
            // Positions de lecture : écriture immédiate à la sortie (quit).
            sharedLibrary?.engine.persistPositionsNow()
        }
    }
}

// MARK: - Point d'entrée

struct TriSyncApp: App {
    @StateObject private var library: VideoLibrary
    @StateObject private var settings = AppSettings()
    @StateObject private var windowController = WindowController()
    @StateObject private var session = SessionState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Création explicite de la bibliothèque pour pouvoir l'exposer à la
        // fonction globale ingestVideos(_:) (découplage avec UI.swift).
        let lib = VideoLibrary()
        _library = StateObject(wrappedValue: lib)
        sharedLibrary = lib
        // Restaure la bibliothèque sauvegardée (bookmarks) + scanne les sources.
        lib.restoreLibrary()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                // macOS ne propose pas preferredColorScheme sur une Scene :
                // on l'applique donc à la vue racine.
                .preferredColorScheme(.dark)
                .environmentObject(settings)
                .environmentObject(windowController)
                .environmentObject(session)
                // Injection RACINE du moteur : TOUTES les vues de l'arbre
                // (y compris sheets, mini-lecteur, bandeaux conditionnels) y
                // ont accès. Un @EnvironmentObject manquant = assertion
                // fatale au premier rendu de la vue concernée.
                .environmentObject(library.engine)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

// MARK: - Référence partagée de la bibliothèque

/// Instance courante de la bibliothèque, utilisée par ingestVideos(_:).
/// Référence faible : la propriété forte est portée par le StateObject de TriSyncApp.
@MainActor
weak var sharedLibrary: VideoLibrary?

// MARK: - Asset vidéo

/// Dossier source de la vidéothèque (Mac, disque externe…) avec bookmark de
/// sécurité persisté pour retrouver l'accès aux prochains lancements.
enum VideoDisplayMode: Int {
    case fit     // Plein : vidéo intégrale, barres noires si ratios différents
    case crop    // Rogner : la vidéo remplit le panneau, recadrage des bords
    case stretch // Remplir : étirement sur tout le panneau
}

/// Action de raccourci clavier émise par un panneau vidéo.
enum ShortcutAction {
    case seek(seconds: Double)
    case rate(factor: Float)
}

/// Section affichée dans la fenêtre principale.
enum AppSection: Equatable {
    case library  // Vidéothèque : navigation dossiers + grilles
    case play     // Lecture : scène synchronisée (sans bandeau de miniatures)
}

/// Dossier intelligent de la bibliothèque : entrée virtuelle de la barre
/// latérale dont le contenu est calculé à la volée depuis les assets.
enum SmartFolder: String, CaseIterable, Identifiable {
    case recent    // Récemment ajoutés (top 50, date d'ajout décroissante)
    case favorites // À regarder (favoris ★)
    case resume    // Reprendre (position de lecture sauvegardée > 15 s)

    var id: String { rawValue }

    /// Libellé affiché dans la barre latérale et l'en-tête de la grille.
    var title: String {
        switch self {
        case .recent: return "Récemment ajoutés"
        case .favorites: return "À regarder"
        case .resume: return "Reprendre"
        }
    }

    /// Icône de la barre latérale.
    var icon: String {
        switch self {
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "star.fill"
        case .resume: return "play.circle"
        }
    }
}

/// État de session partagé (section active, mode immersif, navigation).
final class SessionState: ObservableObject {
    @Published var immersiveMode = false
    @Published var section: AppSection = .library
    /// Source en cours de navigation dans la Vidéothèque (nil = toutes les vidéos).
    @Published var browsingSource: LibrarySource?
    /// Pile de dossiers du navigateur (dernier = dossier courant).
    @Published var folderPath: [URL] = []
    /// Dossier intelligent affiché (nil = vue standard : grille ou navigateur).
    @Published var smartFolder: SmartFolder?
}

// MARK: - Lecteur vidéo (couche d'hébergement)

/// Vue AppKit qui héberge un AVPlayerLayer : rendu vidéo direct, sans
/// composition SwiftUI sur le flux (économie de bande passante GPU).
///
/// Mode « Rogner » : .resizeAspectFill — la vidéo remplit TOUJOURS le panneau
/// (zoom auto vers le centre, aucune barre noire). L'utilisateur peut ensuite
/// naviguer librement dans le bloc :
///   • molette / pincement (trackpad) : zoom autour du curseur ;
///   • glisser-souris : déplacement ;
///   • flèches du clavier : déplacement ; « + » / « - » : zoom ; « 0 » : reset ;
///   • double-clic : réinitialisation complète.
final class PlayerLayerView: NSView {

    private let playerLayer = AVPlayerLayer()

    /// Zoom interactif de l'utilisateur (1 = natif).
    private(set) var interactiveZoom: CGFloat = 1
    /// Déplacement interactif (unités du layer).
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0

    /// Notifie SwiftUI du zoom interactif courant (badge ×N).
    var onStateChange: ((CGFloat) -> Void)?

    /// Raccourcis globaux (skip, vitesse) émis par ce panneau focalisé.
    var onShortcut: ((ShortcutAction) -> Void)?

    /// Vrai en mode immersif : les flèches ←/→ cherchent au lieu de déplacer.
    var immersiveMode = false

    /// Vrai pendant la lecture : les flèches ←/→ font recul/avance rapide
    /// (façon Infuse : ← = −3 s, → = +5 s) au lieu de déplacer le panneau.
    var seekOnArrows = false

    /// Lecteur attaché à la couche. La vérification d'identité évite de
    /// réassigner le même AVPlayer à chaque passe de rendu SwiftUI.
    var player: AVPlayer? {
        didSet {
            guard player !== oldValue else { return }
            playerLayer.player = player
            // Nouvelle vidéo : on repart d'un cadrage neutre.
            interactiveZoom = 1
            panX = 0
            panY = 0
            onStateChange?(1)
            applyGeometry()
        }
    }

    var displayMode: VideoDisplayMode = .crop {
        didSet { applyGeometry() }
    }

    /// Taille d'affichage de la vidéo (upright, rotations appliquées).
    var videoSize: CGSize = .zero {
        didSet { applyGeometry() }
    }

    /// Décalage vertical du cadrage en mode Rogner : 0 = haut, 0,5 = centre, 1 = bas.
    var cropOffset: CGFloat = 0.5 {
        didSet { applyGeometry() }
    }

    /// Zoom supplémentaire (mise à l'échelle avancée) : 1.0 = natif.
    var zoom: CGFloat = 1.0 {
        didSet { applyGeometry() }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Mode « layer-hosting » : la vue ne fait que porter la couche.
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 12
        playerLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas supporté")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        applyGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Libère le AVPlayer quand la vue quitte la fenêtre. On passe par la
        // propriété (et non la couche directement) pour que le didSet puisse
        // rattacher proprement le lecteur lors d'un éventuel retour en fenêtre.
        if window == nil {
            player = nil
        }
    }

    // MARK: Interactions (zoom / déplacement)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            resetInteractive()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let scale = totalScale()
        panX -= event.deltaX / scale
        panY -= event.deltaY / scale
        applyGeometry()
    }

    override func scrollWheel(with event: NSEvent) {
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.02 : 0.12
        let delta = event.scrollingDeltaY * sensitivity
        guard delta != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoom(around: point, to: interactiveZoom * (1 + delta))
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(around: point, to: interactiveZoom * (1 + event.magnification))
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift])
        // Raccourcis façon Infuse (transmis au moteur via onShortcut).
        if mods == .command {
            switch event.keyCode {
            case 124: onShortcut?(.seek(seconds: 60)); return   // ⌘→ : +60 s
            case 123: onShortcut?(.seek(seconds: -60)); return  // ⌘← : −60 s
            default: break
            }
        } else if mods == .option {
            switch event.keyCode {
            case 30: onShortcut?(.rate(factor: 1.25)); return   // ⌥] : accélérer
            case 33: onShortcut?(.rate(factor: 0.8)); return    // ⌥[ : ralentir
            default: break
            }
        } else if mods.isEmpty {
            switch event.keyCode {
            case 124, 123:
                if immersiveMode {
                    // Immersif : sauts de 10 s.
                    onShortcut?(.seek(seconds: event.keyCode == 124 ? 10 : -10)); return
                }
                if seekOnArrows {
                    // Lecture : recul 3 s / avance 5 s (réglages Infuse).
                    onShortcut?(.seek(seconds: event.keyCode == 124 ? 5 : -3)); return
                }
                // Sinon : déplacement du panneau (flèches ci-dessous).
            default:
                break
            }
        }

        // Déplacement / zoom locaux du panneau.
        let step: CGFloat = 28
        let scale = totalScale()
        switch event.keyCode {
        case 123: panX -= step / scale   // ←
        case 124: panX += step / scale   // →
        case 126: panY += step / scale   // ↑
        case 125: panY -= step / scale   // ↓
        case 24, 69: zoom(around: CGPoint(x: bounds.midX, y: bounds.midY), to: interactiveZoom * 1.25) // + / =
        case 27: zoom(around: CGPoint(x: bounds.midX, y: bounds.midY), to: interactiveZoom / 1.25)      // -
        case 29: resetInteractive()      // 0
        default:
            super.keyDown(with: event)
            return
        }
        applyGeometry()
    }

    private func zoom(around point: CGPoint, to newZoom: CGFloat) {
        let old = interactiveZoom
        let clamped = min(max(newZoom, 1), 10)
        guard clamped != old else { return }
        // Le point sous le curseur reste fixe pendant le zoom.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        panX += (point.x - center.x) * (1 / clamped - 1 / old)
        panY += (point.y - center.y) * (1 / clamped - 1 / old)
        interactiveZoom = clamped
        onStateChange?(clamped)
    }

    private func resetInteractive() {
        guard interactiveZoom != 1 || panX != 0 || panY != 0 else { return }
        interactiveZoom = 1
        panX = 0
        panY = 0
        onStateChange?(1)
        applyGeometry()
    }

    /// Échelle totale = zoom des réglages × zoom interactif (mode Rogner uniquement).
    private func totalScale() -> CGFloat {
        displayMode == .crop ? max(zoom, 1) * interactiveZoom : interactiveZoom
    }

    // MARK: Géométrie

    /// Applique gravité + transform selon le mode, la taille vidéo, le
    /// décalage vertical, le zoom des réglages et le zoom/déplacement
    /// interactif. Appelé à chaque changement de bounds ou de paramètre.
    ///
    /// Mode « Rogner » : videoGravity .resizeAspectFill — AVPlayer zoome la
    /// vidéo vers le centre du panneau et la fait TOUJOURS remplir la zone
    /// (aucune barre noire possible). Le zoom/déplacement interactif est
    /// appliqué par transform affine autour du centre.
    private func applyGeometry() {
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }

        switch displayMode {
        case .stretch:
            playerLayer.videoGravity = .resize
            playerLayer.setAffineTransform(.identity)
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.setAffineTransform(.identity)
        case .crop:
            playerLayer.videoGravity = .resizeAspectFill
            guard videoSize.width > 1, videoSize.height > 1 else {
                playerLayer.setAffineTransform(.identity)
                return
            }
            let videoAspect = videoSize.width / videoSize.height
            let boundsAspect = b.width / b.height
            let fittedHeight = videoAspect <= boundsAspect ? b.height : b.width / videoAspect
            let fittedWidth = videoAspect <= boundsAspect ? b.height * videoAspect : b.width
            // Cadrage de base : décalage vertical des réglages.
            let basePanY = (cropOffset - 0.5) * max(fittedHeight * max(zoom, 1) - b.height, 0)
            // Déplacement total = cadrage de base + déplacement interactif,
            // borné pour rester dans la zone vidéo (aspectFill).
            let scale = totalScale()
            let maxPanX = max(fittedWidth / 2 - b.width / (2 * scale), 0)
            let maxPanY = max(fittedHeight / 2 - b.height / (2 * scale), 0)
            let totalPanX = min(max(panX, -maxPanX), maxPanX)
            let totalPanY = min(max(basePanY + panY, -maxPanY), maxPanY)
            // IMPORTANT : CALayer applique déjà la transform AUTOUR DE L'ANCRE
            // (le centre par défaut). Il ne faut donc PAS compenser le centre
            // dans la matrice — sinon le zoom pivote autour du coin bas-gauche
            // et la vidéo « part » en haut à droite. Formule correcte :
            // M(q) = s·(q − pan), soit translate(-pan) puis scale(s).
            let tf = CGAffineTransform(translationX: -totalPanX, y: -totalPanY)
                .scaledBy(x: scale, y: scale)
            playerLayer.setAffineTransform(tf)
        }
    }
}

/// Pont SwiftUI → PlayerLayerView. Aucun coordinator nécessaire : la mise à
/// jour se résume à (ré)assigner le lecteur (le didSet filtre les no-op).
struct VideoPaneView: NSViewRepresentable {

    let player: AVPlayer?
    var displayMode: VideoDisplayMode = .crop
    var videoSize: CGSize = .zero
    var cropOffset: CGFloat = 0.5
    var zoom: CGFloat = 1.0
    var immersiveMode = false
    var seekOnArrows = false
    var onStateChange: ((CGFloat) -> Void)?
    var onShortcut: ((ShortcutAction) -> Void)?
    /// Notifie la vue AppKit créée (utilisée pour la capture PNG du bloc).
    var onViewCreated: ((PlayerLayerView) -> Void)?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.displayMode = displayMode
        view.videoSize = videoSize
        view.cropOffset = cropOffset
        view.zoom = zoom
        view.immersiveMode = immersiveMode
        view.seekOnArrows = seekOnArrows
        view.onStateChange = onStateChange
        view.onShortcut = onShortcut
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
        nsView.displayMode = displayMode
        nsView.videoSize = videoSize
        nsView.cropOffset = cropOffset
        nsView.zoom = zoom
        nsView.immersiveMode = immersiveMode
        nsView.seekOnArrows = seekOnArrows
        nsView.onStateChange = onStateChange
        nsView.onShortcut = onShortcut
        if let onViewCreated {
            onViewCreated(nsView)
        }
    }
}

// MARK: - Formatage du temps

/// Formate un CMTime en « m:ss » (ou « h:mm:ss » au-delà d'une heure).
/// Les temps invalides ou indéfinis renvoient « 0:00 ».
func timeString(_ t: CMTime) -> String {
    guard t.isNumeric, t.seconds.isFinite else { return "0:00" }
    let total = max(0, Int(t.seconds.rounded()))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Vue racine

/// Vue racine : barre supérieure, scène vidéo, bandeau de bibliothèque et
/// barre de transport. La scène accepte les dépôts de fichiers vidéo.
struct ContentView: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var engine: SyncEngine
    @State private var isDropTargeted = false
    @State private var showSettings = false
    @State private var controlsVisible = true
    @State private var hideControlsWork: DispatchWorkItem?
    /// Mini-lecteur flottant : masqué par l'utilisateur (la lecture continue).
    @State private var miniPlayerHidden = false
    /// Décalage du mini-lecteur (glisser-déposer).
    @State private var miniOffset: CGSize = .zero

    // MARK: Corps

    var body: some View {
        Group {
            if session.immersiveMode {
                immersiveLayout
            } else {
                mainLayout
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .preferredColorScheme(.dark)
        // Injection RACINE du moteur : toutes les sections (Vidéothèque,
        // Lecture, immersif) et leurs sous-vues (TransportBar, StagePane,
        // LibraryView, FolderBrowserView) y ont accès. Un @EnvironmentObject
        // manquant = assertion fatale (crash) — d'où l'injection unique ici.
        .environmentObject(library.engine)
        // Quand des vidéos sont ajoutées par l'UTILISATEUR (ouverture, dépôt),
        // on bascule vers la section Vidéothèque. M2 : un ajout d'ARRIÈRE-PLAN
        // (source watcher, scan) ne doit PAS éjecter l'utilisateur de la
        // lecture en cours — d'où la garde !engine.isPlaying.
        .onChange(of: library.assets.count) { oldCount, newCount in
            if newCount > oldCount, !session.immersiveMode, !engine.isPlaying {
                session.section = .library
            }
        }
        .background(WindowAccessor { window in
            if let window {
                // GARDE D'IDENTITÉ : @Published émet objectWillChange même pour
                // une valeur identique — réassigner à chaque re-render crée une
                // boucle infinie (updateNSView → publish → re-render → …),
                // mesurée à 100 % CPU au repos le 11/08/2026.
                if windowController.window !== window {
                    windowController.window = window
                }
                if window.isMovableByWindowBackground != true {
                    window.isMovableByWindowBackground = true
                }
                // m10 : restauration de la position/taille de la fenêtre
                // entre les lancements.
                window.setFrameAutosaveName("TriSync.Main")
            }
        })
        // Dépôt de fichiers vidéo n'importe où dans la fenêtre.
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isDropTargeted = targeted
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(library.engine)
        }
    }

    /// Fenêtre principale : barre latérale (sections + sources) + contenu,
    /// avec le mini-lecteur flottant au-dessus de la section Vidéothèque.
    private var mainLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                SidebarView(
                    onOpenImporter: {
                        let urls = openVideosPanel()
                        if !urls.isEmpty { ingestVideos(urls) }
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
                miniPlayerView
                    .padding(16)
                    .offset(miniOffset)
                    .zIndex(10)
            }
        }
        // Le mini-lecteur réapparaît à chaque retour dans la Vidéothèque.
        // M3 : l'offset est aussi réinitialisé — sinon un mini-lecteur traîné
        // hors de la fenêtre y resterait pour toute la session.
        .onChange(of: session.section) { oldSection, newSection in
            if oldSection == .library, newSection != .library {
                miniPlayerHidden = false
                miniOffset = .zero
            }
        }
    }

    /// Section Vidéothèque : grille de toutes les vidéos, ou navigateur de
    /// dossiers de la source sélectionnée.
    @ViewBuilder
    private var librarySection: some View {
        if let smart = session.smartFolder {
            SmartGridView(title: smart.title,
                          assets: smartAssets(for: smart),
                          showsResumeBadge: smart == .resume) { _ in
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

    /// Assets du dossier intelligent demandé. Réévalué à chaque rendu : les
    /// favoris et les positions de lecture sont publiés par la bibliothèque.
    private func smartAssets(for smart: SmartFolder) -> [VideoAsset] {
        switch smart {
        case .recent:
            // Top 50 des vidéos ajoutées le plus récemment.
            return library.assets
                .sorted { $0.dateAdded > $1.dateAdded }
                .prefix(50)
                .map { $0 }
        case .favorites:
            return library.assets.filter { $0.isFavorite }
        case .resume:
            // Vidéos dont la position de lecture sauvegardée dépasse 15 s.
            return library.assets.filter { library.playbackPosition(for: $0.url) > 15 }
        }
    }

    /// Section Lecture : scène synchronisée + transport, SANS bandeau de
    /// miniatures sous les vidéos.
    @ViewBuilder
    private var playbackSection: some View {
        if library.slots.compactMap({ $0 }).isEmpty {
            emptyPlayback
        } else {
            VStack(spacing: 0) {
                stage
                TransportBar()
            }
        }
    }

    /// État vide de la section Lecture : invitation à sélectionner des vidéos.
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

    // MARK: Mini-lecteur flottant

    /// Le mini-lecteur apparaît dans la Vidéothèque dès qu'une vidéo est
    /// chargée ou en cours de lecture. Il réutilise le PlayerLayerView du
    /// slot référentiel (même AVPlayer : les players restent vivants en
    /// naviguant — aucune reconfiguration du moteur au changement de section).
    private var showMiniPlayer: Bool {
        engine.isPlaying || !library.slots.compactMap({ $0 }).isEmpty
    }

    /// Taille d'affichage du slot référentiel (cadrage du mini-lecteur).
    private var referenceVideoSize: CGSize {
        guard let slot = engine.currentReferenceSlot,
              library.slots.indices.contains(slot),
              let asset = library.slots[slot] else { return .zero }
        return asset.size
    }

    private var miniPlayerView: some View {
        VStack(spacing: 0) {
            VideoPaneView(
                player: engine.referencePlayer(),
                displayMode: settings.displayMode.videoMode,
                videoSize: referenceVideoSize,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: false,
                seekOnArrows: false
            )
            .frame(width: 280, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )

            // Barre de contrôle : lecture/pause, temps, dérive Δ, fermeture.
            // Le glisser-déposer du panneau se fait par cette barre (la zone
            // vidéo garde ses interactions de pan/zoom).
            HStack(spacing: 10) {
                Button {
                    engine.togglePlay()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(engine.isPlaying ? "Pause" : "Lecture")

                Text(timeString(engine.timelineTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let drift = engine.maxDriftMilliseconds, drift >= 5 {
                    Text("Δ \(drift) ms")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .help("Dérive maximale entre les flux")
                }

                Spacer(minLength: 4)

                Button {
                    // Fermer ne stoppe PAS la lecture : le mini-lecteur est
                    // simplement masqué (il réapparaîtra au prochain passage
                    // dans la Vidéothèque).
                    withAnimation(.easeOut(duration: 0.2)) { miniPlayerHidden = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Masquer le mini-lecteur")
                .help("Masquer le mini-lecteur (la lecture continue)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        miniOffset = value.translation
                    }
                    .onEnded { value in
                        miniOffset = value.translation
                    }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .frame(width: 360)
    }

    /// Mode immersif (« super fullscreen ») : uniquement les vidéos. La barre
    /// du haut et le transport apparaissent au mouvement de la souris puis
    /// disparaissent après 3 s sans mouvement. Échap ou bouton pour sortir.
    private var immersiveLayout: some View {
        ZStack {
            background
            stage
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

    /// Barre minimale du mode immersif : sortie + réglages.
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
            .accessibilityLabel("Sortir du mode immersif")
            Text("TriSync")
                .font(.system(size: 13, weight: .bold))
            Text("· mode immersif — souris pour afficher les contrôles")
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
            .help("Réglages")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: Mode immersif — contrôle d'affichage

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

    /// Affiche les contrôles et programme leur disparition après 3 s.
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

    // MARK: Scène

    /// Scène vidéo : disposition réactive selon le nombre d'emplacements
    /// remplis ET leurs ratios (responsive, type page web), avec dépôt de
    /// fichiers sur toute la zone.
    private var stage: some View {
        GeometryReader { geo in
            slotGrid(in: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: loadedCount)
        }
    }

    /// Disposition de la scène selon le preset bento choisi (menu « bento »).
    /// Auto = auto-ajustement selon les ratios des vidéos ; les presets
    /// imposent des compositions fixes (colonnes, maître+détail, murs…).
    @ViewBuilder
    private func slotGrid(in size: CGSize) -> some View {
        let slots = loadedSlots
        let aspects = slots.compactMap { library.slots[$0].map { settings.targetAspect(for: $0) } }
        let spacing: CGFloat = 12
        let preset = settings.isValidPreset(settings.layoutPreset, forCount: slots.count)
            ? settings.layoutPreset : .auto

        if slots.isEmpty {
            HStack(spacing: spacing) {
                ForEach(0..<VideoLibrary.maxSlots, id: \.self) { slot in
                    StagePane(slot: slot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            switch preset {
            case .custom:
                customGrid(slots: slots, size: size, spacing: spacing)
            case .auto:
                autoGrid(slots: slots, aspects: aspects, size: size, spacing: spacing)
            case .sideBySide:
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
            case .stacked:
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
            case .masterH:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    pane(slots[1]).frame(width: max(1, size.width * 0.38))
                }
            case .masterV:
                VStack(spacing: spacing) {
                    pane(slots[0]).frame(maxHeight: .infinity)
                    pane(slots[1]).frame(height: max(1, size.height * 0.38))
                }
            case .threeColumns:
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
            case .masterTwo:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) { pane(slots[1]); pane(slots[2]) }
                        .frame(maxWidth: .infinity)
                }
            case .threeRows:
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
            case .grid2x2:
                HStack(spacing: spacing) {
                    VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: spacing) { pane(slots[2]); pane(slots[3]) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .fourColumns:
                HStack(spacing: spacing) {
                    pane(slots[0]); pane(slots[1]); pane(slots[2]); pane(slots[3])
                }
            case .masterThree:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) { pane(slots[1]); pane(slots[2]); pane(slots[3]) }
                        .frame(maxWidth: .infinity)
                }
            case .wall32:
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
                        .frame(maxHeight: .infinity)
                    HStack(spacing: spacing) { pane(slots[3]); pane(slots[4]) }
                        .frame(maxHeight: .infinity)
                }
            case .wall23:
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
                        .frame(maxHeight: .infinity)
                    HStack(spacing: spacing) { pane(slots[2]); pane(slots[3]); pane(slots[4]) }
                        .frame(maxHeight: .infinity)
                }
            case .fiveColumns:
                HStack(spacing: spacing) {
                    pane(slots[0]); pane(slots[1]); pane(slots[2]); pane(slots[3]); pane(slots[4])
                }
            case .masterFour:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) {
                        HStack(spacing: spacing) { pane(slots[1]); pane(slots[2]) }
                            .frame(maxHeight: .infinity)
                        HStack(spacing: spacing) { pane(slots[3]); pane(slots[4]) }
                            .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Panneau de scène plein cadre.
    private func pane(_ slot: Int) -> some View {
        StagePane(slot: slot)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Layout LIBRE (redimensionnement manuel)

    /// Une rangée de blocs dont les largeurs suivent les poids utilisateur
    /// (settings.weight(for:)) — 2 portrait + 1 paysage : donne plus de
    /// largeur au paysage avec les poignées. Les poignées entre les blocs
    /// se font glisser à la souris (⌥← / ⌥→ au clavier).
    @ViewBuilder
    private func customGrid(slots: [Int], size: CGSize, spacing: CGFloat) -> some View {
        let weights = slots.map { settings.weight(for: $0) }
        let total = max(weights.reduce(0, +), 0.001)
        let available = max(size.width - spacing * CGFloat(slots.count - 1), 1)
        HStack(spacing: spacing) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                pane(slot)
                    .frame(width: max(40, available * weights[index] / total))
                if index < slots.count - 1 {
                    ResizeHandle(left: slot, right: slots[index + 1])
                }
            }
        }
    }

    /// Poignée de redimensionnement entre deux blocs : curseur ↔ et drag
    /// horizontal qui répartit la largeur entre les voisins.
    private struct ResizeHandle: View {
        let left: Int
        let right: Int
        @EnvironmentObject private var settings: AppSettings
        @State private var lastTranslation: CGFloat = 0

        var body: some View {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // Delta incrémental par rapport au tick précédent :
                            // ±300 px de drag = ±100 % de la paire.
                            let delta = Double(value.translation.width - lastTranslation) / 300.0
                            lastTranslation = value.translation.width
                            settings.adjustWeight(delta, left: left, right: right)
                        }
                        .onEnded { _ in
                            lastTranslation = 0
                            NSCursor.pop()
                        }
                )
                .help("Glisser pour redimensionner les blocs (⌥← / ⌥→ au clavier)")
        }
    }

    /// Disposition auto-ajustée selon les ratios des vidéos (responsive) :
    /// — 1 vidéo : plein cadre ;
    /// — 2 vidéos : largeurs proportionnelles aux ratios (ou hauteurs si
    ///   les deux sont en paysage) ;
    /// — 3 vidéos portrait : 3 colonnes proportionnelles (aucun espace noir) ;
    /// — 3 vidéos mixtes : maître à 50 % + colonne de droite dont les hauteurs
    ///   sont proportionnelles aux ratios (le portrait prend plus de place) ;
    /// — 4 vidéos : grille 2×2 ; — 5 vidéos : mur 3+2.
    @ViewBuilder
    private func autoGrid(slots: [Int], aspects: [CGFloat], size: CGSize, spacing: CGFloat) -> some View {
        if slots.count == 1 {
            pane(slots[0])
        } else if slots.count == 2 {
            let bothLandscape = aspects.allSatisfy { $0 >= 1 }
            if bothLandscape {
                let inv = aspects.map { 1 / $0 }
                let total = inv.reduce(0, +)
                VStack(spacing: spacing) {
                    pane(slots[0]).frame(height: max(1, (size.height - spacing) * inv[0] / total))
                    pane(slots[1]).frame(height: max(1, (size.height - spacing) * inv[1] / total))
                }
                .frame(maxWidth: .infinity)
            } else {
                let total = aspects.reduce(0, +)
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(width: max(1, (size.width - spacing) * aspects[0] / total))
                    pane(slots[1]).frame(width: max(1, (size.width - spacing) * aspects[1] / total))
                }
            }
        } else if slots.count == 3 {
            let allPortrait = aspects.allSatisfy { $0 < 1 }
            if allPortrait {
                let total = aspects.reduce(0, +)
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(width: max(1, (size.width - 2 * spacing) * aspects[0] / total))
                    pane(slots[1]).frame(width: max(1, (size.width - 2 * spacing) * aspects[1] / total))
                    pane(slots[2]).frame(width: max(1, (size.width - 2 * spacing) * aspects[2] / total))
                }
            } else {
                let inv = [aspects[1], aspects[2]].map { 1 / $0 }
                let total = inv.reduce(0, +)
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) {
                        pane(slots[1]).frame(height: max(1, (size.height - spacing) * inv[0] / total))
                        pane(slots[2]).frame(height: max(1, (size.height - spacing) * inv[1] / total))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else if slots.count == 4 {
            HStack(spacing: spacing) {
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: spacing) { pane(slots[2]); pane(slots[3]) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: spacing) {
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
                    .frame(maxHeight: .infinity)
                HStack(spacing: spacing) { pane(slots[3]); pane(slots[4]) }
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// Indices des emplacements remplis, dans l'ordre.
    private var loadedSlots: [Int] {
        library.slots.indices.filter { library.slots[$0] != nil }
    }

    private var loadedCount: Int { loadedSlots.count }

    /// Filtre les dossiers déposés et transmet le reste à l'ingestion
    /// (le filtrage vidéo complet est fait par VideoLibrary.videoFiles).
    private func addDropped(_ urls: [URL]) {
        let files = urls.filter { !isDirectory($0) }
        guard !files.isEmpty else { return }
        Task { @MainActor in ingestVideos(files) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: Fond

    /// Fond sombre : dégradé subtil + voile de material très léger
    /// (derrière la scène, jamais au-dessus des vidéos).
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.11, blue: 0.14),
                    Color(red: 0.045, green: 0.045, blue: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.35)
            // Anneau de dépôt : retour visuel pendant le glisser-déposer.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(accent.opacity(0.85), lineWidth: 2)
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Barre supérieure

/// Barre supérieure : identité de l'app + actions d'ouverture et de
/// nettoyage. Préparée pour un titre de fenêtre masqué (hiddenTitleBar) :
/// le bloc titre est décalé pour dégager les feux de signalisation.
struct TopBar: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController
    @Binding var showLibrary: Bool
    @Binding var showSettings: Bool
    var onEnterImmersive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TriSync")
                    .font(.system(size: 16, weight: .bold))
                Text("Lecture synchronisée · Apple Silicon")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 56)

            Spacer()

            // Bascule Bibliothèque (grille complète) / Lecture.
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showLibrary.toggle() }
            } label: {
                Image(systemName: showLibrary ? "play.rectangle.fill" : "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(7)
                    .background(
                        Circle().fill(showLibrary ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showLibrary ? "Revenir à la lecture" : "Afficher la bibliothèque")
            .help(showLibrary ? "Revenir à la lecture" : "Afficher la bibliothèque en grille")
            .disabled(library.assets.isEmpty)

            // Menu bento : compositions selon le nombre de vidéos.
            bentoMenu

            BarButton(systemName: "folder", title: "Ouvrir…") {
                let urls = openVideosPanel()
                if !urls.isEmpty { ingestVideos(urls) }
            }
            .keyboardShortcut("o", modifiers: [.command])
            .help("Importer des vidéos (⌘O)")

            BarButton(systemName: "trash", title: "Tout effacer") {
                library.clearAll()
            }
            .help("Vider la bibliothèque")

            // Plein écran.
            Button {
                windowController.window?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.control, .command])
            .accessibilityLabel("Plein écran")
            .help("Plein écran (⌃⌘F)")

            // Mode multi-écran : envoie la scène sur l'écran externe (si présent).
            Button {
                if !windowController.moveToExternalScreen() {
                    NSSound.beep()
                }
            } label: {
                Image(systemName: "display.2")
                    .font(.system(size: 12, weight: .medium))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Écran externe")
            .help(windowController.externalScreenName.map {
                "Déplacer vers \($0)" } ?? "Aucun écran externe détecté")
            .disabled(windowController.externalScreenName == nil)

            // Mode immersif (super fullscreen).
            Button(action: onEnterImmersive) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .accessibilityLabel("Mode immersif")
            .help("Mode immersif : uniquement les vidéos (⇧⌘F)")

            // Réglages d'affichage.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Réglages")
            .help("Réglages (affichage, ratio, cadrage…)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Menu bento

    private var loadedCount: Int { library.slots.compactMap { $0 }.count }

    private var bentoMenu: some View {
        Menu {
            ForEach(settings.validPresets(forCount: loadedCount)) { preset in
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        settings.layoutPreset = preset
                    }
                } label: {
                    HStack(spacing: 10) {
                        bentoThumb(preset)
                        Text(preset.rawValue)
                            .font(.system(size: 12))
                        if settings.layoutPreset == preset {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 12, weight: .medium))
                .padding(7)
                .background(Circle().fill(Color.white.opacity(0.05)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(library.assets.isEmpty || loadedCount == 0)
        .accessibilityLabel("Composition de la scène")
        .help("Composition bento : \(settings.layoutPreset.rawValue)")
    }

    /// Miniature de composition (bento) pour le menu.
    @ViewBuilder
    private func bentoThumb(_ preset: AppSettings.LayoutPreset) -> some View {
        let rect = RoundedRectangle(cornerRadius: 1.5)
        let selected = settings.layoutPreset == preset
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.4))
            switch preset {
            case .custom:
                // Vignette « Libre » : blocs de largeurs inégales (poignées).
                HStack(spacing: 2) {
                    rect.fill(accent.opacity(0.8)).frame(width: 12, height: 14)
                    rect.fill(accent.opacity(0.45)).frame(width: 4, height: 14)
                    rect.fill(accent.opacity(0.8)).frame(width: 8, height: 14)
                }
            case .auto:
                HStack(spacing: 2) {
                    rect.fill(accent.opacity(0.95)).frame(width: 10, height: 14)
                    rect.fill(accent.opacity(0.6)).frame(width: 7, height: 14)
                    rect.fill(accent.opacity(0.4)).frame(width: 5, height: 14)
                }
            case .sideBySide:
                HStack(spacing: 2) { rect.fill(accent.opacity(0.8)); rect.fill(accent.opacity(0.8)) }
            case .stacked:
                VStack(spacing: 2) { rect.fill(accent.opacity(0.8)); rect.fill(accent.opacity(0.8)) }
            case .masterH:
                HStack(spacing: 2) { rect.fill(accent.opacity(0.9)).frame(width: 10); rect.fill(accent.opacity(0.6)).frame(width: 6) }
            case .masterV:
                VStack(spacing: 2) { rect.fill(accent.opacity(0.9)).frame(height: 10); rect.fill(accent.opacity(0.6)).frame(height: 6) }
            case .threeColumns:
                HStack(spacing: 2) { rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)) }
            case .masterTwo:
                HStack(spacing: 2) {
                    rect.fill(accent.opacity(0.9)).frame(width: 9)
                    VStack(spacing: 2) { rect.fill(accent.opacity(0.6)); rect.fill(accent.opacity(0.6)) }
                        .frame(width: 7)
                }
            case .threeRows:
                VStack(spacing: 2) { rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)) }
            case .grid2x2:
                VStack(spacing: 2) {
                    HStack(spacing: 2) { rect.fill(accent.opacity(0.75)); rect.fill(accent.opacity(0.75)) }
                    HStack(spacing: 2) { rect.fill(accent.opacity(0.75)); rect.fill(accent.opacity(0.75)) }
                }
            case .fourColumns:
                HStack(spacing: 2) { rect.fill(accent.opacity(0.65)); rect.fill(accent.opacity(0.65)); rect.fill(accent.opacity(0.65)); rect.fill(accent.opacity(0.65)) }
            case .masterThree:
                HStack(spacing: 2) {
                    rect.fill(accent.opacity(0.9)).frame(width: 9)
                    VStack(spacing: 2) { rect.fill(accent.opacity(0.55)); rect.fill(accent.opacity(0.55)); rect.fill(accent.opacity(0.55)) }
                        .frame(width: 7)
                }
            case .wall32:
                VStack(spacing: 2) {
                    HStack(spacing: 2) { rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)) }
                    HStack(spacing: 2) { rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)) }
                }
            case .wall23:
                VStack(spacing: 2) {
                    HStack(spacing: 2) { rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)) }
                    HStack(spacing: 2) { rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)); rect.fill(accent.opacity(0.7)) }
                }
            case .fiveColumns:
                HStack(spacing: 2) {
                    rect.fill(accent.opacity(0.6)); rect.fill(accent.opacity(0.6)); rect.fill(accent.opacity(0.6)); rect.fill(accent.opacity(0.6)); rect.fill(accent.opacity(0.6))
                }
            case .masterFour:
                HStack(spacing: 2) {
                    rect.fill(accent.opacity(0.9)).frame(width: 9)
                    VStack(spacing: 2) {
                        HStack(spacing: 2) { rect.fill(accent.opacity(0.55)); rect.fill(accent.opacity(0.55)) }
                        HStack(spacing: 2) { rect.fill(accent.opacity(0.55)); rect.fill(accent.opacity(0.55)) }
                    }
                    .frame(width: 7)
                }
            }
        }
        .frame(width: 24, height: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(selected ? Color.white.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Bandeau de bibliothèque

/// Bandeau horizontal des vidéos de la bibliothèque (miniatures cliquables).
/// Masqué tant que la bibliothèque est vide.
struct GalleryStrip: View {

    @EnvironmentObject private var library: VideoLibrary

    var body: some View {
        if !library.assets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(library.assets) { asset in
                        AssetChip(asset: asset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }
}

/// Pastille de bibliothèque : miniature 160×90, titre, durée, emplacement
/// assigné (A/B/C) et bouton de retrait. Un clic assigne l'actif à
/// l'emplacement sélectionné.
private struct AssetChip: View {

    @EnvironmentObject private var library: VideoLibrary

    let asset: VideoAsset

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeString(asset.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let letter = slotLetter {
                    Text("Emplacement \(letter)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.85)))
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 4)

            Button {
                library.removeAsset(asset)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(hovering ? Color.white.opacity(0.15) : Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Retirer de la bibliothèque")
            .padding(.trailing, 6)
        }
        .frame(width: 300, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { library.assign(asset, to: library.selectedSlot) }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = asset.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 90)
                .clipped()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.22, blue: 0.27),
                        Color(red: 0.10, green: 0.10, blue: 0.13)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 160, height: 90)
        }
    }

    /// Lettre A/B/C si l'actif occupe un emplacement, sinon nil.
    private var slotLetter: String? {
        guard let index = library.slots.firstIndex(where: { $0?.id == asset.id }) else { return nil }
        return slotLetters[index]
    }
}

// MARK: - Caches (métadonnées + vignettes)

/// Métadonnées vidéo mémoïsées (durée, taille d'affichage, fréquence).
struct VideoMetadata: Codable {
    var duration: Double
    var width: Double
    var height: Double
    var frameRate: Double
}

/// Cache de métadonnées persisté dans UserDefaults : évite de relire
/// l'AVAsset (chargement AVFoundation) pour chaque vidéo déjà connue, y
/// compris entre deux lancements de l'application.
final class MetadataCache {
    static let shared = MetadataCache()
    private let defaultsKey = "library.metadataCache"
    private var cache: [String: VideoMetadata] = [:]
    private let maxEntries = 2000
    private var saveWork: DispatchWorkItem?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([String: VideoMetadata].self, from: data) else { return }
        cache = saved
    }

    func get(for url: URL) -> VideoMetadata? {
        cache[url.path]
    }

    func set(_ metadata: VideoMetadata, for url: URL) {
        guard metadata.duration.isFinite, metadata.width > 0 else { return }
        cache[url.path] = metadata
        // Éviction simple si le cache dépasse la taille maximale.
        while cache.count > maxEntries, let key = cache.keys.first {
            cache.removeValue(forKey: key)
        }
        // Sauvegarde différée pour ne pas écrire UserDefaults à chaque vidéo.
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Limite les générations de vignettes simultanées (protège le décodeur
/// matériel VideoToolbox d'une surcharge au premier scan).
private actor ThumbGenLimiter {
    private var active = 0
    private let max = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < max {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Génère et met en cache les captures d'écran des vidéos.
///
/// PERSISTANCE DISQUE : chaque vignette est sauvegardée en JPEG dans
/// ~/Library/Caches/TriSync/Thumbs/ (clé = empreinte SHA-256 stable du
/// chemin). Une fois un dossier synchronisé, les vignettes se chargent
/// instantanément — y compris après redémarrage de l'application — sans
/// jamais redécoder la vidéo. (Le hashValue de Swift n'est PAS stable entre
/// lancements, d'où SHA-256 via CryptoKit.)
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    enum Variant: String {
        case portrait = "p"   // cartes du navigateur (3:4)
        case landscape = "l"  // vignettes de bibliothèque (16:9)
    }

    private let memory = NSCache<NSString, NSImage>()
    private let diskDir: URL
    private let limiter = ThumbGenLimiter()

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = base.appendingPathComponent("TriSync/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// Empreinte stable du chemin (SHA-256 tronquée).
    private func stableKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    private func diskFile(for url: URL, variant: Variant) -> URL {
        diskDir.appendingPathComponent("\(stableKey(url))_\(variant.rawValue).jpg")
    }

    /// Retourne la vignette : mémoire → disque → génération (limitée à 4
    /// en parallèle), avec sauvegarde JPEG automatique après génération.
    func thumbnail(for url: URL, variant: Variant = .portrait) async -> NSImage? {
        let file = diskFile(for: url, variant: variant)
        let memKey = file.lastPathComponent as NSString

        if let image = memory.object(forKey: memKey) { return image }
        if let image = NSImage(contentsOf: file) {
            memory.setObject(image, forKey: memKey)
            return image
        }

        await limiter.acquire()
        defer { Task { await limiter.release() } }

        // Une autre tâche a pu générer le fichier pendant l'attente.
        if let image = NSImage(contentsOf: file) {
            memory.setObject(image, forKey: memKey)
            return image
        }

        let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = variant == .portrait ? CGSize(width: 360, height: 480) : CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        memory.setObject(image, forKey: memKey)
        // Persistance disque : la vidéo ne sera plus jamais redécodée.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) {
            try? data.write(to: file)
        }
        return image
    }

    /// Préchauffe les vignettes d'une liste d'URLs en arrière-plan (priorité
    /// utilitaire, 4 générations simultanées max — évite de saturer le
    /// décodeur matériel VideoToolbox).
    func prefetch(_ urls: [URL], limit: Int = 4) async {
        let pending = urls.filter { url in
            let file = diskFile(for: url, variant: .portrait)
            let memKey = file.lastPathComponent as NSString
            return memory.object(forKey: memKey) == nil
                && !FileManager.default.fileExists(atPath: file.path)
        }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for url in pending.prefix(500) {
                group.addTask(priority: .utility) {
                    _ = await ThumbnailCache.shared.thumbnail(for: url, variant: .portrait)
                }
                active += 1
                if active >= limit {
                    await group.next()
                    active -= 1
                }
            }
        }
    }
}

// MARK: - Barre latérale (sections + sources)

/// Navigation principale : sections Vidéothèque / Lecture, sources de la
/// bibliothèque, et actions (importer, plein écran, immersif, réglages).
struct SidebarView: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController
    var onOpenImporter: () -> Void = {}
    var onEnterImmersive: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private var filledSlots: Int { library.slots.compactMap { $0 }.count }

    /// Résumé du mode maître affiché dans le menu de la barre latérale :
    /// « Auto », « Aucun », ou « Bloc B ».
    private var masterSummary: String {
        let engine = library.engine
        switch engine.referenceMode {
        case .auto:
            return "Auto"
        case .none:
            return "Aucun"
        case .manual:
            if let slot = engine.manualReferenceSlot {
                return "Bloc \(slotLetters[slot])"
            }
            return "Manuel"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Titre (décalé sous les feux tricolores).
            VStack(alignment: .leading, spacing: 2) {
                Text("TriSync")
                    .font(.system(size: 15, weight: .bold))
                Text("Lecture synchronisée")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 44)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Section Lecture (badge N/5).
            itemButton(title: "Lecture", icon: "play.rectangle.fill",
                       badge: filledSlots > 0 ? "\(filledSlots)/\(VideoLibrary.maxSlots)" : nil,
                       selected: session.section == .play) {
                session.section = .play
            }

            // M1 : menu de composition (bento) — il n'existait que dans la
            // TopBar jamais rendue : la fonctionnalité était inaccessible.
            // Réintégré ici, sous la section Lecture.
            Menu {
                ForEach(settings.validPresets(forCount: filledSlots)) { preset in
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            settings.layoutPreset = preset
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(preset.rawValue)
                                .font(.system(size: 12))
                            if settings.layoutPreset == preset {
                                Spacer()
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16)
                    Text("Composition")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 8)
            .help("Composition de la scène (Auto, Côte à côte, Maître+détail…)")

            // MAÎTRE : mode de désignation du référentiel (auto / aucun /
            // bloc manuel). Le maître pilote la timeline globale et l'audio
            // par défaut.
            Menu {
                Button {
                    library.engine.setReferenceMode(.auto)
                } label: {
                    HStack(spacing: 10) {
                        Text("Auto (premier bloc)")
                            .font(.system(size: 12))
                        if library.engine.referenceMode == .auto {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                }
                Button {
                    library.engine.setReferenceMode(.none)
                } label: {
                    HStack(spacing: 10) {
                        Text("Aucun maître")
                            .font(.system(size: 12))
                        if library.engine.referenceMode == .none {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                }
                .help("Aucun bloc privilégié : le clic rend n'importe quel bloc indépendant")

                Divider()

                ForEach(Array(library.slots.enumerated()), id: \.offset) { index, asset in
                    if let asset {
                        Button {
                            library.engine.setManualMaster(index)
                        } label: {
                            HStack(spacing: 10) {
                                Text("Bloc \(slotLetters[index]) — \(asset.title)")
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if library.engine.referenceMode == .manual, library.engine.manualReferenceSlot == index {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(accent)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16)
                    Text("Maître")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(masterSummary)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 8)
            .help("Choisir la vidéo maître (timeline globale, audio par défaut)")

            // Section Vidéothèque : toutes les vidéos.
            itemButton(title: "Vidéothèque", icon: "square.grid.2x2.fill",
                       selected: session.section == .library && session.browsingSource == nil && session.smartFolder == nil) {
                session.section = .library
                session.browsingSource = nil
                session.smartFolder = nil
            }

            // Dossiers intelligents : vues calculées à la volée depuis les
            // assets (récemment ajoutés, favoris ★, reprise de lecture).
            Text("BIBLIOTHÈQUE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.horizontal, 14)
            ForEach(SmartFolder.allCases) { smart in
                smartFolderRow(smart)
            }

            // Sources (dossiers Mac / disque externe).
            if !library.sources.isEmpty {
                Text("SOURCES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.horizontal, 14)
                ForEach(library.sources) { source in
                    sourceRow(source)
                }
            }

            Spacer()

            // Actions.
            HStack(spacing: 8) {
                // M1 : raccourcis branchés ici (la TopBar n'est jamais rendue —
                // ces touches étaient annoncées mais mortes).
                iconButton("folder.badge.plus", "Importer des vidéos… (⌘O)") { onOpenImporter() }
                    .keyboardShortcut("o", modifiers: [.command])
                iconButton("folder", "Ajouter un dossier source…") {
                    if let url = openFolderPanel() {
                        library.addSource(url: url)
                        session.browsingSource = library.sources.last
                        session.folderPath = library.sources.last.map { [$0.url] } ?? []
                        session.section = .library
                    }
                }
                iconButton("trash", "Tout effacer") { library.clearAll() }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            HStack(spacing: 8) {
                iconButton("viewfinder", "Mode immersif (⇧⌘F)") { onEnterImmersive() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                iconButton("arrow.up.left.and.arrow.down.right", "Plein écran (⌃⌘F)") {
                    windowController.window?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
                iconButton("gearshape.fill", "Réglages") { onOpenSettings() }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.35))
    }

    private func itemButton(title: String, icon: String, badge: String? = nil,
                            selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.11) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func sourceRow(_ source: LibrarySource) -> some View {
        let selected = session.section == .library && session.browsingSource?.id == source.id
        return Button {
            session.section = .library
            session.browsingSource = source
            session.smartFolder = nil
            session.folderPath = [source.url]
        } label: {
            HStack(spacing: 8) {
                Image(systemName: source.enabled ? "externaldrive.fill" : "externaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(source.enabled ? accent : Color.secondary)
                    .frame(width: 16)
                Text(source.url.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.11) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help(source.url.path)
    }

    /// Entrée de dossier intelligent : affiche la grille calculée associée.
    private func smartFolderRow(_ smart: SmartFolder) -> some View {
        let selected = session.section == .library
            && session.browsingSource == nil
            && session.smartFolder == smart
        return Button {
            session.section = .library
            session.browsingSource = nil
            session.smartFolder = smart
        } label: {
            HStack(spacing: 8) {
                Image(systemName: smart.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? accent : Color.secondary)
                    .frame(width: 16)
                Text(smart.title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.11) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Navigateur de dossiers

/// Navigateur de dossiers d'une source (façon Infuse « Fichiers ») : liste
/// les sous-dossiers et les vidéos du dossier courant à la demande, avec
/// captures d'écran en cache. Clic = sélection, ⌘+clic = multi-sélection,
/// double-clic = lancer immédiatement.
struct FolderBrowserView: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    let source: LibrarySource

    /// Dossier « géant » : au-delà, les vignettes sont désactivées pour
    /// garder la navigation instantanée (placeholder icône uniquement).
    static let thumbnailLimit = 200

    /// Ordre de tri des vidéos du navigateur.
    private enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Nom"
        case date = "Date"
        case duration = "Durée"
        var id: String { rawValue }
    }

    /// Mode d'affichage : grille (vignettes) ou liste (lignes compactes).
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case grid = "Grille"
        case list = "Liste"
        var id: String { rawValue }
    }

    @State private var folders: [URL] = []
    @State private var videos: [URL] = []
    /// Texte de recherche : filtre instantané par titre, insensible à la
    /// casse et aux diacritiques.
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var displayMode: DisplayMode = .grid

    private var currentURL: URL { session.folderPath.last ?? source.url }
    private var showThumbnails: Bool { videos.count <= Self.thumbnailLimit }
    // Colonnes à largeur quasi constante (128-152) : cartes toutes au même
    // format, rangées parfaitement alignées (aucune superposition).
    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 152), spacing: 12)]

    /// Vidéos filtrées par la recherche puis triées selon le critère choisi.
    /// Appliqué AVANT l'affichage : les vignettes de la grille restent
    /// inchangées (cache par URL).
    private var filteredVideos: [URL] {
        var result = videos
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !query.isEmpty {
            result = result.filter {
                $0.deletingPathExtension().lastPathComponent
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query)
            }
        }
        switch sortOrder {
        case .name:
            result.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        case .date:
            result.sort { modificationDate($0) > modificationDate($1) }
        case .duration:
            result.sort { cachedDuration($0) > cachedDuration($1) }
        }
        return result
    }

    /// Date de modification d'une vidéo (tri « Date »).
    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Durée mémoïsée d'une vidéo (tri « Durée », sans ouvrir l'AVAsset).
    private func cachedDuration(_ url: URL) -> Double {
        MetadataCache.shared.get(for: url)?.duration ?? 0
    }

    /// Clic simple / ⌘+clic sur une vidéo (mêmes règles que la grille).
    private func selectVideo(_ url: URL) {
        guard let asset = library.ensureInLibrary(url) else { return }
        if NSEvent.modifierFlags.contains(.command) {
            library.toggleSelection(asset)
        } else {
            library.selectOnly(asset)
        }
    }

    /// Double-clic : lance immédiatement cette vidéo seule.
    private func launchVideo(_ url: URL) {
        guard let asset = library.ensureInLibrary(url) else { return }
        library.selectOnly(asset)
        library.launchSelected()
        withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
    }

    var body: some View {
        VStack(spacing: 0) {
            // En-tête : retour, chemin, lancer la sélection.
            HStack(spacing: 10) {
                if session.folderPath.count > 1 {
                    Button {
                        session.folderPath.removeLast()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(6)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Dossier parent")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.folderPath.count > 1
                         ? session.folderPath.last?.lastPathComponent ?? source.url.lastPathComponent
                         : source.url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(currentURL.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if !showThumbnails {
                    Text("\(videos.count) vidéos — vignettes désactivées (dossier volumineux)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Barre d'outils : recherche, tri et bascule Grille/Liste.
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Rechercher…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        // m4 : Retour dans le champ ne doit pas déclencher
                        // « Lancer (N) » (key equivalents prioritaire).
                        .onSubmit { }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .frame(width: 170)

                if !searchText.isEmpty {
                    Text("\(filteredVideos.count) résultat\(filteredVideos.count > 1 ? "s" : "")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Picker("Trier", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 96)
                .help("Trier les vidéos")

                Picker("Affichage", selection: $displayMode) {
                    Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                    Image(systemName: "list.bullet").tag(DisplayMode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 92)
                .help("Grille / Liste")

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if displayMode == .grid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(folders, id: \.self) { folder in
                            folderTile(folder)
                        }
                        ForEach(filteredVideos, id: \.self) { video in
                            BrowserVideoCard(url: video, showThumbnail: showThumbnails)
                        }
                    }
                    .padding(14)
                }
            } else {
                // Mode liste : lignes compactes sans vignettes (économie pour
                // les gros dossiers) — mêmes interactions que la grille.
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders, id: \.self) { folder in
                            folderListRow(folder)
                        }
                        ForEach(filteredVideos, id: \.self) { video in
                            VideoListRow(url: video,
                                         onSelect: { selectVideo(video) },
                                         onLaunch: { launchVideo(video) })
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color.black.opacity(0.25))
        .task(id: currentURL) { await loadContents() }
    }

    private func folderTile(_ folder: URL) -> some View {
        Button {
            session.folderPath.append(folder)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(accent.opacity(0.85))
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                Text(folder.lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            // MÊME hauteur que les cartes vidéo (210 px) : dans la grille
            // mixte dossiers+vidéos, toutes les tuiles sont alignées.
            .frame(height: 210)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(folder.path)
    }

    /// Ligne de dossier en mode Liste (icône + nom + chevron).
    private func folderListRow(_ folder: URL) -> some View {
        Button {
            session.folderPath.append(folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accent.opacity(0.85))
                    .frame(width: 16)
                Text(folder.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.03)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(folder.path)
    }

    /// Liste à la demande du dossier courant (rapide : fichiers locaux).
    private func loadContents() async {
        let url = currentURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        var dirs: [URL] = []
        var files: [URL] = []
        for item in contents {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isHidden != true else { continue }
            if values.isDirectory == true {
                dirs.append(item)
            } else if values.isRegularFile == true {
                files.append(item)
            }
        }
        folders = dirs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        videos = VideoLibrary.videoFiles(from: files).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        // Préchargement des vignettes du dossier courant (si pas géant),
        // et du dossier PARENT pour un retour arrière instantané.
        if showThumbnails {
            await ThumbnailCache.shared.prefetch(videos)
            let parentURL = session.folderPath.count > 1 ? session.folderPath.dropLast().last : nil
            if let parentURL {
                Task.detached(priority: .utility) {
                    let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
                    guard let contents = try? FileManager.default.contentsOfDirectory(
                        at: parentURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                    ) else { return }
                    let parentVideos = VideoLibrary.videoFiles(from: contents)
                    await ThumbnailCache.shared.prefetch(parentVideos)
                }
            }
        }
    }

    private func launchSelection() {
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        library.launchSelected()
        withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
        library.engine.play()
    }
}

/// Ligne compacte du mode Liste du navigateur de dossiers : titre, durée,
/// date et taille SANS vignette (économie pour les gros dossiers). Mêmes
/// interactions que la grille : ⌘+clic = sélectionner, double-clic = lancer.
private struct VideoListRow: View {

    @EnvironmentObject private var library: VideoLibrary
    let url: URL
    var onSelect: () -> Void = {}
    var onLaunch: () -> Void = {}

    private var asset: VideoAsset? { library.assets.first { $0.url == url } }
    private var selected: Bool {
        guard let asset else { return false }
        return library.selectedOrder.contains(asset.id)
    }
    private var slotLetter: String? {
        guard let asset else { return nil }
        return library.slots.firstIndex { $0?.id == asset.id }.map { slotLetters[$0] }
    }
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }
    private var dateText: String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        return Self.dateFormatter.string(from: date)
    }
    private var sizeText: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let letter = slotLetter {
                Text(letter)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(accent))
            }
            Spacer(minLength: 8)
            if let duration = cachedDuration, duration.isNumeric, duration.seconds > 0 {
                Text(timeString(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            Text(dateText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            Text(sizeText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.09) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onLaunch() }
        .help("Clic : sélectionner · ⌘+clic : multi-sélection · Double-clic : lancer")
    }
}

/// Carte vidéo du navigateur de dossiers : capture en cache, badge
/// d'emplacement si déjà chargée, coche de sélection multi.
struct BrowserVideoCard: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var engine: SyncEngine
    let url: URL
    var showThumbnail = true

    @State private var thumbnail: NSImage?

    private var asset: VideoAsset? { library.assets.first { $0.url == url } }
    private var selected: Bool {
        guard let asset else { return false }
        return library.selectedOrder.contains(asset.id)
    }
    private var slotLetter: String? {
        guard let asset else { return nil }
        return library.slots.firstIndex { $0?.id == asset.id }.map { slotLetters[$0] }
    }
    /// Durée affichée depuis le cache de métadonnées (sans ouvrir l'AVAsset).
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }

    /// Étoile de favori : bascule « À regarder » (persistée par chemin).
    private func favoriteButton(_ asset: VideoAsset) -> some View {
        Button {
            library.toggleFavorite(asset)
        } label: {
            Image(systemName: asset.isFavorite ? "star.fill" : "star")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(asset.isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
        .help(asset.isFavorite ? "Retirer des favoris (À regarder)" : "Ajouter aux favoris (À regarder)")
    }

    /// Position de lecture mémorisée (> 15 s) → badge « Repris ».
    private var resumePosition: Double? {
        let position = engine.position(for: url)
        return position > 15 ? position : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if showThumbnail, let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.06))
                            Image(systemName: showThumbnail ? "film" : "film.stack")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Hauteur FIXE : toutes les cartes ont exactement le même
                // format (148 px de vignette) → rangées alignées, jamais de
                // chevauchement entre blocs voisins.
                .frame(height: 148)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(accent)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let letter = slotLetter {
                    Text(letter)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(accent))
                        .padding(6)
                }
                if let position = resumePosition {
                    Text("Repris \(timeString(CMTime(seconds: position, preferredTimescale: 600)))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                if let duration = cachedDuration, duration.isNumeric, duration.seconds > 0 {
                    Text(timeString(duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                if let asset {
                    favoriteButton(asset)
                }
            }
        }
        .padding(8)
        .frame(height: 210)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.09 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? accent : Color.white.opacity(0.07), lineWidth: selected ? 2 : 1)
        )
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            guard let asset = library.ensureInLibrary(url) else { return }
            if NSEvent.modifierFlags.contains(.command) {
                library.toggleSelection(asset)
            } else {
                library.selectOnly(asset)
            }
        }
        .onTapGesture(count: 2) {
            guard let asset = library.ensureInLibrary(url) else { return }
            library.selectOnly(asset)
            library.launchSelected()
            withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
        }
        .help("Clic : sélectionner · ⌘+clic : multi-sélection · Double-clic : lancer")
        .task(id: showThumbnail) {
            guard showThumbnail else { thumbnail = nil; return }
            thumbnail = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

// MARK: - Bibliothèque (grille)

/// Bibliothèque complète : grille responsive de cartes portrait (captures
/// d'écran des vidéos, titre, durée, emplacement, retrait).
/// — Clic simple : sélectionne la carte ;
/// — ⌘+clic : ajoute/retire de la sélection (multi) ;
/// — « Lancer (N) » : place la sélection (max 5, ordre des clics = A→E) puis lit ;
/// — Double-clic : lance immédiatement cette vidéo seule.
struct LibraryView: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    var onLaunch: ([VideoAsset]) -> Void = { _ in }

    /// Ordre de tri de la bibliothèque.
    private enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Nom"
        case date = "Date"
        case duration = "Durée"
        var id: String { rawValue }
    }

    /// Texte de recherche : filtre instantané par titre (insensible à la
    /// casse et aux diacritiques).
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 152), spacing: 12)]

    /// Assets filtrés par la recherche puis triés (nom, date d'ajout, durée).
    /// Appliqué AVANT l'affichage : les vignettes restent inchangées.
    private var filteredAssets: [VideoAsset] {
        var result = library.assets
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !query.isEmpty {
            result = result.filter {
                $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query)
            }
        }
        switch sortOrder {
        case .name:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date:
            result.sort { $0.dateAdded > $1.dateAdded }
        case .duration:
            result.sort { $0.duration.seconds > $1.duration.seconds }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(filteredAssets.count) vidéo\(filteredAssets.count > 1 ? "s" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots) à l'écran")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Lancer la sélection (Entrée)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Rechercher…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        // m4 : Retour dans le champ ne doit pas déclencher
                        // « Lancer (N) » (key equivalents prioritaire).
                        .onSubmit { }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .frame(width: 170)
                Picker("Trier", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 96)
                .help("Trier les vidéos")
                Spacer()
                Text("⌘+clic : multi-sélection · Double-clic : lancer directement")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredAssets) { asset in
                        LibraryCard(asset: asset, onDoubleClick: {
                            library.selectOnly(asset)
                            launchSelection()
                        })
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
    }

    /// Place la sélection (max 5, ordre des clics) dans les emplacements A→E,
    /// vide la sélection et lance la lecture synchronisée.
    private func launchSelection() {
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        library.launchSelected()
        onLaunch(assets)
    }
}

/// Carte de la bibliothèque : vignette portrait 3:4, titre, durée, badge
/// d'emplacement (A/B/C) et bouton de retrait au survol.
struct LibraryCard: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    let asset: VideoAsset
    /// Badge de reprise (« Repris 3:24 ») affiché sur la vignette, si présent.
    var resumeText: String? = nil
    var onDoubleClick: () -> Void = {}

    /// Vrai quand la carte fait partie de la sélection multi (⌘+clic).
    private var selected: Bool {
        library.selectedOrder.contains(asset.id)
    }

    /// Position de lecture mémorisée (> 15 s) → badge « Repris ».
    private var resumePosition: Double? {
        let position = engine.position(for: asset.url)
        return position > 15 ? position : nil
    }

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumb
                    // Hauteur FIXE : toutes les cartes au même format (148 px),
                    // rangées alignées, aucun chevauchement entre blocs.
                    .frame(height: 148)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Coche de sélection (⌘+clic) en haut à gauche.
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(accent)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let letter = slotLetter {
                    Text(letter)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accent))
                        .padding(5)
                }
                if hovering {
                    // M4 : le ✕ est décalé SOUS le badge de lettre (sinon il le
                    // recouvre exactement — badge illisible au survol).
                    Button {
                        library.removeAsset(asset)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 28)
                    .accessibilityLabel("Retirer de la bibliothèque")
                    .help("Retirer de la bibliothèque")
                }
                if let position = resumePosition {
                    Text("Repris \(timeString(CMTime(seconds: position, preferredTimescale: 600)))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(asset.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(timeString(asset.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                favoriteButton
            }
        }
        .padding(8)
        .frame(height: 210)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    selected ? accent : Color.white.opacity(0.07),
                    lineWidth: selected ? 2 : 1
                )
        )
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                // ⌘+clic : ajoute/retire de la sélection (multi).
                library.toggleSelection(asset)
            } else {
                // Clic simple : sélection unique.
                library.selectOnly(asset)
            }
        }
        .onTapGesture(count: 2) { onDoubleClick() }
        .onHover { hovering = $0 }
        .help("Clic : sélectionner · ⌘+clic : multi-sélection · Double-clic : lancer")
    }

    @ViewBuilder
    private var thumb: some View {
        if let image = asset.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.22, green: 0.22, blue: 0.27), Color(red: 0.10, green: 0.10, blue: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// Étoile de favori : bascule « À regarder » (persistée par chemin).
    private var favoriteButton: some View {
        Button {
            library.toggleFavorite(asset)
        } label: {
            Image(systemName: asset.isFavorite ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(asset.isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
        .help(asset.isFavorite ? "Retirer des favoris (À regarder)" : "Ajouter aux favoris (À regarder)")
    }

    /// Lettre A/B/C si l'actif occupe un emplacement, sinon nil.
    private var slotLetter: String? {
        guard let index = library.slots.firstIndex(where: { $0?.id == asset.id }) else { return nil }
        return slotLetters[index]
    }
}

// MARK: - Dossiers intelligents

/// Grille générique des dossiers intelligents (« Récemment ajoutés »,
/// « À regarder », « Reprendre ») : réutilise les cartes de la bibliothèque
/// (vignettes, sélection ⌘+clic, double-clic, étoile ★) sur un sous-ensemble
/// d'assets — aucune logique dupliquée entre les trois vues.
struct SmartGridView: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    let title: String
    let assets: [VideoAsset]
    /// Affiche le badge « Repris m:ss » sur les cartes (vue « Reprendre »).
    var showsResumeBadge = false
    var onLaunch: ([VideoAsset]) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 152), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(assets.count) vidéo\(assets.count > 1 ? "s" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots) à l'écran")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Lancer la sélection (Entrée)")
                }
                Text("⌘+clic : multi-sélection · Double-clic : lancer directement")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in
                        LibraryCard(asset: asset,
                                    resumeText: showsResumeBadge ? resumeText(for: asset) : nil,
                                    onDoubleClick: {
                            library.selectOnly(asset)
                            launchSelection()
                        })
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
    }

    /// Badge « Repris m:ss » si une position de lecture est enregistrée.
    private func resumeText(for asset: VideoAsset) -> String? {
        let position = library.playbackPosition(for: asset.url)
        guard position > 15 else { return nil }
        return "Repris " + timeString(CMTime(seconds: position, preferredTimescale: 600))
    }

    /// Place la sélection (max 5, ordre des clics) dans les emplacements A→E,
    /// vide la sélection et lance la lecture synchronisée.
    private func launchSelection() {
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        library.launchSelected()
        onLaunch(assets)
    }
}

// MARK: - Réglages (panneau modal)

/// Panneau « Réglages » façon lecteur pro : colonne de navigation à gauche
/// (catégorie Vidéo), options à droite avec coche sur la valeur active.
struct SettingsSheet: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var library: VideoLibrary
    @Environment(\.dismiss) private var dismiss

    private enum Section: String, CaseIterable, Identifiable {
        case library = "Bibliothèque"
        case playback = "Lecture"
        case display = "Affichage"
        case ratio = "Ratio"
        case offset = "Décalage vertical"
        case scale = "Mise à l'échelle avancée"
        case speed = "Vitesse de lecture"
        var id: String { rawValue }
    }

    @State private var selection: Section = .display

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.35)
                detail
            }
        }
        .frame(width: 580, height: 460)
        .background(Color(red: 0.07, green: 0.07, blue: 0.085))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private var header: some View {
        ZStack {
            Text("Réglages")
                .font(.system(size: 15, weight: .bold))
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer les réglages")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vidéo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.bottom, 6)
            ForEach(Section.allCases) { section in
                sidebarRow(section)
            }
            Spacer()
        }
        .frame(width: 210, alignment: .leading)
        .padding(14)
    }

    private func sidebarRow(_ section: Section) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue)
                    .font(.system(size: 12, weight: selection == section ? .semibold : .regular))
                    .foregroundStyle(.white)
                Text(subtitle(for: section))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selection == section {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selection == section ? Color.white.opacity(0.09) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { selection = section }
    }

    private func subtitle(for section: Section) -> String {
        switch section {
        case .library: return "\(library.sources.count) source\(library.sources.count > 1 ? "s" : "")"
        case .playback: return engine.autoReplace ? "Activé" : "Désactivé"
        case .display: return settings.displayMode.rawValue
        case .ratio: return settings.ratioMode.rawValue
        case .offset: return settings.verticalOffset.rawValue
        case .scale: return settings.advancedScale.rawValue
        case .speed: return speedLabel(settings.playbackSpeed)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selection == .library {
                libraryDetail
            } else {
                Text(selection.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, 4)
                ForEach(options(for: selection), id: \.self) { option in
                    optionRow(option)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    /// Panneau Bibliothèque : dossiers sources (Mac, disque externe…) avec
    /// case à cocher, ajout, analyse et retrait.
    private var libraryDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 2)
            if library.sources.isEmpty {
                Text("Aucun dossier source. Ajoutez un dossier de votre Mac ou d'un disque externe : ses vidéos apparaîtront automatiquement dans la bibliothèque.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(library.sources) { source in
                HStack(spacing: 10) {
                    Button {
                        library.toggleSource(id: source.id)
                    } label: {
                        Image(systemName: source.enabled ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(source.enabled ? Color(nsColor: .controlAccentColor) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(source.enabled ? "Désactiver la source" : "Activer la source")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.url.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(source.url.path)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if !source.enabled {
                        Text("Inactive")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        library.removeSource(id: source.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer la source")
                    .help("Retirer ce dossier de la bibliothèque")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
            HStack(spacing: 10) {
                Button {
                    if let url = openFolderPanel() {
                        library.addSource(url: url)
                    }
                } label: {
                    Label("Ajouter un dossier…", systemImage: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                Button {
                    library.scanSources()
                } label: {
                    Label("Analyser", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Relancer l'analyse des dossiers sources")
            }
            .padding(.top, 4)
            Text("Les vidéos des sources sont synchronisées automatiquement. Leurs emplacements (A–E) se règlent depuis la grille de lecture.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func options(for section: Section) -> [String] {
        switch section {
        case .library: return []
        case .playback: return ["Activé", "Désactivé"]
        case .display: return AppSettings.DisplayMode.allCases.map(\.rawValue)
        case .ratio: return AppSettings.RatioMode.allCases.map(\.rawValue)
        case .offset: return AppSettings.VerticalOffset.allCases.map(\.rawValue)
        case .scale: return AppSettings.AdvancedScale.allCases.map(\.rawValue)
        case .speed: return [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map(speedLabel)
        }
    }

    private func optionRow(_ option: String) -> some View {
        let isSelected = isSelected(option)
        return HStack {
            Text(option)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.08 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { select(option) }
    }

    private func isSelected(_ option: String) -> Bool {
        switch selection {
        case .library: return false
        case .playback: return engine.autoReplace ? "Activé" == option : "Désactivé" == option
        case .display: return settings.displayMode.rawValue == option
        case .ratio: return settings.ratioMode.rawValue == option
        case .offset: return settings.verticalOffset.rawValue == option
        case .scale: return settings.advancedScale.rawValue == option
        case .speed: return speedLabel(settings.playbackSpeed) == option
        }
    }

    private func select(_ option: String) {
        switch selection {
        case .library:
            break
        case .playback:
            engine.autoReplace = (option == "Activé")
        case .display:
            if let mode = AppSettings.DisplayMode(rawValue: option) { settings.displayMode = mode }
        case .ratio:
            if let ratio = AppSettings.RatioMode(rawValue: option) { settings.ratioMode = ratio }
        case .offset:
            if let offset = AppSettings.VerticalOffset(rawValue: option) { settings.verticalOffset = offset }
        case .scale:
            if let scale = AppSettings.AdvancedScale(rawValue: option) { settings.advancedScale = scale }
        case .speed:
            if let value = speedValues.first(where: { speedLabel($0) == option }) {
                settings.playbackSpeed = value
                engine.setRate(Float(value))
            }
        }
    }

    private let speedValues: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private func speedLabel(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f×", value)
            : String(format: "%.2f×", value)
    }
}

// MARK: - Barre de transport

/// Barre de transport : lecture/pause, arrêt, resynchronisation, vitesse,
/// scrubber synchronisé sur le temps du maître et statut de lecture.
struct TransportBar: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine

    private static let rates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var rate: Float = 1.0
    @State private var playHover = false

    private var loadedCount: Int { library.slots.compactMap { $0 }.count }

    /// Lecture possible uniquement quand tous les emplacements remplis sont prêts.
    private var canPlay: Bool { loadedCount > 0 && engine.readyCount >= loadedCount }

    var body: some View {
        HStack(spacing: 12) {
            playButton
            BarIconButton(systemName: "stop.fill", help: "Arrêter") { engine.stop() }
            BarIconButton(systemName: "gobackward.10", help: "Reculer de 10 s") { engine.skip(by: -10) }
            BarIconButton(systemName: "goforward.10", help: "Avancer de 10 s") { engine.skip(by: 10) }
            BarIconButton(systemName: "arrow.triangle.2.circlepath", help: "Resynchroniser") { engine.resync() }
            BarIconButton(systemName: "shuffle", help: "Mélanger les files de lecture") { library.shuffleQueues() }
            ratePicker
            scrubber
            timeLabel
            Spacer(minLength: 8)
            statusLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        // Bandeau temporaire de reprise de lecture (6 s), au-dessus du transport.
        .overlay(alignment: .top) {
            resumeBanner
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            if engine.currentRate > 0 {
                rate = engine.currentRate
            }
        }
        .onChange(of: engine.leaderTime.seconds) { _, _ in syncScrub() }
        .onChange(of: rate) { _, newValue in engine.setRate(newValue) }
        // m1 : la vitesse peut changer par ⌥[/⌥] ou par les Réglages — le
        // picker doit suivre (sinon affichage « 1× » mensonger).
        .onChange(of: engine.currentRate) { _, newValue in
            if newValue != rate {
                rate = newValue
            }
        }
    }

    // MARK: Contrôles

    private var playButton: some View {
        Button {
            engine.togglePlay()
        } label: {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(accent))
                .scaleEffect(playHover ? 1.06 : 1.0)
                .shadow(color: accent.opacity(playHover ? 0.45 : 0.2), radius: playHover ? 10 : 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1.0 : 0.35)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(engine.isPlaying ? "Pause" : "Lecture")
        .help(engine.isPlaying ? "Pause" : "Lecture")
        .onHover { playHover = $0 }
    }

    private var ratePicker: some View {
        Picker("Vitesse", selection: $rate) {
            ForEach(Self.rates, id: \.self) { value in
                Text(rateLabel(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 74)
        .help("Vitesse de lecture")
    }

    private var scrubber: some View {
        Slider(value: $scrub, in: 0...1) { editing in
            if editing {
                isScrubbing = true
                engine.beginScrub()
            } else {
                isScrubbing = false
                engine.endScrub(atFraction: scrub)
            }
        }
        .frame(minWidth: 120, maxWidth: 260)
        .disabled(loadedCount == 0)
        .help("Position de lecture")
    }

    private var timeLabel: some View {
        // Quand un bloc est ciblé (timeline indépendante), le préfixe « B · »
        // indique quel slot est piloté par le scrubber.
        Text("\(independentPrefix)\(timeString(engine.timelineTime)) / \(timeString(engine.timelineDuration))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 120, alignment: .leading)
    }

    /// Préfixe du temps affiché : « B · » quand la timeline est indépendante
    /// sur le slot B, vide en mode synchronisé global.
    private var independentPrefix: String {
        guard let slot = engine.independentSlot, engine.timelineDuration.seconds > 0 else { return "" }
        return slotLetters[slot] + " · "
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 96, alignment: .trailing)
    }

    private var statusText: String {
        if engine.isPlaying { return "Lecture synchronisée" }
        if loadedCount > 0 && engine.readyCount < loadedCount {
            return "Chargement \(engine.readyCount)/\(loadedCount)…"
        }
        return "Prêt"
    }

    // MARK: Bandeau de reprise

    /// Bandeau temporaire proposant de reprendre la lecture à la position
    /// mémorisée (« Reprendre ») ou de repartir de zéro (« Recommencer »).
    /// Affiché 6 s par le moteur après le lancement d'une vidéo interrompue.
    @ViewBuilder
    private var resumeBanner: some View {
        if let offer = engine.resumeOffer {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                Text("Reprendre à \(offer.label)")
                    .font(.system(size: 12, weight: .semibold))
                Button {
                    engine.acceptResumeOffer()
                } label: {
                    Text("Reprendre")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                Button {
                    engine.declineResumeOffer()
                } label: {
                    Text("Recommencer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Aides

    /// Synchronise le scrubber local depuis le temps du maître, sauf pendant
    /// un glissement manuel (le flag isScrubbing évite les combats de valeur).
    private func syncScrub() {
        guard !isScrubbing else { return }
        let time = engine.timelineTime
        let duration = engine.timelineDuration.seconds
        guard time.isNumeric, duration.isFinite, duration > 0 else { return }
        scrub = min(max(time.seconds / duration, 0), 1)
    }

    private func rateLabel(_ value: Float) -> String {
        value == value.rounded()
            ? String(format: "%.0f×", value)
            : String(format: "%.2f×", value)
    }
}

// MARK: - État vide

/// Écran d'accueil : héros animé (pulsation douce) et bouton d'ouverture.
struct EmptyStateView: View {

    @State private var pulsing = false
    @State private var buttonHover = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.secondary)
                .opacity(pulsing ? 0.4 : 0.85)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulsing)
            Text("Jusqu'à 5 vidéos, parfaitement synchronisées")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 18)
            Text("Glissez vos fichiers vidéo dans la fenêtre ou cliquez sur Ouvrir…")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Button {
                let urls = openVideosPanel()
                if !urls.isEmpty { ingestVideos(urls) }
            } label: {
                Label("Choisir des vidéos…", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accent)
                    )
                    .scaleEffect(buttonHover ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            .help("Importer des vidéos")
            .padding(.top, 22)
            .onHover { buttonHover = $0 }
            Spacer()
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulsing = true }
    }
}

// MARK: - Sous-vues privées

/// Panneau d'un emplacement de la scène : vidéo (ou placeholder) + barre
/// d'infos avec contrôles par panneau (son, volume, retrait).
private struct StagePane: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var session: SessionState

    let slot: Int

    @State private var speakerHover = false
    @State private var clearHover = false
    @State private var paneZoom: CGFloat = 1
    /// Vue AppKit du bloc, retenue pour la capture PNG (⌘⇧S / menu contextuel).
    @State private var paneView: PlayerLayerView?
    /// Survol d'un glisser-déposer Finder au-dessus de ce bloc.
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let asset = library.slots[slot] {
                videoPane(asset: asset)
            } else {
                emptyPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(library.selectedSlot == slot ? accent : .clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: library.selectedSlot)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            library.select(slot: slot)
            // Clic sur un bloc = source audio + TIMELINE INDÉPENDANTE : ce
            // bloc devient la cible du scrubber et des raccourcis de navigation
            // (←/→, ±10 s) SANS toucher aux autres flux.
            // En mode maître (auto/manuel) : clic sur le MAÎTRE = retour au
            // mode global (audio par défaut + timeline synchronisée).
            // En mode AUCUN maître : aucun bloc privilégié — le clic rend
            // toujours le bloc indépendant.
            if engine.referenceMode != .none, engine.isReferenceSlot(slot) {
                engine.setAudioSlot(nil)
                engine.setIndependentSlot(nil)
            } else {
                engine.setAudioSlot(slot)
                engine.setIndependentSlot(slot)
            }
        }
        .overlay(
            // TIMELINE INDÉPENDANTE : bordure orange nette sur le bloc ciblé.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    engine.isIndependentSlot(slot) ? Color.orange.opacity(0.9) : .clear,
                    lineWidth: engine.isIndependentSlot(slot) ? 2.5 : 0
                )
        )
        .overlay(
            // Anneau de dépôt : retour visuel pendant un glisser-déposer Finder.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? accent.opacity(0.9) : .clear, lineWidth: 2.5)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers, into: slot)
            return true
        }
        .contextMenu {
            // Volume individuel du bloc (0–100 %).
            Slider(
                value: Binding(
                    get: { Double(engine.volume(forSlot: slot) * 100) },
                    set: { engine.setVolume(Float($0 / 100), forSlot: slot) }
                ),
                in: 0...100
            ) {
                Text("Volume")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("100")
            }
            .frame(width: 180)
            .padding(.horizontal, 10)
            .help("Volume du bloc")

            Divider()

            // MAÎTRE : désigne ce bloc comme référentiel (mode manuel).
            Button {
                engine.setManualMaster(slot)
            } label: {
                Label("Définir comme maître", systemImage: "crown.fill")
            }
            .help("Ce bloc pilote la timeline globale et l'audio par défaut")
            .disabled(engine.referenceMode == .manual && engine.manualReferenceSlot == slot)

            Button {
                engine.setReferenceMode(.auto)
            } label: {
                Label("Maître automatique (premier bloc)", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Le premier bloc actif redevient le maître")

            Divider()

            Button {
                engine.setAudioSlot(engine.isAudioSlot(slot) ? nil : slot)
            } label: {
                if engine.isAudioSlot(slot) {
                    Label("Rétablir l'audio automatique (maître)", systemImage: "speaker.slash")
                } else {
                    Label("Utiliser comme source audio", systemImage: "speaker.wave.2.fill")
                }
            }
            .help("Fait de ce bloc la source audio de la session")

            Button {
                capturePane()
            } label: {
                Label("Capture du bloc…", systemImage: "camera")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Enregistrer une capture PNG du bloc (⌘⇧S)")
        }
        // Raccourci global ⌘⇧S : capture ce bloc (bouton invisible, toujours
        // présent dans la hiérarchie pour enregistrer l'équivalent clavier).
        .background(
            Button { capturePane() } label: { EmptyView() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .transition(.opacity.combined(with: .scale(0.96)))
        // Raccourcis du layout LIBRE : ⌥← / ⌥→ ajustent la taille du bloc
        // sélectionné (le voisin prend le complément), ⌥0 réinitialise.
        .background(
            Button { nudgeSelectedWeight(-0.1) } label: { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .background(
            Button { nudgeSelectedWeight(0.1) } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .background(
            Button { settings.resetCustomWeights() } label: { EmptyView() }
                .keyboardShortcut("0", modifiers: [.option])
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    /// ⌥← / ⌥→ : ajuste la taille du bloc sélectionné dans le layout Libre
    /// (le bloc voisin prend le complément — répartition conservée).
    private func nudgeSelectedWeight(_ delta: Double) {
        guard settings.layoutPreset == .custom else { return }
        let selected = library.selectedSlot
        guard selected >= 0, library.slots.indices.contains(selected), library.slots[selected] != nil else { return }
        let active = library.slots.enumerated().compactMap { $0.element != nil ? $0.offset : nil }
        guard active.count >= 2, let idx = active.firstIndex(of: selected) else { return }
        let right = idx < active.count - 1 ? active[idx + 1] : active[idx - 1]
        settings.adjustWeight(delta, left: selected, right: right)
    }

    // MARK: Panneau vidéo

    private func videoPane(asset: VideoAsset) -> some View {
        ZStack(alignment: .bottom) {
            VideoPaneView(
                player: engine.player(forSlot: slot),
                displayMode: settings.displayMode.videoMode,
                videoSize: asset.size,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: session.immersiveMode,
                seekOnArrows: engine.isPlaying,
                onStateChange: { zoom in
                    paneZoom = zoom
                },
                onShortcut: { action in
                    switch action {
                    case .seek(let seconds): engine.skip(by: seconds)
                    case .rate(let factor): engine.nudgeRate(factor)
                    }
                },
                onViewCreated: { view in
                    if paneView !== view {
                        paneView = view
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dégradé léger en bas pour détacher la barre d'infos du contenu.
            // Simple dégradé (pas de flou) : aucun material au-dessus de la vidéo.
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            infoBar(asset: asset)
                .padding(10)
        }
    }

    /// Barre d'infos : titre, badges (maître, dérive, erreur), durée et
    /// contrôles du panneau. Material autorisé : c'est un overlay de panneau,
    /// pas une couche posée sur le flux vidéo.
    private func infoBar(asset: VideoAsset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(asset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Badge MAÎTRE : masqué en mode « Aucun maître ».
                    if engine.referenceMode != .none, isLeader {
                        leaderBadge
                    }
                    if engine.isIndependentSlot(slot) {
                        timelineBadge
                    }
                    if engine.isAudioSlot(slot) {
                        Text("🔊")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .help("Source audio de la session — clic sur un autre bloc pour changer")
                    }
                    if paneZoom != 1 {
                        Text(String(format: "×%.1f", paneZoom))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .help("Zoom du panneau — molette : zoom, glisser : déplacer, 0 : réinitialiser")
                    }
                    if let drift = engine.driftText[slot], !drift.isEmpty {
                        Text(drift)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 10) {
                    Text(timeString(asset.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let error = engine.slotError[slot], !error.isEmpty {
                        Text(error)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 8)
            speakerButton
            volumeSlider
            clearButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    /// Le slot référentiel est le maître de la session : badge « MAÎTRE ».
    private var isLeader: Bool {
        engine.isReferenceSlot(slot)
    }

    private var leaderBadge: some View {
        Text("MAÎTRE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(accent))
    }

    /// Badge « TIMELINE » : ce bloc est la cible indépendante du scrubber et
    /// des raccourcis de navigation (position découplée des autres flux).
    private var timelineBadge: some View {
        Text("TIMELINE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange))
    }

    private var speakerButton: some View {
        Button {
            mutedBinding.wrappedValue.toggle()
        } label: {
            Image(systemName: engine.isMuted(slot: slot) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(speakerHover ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(engine.isMuted(slot: slot) ? "Activer le son" : "Couper le son")
        .help(engine.isMuted(slot: slot) ? "Activer le son" : "Couper le son")
        .onHover { speakerHover = $0 }
    }

    private var volumeSlider: some View {
        Slider(value: volumeBinding, in: 0...1)
            .frame(width: 90)
            .controlSize(.small)
            .help("Volume")
    }

    private var clearButton: some View {
        Button {
            library.clear(slot: slot)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(clearHover ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Retirer du panneau")
        .help("Retirer du panneau")
        .onHover { clearHover = $0 }
    }

    /// Liaison de mise en sourdine vers le moteur (lecture + écriture).
    private var mutedBinding: Binding<Bool> {
        Binding(
            get: { engine.isMuted(slot: slot) },
            set: { engine.setMuted($0, forSlot: slot) }
        )
    }

    /// Liaison de volume vers le moteur (lecture + écriture).
    private var volumeBinding: Binding<Float> {
        Binding(
            get: { engine.volume(forSlot: slot) },
            set: { engine.setVolume($0, forSlot: slot) }
        )
    }

    // MARK: Capture du bloc

    /// Capture la vue du bloc en PNG sur le Bureau
    /// (~/Desktop/TriSync-Capture-AAAA-MM-JJ-HHMMSS.png) + bip de confirmation.
    /// Si l'écriture échoue (app sandboxée), bascule sur NSSavePanel.
    private func capturePane() {
        guard let view = paneView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "TriSync-Capture-\(formatter.string(from: Date())).png"

        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let url = desktop.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
                NSSound.beep()
                return
            } catch {
                // Bureau inaccessible (sandbox) : panneau de sauvegarde ci-dessous.
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
            NSSound.beep()
        }
    }

    // MARK: Emplacement vide

    /// Panneau d'attente : invite au glisser-déposer vers cet emplacement.
    private var emptyPane: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Glisser une vidéo ici")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Emplacement \(slotLetters[slot])")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            )
    }

    // MARK: Dépôt de fichiers (Finder)

    /// Extrait les URLs des providers du dépôt et les applique au slot.
    /// Chargement asynchrone des providers : la suite s'exécute sur le
    /// thread principal. StagePane étant une struct, on capture la référence
    /// à la bibliothèque (classe, durée de vie = application) plutôt que self.
    private func handleDrop(_ providers: [NSItemProvider], into targetSlot: Int) {
        let library = self.library
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                } else if let found = item as? URL {
                    url = found
                } else {
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    // Accès sandbox : requis pour les URLs venues du Finder
                    // quand l'app est sandboxée ; sans effet (false) sinon.
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    guard !VideoLibrary.videoFiles(from: [url]).isEmpty,
                          let asset = library.ensureInLibrary(url) else { return }
                    // Remplace le slot ; engine.reconfigure est appelé par
                    // VideoLibrary.assign (via syncEngine()).
                    library.assign(asset, to: targetSlot)
                }
            }
        }
    }
}

/// Bouton de barre avec libellé : fond discret et effet de survol.
private struct BarButton: View {

    let systemName: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Bouton icône de barre : fond discret et effet de survol.
private struct BarIconButton: View {

    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
        .onHover { hovering = $0 }
    }
}
