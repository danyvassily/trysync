// TriSync — Moteur, réglages & fenêtre
// Découpage en modules (v7.1) : même target SwiftPM, aucune visibilité modifiée.
// Sources : ContentView.swift (UI + App), VideoLibrary.swift, EngineAndSettings.swift.

import SwiftUI
import AppKit
import AVFoundation
import Combine

final class AppSettings: ObservableObject {

    enum DisplayMode: String, CaseIterable, Identifiable {
        case fit = "Plein"
        case crop = "Rogner"
        case stretch = "Remplir"
        var id: String { rawValue }
        var videoMode: VideoDisplayMode {
            switch self {
            case .fit: return .fit
            case .crop: return .crop
            case .stretch: return .stretch
            }
        }
    }

    enum RatioMode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case r43 = "4:3"
        case r169 = "16:9"
        case r11 = "1:1"
        var id: String { rawValue }
    }

    enum VerticalOffset: String, CaseIterable, Identifiable {
        case none = "Aucun"
        case top = "Haut"
        case center = "Centre"
        case bottom = "Bas"
        var id: String { rawValue }
        /// 0 = haut de la vidéo, 0,5 = centre, 1 = bas. « Aucun » = centré.
        var value: CGFloat {
            switch self {
            case .top: return 0
            case .none, .center: return 0.5
            case .bottom: return 1
            }
        }
    }

    enum AdvancedScale: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case p110 = "110 %"
        case p125 = "125 %"
        case p150 = "150 %"
        var id: String { rawValue }
        var value: CGFloat {
            switch self {
            case .auto: return 1.0
            case .p110: return 1.1
            case .p125: return 1.25
            case .p150: return 1.5
            }
        }
    }

    /// Presets de composition « bento » pour la scène multi-vidéos.
    enum LayoutPreset: String, CaseIterable, Identifiable {
        case custom = "Libre"
        case auto = "Auto"
        case sideBySide = "Côte à côte"
        case stacked = "Empilées"
        case masterH = "Maître + détail"
        case masterV = "Maître haut + détail"
        case threeColumns = "3 colonnes"
        case masterTwo = "Maître + 2"
        case threeRows = "3 rangées"
        case grid2x2 = "Grille 2×2"
        case fourColumns = "4 colonnes"
        case masterThree = "Maître + 3"
        case wall32 = "Mur 3+2"
        case wall23 = "Mur 2+3"
        case fiveColumns = "5 colonnes"
        case masterFour = "Maître + 4"
        var id: String { rawValue }
    }

    @Published var displayMode: DisplayMode { didSet { save() } }
    @Published var ratioMode: RatioMode { didSet { save() } }
    @Published var verticalOffset: VerticalOffset { didSet { save() } }
    @Published var advancedScale: AdvancedScale { didSet { save() } }
    @Published var playbackSpeed: Double { didSet { save() } }
    @Published var layoutPreset: LayoutPreset { didSet { save() } }

    private static let keys = (
        display: "settings.displayMode",
        ratio: "settings.ratioMode",
        offset: "settings.verticalOffset",
        scale: "settings.advancedScale",
        speed: "settings.playbackSpeed",
        layout: "settings.layoutPreset",
        customWeights: "settings.customWeights"
    )

    /// Clés du miroir iCloud (préfixe « cloud. » pour éviter tout collision
    /// avec les clés locales lors du fallback).
    private static let cloudKeys = (
        display: "cloud.displayMode",
        ratio: "cloud.ratioMode",
        offset: "cloud.verticalOffset",
        scale: "cloud.advancedScale",
        speed: "cloud.playbackSpeed",
        layout: "cloud.layoutPreset"
    )

    /// Store iCloud (NSUbiquitousKeyValueStore) : miroir des réglages entre
    /// Mac. Sans entitlement iCloud, tous les appels sont des no-op silencieux
    /// (le fallback UserDefaults continue de fonctionner normalement).
    private static let cloud = NSUbiquitousKeyValueStore.default

    init() {
        // iCloud sert de source secondaire : si ce Mac n'a AUCUNE valeur
        // locale (premier lancement), les réglages venus d'un autre Mac sont
        // adoptés. Sinon, les valeurs locales restent maîtres (pas de conflit).
        let d = UserDefaults.standard
        let fromCloud = Self.cloud.dictionaryRepresentation
        func localString(_ key: String, _ cloudKey: String) -> String? {
            if d.object(forKey: key) != nil { return d.string(forKey: key) }
            return fromCloud[cloudKey] as? String
        }
        func localDouble(_ key: String, _ cloudKey: String) -> Double? {
            if d.object(forKey: key) != nil { return d.object(forKey: key) as? Double }
            return fromCloud[cloudKey] as? Double
        }
        displayMode = DisplayMode(rawValue: localString(Self.keys.display, Self.cloudKeys.display) ?? "") ?? .crop
        ratioMode = RatioMode(rawValue: localString(Self.keys.ratio, Self.cloudKeys.ratio) ?? "") ?? .auto
        verticalOffset = VerticalOffset(rawValue: localString(Self.keys.offset, Self.cloudKeys.offset) ?? "") ?? .center
        advancedScale = AdvancedScale(rawValue: localString(Self.keys.scale, Self.cloudKeys.scale) ?? "") ?? .auto
        playbackSpeed = localDouble(Self.keys.speed, Self.cloudKeys.speed) ?? 1.0
        layoutPreset = LayoutPreset(rawValue: localString(Self.keys.layout, Self.cloudKeys.layout) ?? "") ?? .auto
        // Poids du layout libre (clés String pour UserDefaults : les
        // Dictionary [Int: Double] ne sont pas plistables directement).
        if let raw = d.dictionary(forKey: Self.keys.customWeights) as? [String: Double] {
            customWeights = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        // Écoute des changements venus d'un autre Mac (iCloud).
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: Self.cloud, queue: .main
        ) { [weak self] _ in
            self?.loadFromCloud()
        }
    }

    /// Applique les réglages reçus depuis iCloud (les didSet réécrivent le
    /// cache local : l'UI se met à jour et la valeur est conservée).
    private func loadFromCloud() {
        let fromCloud = Self.cloud.dictionaryRepresentation
        if let raw = fromCloud[Self.cloudKeys.display] as? String, let value = DisplayMode(rawValue: raw) {
            displayMode = value
        }
        if let raw = fromCloud[Self.cloudKeys.ratio] as? String, let value = RatioMode(rawValue: raw) {
            ratioMode = value
        }
        if let raw = fromCloud[Self.cloudKeys.offset] as? String, let value = VerticalOffset(rawValue: raw) {
            verticalOffset = value
        }
        if let raw = fromCloud[Self.cloudKeys.scale] as? String, let value = AdvancedScale(rawValue: raw) {
            advancedScale = value
        }
        if let value = fromCloud[Self.cloudKeys.speed] as? Double {
            playbackSpeed = value
        }
        if let raw = fromCloud[Self.cloudKeys.layout] as? String, let value = LayoutPreset(rawValue: raw) {
            layoutPreset = value
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(displayMode.rawValue, forKey: Self.keys.display)
        d.set(ratioMode.rawValue, forKey: Self.keys.ratio)
        d.set(verticalOffset.rawValue, forKey: Self.keys.offset)
        d.set(advancedScale.rawValue, forKey: Self.keys.scale)
        d.set(playbackSpeed, forKey: Self.keys.speed)
        d.set(layoutPreset.rawValue, forKey: Self.keys.layout)
        d.set(
            Dictionary(uniqueKeysWithValues: customWeights.map { (String($0.key), $0.value) }),
            forKey: Self.keys.customWeights
        )
        // Miroir iCloud : no-op silencieux sans entitlement (la version Xcode
        // finale activera iCloud → synchronisation multi-Mac).
        let cloud = Self.cloud
        cloud.set(displayMode.rawValue, forKey: Self.cloudKeys.display)
        cloud.set(ratioMode.rawValue, forKey: Self.cloudKeys.ratio)
        cloud.set(verticalOffset.rawValue, forKey: Self.cloudKeys.offset)
        cloud.set(advancedScale.rawValue, forKey: Self.cloudKeys.scale)
        cloud.set(playbackSpeed, forKey: Self.cloudKeys.speed)
        cloud.set(layoutPreset.rawValue, forKey: Self.cloudKeys.layout)
        cloud.synchronize()
    }

    /// Presets valides pour un nombre de vidéos donné (menu bento).
    /// « Libre » (redimensionnement manuel) est toujours proposé à partir
    /// de 2 vidéos.
    func validPresets(forCount count: Int) -> [LayoutPreset] {
        switch count {
        case 2: return [.custom, .auto, .sideBySide, .stacked, .masterH, .masterV]
        case 3: return [.custom, .auto, .threeColumns, .masterTwo, .threeRows]
        case 4: return [.custom, .auto, .grid2x2, .fourColumns, .masterThree]
        case 5: return [.custom, .auto, .wall32, .wall23, .fiveColumns, .masterFour]
        default: return [.auto]
        }
    }

    func isValidPreset(_ preset: LayoutPreset, forCount count: Int) -> Bool {
        validPresets(forCount: count).contains(preset)
    }

    // MARK: Layout LIBRE (redimensionnement manuel des blocs)

    /// Poids de taille par slot pour le preset « Libre » : la largeur de
    /// chaque bloc est proportionnelle à son poids (défaut 1.0). Modifié
    /// à la souris (poignées entre les blocs) ou au clavier (⌥← / ⌥→).
    @Published private var customWeights: [Int: Double] = [:]

    func weight(for slot: Int) -> Double {
        customWeights[slot] ?? 1.0
    }

    func setWeight(_ value: Double, for slot: Int) {
        let clamped = min(max(value, 0.1), 10.0)
        let old = customWeights[slot] ?? 1.0
        if abs(old - clamped) > 0.001 {
            customWeights[slot] = clamped
            save()
        }
    }

    func resetCustomWeights() {
        guard !customWeights.isEmpty else { return }
        customWeights.removeAll()
        save()
    }

    /// Ajuste la répartition entre deux blocs voisins (total conservé) :
    /// `delta` > 0 agrandit le bloc de gauche. Les deux poids restent
    /// dans [15 %, 85 %] de leur somme.
    func adjustWeight(_ delta: Double, left: Int, right: Int) {
        let wl = weight(for: left)
        let wr = weight(for: right)
        let total = wl + wr
        let newL = min(max(wl + delta * total, total * 0.15), total * 0.85)
        if abs(newL - wl) > 0.001 {
            customWeights[left] = newL
            customWeights[right] = total - newL
            save()
        }
    }

    /// Ratio d'affichage cible d'une vidéo : ratio forcé (Réglages) ou natif.
    func targetAspect(for asset: VideoAsset) -> CGFloat {
        switch ratioMode {
        case .auto:
            return (asset.size.width > 1 && asset.size.height > 1)
                ? asset.size.width / asset.size.height : 0.75
        case .r43: return 4.0 / 3.0
        case .r169: return 16.0 / 9.0
        case .r11: return 1.0
        }
    }
}

// MARK: - Panneau d'ouverture de fichiers

/// Ouvre le panneau de sélection et retourne les URLs choisies (ou [] si annulé).
/// Dans la sandbox, NSOpenPanel accorde l'accès aux fichiers sélectionnés pour
/// la durée de la session ; aucun bookmark n'est persisté.
@MainActor
func openVideosPanel() -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.prompt = "Ajouter"

    guard panel.runModal() == .OK else { return [] }

    // NB : pas de startAccessingSecurityScopedResource ici — l'accès sandbox
    // est déjà accordé par NSOpenPanel pour la session. Le start/stop équilibré
    // est fait dans loadMetadata(for:) uniquement (évite un leak d'extensions
    // pour les fichiers filtrés ou dédupliqués ensuite).
    return panel.urls
}

/// Panneau de sélection d'un dossier source (disque Mac ou externe).
/// Dans la sandbox, l'accès est accordé par NSOpenPanel puis persisté via
/// un security-scoped bookmark (VideoLibrary.addSource).
@MainActor
func openFolderPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.folder]
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.prompt = "Ajouter"
    panel.message = "Choisissez un dossier de vidéos (Mac, disque externe…)"
    guard panel.runModal() == .OK, let url = panel.urls.first else { return nil }
    return url
}

/// Reçoit les URLs (bouton Ouvrir… ou glisser-déposer), filtre les vidéos et
/// les transmet à la bibliothèque courante. Ne fait rien si l'application
/// n'est pas encore initialisée (sharedLibrary nil).
@MainActor
func ingestVideos(_ urls: [URL]) {
    guard let library = sharedLibrary else { return }
    library.ingest(VideoLibrary.videoFiles(from: urls))
}

// MARK: - Accès à la fenêtre hôte

/// Contrôleur de fenêtre : référence faible vers la NSWindow principale,
/// utilisée pour le plein écran et les réglages de fenêtre.
final class WindowController: ObservableObject {
    @Published var window: NSWindow?

    /// Mode multi-écran : déplace la fenêtre sur l'écran externe (si présent)
    /// et l'agrandit à sa zone visible. Retourne false si aucun second écran.
    /// Pratique pour envoyer la scène multi-vidéos sur un grand écran externe
    /// tout en gardant les contrôles sur le Mac.
    func moveToExternalScreen() -> Bool {
        guard let window, NSScreen.screens.count > 1 else { return false }
        let target = NSScreen.screens[1]
        window.setFrame(target.visibleFrame, display: true, animate: true)
        return true
    }

    /// Nom de l'écran externe (pour le libellé du bouton), nil si absent.
    var externalScreenName: String? {
        guard NSScreen.screens.count > 1 else { return nil }
        return NSScreen.screens[1].localizedName
    }
}

/// Vue utilitaire : expose la NSWindow hôte à la hiérarchie SwiftUI.
/// Permet à ContentView de rendre la fenêtre déplaçable par son fond
/// (window.isMovableByWindowBackground = true) malgré la barre de titre masquée.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}

// SyncEngine.swift
//
// TriSync — moteur de synchronisation de lecture multi-vidéos.
// Jusqu'à 3 vidéos locales lues simultanément, synchronisées à la trame près
// sur le Media Engine des puces Apple Silicon (M3).
//
// Stratégie de synchronisation :
// • Horloge maître commune : AVPlayer.masterClock = CMClockGetHostTimeClock(),
//   définie AVANT toute lecture (prérequis de setRate(_:time:atHostTime:)).
// • Départ simultané : setRate(_:time:atHostTime:) appelé sur CHAQUE player avec
//   la MÊME cible d'horloge hôte future (CACurrentMediaTime() + 0,25 s). Un simple
//   .play() laisse chaque player démarrer sur son propre runloop → 50 à 300 ms de
//   gigue entre les vidéos ; l'ancrage sur l'horloge hôte garantit un départ au tick.
// • Correction de dérive : moniteur périodique (1 s) qui ré-ancre les slots en
//   retard (|Δ| > 50 ms) via setRate(_:time:atHostTime:) — repositionnement sans
//   saut d'image et sans interruption des sessions de décodage matériel.

import AVFoundation
import Combine
import CoreMedia
import Foundation
import QuartzCore

// MARK: - État interne d'un slot

/// Regroupe toutes les ressources AV d'un slot de lecture.
/// La libération complète (player, item, asset) rend les sessions de décodage
/// matériel VideoToolbox du Media Engine au système.
private final class SlotState {
    let slot: Int
    let url: URL
    let asset: AVAsset
    let item: AVPlayerItem
    let player: AVPlayer

    var timeObserver: Any?
    var statusObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    var volume: Float = 1.0
    var muted = false
    /// Vrai dès que l'utilisateur a réglé le mute manuellement :
    /// son choix est alors préservé lors d'un changement de leader.
    var userAdjustedMute = false
    /// Vrai quand l'item a atteint la fin de sa lecture.
    var ended = false

    init(slot: Int, url: URL, asset: AVAsset, item: AVPlayerItem, player: AVPlayer) {
        self.slot = slot
        self.url = url
        self.asset = asset
        self.item = item
        self.player = player
    }
}

// MARK: - Moteur de synchronisation

/// Moteur de synchronisation de TriSync : jusqu'à 3 AVPlayer démarrés
/// simultanément sur la même cible d'horloge hôte (précision à la trame près).
final class SyncEngine: NSObject, ObservableObject {

    // MARK: État publié (consommé par SwiftUI)

    @Published private(set) var isPlaying = false
    @Published private(set) var currentRate: Float = 1.0
    @Published private(set) var leaderTime: CMTime = .zero
    @Published private(set) var leaderDuration: CMTime = .zero
    @Published private(set) var readyCount = 0
    @Published private(set) var driftText: [Int: String] = [:]
    @Published private(set) var slotError: [Int: String] = [:]
    /// Source audio de la session : nil = comportement par défaut (le slot
    /// référentiel est le seul audible). Choisi par clic sur un bloc.
    @Published private(set) var audioSlot: Int?

    /// Slot dont la TIMELINE est découplée du groupe : quand il est non-nil,
    /// le scrubber et les raccourcis de navigation (←/→, ⌘←/⌘→, ±10 s)
    /// agissent sur CE SEUL slot, sans toucher aux autres flux. Choisi par
    /// clic sur un bloc ; `nil` = mode synchronisé global (référentiel).
    /// Le slot référentiel ne peut JAMAIS être indépendant (il EST la base
    /// de la timeline globale).
    @Published private(set) var independentSlot: Int?

    // MARK: État interne

    private var slotStates: [Int: SlotState] = [:]
    private var driftTimer: Timer?

    // MARK: Reprise des positions de lecture

    /// Positions mémorisées par chemin de fichier, persistées dans
    /// UserDefaults sous « playback.positions » (sauvegarde différée 2 s).
    private var positions: [String: Double] = [:]
    private var positionSaveWork: DispatchWorkItem?
    private static let positionsKey = "playback.positions"

    /// Proposition de reprise affichée par la barre de transport (6 s).
    struct ResumeOffer: Equatable {
        let slot: Int
        let url: URL
        let position: Double
        var label: String { timeString(CMTime(seconds: position, preferredTimescale: 600)) }
    }
    @Published private(set) var resumeOffer: ResumeOffer?
    private var resumeDismissWork: DispatchWorkItem?
    private var wasPlayingBeforeScrub = false
    private var playRequestedWhileRewinding = false
    private var rewindPendingSlots: Set<Int> = []
    /// Compteur de génération des seeks : invalide les complétions obsolètes
    /// (scrub rapide, pause ou reconfiguration pendant un seek en vol).
    private var seekGeneration = 0

    /// Slot leader : index le plus bas parmi les slots configurés.
    private var leaderSlot: Int? {
        slotStates.keys.min()
    }

    private var leaderState: SlotState? {
        guard let slot = leaderSlot else { return nil }
        return slotStates[slot]
    }

    /// Mode de désignation du maître : AUTO (premier bloc actif, comportement
    /// historique), MANUEL (bloc choisi par l'utilisateur), AUCUN (aucun bloc
    /// privilégié — le clic rend n'importe quel bloc indépendant).
    enum ReferenceMode: String, CaseIterable {
        case auto = "Auto"
        case manual = "Manuel"
        case none = "Aucun"
    }

    /// Mode de maître courant (choix utilisateur, non persisté).
    @Published private(set) var referenceMode: ReferenceMode = .auto
    /// Bloc désigné maître en mode MANUEL (repli auto s'il devient inactif).
    @Published private(set) var manualReferenceSlot: Int?

    /// Slot référentiel pour le temps affiché, le scrubber et la dérive :
    /// le leader tant qu'il joue, sinon le premier slot non terminé
    /// (migration en fin de lecture partielle, cf. handleItemDidPlayToEnd).
    /// En mode MANUEL : le bloc choisi (s'il est actif), sinon repli auto.
    private var referenceSlot: Int? {
        if referenceMode == .manual, let manual = manualReferenceSlot,
           let state = slotStates[manual], !state.ended {
            return manual
        }
        if let leader = leaderSlot, let state = slotStates[leader], !state.ended {
            return leader
        }
        return slotStates.first(where: { !$0.value.ended })?.key
    }

    /// Change le mode de maître. `manual` sans slot choisi = repli auto.
    func setReferenceMode(_ mode: ReferenceMode) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        if referenceMode != mode {
            referenceMode = mode
        }
        if mode != .manual {
            if manualReferenceSlot != nil {
                manualReferenceSlot = nil
            }
        }
    }

    /// Désigne `slot` comme maître (passe en mode MANUEL). Le slot doit être
    /// actif. Annule l'indépendance du nouveau maître (il devient la base de
    /// la timeline globale).
    func setManualMaster(_ slot: Int?) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let slot, let state = slotStates[slot], !state.ended else { return }
        if referenceMode != .manual {
            referenceMode = .manual
        }
        if manualReferenceSlot != slot {
            manualReferenceSlot = slot
        }
        if independentSlot == slot {
            independentSlot = nil
        }
    }

    private var referenceState: SlotState? {
        guard let slot = referenceSlot else { return nil }
        return slotStates[slot]
    }

    /// Nombre de slots actuellement configurés.
    var totalSlotCount: Int {
        slotStates.count
    }

    private var isReadyToPlayAll: Bool {
        !slotStates.isEmpty && slotStates.values.allSatisfy { $0.item.status == .readyToPlay }
    }

    // MARK: Cycle de vie

    override init() {
        super.init()
        // Restaure les positions de lecture mémorisées (reprise).
        loadPositions()
    }

    deinit {
        // Nettoyage complet, même si le deinit survient hors du thread principal.
        stopDriftMonitor()
        // Feature 1 : libère les items préchargés (chargements annulés).
        for pending in pendingItems.values {
            pending.item.asset.cancelLoading()
        }
        pendingItems.removeAll()
        let states = Array(slotStates.values)
        if Thread.isMainThread {
            states.forEach { Self.teardown($0) }
        } else {
            DispatchQueue.main.async {
                // Aucune capture de self ici : le moteur est déjà en cours de libération.
                states.forEach { Self.teardown($0) }
            }
        }
    }

    // MARK: API publique

    /// Reconfigure les slots par diff : les players dont l'URL est inchangée
    /// sont conservés, les autres sont remplacés ou retirés.
    func reconfigure(slots newSlots: [Int: VideoAsset]) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        let oldLeader = leaderSlot
        let newLeader = newSlots.keys.min()
        // M3 : capturer l'ITEM du référentiel AVANT le diff — si le leader est
        // remplacé EN PLACE (autoReplace, même index), referenceSlot reste le
        // même index et la durée ne serait jamais rafraîchie sans cette garde.
        let oldReferenceItem = referenceState?.item

        // 1. Retrait des slots supprimés, dont l'URL change, ou dont l'item est en échec
        //    (ré-assigner le même fichier sur un slot .failed doit recréer le player).
        let removed = slotStates.keys.filter { slot in
            guard let asset = newSlots[slot] else { return true }
            guard let state = slotStates[slot] else { return true }
            return state.url != asset.url || state.item.status == .failed
        }
        if !removed.isEmpty {
            cancelPendingPlaybackStart()
            for slot in removed {
                teardownSlot(slot)
            }
        }

        // 2. Ajout des nouveaux slots.
        for (slot, asset) in newSlots where slotStates[slot] == nil {
            addSlot(slot, url: asset.url, isLeader: slot == newLeader)
        }

        // 3. Mute par défaut : seul le RÉFÉRENTIEL est audible, sauf réglage
        // utilisateur explicite. Le référentiel suit le maître (auto, manuel
        // ou repli) — pas simplement le premier bloc.
        let refSlot = referenceSlot
        for (slot, state) in slotStates where !state.userAdjustedMute {
            let shouldMute = (slot != refSlot)
            if state.muted != shouldMute {
                state.muted = shouldMute
                state.player.isMuted = shouldMute
            }
        }

        // 3 bis. Source audio choisie par l'utilisateur : on ré-applique le
        // routage (volume 1.0 / 0.0) pour intégrer les nouveaux slots.
        if audioSlot != nil {
            setAudioSlot(audioSlot)
        }

        // 4. Purge des états publiés orphelins + recompte.
        let validSlots = Set(slotStates.keys)
        if driftText.keys.contains(where: { !validSlots.contains($0) }) {
            driftText = driftText.filter { validSlots.contains($0.key) }
        }
        if slotError.keys.contains(where: { !validSlots.contains($0) }) {
            slotError = slotError.filter { validSlots.contains($0.key) }
        }
        if lastProgression.keys.contains(where: { !validSlots.contains($0) }) {
            lastProgression = lastProgression.filter { validSlots.contains($0.key) }
        }
        // Badges persistants (« Fichier illisible » sur slot vidé) :
        // ré-appliqués après la purge tant que le slot n'est pas réassigné.
        for (slot, message) in persistentSlotErrors where !validSlots.contains(slot) {
            if slotError[slot] != message {
                slotError[slot] = message
            }
        }
        updateReadyCount()

        // 5. Durée du référentiel : rechargée si l'INDEX du référentiel a
        // changé OU si son ITEM a été remplacé en place (M3).
        if referenceSlot != oldLeader || referenceState?.item !== oldReferenceItem {
            refreshReferenceDuration()
        }

        // 6. Reprise de la lecture si elle était en cours.
        if slotStates.isEmpty {
            resetPlaybackState()
        } else if isPlaying {
            if isReadyToPlayAll {
                startPlayback()
            }
            // Sinon : le moniteur de dérive intégrera chaque nouveau slot dès qu'il sera prêt.
        }
    }

    func player(forSlot slot: Int) -> AVPlayer? {
        slotStates[slot]?.player
    }

    /// Vrai si le slot est le référentiel courant (temps affiché, dérive, audio).
    func isReferenceSlot(_ slot: Int) -> Bool {
        referenceSlot == slot
    }

    /// Démarre la lecture synchronisée. Ne fait rien tant que tous les items
    /// ne sont pas prêts (bouton désactivé côté UI) ou si la lecture est déjà en cours.
    func play() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard !slotStates.isEmpty, !isPlaying, !playRequestedWhileRewinding,
              isReadyToPlayAll, currentRate > 0 else { return }

        // Rembobinage différé des slots terminés : le départ synchronisé n'intervient
        // qu'une fois tous les seeks revenus à zéro.
        let toRewind = slotStates.values.filter(\.ended).map(\.slot)
        guard !toRewind.isEmpty else {
            startPlayback()
            return
        }

        playRequestedWhileRewinding = true
        rewindPendingSlots = Set(toRewind)
        // M9 : watchdog — si une complétion de seek ne revient jamais (player
        // remplacé/détruit en vol), le bouton Lecture resterait mort pour la
        // session. On force la reprise après 2 s.
        let rewindWatchdog = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playRequestedWhileRewinding else { return }
                self.rewindPendingSlots.removeAll()
                self.playRequestedWhileRewinding = false
                self.startPlayback()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: rewindWatchdog)
        for slot in toRewind {
            guard let state = slotStates[slot] else { continue }
            state.ended = false
            state.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.playRequestedWhileRewinding else { return }
                    self.rewindPendingSlots.remove(slot)
                    if self.rewindPendingSlots.isEmpty {
                        self.playRequestedWhileRewinding = false
                        self.startPlayback()
                    }
                }
            }
        }
    }

    func pause() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        cancelPendingPlaybackStart()
        stopDriftMonitor()
        // Feature 5 : le watchdog s'arrête avec la lecture (progression oubliée).
        lastProgression.removeAll()
        // Reprise : mémorise la position de chaque slot encore en cours avant
        // la pause — persistée dans UserDefaults (sauvegarde différée 2 s).
        for state in slotStates.values where !state.ended {
            let time = state.player.currentTime()
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                savePosition(time.seconds, for: state.url)
            }
        }
        for state in slotStates.values {
            state.player.pause()
        }
        isPlaying = false
        // Le picker de vitesse ne peut pas produire 0, mais setRate(0) peut :
        // on restaure un taux sain pour que play() ne reste pas inerte.
        if currentRate == 0 { currentRate = 1.0 }
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Arrête la lecture et revient au début de la vidéo.
    func stop() {
        // « Arrêter » est une action GLOBALE : on sort d'abord du mode
        // timeline indépendante (sinon seekAll ne rembobinerait qu'un bloc).
        setIndependentSlot(nil)
        pause()
        seekAll(to: .zero)
        // Rembobiner = repartir de zéro la prochaine fois : on oublie les
        // positions mémorisées (sinon « Reprendre » serait proposé à
        // l'ancienne position malgré l'arrêt explicite).
        for state in slotStates.values {
            clearPosition(for: state.url)
        }
        driftText.removeAll()
    }

    /// Ré-aligne immédiatement tous les slots sur le référentiel (au-delà du seuil de dérive).
    func resync() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        // Resynchroniser = revenir au mode global : la timeline indépendante
        // est désactivée (tous les flux repartent alignés sur le référentiel).
        setIndependentSlot(nil)
        guard let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return }
        let target = reference.item.currentTime()
        for (slot, state) in slotStates where slot != reference.slot && !state.ended {
            // GARDE readyToPlay par slot : setRate(atHostTime:) sur un item
            // non prêt → exception Objective-C → SIGABRT (bloc en chargement).
            guard state.item.status == .readyToPlay else { continue }
            if isPlaying {
                state.player.setRate(
                    currentRate,
                    time: target,
                    atHostTime: CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                )
            } else {
                state.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            publishDrift((target - state.item.currentTime()).seconds, for: slot)
        }
        leaderTime = target
    }

    func setRate(_ rate: Float) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        currentRate = rate
        guard isPlaying else { return }
        if rate == 0 {
            // Taux nul = pause.
            pause()
            return
        }
        // Ré-ancrage de tous les players sur la même cible d'horloge hôte future.
        // GARDE readyToPlay : setRate(_:time:atHostTime:) sur un item non prêt
        // (remplacement auto en chargement, slot ajouté à chaud) lève une
        // exception Objective-C → SIGABRT. Les slots non prêts rejoindront via
        // handleStatusChange (.readyToPlay) → scheduleSlotStart.
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended && state.item.status == .readyToPlay {
            state.player.setRate(rate, time: state.player.currentTime(), atHostTime: host)
        }
    }

    /// Mémorise l'état de lecture puis met en pause (préparation du scrub).
    func beginScrub() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    /// Cherche la fraction demandée sur tous les slots, puis reprend si on jouait.
    func endScrub(atFraction fraction: Double) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        // Durée de la timeline : celle du slot indépendant si un bloc est
        // ciblé, sinon celle du leader (see timelineDuration).
        guard timelineDuration.isNumeric, timelineDuration.seconds.isFinite, timelineDuration.seconds > 0 else { return }
        let clamped = min(max(fraction, 0.0), 1.0)
        let target = CMTime(seconds: timelineDuration.seconds * clamped, preferredTimescale: 600)
        let resume = wasPlayingBeforeScrub
        wasPlayingBeforeScrub = false
        seekAll(to: target) { [weak self] in
            guard let self, resume else { return }
            self.play()
        }
    }

    func setVolume(_ volume: Float, forSlot slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let state = slotStates[slot] else { return }
        state.volume = min(max(volume, 0.0), 1.0)
        state.player.volume = state.volume
    }

    /// Remplacement automatique des vidéos terminées (lecture continue).
    /// Quand il est actif, un slot terminé est remplacé par une vidéo de la
    /// bibliothèque et relancé — le bloc ne reste jamais vide.
    var autoReplace = true

    /// Rappel émis quand un slot atteint la fin de sa lecture (main thread) :
    /// la bibliothèque choisit une vidéo de remplacement.
    var onItemEnded: ((Int) -> Void)?

    /// Rappel émis quand un slot passe en échec (statut .failed, feature 3) :
    /// la bibliothèque tente le contenu suivant de la file.
    var onSlotFailed: ((Int) -> Void)?

    /// Rappel émis quand le référentiel approche de sa fin (feature 1) : la
    /// bibliothèque prépare le prochain item pour un remplacement instantané.
    var onPreloadNeeded: ((Int) -> Void)?

    // MARK: Préchargement du remplacement (feature 1)

    /// Item AVPlayerItem préchargé par slot, prêt à être réutilisé par
    /// reconfigure à la fin de lecture (transition sans écran noir).
    struct PendingPreload {
        let url: URL
        let item: AVPlayerItem
    }

    /// Items préchargés par slot (feature 1) : produits par la bibliothèque
    /// (prepareNext) puis consommés par addSlot. Thread principal uniquement.
    private(set) var pendingItems: [Int: PendingPreload] = [:]

    /// Slots dont la demande de préchargement a déjà été émise : évite de
    /// re-déclencher la demande toutes les 0,1 s pendant la même lecture.
    private var preloadRequested: Set<Int> = []

    // MARK: Échecs (feature 3)

    /// Tâches de remplacement différé après échec, par slot.
    private var failedReplacementTasks: [Int: Task<Void, Never>] = [:]
    /// Slots dont le remplacement d'échec est déjà programmé (le KVO .failed
    /// peut être émis plusieurs fois pour le même item).
    private var failedReplacementPending: Set<Int> = []

    // MARK: Watchdog anti-blocage (feature 5)

    /// Dernier temps observé par slot (watchdog de blocage), avec sa date.
    private var lastProgression: [Int: (time: CMTime, date: Date)] = [:]

    /// Erreurs persistantes par slot (badge « Fichier illisible » sur un slot
    /// vidé) : ré-appliquées après chaque purge de reconfigure.
    private var persistentSlotErrors: [Int: String] = [:]

    /// Slots dont le remplacement attend que leur item soit .readyToPlay
    /// avant de démarrer (setRate(_:time:atHostTime:) exige un item prêt —
    /// sinon exception Objective-C, cf. crash 2026-08-11).
    private var startFromZeroOnReady: Set<Int> = []

    /// Démarre (ou redémarre) le contenu d'un slot à zéro, synchronisé avec
    /// les autres flux si la lecture est en cours. Utilisé par le remplacement
    /// automatique après reconfiguration du slot.
    ///
    /// SÉCURITÉ : si le nouvel item n'est pas encore .readyToPlay, le démarrage
    /// est différé — il sera exécuté par handleStatusChange dès que l'item
    /// sera prêt (setRate avec atHostTime sur un item non prêt = exception).
    func joinNewSlot(_ slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let state = slotStates[slot] else { return }
        state.ended = false
        if state.item.status == .readyToPlay {
            scheduleSlotStart(slot)
        } else {
            startFromZeroOnReady.insert(slot)
        }
    }

    /// Programme le démarrage à zéro d'un slot (item garantie prête).
    private func scheduleSlotStart(_ slot: Int) {
        guard let state = slotStates[slot], !state.ended, isPlaying else { return }
        guard state.item.status == .readyToPlay else {
            // Statut re-devenu transitoire : on rediffère au prochain .readyToPlay.
            startFromZeroOnReady.insert(slot)
            return
        }
        state.item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        state.player.setRate(currentRate, time: .zero, atHostTime: host)
    }

    /// Avance / recule TOUS les flux d'une durée donnée (façon Infuse),
    /// en restant synchronisés sur le temps du référentiel.
    func skip(by seconds: Double) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        // TIMELINE INDÉPENDANTE : si un bloc est ciblé, le saut ne concerne
        // QUE ce bloc (position avancée sans toucher aux autres flux).
        if let slot = independentSlot, let state = slotStates[slot], !state.ended {
            let current = state.item.currentTime()
            let duration = state.item.duration.isNumeric ? state.item.duration.seconds : 0
            var target = current.seconds + seconds
            if duration > 0, duration.isFinite { target = min(max(target, 0), duration) }
            seekSlot(slot, to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
            return
        }
        guard let reference = referenceState, reference.item.status == .readyToPlay else { return }
        let current = reference.item.currentTime()
        let duration = leaderDuration.isNumeric && leaderDuration.seconds.isFinite ? leaderDuration.seconds : 0
        var target = current.seconds + seconds
        if duration > 0 { target = min(max(target, 0), duration) }
        seekAll(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
    }

    /// Modifie la vitesse de lecture par un facteur (borné 0,25×–2×).
    func nudgeRate(_ factor: Float) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        setRate(min(max(currentRate * factor, 0.25), 2.0))
    }

    func setMuted(_ muted: Bool, forSlot slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let state = slotStates[slot] else { return }
        state.userAdjustedMute = true
        state.muted = muted
        state.player.isMuted = muted
    }

    func isMuted(slot: Int) -> Bool {
        slotStates[slot]?.muted ?? false
    }

    func volume(forSlot slot: Int) -> Float {
        slotStates[slot]?.volume ?? 1.0
    }

    // MARK: Source audio (clic sur un bloc)

    /// Vrai si le slot est la source audio courante : le slot choisi par
    /// l'utilisateur ou, par défaut, le slot référentiel.
    func isAudioSlot(_ slot: Int) -> Bool {
        (audioSlot ?? referenceSlot) == slot
    }

    /// Fait de `slot` la source audio de la session : volume 1.0 sur ce bloc,
    /// volume 0.0 sur les autres, en passant par player.volume (PAS isMuted)
    /// pour ne pas perturber la synchro audio des autres flux.
    /// `nil` (clic sur le bloc maître) revient au comportement par défaut :
    /// seul le slot référentiel est audible.
    func setAudioSlot(_ slot: Int?) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        // M2 (blindage) : un slot inexistant ne doit JAMAIS devenir la cible —
        // sinon toutes les volumes passeraient à 0 (silence total).
        let target: Int?
        if let slot, slotStates[slot] != nil {
            target = slot
        } else {
            target = referenceSlot
        }
        for (index, state) in slotStates {
            let isAudio = (index == target)
            if isAudio {
                // Le slot choisi doit être audible même s'il n'est pas le
                // leader (le moteur mute les non-leaders par défaut).
                state.muted = false
                state.player.isMuted = false
            }
            let desired: Float = isAudio ? 1.0 : 0.0
            if state.volume != desired {
                state.volume = desired
                state.player.volume = desired
            }
        }
        if audioSlot != slot {
            audioSlot = slot
        }
    }

    // MARK: Reprise des positions de lecture

    /// Restaure les positions mémorisées depuis UserDefaults.
    private func loadPositions() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        positions = stored
    }

    /// Position de lecture mémorisée pour une URL (0 si aucune).
    /// M4 : clé STANDARDISÉE — la bibliothèque lit playbackPosition(for:)
    /// avec standardizedFileURL.path ; sans normalisation, une vidéo dont le
    /// chemin stocké n'est pas canonique (/var vs /private/var) n'apparaît
    /// jamais dans le dossier intelligent « Reprendre ».
    func position(for url: URL) -> Double {
        positions[url.standardizedFileURL.path] ?? 0
    }

    /// Mémorise la position d'une vidéo (sauvegarde différée de 2 s).
    func savePosition(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds > 0 else { return }
        positions[url.standardizedFileURL.path] = seconds
        schedulePositionsSave()
    }

    /// Efface la position mémorisée d'une vidéo (fin de lecture réelle,
    /// « Recommencer »).
    func clearPosition(for url: URL) {
        guard positions.removeValue(forKey: url.standardizedFileURL.path) != nil else { return }
        persistPositionsNow()
    }

    private func schedulePositionsSave() {
        positionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistPositionsNow() }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Écrit immédiatement les positions dans UserDefaults (thread principal).
    func persistPositionsNow() {
        positionSaveWork?.cancel()
        positionSaveWork = nil
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    /// Propose la reprise d'une vidéo au lancement (position > 15 s) : la
    /// lecture démarre à zéro et un bandeau temporaire (6 s) propose
    /// « Reprendre » ou « Recommencer ».
    func offerResumeIfNeeded(slot: Int, url: URL) {
        let position = positions[url.standardizedFileURL.path] ?? 0
        guard position > 15 else { return }
        let offer = ResumeOffer(slot: slot, url: url, position: position)
        if resumeOffer != offer {
            resumeOffer = offer
        }
        resumeDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissResumeOffer() }
        resumeDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    /// « Reprendre » : aligne tous les flux sur la position proposée.
    func acceptResumeOffer() {
        guard let offer = resumeOffer else { return }
        // La reprise est une action GLOBALE : on sort du mode indépendant.
        setIndependentSlot(nil)
        seekAll(to: CMTime(seconds: offer.position, preferredTimescale: 600))
        dismissResumeOffer()
    }

    /// « Recommencer » : retour à zéro et oubli de la position mémorisée.
    func declineResumeOffer() {
        guard let offer = resumeOffer else { return }
        // Action globale : sort du mode indépendant avant de tout rembobiner.
        setIndependentSlot(nil)
        clearPosition(for: offer.url)
        seekAll(to: .zero)
        dismissResumeOffer()
    }

    private func dismissResumeOffer() {
        resumeDismissWork?.cancel()
        resumeDismissWork = nil
        if resumeOffer != nil {
            resumeOffer = nil
        }
    }

    // MARK: Accès référentiel (mini-lecteur flottant)

    /// Indice du slot référentiel courant (temps affiché, audio par défaut).
    var currentReferenceSlot: Int? { referenceSlot }

    /// Player du slot référentiel (réutilisé par le mini-lecteur flottant).
    func referencePlayer() -> AVPlayer? {
        guard let slot = referenceSlot else { return nil }
        return slotStates[slot]?.player
    }

    /// Dérive maximale (ms) entre le référentiel et les autres slots actifs
    /// (badge Δ du mini-lecteur). Nil si rien d'actif ou pas de dérive.
    var maxDriftMilliseconds: Int? {
        guard let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return nil }
        let refTime = reference.item.currentTime()
        var maxMs: Int?
        // M7 : le slot INDÉPENDANT est exclu du calcul — son écart est
        // volontaire (badge Δ trompeur sinon).
        for state in slotStates.values where state.slot != reference.slot
            && state.slot != independentSlot && !state.ended {
            guard state.item.status == .readyToPlay else { continue }
            let delta = abs((refTime - state.item.currentTime()).seconds)
            guard delta.isFinite else { continue }
            let ms = Int((delta * 1000).rounded())
            if let current = maxMs {
                if ms > current { maxMs = ms }
            } else {
                maxMs = ms
            }
        }
        return maxMs
    }

    /// Retire tous les slots et réinitialise complètement l'état publié.
    func clear() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        wasPlayingBeforeScrub = false
        for slot in Array(slotStates.keys) {
            teardownSlot(slot)
        }
        resetPlaybackState()
    }

    // MARK: Préchargement du remplacement (feature 1)

    /// Confie un item préchargé au moteur pour le slot donné. Remplace un
    /// éventuel item en attente (annulation propre de l'ancien).
    func storePendingItem(_ item: AVPlayerItem, for url: URL, slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        cancelPendingItem(for: slot)
        pendingItems[slot] = PendingPreload(url: url, item: item)
    }

    /// Récupère l'item préchargé d'un slot si son URL correspond encore à la
    /// configuration demandée (le slot a pu changer entre-temps).
    func consumePendingItem(for slot: Int, url: URL) -> AVPlayerItem? {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let pending = pendingItems.removeValue(forKey: slot), pending.url == url else {
            return nil
        }
        preloadRequested.remove(slot)
        return pending.item
    }

    /// Annule le préchargement d'un slot : l'item en attente est libéré et
    /// son chargement stoppé. L'item en attente n'est jamais attaché à un
    /// player ; s'il l'avait été (cas limite), teardownSlot le détache avec
    /// replaceCurrentItem(nil).
    func cancelPendingItem(for slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let pending = pendingItems.removeValue(forKey: slot) else { return }
        pending.item.asset.cancelLoading()
        preloadRequested.remove(slot)
    }

    /// PRÉCHARGEMENT ANTICIPÉ (feature 1) : à moins de 10 s de la fin du
    /// référentiel, demande à la bibliothèque de préparer le prochain
    /// candidat. Appelé depuis l'observateur périodique du référentiel
    /// (toutes les 0,1 s), une seule fois par lecture (garde preloadRequested).
    private func maybePreloadReplacement(for slot: Int, time: CMTime) {
        guard autoReplace, !preloadRequested.contains(slot), pendingItems[slot] == nil,
              let state = slotStates[slot], !state.ended,
              state.item.status == .readyToPlay else { return }
        let duration: Double
        if state.item.duration.isNumeric, state.item.duration.seconds.isFinite,
           state.item.duration.seconds > 0 {
            duration = state.item.duration.seconds
        } else if leaderDuration.isNumeric, leaderDuration.seconds.isFinite,
                  leaderDuration.seconds > 0 {
            duration = leaderDuration.seconds
        } else {
            return
        }
        let remaining = duration - time.seconds
        guard remaining.isFinite, remaining >= 0, remaining < 10 else { return }
        preloadRequested.insert(slot)
        onPreloadNeeded?(slot)
    }

    // MARK: Échec de lecture (feature 3)

    /// Programme le remplacement d'un slot en échec dans ~0,5 s (différé :
    /// laisse le système stabiliser l'échec avant de tenter la file).
    private func scheduleFailedReplacement(for slot: Int) {
        guard !failedReplacementPending.contains(slot) else { return }
        failedReplacementPending.insert(slot)
        failedReplacementTasks[slot]?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.failedReplacementPending.remove(slot)
            self.failedReplacementTasks[slot] = nil
            // Re-vérification : le slot doit exister et être toujours en échec.
            guard let state = self.slotStates[slot], state.item.status == .failed else { return }
            self.onSlotFailed?(slot)
        }
        failedReplacementTasks[slot] = task
    }

    /// Affecte une erreur persistante à un slot (badge « Fichier illisible »
    /// sur un slot vidé) : survit aux purges de reconfigure.
    func setSlotError(_ message: String, for slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        persistentSlotErrors[slot] = message
        if slotError[slot] != message {
            slotError[slot] = message
        }
    }

    // MARK: Watchdog anti-blocage (feature 5)

    /// Surveille la progression de chaque slot non référentiel pendant la
    /// lecture : un slot dont le temps n'avance pas depuis 3 s (sans être
    /// terminé ni en pause) est relancé (seek position actuelle + setRate
    /// ancré sur l'horloge hôte). Cadence : le timer du moniteur de dérive
    /// (1 s) ; s'arrête avec lui à la pause.
    private func checkFrozenSlots(now: Date = Date()) {
        guard isPlaying else { return }
        for (slot, state) in slotStates where slot != referenceSlot && slot != independentSlot {
            guard !state.ended, state.item.status == .readyToPlay,
                  state.player.rate != 0 else { continue }
            let current = state.item.currentTime()
            guard current.isNumeric else { continue }
            if let last = lastProgression[slot] {
                if current.seconds != last.time.seconds {
                    lastProgression[slot] = (current, now)
                } else if now.timeIntervalSince(last.date) >= 3.0 {
                    // Blocage confirmé : relance du slot sur sa position.
                    restartFrozenSlot(slot, state: state, at: current)
                    // Remet le compteur à zéro : pas de relance en rafale.
                    lastProgression[slot] = (current, now)
                }
            } else {
                lastProgression[slot] = (current, now)
            }
        }
    }

    /// Relance un slot figé : seek sur sa position actuelle puis setRate
    /// ancré sur l'horloge hôte (même mécanique que le moniteur de dérive).
    private func restartFrozenSlot(_ slot: Int, state: SlotState, at time: CMTime) {
        state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying,
                      self.slotStates[slot]?.item === state.item,
                      !state.ended, state.item.status == .readyToPlay else { return }
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(self.currentRate, time: state.item.currentTime(), atHostTime: host)
            }
        }
    }

    // MARK: Cycle de vie des slots

    private func addSlot(_ slot: Int, url: URL, isLeader: Bool) {
        // Feature 1 : réutilise l'item préchargé (remplacement anticipé) si
        // son URL correspond — transition instantanée, sans écran noir.
        let item: AVPlayerItem
        let asset: AVURLAsset
        if let preloaded = consumePendingItem(for: slot, url: url) {
            item = preloaded
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url)
            item = AVPlayerItem(asset: asset)
            // Tampon court : fichiers locaux, démarrage rapide sans attendre le remplissage.
            item.preferredForwardBufferDuration = 2.0
        }
        preloadRequested.remove(slot)
        // Le slot est réassigné : le badge d'erreur persistant n'a plus lieu d'être.
        persistentSlotErrors.removeValue(forKey: slot)

        let player = AVPlayer(playerItem: item)
        // Pas d'attente anti-stall : sources locales, on privilégie la réactivité.
        player.automaticallyWaitsToMinimizeStalling = false
        // Horloge maître = horloge hôte. À définir AVANT toute lecture : c'est elle qui
        // permet à setRate(_:time:atHostTime:) d'aligner tous les players sur le même timebase.
        player.masterClock = CMClockGetHostTimeClock()

        // Pré-chauffage : initialise le pipeline de décodage (sessions VideoToolbox
        // du M3) sans démarrer la lecture — élimine le hoquet de la première image.
        player.playImmediately(atRate: 0)

        let state = SlotState(slot: slot, url: url, asset: asset, item: item, player: player)
        state.muted = !isLeader
        state.volume = 1.0
        player.isMuted = state.muted
        player.volume = 1.0

        // Observation KVO du statut (prêt / échec), publiée sur le thread principal.
        state.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleStatusChange(slot: slot)
            }
        }

        // Observateur périodique : seul le slot référentiel publie leaderTime.
        // Garde de changement : AVPlayer appelle ce callback même en pause
        // (0,1 s) avec la MÊME valeur — publier sans garde provoquerait un
        // re-render complet de l'UI 10×/s (100 % CPU au repos, mesuré au
        // profileur le 11/08/2026).
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        state.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.referenceSlot == slot else { return }
            if time != self.leaderTime {
                self.leaderTime = time
            }
            // PRÉCHARGEMENT ANTICIPÉ DU REMPLACEMENT (feature 1) : à moins de
            // 10 s de la fin du référentiel, la bibliothèque prépare le
            // prochain item — le remplacement devient instantané.
            self.maybePreloadReplacement(for: slot, time: time)
        }

        // Fin de lecture : notification par item, reçue sur le thread principal.
        state.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self, let endedItem = note.object as? AVPlayerItem else { return }
            self.handleItemDidPlayToEnd(item: endedItem)
        }

        slotStates[slot] = state
        updateReadyCount()
    }

    private func teardownSlot(_ slot: Int) {
        guard let state = slotStates.removeValue(forKey: slot) else { return }
        // TIMELINE INDÉPENDANTE / AUDIO : un slot retiré ne peut plus être
        // cible — sinon le mode se réactiverait silencieusement si l'index est
        // réutilisé plus tard, et setAudioSlot(stale) mettrait TOUT à volume 0.
        if independentSlot == slot {
            independentSlot = nil
        }
        if audioSlot == slot {
            audioSlot = nil
        }
        // Feature 1 : annulation propre du préchargement éventuel du slot.
        cancelPendingItem(for: slot)
        preloadRequested.remove(slot)
        // Feature 3 : annule un remplacement d'échec encore en attente.
        failedReplacementTasks[slot]?.cancel()
        failedReplacementTasks.removeValue(forKey: slot)
        failedReplacementPending.remove(slot)
        // Feature 5 : oublie la progression du slot retiré.
        lastProgression.removeValue(forKey: slot)
        // M9 : annule aussi un éventuel rembobinage en cours pour ce slot
        // (sinon sa complétion relancerait un player détruit).
        cancelPendingPlaybackStart()
        Self.teardown(state)
    }

    /// Libère intégralement les ressources d'un slot : observations invalidées,
    /// observateurs retirés, item détaché, puis références relâchées (les sessions
    /// de décodage VideoToolbox sont alors rendues au système).
    private static func teardown(_ state: SlotState) {
        state.statusObservation?.invalidate()
        state.statusObservation = nil

        if let observer = state.endObserver {
            NotificationCenter.default.removeObserver(observer)
            state.endObserver = nil
        }

        if let token = state.timeObserver {
            state.player.removeTimeObserver(token)
            state.timeObserver = nil
        }

        state.player.pause()
        // Détache l'item : AVPlayer, AVPlayerItem et AVAsset sont libérés quand
        // SlotState disparaît → sessions de décodage matériel libérées.
        state.player.replaceCurrentItem(with: nil)
    }

    // MARK: Lecture synchronisée

    /// Démarre tous les players sur la MÊME cible d'horloge hôte future :
    /// c'est le cœur de la synchronisation à la trame près.
    /// GARDE readyToPlay par slot (défense en profondeur) : un slot remplacé
    /// entre la vérification du call-site et cette boucle (rewind asynchrone)
    /// ne doit JAMAIS recevoir setRate(atHostTime:) non prêt → SIGABRT.
    private func startPlayback() {
        guard !slotStates.isEmpty else { return }
        startDriftMonitor()
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended && state.item.status == .readyToPlay {
            state.player.setRate(currentRate, time: state.player.currentTime(), atHostTime: host)
        }
        isPlaying = true
    }

    /// Cherche la même position sur tous les players (tolérance zéro = image exacte)
    /// et met à jour leaderTime immédiatement.
    private func seekAll(to time: CMTime, completion: (() -> Void)? = nil) {
        // TIMELINE INDÉPENDANTE : le scrubber ne pilote que le bloc ciblé.
        if let slot = independentSlot, slotStates[slot] != nil {
            leaderTime = time
            seekSlot(slot, to: time)
            completion?()
            return
        }
        leaderTime = time
        seekGeneration += 1
        let generation = seekGeneration
        let slots = Array(slotStates.keys)
        guard !slots.isEmpty else {
            completion?()
            return
        }
        // Compteur partagé par les complétions, toutes rapatriées sur le thread principal.
        var remaining = slots.count
        // Watchdog : si un player est détruit en vol (slot retiré pendant un seek),
        // AVPlayer n'appelle jamais la complétion — on ne laisse pas l'app en pause.
        let watchdog = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.seekGeneration == generation, remaining > 0 else { return }
                remaining = 0
                completion?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
        for slot in slots {
            guard let state = slotStates[slot] else {
                remaining -= 1
                continue
            }
            state.ended = false
            state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.seekGeneration == generation else { return }
                    remaining -= 1
                    if remaining == 0 {
                        completion?()
                    }
                }
            }
        }
    }

    /// Seek d'UN SEUL slot (timeline indépendante) : sans compteur global,
    /// sans toucher aux autres flux. Le rate en cours est conservé.
    private func seekSlot(_ slot: Int, to time: CMTime) {
        guard let state = slotStates[slot] else { return }
        state.ended = false
        state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.slotStates[slot]?.item === state.item else { return }
                // M6 : publie la position cible pour l'UI (scrubber + label) —
                // sinon, en pause, l'affichage resterait à l'ancienne position
                // indéfiniment (le time observer publie la même valeur, garde ≠).
                if self.leaderTime != time {
                    self.leaderTime = time
                }
                // Re-ancrage sur l'horloge hôte si la lecture continue, pour
                // que le flux reparte proprement depuis la nouvelle position.
                if self.isPlaying, state.item.status == .readyToPlay, !state.ended {
                    let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                    state.player.setRate(self.currentRate, time: state.item.currentTime(), atHostTime: host)
                }
            }
        }
    }

    /// Fait de `slot` la cible de timeline indépendante : le scrubber et les
    /// raccourcis de navigation n'agissent plus que sur ce bloc (les autres
    /// flux continuent sans être modifiés). `nil` (clic sur le bloc maître)
    /// revient au mode synchronisé global.
    /// Le slot référentiel est refusé SAUF en mode AUCUN maître (aucun bloc
    /// privilégié → n'importe quel bloc peut être découplé).
    func setIndependentSlot(_ slot: Int?) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        if let slot, slotStates[slot] == nil || (slot == referenceSlot && referenceMode != .none) {
            independentSlot = nil
            return
        }
        if independentSlot != slot {
            independentSlot = slot
        }
    }

    /// Vrai si ce slot est la cible de timeline indépendante courante.
    func isIndependentSlot(_ slot: Int) -> Bool {
        independentSlot == slot
    }

    /// Temps affiché par la barre de transport : celui du slot indépendant
    /// quand il est actif, sinon celui du référentiel.
    var timelineTime: CMTime {
        if let slot = independentSlot, let state = slotStates[slot], !state.ended {
            return state.item.currentTime()
        }
        return leaderTime
    }

    /// Durée affichée par la barre de transport : celle du slot indépendant
    /// quand il est actif, sinon celle du référentiel.
    var timelineDuration: CMTime {
        if let slot = independentSlot, let state = slotStates[slot], !state.ended {
            let duration = state.item.duration
            return duration.isNumeric ? duration : leaderDuration
        }
        return leaderDuration
    }

    private func cancelPendingPlaybackStart() {
        playRequestedWhileRewinding = false
        rewindPendingSlots.removeAll()
        seekGeneration += 1
    }

    private func resetPlaybackState() {
        cancelPendingPlaybackStart()
        wasPlayingBeforeScrub = false
        isPlaying = false
        leaderTime = .zero
        leaderDuration = .zero
        driftText.removeAll()
        slotError.removeAll()
        persistentSlotErrors.removeAll()
        lastProgression.removeAll()
        // M1 : un clear() vide aussi les cibles utilisateur — sinon le mode
        // indépendant/audio se réactiverait si l'index est réutilisé.
        independentSlot = nil
        audioSlot = nil
        updateReadyCount()
    }

    // MARK: Moniteur de dérive

    private func startDriftMonitor() {
        stopDriftMonitor()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkDrift()
            // Feature 5 : watchdog anti-blocage, même cadence (1 s), arrêté
            // avec le moniteur de dérive à la pause.
            self?.checkFrozenSlots()
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }

    private func stopDriftMonitor() {
        driftTimer?.invalidate()
        driftTimer = nil
    }

    private func checkDrift() {
        guard isPlaying, let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return }
        let referenceCurrent = reference.item.currentTime()
        for (slot, state) in slotStates where slot != reference.slot && slot != independentSlot {
            // On ignore les slots terminés, en échec ou pas encore prêts : rien à réaligner.
            // Le slot INDÉPENDANT est aussi ignoré : sa position est volontairement
            // découplée — le corriger reviendrait à annuler le mode indépendant.
            guard !state.ended, state.item.status == .readyToPlay else { continue }
            let otherCurrent = state.item.currentTime()
            let delta = referenceCurrent - otherCurrent
            guard delta.seconds.isFinite else { continue }
            if abs(delta.seconds) > 0.05 {
                // ANTI-BOUCLE (bug 11/08) : la cible de re-cale est la position
                // du référentiel. Si elle dépasse la FIN de ce slot (durées
                // différentes, avance rapide du référentiel), le seek le fait
                // terminer INSTANTANÉMENT → remplacement auto → re-cale →
                // boucle infinie de changement de vidéos. On ignore le slot :
                // il joue sa propre course et sera re-synchronisé quand le
                // référentiel reviendra en deçà.
                let duration = state.item.duration
                if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0.5,
                   (otherCurrent + delta).seconds > duration.seconds - 0.2 {
                    continue
                }
                // Ré-ancrage sans saut : on repositionne l'item sur le temps du
                // référentiel (other + delta == reference) au prochain tick de l'horloge hôte.
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(currentRate, time: otherCurrent + delta, atHostTime: host)
                // Feature 5 : la correction de dérive compte comme progression —
                // on repousse le compteur du watchdog pour ce slot.
                lastProgression[slot] = (otherCurrent + delta, Date())
            }
            publishDrift(delta.seconds, for: slot)
        }

        // Reprise : enregistre la position courante de chaque slot (1 Hz) ;
        // la persistance reste différée (2 s) pour ne pas écrire UserDefaults
        // en continu pendant la lecture.
        for (_, state) in slotStates where !state.ended {
            let time = state.player.currentTime()
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                positions[state.url.standardizedFileURL.path] = time.seconds
            }
        }
        schedulePositionsSave()
    }

    private func publishDrift(_ deltaSeconds: Double, for slot: Int) {
        guard deltaSeconds.isFinite else { return }
        let magnitude = abs(deltaSeconds)
        if magnitude >= 0.01 {
            let text = String(format: "Δ %.0f ms", magnitude * 1000.0)
            // Comparaison avant affectation : évite de spammer @Published.
            if driftText[slot] != text {
                driftText[slot] = text
            }
        } else if magnitude < 0.005 {
            if driftText[slot] != nil {
                driftText.removeValue(forKey: slot)
            }
        }
        // Entre 0.005 s et 0.01 s : hystérésis, on laisse la valeur précédente.
    }

    // MARK: Observations KVO et notifications

    private func handleStatusChange(slot: Int) {
        guard let state = slotStates[slot] else { return }
        switch state.item.status {
        case .readyToPlay:
            if slotError[slot] != nil {
                slotError.removeValue(forKey: slot)
            }
            // Slot devenu prêt PENDANT une lecture en cours : il rejoint la
            // session en se positionnant sur le temps du RÉFÉRENTIEL (pas du
            // leader — en fin de lecture partielle, le référentiel a migré),
            // puis en s'ancrant sur l'horloge hôte (sinon il resterait en pause
            // indéfiniment, invisible pour le moniteur de dérive).
            // Démarrage différé d'un slot de REMPLACEMENT AUTO (nouvel item
            // prêt) : démarre à ZÉRO, ancré sur l'horloge hôte. Prioritaire
            // sur le join « à chaud » classique (qui aligne sur le référentiel).
            // M4 : un slot INDÉPENDANT dont le contenu vient d'être remplacé
            // (assign manuel pendant la lecture) rejoint à ZÉRO comme l'auto-
            // remplacement — sinon le join « à chaud » écraserait sa position
            // indépendante avec celle du référentiel (indépendance détruite
            // en silence).
            if startFromZeroOnReady.remove(slot) != nil || independentSlot == slot {
                scheduleSlotStart(slot)
            } else if isPlaying, let reference = referenceState, !reference.ended {
                var target = reference.item.currentTime()
                // ANTI-BOUCLE (11/08) : si la position du référentiel dépasse
                // la durée de ce slot, rejointe à ZÉRO — sinon fin instantanée
                // → remplacement → boucle infinie.
                let duration = state.item.duration
                if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0.5,
                   target.seconds > duration.seconds - 0.2 {
                    target = .zero
                }
                seekGeneration += 1
                let generation = seekGeneration
                state.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.seekGeneration == generation, self.isPlaying else { return }
                        let host = CMTime(seconds: CACurrentMediaTime() + 0.15, preferredTimescale: 1000)
                        state.player.setRate(self.currentRate, time: target, atHostTime: host)
                    }
                }
            }
        case .failed:
            let message = state.item.error?.localizedDescription ?? "Fichier illisible"
            if slotError[slot] != message {
                slotError[slot] = message
            }
            // Feature 3 : remplacement automatique différé (~0,5 s) — laisse
            // le système stabiliser l'échec avant de tenter la file.
            if autoReplace {
                scheduleFailedReplacement(for: slot)
            }
        case .unknown:
            break
        @unknown default:
            break
        }
        updateReadyCount()
    }

    private func handleItemDidPlayToEnd(item: AVPlayerItem) {
        guard let slot = slotStates.first(where: { $0.value.item === item })?.key,
              let state = slotStates[slot] else { return }
        // M3 : le référentiel doit être capturé AVANT de poser ended —
        // referenceSlot (computed) ignore les slots ended, donc la branche
        // de migration ci-dessous serait du code mort sinon.
        let wasReference = (slot == referenceSlot)
        state.ended = true
        // Purge de la dérive affichée : un slot terminé ne dérive plus.
        if driftText[slot] != nil {
            driftText.removeValue(forKey: slot)
        }
        // Fin RÉELLE de la vidéo : la position mémorisée est effacée — la
        // prochaine lecture repartira de zéro sans proposition de reprise.
        clearPosition(for: state.url)
        // TIMELINE INDÉPENDANTE : si le slot ciblé vient de se terminer, on
        // revient au mode global (le bloc va être remplacé/relancé).
        if independentSlot == slot {
            independentSlot = nil
        }
        // Si le slot terminé était le référentiel, la migration fait d'un
        // autre slot le nouveau référentiel : un slot indépendant ne peut
        // pas devenir référentiel — on le libère aussi.
        if let independent = independentSlot, independent == referenceSlot {
            independentSlot = nil
        }
        // REMPLACEMENT AUTOMATIQUE : la bibliothèque choisit une vidéo de
        // remplacement et relance le slot — le bloc ne reste jamais vide et
        // la lecture continue (playlist infinie). Aucune pause ici : chaque
        // slot terminé est remplacé puis re-synchronisé individuellement.
        if autoReplace {
            onItemEnded?(slot)
            return
        }
        // Quand TOUS les slots configurés sont terminés, on coupe tout.
        if slotStates.values.allSatisfy(\.ended) {
            pause()
            return
        }
        // M3 (corrigé) : `wasReference` est capturé AVANT ended — la branche
        // fonctionne enfin : migration de durée + unmute du nouveau référentiel.
        if wasReference {
            refreshReferenceDuration()
            // Audio : le nouveau référentiel était muet par défaut (seul le
            // leader l'était audible) — on le rend audible si l'utilisateur
            // n'a pas réglé le mute manuellement (W-D).
            if let newRef = referenceState, !newRef.userAdjustedMute, newRef.muted {
                newRef.muted = false
                newRef.player.isMuted = false
            }
        }
    }

    /// Charge la durée du slot référentiel de manière asynchrone et la publie.
    private func refreshReferenceDuration() {
        guard let reference = referenceState else {
            if leaderDuration != .zero {
                leaderDuration = .zero
            }
            return
        }
        let item = reference.item
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Note : l'API async load(_:) vit sur AVAsset, pas sur AVPlayerItem.
            guard let duration = try? await item.asset.load(.duration) else { return }
            // Le référentiel a pu changer pendant le chargement : on ne publie que si
            // l'item est toujours celui du référentiel actuel.
            if self.referenceState?.item === item {
                self.leaderDuration = duration
            }
        }
    }

    private func updateReadyCount() {
        let count = slotStates.values.filter { $0.item.status == .readyToPlay }.count
        if count != readyCount {
            readyCount = count
        }
    }
}

//  UI.swift
//  TriSync — Couche d'interface SwiftUI : scène synchronisée jusqu'à 3 vidéos.
//  macOS 14+, optimisé Apple Silicon M3.
//
//  Règle de performance critique : aucun material/flou/ombre AU-DESSUS des
//  couches vidéo (composition hors-écran coûteuse). Les materials ne sont
//  utilisés que sur le « chrome » : barre supérieure, barre de transport et
//  panneaux d'infos superposés.

import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Constantes

/// Couleur d'accent système (évite l'API dépréciée Color.accentColor).
let accent = Color(nsColor: .controlAccentColor)

/// Lettres des emplacements (jusqu'à 5 vidéos).
let slotLetters = ["A", "B", "C", "D", "E"]

// MARK: - Modes d'affichage vidéo

/// Mode de remplissage d'un panneau vidéo.