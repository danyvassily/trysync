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

@main
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
fileprivate weak var sharedLibrary: VideoLibrary?

// MARK: - Asset vidéo

/// Dossier source de la vidéothèque (Mac, disque externe…) avec bookmark de
/// sécurité persisté pour retrouver l'accès aux prochains lancements.
struct LibrarySource: Identifiable, Codable {
    let id: UUID
    let url: URL
    var enabled: Bool
    let bookmark: Data
}

final class VideoAsset: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    /// Date d'ajout à la bibliothèque (trie le dossier intelligent
    /// « Récemment ajoutés »).
    let dateAdded = Date()

    var duration: CMTime = .zero
    var frameRate: Double = 0
    var size: CGSize = .zero
    var thumbnail: NSImage? = nil

    /// Favori (dossier intelligent « À regarder »), persisté par chemin
    /// STANDARDISÉ dans UserDefaults (« library.favorites »). Les clés sont
    /// des chemins (et non des UUID) car VideoAsset.id est régénéré à chaque
    /// lancement : les favoris survivent ainsi au redémarrage.
    /// VideoLibrary.toggleFavorite(_:) publie la bascule pour rafraîchir l'UI.
    var isFavorite: Bool {
        get { Self.favoritePaths.contains(url.standardizedFileURL.path) }
        set {
            var paths = Self.favoritePaths
            let key = url.standardizedFileURL.path
            if newValue { paths.insert(key) } else { paths.remove(key) }
            UserDefaults.standard.set(Array(paths), forKey: "library.favorites")
            Self.favoritePaths = paths
        }
    }

    private static var favoritePaths: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "library.favorites") ?? [])
    }()

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Bibliothèque vidéo

@MainActor
final class VideoLibrary: ObservableObject {
    static let maxSlots = 5

    @Published var slots: [VideoAsset?] = Array(repeating: nil, count: VideoLibrary.maxSlots)
    @Published var assets: [VideoAsset] = []
    @Published var selectedSlot = 0
    /// Révision des favoris : incrémentée à chaque bascule d'étoile pour que
    /// les cartes et le dossier intelligent « À regarder » se rafraîchissent
    /// (la persistance elle-même vit dans VideoAsset.isFavorite).
    @Published private(set) var favoritesRevision = 0

    let engine = SyncEngine()

    /// Tâches de chargement des métadonnées par asset : annulées quand l'asset
    /// est retiré ou que la bibliothèque est vidée (W8 — pas de tâches orphelines).
    private var metadataTasks: [UUID: Task<Void, Never>] = [:]

    /// Dossiers sources (Mac, disque externe…) scannés pour la vidéothèque.
    @Published var sources: [LibrarySource] = []
    /// Asset → source d'origine (pour retirer les vidéos d'une source).
    private var assetSource: [UUID: UUID] = [:]

    private var saveWorkItem: DispatchWorkItem?
    private static let sourcesKey = "library.sources"
    private static let assetsKey = "library.assetBookmarks"
    private static let slotsKey = "library.slotURLs"
    private static let queuesKey = "library.queues"

    // MARK: Files de lecture par slot (feature 2)

    /// Files ordonnées par slot : ordre des remplacements automatiques.
    /// Par défaut (file absente), le prochain contenu est la première vidéo
    /// de la bibliothèque non déjà chargée (boucle sur la sélection).
    private var queues: [Int: [VideoAsset]] = [:]

    // MARK: Échecs de lecture et anti-rafale (features 3 et 4)

    /// URLs en échec consécutif par slot : quand toute la file a été tentée,
    /// le slot est vidé avec le badge « Fichier illisible ».
    private var failedURLs: [Int: Set<URL>] = [:]
    /// Remplacements différés en attente (anti-rafale), par slot.
    private var pendingReplacements: [Int: Task<Void, Never>] = [:]
    /// Horodatage du dernier remplacement appliqué (anti-rafale : deux
    /// remplacements à moins d'une seconde sont espacés).
    private var lastReplacementDate = Date.distantPast

    init() {
        // Remplacement automatique : quand une vidéo se termine, la
        // bibliothèque choisit une autre vidéo pour que le bloc continue.
        engine.onItemEnded = { [weak self] slot in
            self?.autoReplace(slot: slot)
        }
        // Feature 3 : échec de lecture → remplacement différé (0,5 s côté moteur).
        engine.onSlotFailed = { [weak self] slot in
            self?.handleSlotFailure(slot)
        }
        // Feature 1 : préchargement anticipé du prochain contenu du référentiel.
        engine.onPreloadNeeded = { [weak self] slot in
            self?.prepareNext(for: slot)
        }
        // Détection automatique des nouveaux fichiers dans les sources
        // (polling léger toutes les 5 s, voir checkSourcesForChanges).
        startSourceWatcher()
    }

    // MARK: Sélection et gestion des slots

    func select(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        selectedSlot = slot
    }

    func clear(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        // Nettoyage complet : file, compteur d'échecs et remplacement différé.
        queues.removeValue(forKey: slot)
        failedURLs.removeValue(forKey: slot)
        pendingReplacements[slot]?.cancel()
        pendingReplacements.removeValue(forKey: slot)
        slots[slot] = nil
        syncEngine()
    }

    func clearAll() {
        for task in metadataTasks.values { task.cancel() }
        metadataTasks.removeAll()
        for task in pendingReplacements.values { task.cancel() }
        pendingReplacements.removeAll()
        queues.removeAll()
        failedURLs.removeAll()
        slots = Array(repeating: nil, count: VideoLibrary.maxSlots)
        assets = []
        engine.clear()
    }

    func assign(_ asset: VideoAsset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        // W5 : un asset déjà affiché dans un slot est DÉPLACÉ, jamais dupliqué.
        if let old = slots.firstIndex(where: { $0?.id == asset.id }), old != slot {
            slots[old] = nil
        }
        // Affectation manuelle : annule un remplacement différé (anti-rafale)
        // et repart d'un compteur d'échecs propre (feature 3).
        pendingReplacements[slot]?.cancel()
        pendingReplacements.removeValue(forKey: slot)
        failedURLs.removeValue(forKey: slot)
        slots[slot] = asset
        // Reprise : si une position a été mémorisée pour cette vidéo (> 15 s),
        // la lecture démarre à zéro et la barre de transport affiche un
        // bandeau « Reprendre / Recommencer » (6 s).
        engine.offerResumeIfNeeded(slot: slot, url: asset.url)
        syncEngine()
    }

    func removeAsset(_ asset: VideoAsset) {
        metadataTasks[asset.id]?.cancel()
        metadataTasks.removeValue(forKey: asset.id)
        assets.removeAll { $0.id == asset.id }
        for index in slots.indices where slots[index]?.id == asset.id {
            slots[index] = nil
        }
        syncEngine()
    }

    // MARK: Ajout et ingestion de fichiers

    func add(urls: [URL]) {
        // Ajout à la VIDÉOTHÈQUE uniquement : aucun slot n'est occupé
        // automatiquement — l'utilisateur place ensuite ses vidéos dans les
        // emplacements A–E depuis la grille (clic / double-clic).
        add(urls: urls, source: nil)
    }

    func ingest(_ urls: [URL]) {
        add(urls: urls, source: nil)
    }

    /// Ajoute des URLs à la bibliothèque, avec une source d'origine
    /// optionnelle (dossier Mac / disque externe).
    private func add(urls: [URL], source: UUID?) {
        for url in Self.videoFiles(from: urls) {
            guard !assets.contains(where: { $0.url == url }) else { continue }
            let asset = VideoAsset(url: url)
            assets.append(asset)
            assetSource[asset.id] = source
            let task = Task { @MainActor in
                await loadMetadata(for: asset)
                if !Task.isCancelled {
                    objectWillChange.send()
                }
            }
            metadataTasks[asset.id] = task
        }
        syncEngine()
        scheduleSave()
    }

    // MARK: Sources (Mac, disque externe…)

    /// Ajoute un dossier source (bookmark de sécurité persisté) puis le scanne.
    func addSource(url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        if sources.contains(where: { $0.url == url }) { return }
        sources.append(LibrarySource(id: UUID(), url: url, enabled: true, bookmark: bookmark))
        persistSources()
        scanSources()
    }

    func removeSource(id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        persistSources()
        sourceFingerprints.removeValue(forKey: id)
        // Retire les vidéos issues de cette source (slots inclus).
        let doomed = assets.filter { assetSource[$0.id] == id }
        for asset in doomed {
            metadataTasks[asset.id]?.cancel()
            metadataTasks.removeValue(forKey: asset.id)
            assetSource.removeValue(forKey: asset.id)
            assets.removeAll { $0.id == asset.id }
            for i in slots.indices where slots[i]?.id == asset.id { slots[i] = nil }
        }
        syncEngine()
        scheduleSave()
    }

    func toggleSource(id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled.toggle()
        persistSources()
        // Empreinte oubliée : à la réactivation, le moniteur détectera le
        // moindre changement (et le scan ci-dessous la rafraîchit).
        sourceFingerprints.removeValue(forKey: id)
        if sources[index].enabled {
            scanSources()
        } else {
            removeSourceVideos(id: id)
        }
    }

    private func removeSourceVideos(id: UUID) {
        let doomed = assets.filter { assetSource[$0.id] == id }
        for asset in doomed {
            assets.removeAll { $0.id == asset.id }
            for i in slots.indices where slots[i]?.id == asset.id { slots[i] = nil }
        }
        syncEngine()
        scheduleSave()
    }

    // MARK: Surveillance automatique des sources

    /// Empreinte du dossier source (date de modification) à la dernière
    /// vérification : un changement déclenche un rescan incrémental.
    private var sourceFingerprints: [UUID: Date] = [:]
    /// Vrai tant qu'au moins un scan de source est en cours (évite les
    /// double scans déclenchés par la surveillance ou l'interface).
    @Published private(set) var isScanning = false
    private var activeScans = 0
    /// Tâche de polling des sources : s'arrête d'elle-même quand la
    /// bibliothèque est libérée (capture faible).
    private var sourceWatcherTask: Task<Void, Never>?

    /// Scanne tous les dossiers sources actifs (en arrière-plan, priorité
    /// utilitaire) et ingère les vidéos trouvées sans occuper les slots.
    func scanSources() {
        guard !isScanning else { return }
        for source in sources where source.enabled {
            scanSource(source)
        }
    }

    /// Scanne UNE source en arrière-plan, puis met à jour son empreinte.
    private func scanSource(_ source: LibrarySource) {
        activeScans += 1
        isScanning = true
        let url = source.url
        let sourceID = source.id
        Task.detached(priority: .utility) { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var found: [URL] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
            if let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    guard found.count < 5000 else { break }
                    guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    if !Self.videoFiles(from: [fileURL]).isEmpty { found.append(fileURL) }
                }
            }
            let result = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.add(urls: result, source: sourceID)
                self.sourceFingerprints[sourceID] = Self.modificationDate(of: url)
                self.activeScans -= 1
                if self.activeScans == 0 { self.isScanning = false }
            }
        }
    }

    /// Lance le moniteur : toutes les 5 s (si une source active existe et
    /// qu'aucun scan n'est en cours), compare les dates de modification des
    /// dossiers sources et rescanne ceux qui ont changé. Léger : une stat par
    /// source sur le main thread ; le scan reste en arrière-plan. La lecture
    /// n'est jamais interrompue (ajout sans occupation de slot).
    func startSourceWatcher() {
        guard sourceWatcherTask == nil else { return }
        sourceWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkSourcesForChanges()
            }
        }
    }

    /// Compare les sources actives à leurs empreintes et rescanne les
    /// dossiers modifiés (jamais pendant un scan en cours).
    private func checkSourcesForChanges() {
        guard !isScanning else { return }
        let active = sources.filter { $0.enabled }
        guard !active.isEmpty else {
            sourceFingerprints.removeAll()
            return
        }
        for source in active {
            let current = Self.modificationDate(of: source.url)
            guard let known = sourceFingerprints[source.id] else {
                // Source jamais échantillonnée (ex. réactivée pendant un
                // scan) : on enregistre l'empreinte ET on scanne.
                sourceFingerprints[source.id] = current
                scanSource(source)
                continue
            }
            // Tolérance de 1,5 s : évite les rescan en rafale quand le
            // système de fichiers arrondit les dates de modification.
            if abs(current.timeIntervalSince(known)) > 1.5 {
                sourceFingerprints[source.id] = current
                scanSource(source)
            }
        }
    }

    /// Date de modification d'un dossier (empreinte de surveillance).
    /// nonisolated : appelable depuis la fin d'un scan (Task détachée).
    nonisolated private static func modificationDate(of url: URL) -> Date {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    // MARK: Persistance de la bibliothèque

    /// Sauvegarde différée (1,5 s après la dernière modification).
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Sauvegarde immédiate : sources, assets et slots (bookmarks de sécurité).
    func saveNow() {
        let d = UserDefaults.standard
        var bookmarks: [String] = []
        for asset in assets {
            if let data = try? asset.url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                bookmarks.append(data.base64EncodedString())
            }
        }
        d.set(bookmarks, forKey: Self.assetsKey)
        // Chemins STANDARDISÉS : la résolution d'un bookmark peut retourner le
        // chemin canonique (/private/var/... au lieu de /var/...) — comparer
        // des chaînes brutes casserait la restauration des slots (bug trouvé
        // par le test de persistance round-trip, 11/08/2026).
        d.set(slots.map { $0?.url.standardizedFileURL.absoluteString ?? "" }, forKey: Self.slotsKey)
        persistQueues()
    }

    /// Restaure la bibliothèque sauvegardée au lancement (bookmarks résolus).
    func restoreLibrary() {
        let d = UserDefaults.standard
        var urls: [URL] = []
        for b64 in d.stringArray(forKey: Self.assetsKey) ?? [] {
            guard let data = Data(base64Encoded: b64) else { continue }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &isStale) else { continue }
            urls.append(url)
        }
        if !urls.isEmpty {
            add(urls: urls, source: nil)
        }
        let slotURLs = d.stringArray(forKey: Self.slotsKey) ?? []
        for (index, urlString) in slotURLs.enumerated() where !urlString.isEmpty {
            // Comparaison sur chemins standardisés (voir saveNow).
            if let asset = assets.first(where: { $0.url.standardizedFileURL.absoluteString == urlString }) {
                slots[index] = asset
            }
        }
        syncEngine()
        restoreQueues()
        restoreSources()
        scanSources()
    }

    private func persistSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourcesKey)
    }

    private func restoreSources() {
        guard let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
              let saved = try? JSONDecoder().decode([LibrarySource].self, from: data) else { return }
        sources = saved
    }

    // MARK: Synchronisation du moteur

    private func syncEngine() {
        var configuration: [Int: VideoAsset] = [:]
        for (index, asset) in slots.enumerated() {
            guard let asset = asset else { continue }
            configuration[index] = asset
        }
        engine.reconfigure(slots: configuration)
        scheduleSave()
    }

    // MARK: Filtrage des fichiers vidéo

    /// Extensions de secours quand UTType ne reconnaît pas le fichier
    /// (mkv, webm, ts, m2ts… ne sont pas toujours déclarés dans la base UTType).
    nonisolated private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "ts", "m2ts"]

    /// Type du fichier : d'abord le type réel sur disque (NSURLContentTypeKey),
    /// puis déduction depuis l'extension (UTType n'a pas d'init(url:)).
    nonisolated private static func fileType(of url: URL) -> UTType? {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Ne conserve que les URLs correspondant à des fichiers vidéo :
    /// conformité UTType (.movie / .video) ou extension de la liste de secours.
    /// nonisolated : appelable depuis le scan des sources (Task détachée).
    nonisolated static func videoFiles(from urls: [URL]) -> [URL] {
        urls.filter { url in
            if let type = Self.fileType(of: url) {
                return type.conforms(to: .movie) || type.conforms(to: .video)
            }
            return videoExtensions.contains(url.pathExtension.lowercased())
        }
    }

    // MARK: Attribution d'un slot

    /// Place une vidéo dans le premier emplacement libre, sinon dans
    /// l'emplacement sélectionné. Appelé par la grille (clic ou double-clic).
    func place(_ asset: VideoAsset, preferredSlot: Int? = nil) {
        guard slots.indices.contains(preferredSlot ?? 0) else { return }
        if let empty = slots.firstIndex(where: { $0 == nil }) {
            assign(asset, to: empty)
        } else {
            assign(asset, to: preferredSlot ?? 0)
        }
    }

    // MARK: Sélection multi (⌘+clic)

    /// Sélection ordonnée des cartes de la bibliothèque (ordre des clics) :
    /// c'est cet ordre qui remplit les emplacements A→E au lancement.
    @Published var selectedOrder: [UUID] = []

    /// Bascule la sélection d'un asset (⌘+clic).
    func toggleSelection(_ asset: VideoAsset) {
        if let index = selectedOrder.firstIndex(of: asset.id) {
            selectedOrder.remove(at: index)
        } else {
            selectedOrder.append(asset.id)
        }
    }

    /// Sélectionne uniquement cet asset (clic simple).
    func selectOnly(_ asset: VideoAsset) {
        selectedOrder = [asset.id]
    }

    func clearSelection() {
        selectedOrder = []
    }

    /// Assets sélectionnés, bornés à maxSlots (5), dans l'ordre des clics.
    var selectedAssets: [VideoAsset] {
        selectedOrder.prefix(VideoLibrary.maxSlots).compactMap { id in
            assets.first { $0.id == id }
        }
    }

    /// Garantit qu'un fichier est présent dans la bibliothèque (sans occuper
    /// de slot) et retourne l'asset correspondant. Utilisé par le navigateur
    /// de dossiers au clic sur une vidéo.
    func ensureInLibrary(_ url: URL) -> VideoAsset? {
        if let existing = assets.first(where: { $0.url == url }) { return existing }
        add(urls: [url], source: nil)
        return assets.first(where: { $0.url == url })
    }

    // MARK: Favoris et reprise de lecture (dossiers intelligents)

    /// Bascule le favori d'un asset (étoile des cartes) et publie le
    /// changement pour rafraîchir les vues qui en dépendent (« À regarder »).
    func toggleFavorite(_ asset: VideoAsset) {
        asset.isFavorite.toggle()
        favoritesRevision += 1
    }

    /// Position de lecture sauvegardée pour une URL (dict « playback.positions »,
    /// clé = chemin standardisé), écrite par la feature « Reprendre ».
    /// Retourne 0 quand aucune position n'est enregistrée.
    func playbackPosition(for url: URL) -> Double {
        let key = url.standardizedFileURL.path
        return UserDefaults.standard.dictionary(forKey: "playback.positions")?[key] as? Double ?? 0
    }

    /// Place la sélection (max 5, ordre des clics) dans les emplacements A→E
    /// puis vide la sélection. Appelé par « Lancer (N) ».
    func launchSelected() {
        let assets = selectedAssets
        guard !assets.isEmpty else { return }
        for (index, asset) in assets.enumerated() {
            assign(asset, to: index)
        }
        clearSelection()
    }

    // MARK: Files de lecture par slot (feature 2)

    /// File de lecture du slot, nettoyée des assets retirés de la
    /// bibliothèque. Vide tant qu'aucun ordre n'a été défini.
    func queue(for slot: Int) -> [VideoAsset] {
        guard slots.indices.contains(slot), let raw = queues[slot] else { return [] }
        let live = raw.filter { asset in assets.contains(where: { $0.id == asset.id }) }
        if live.count != raw.count {
            queues[slot] = live
            scheduleSave()
        }
        return live
    }

    /// Définit la file de lecture d'un slot (ordre des remplacements).
    func setQueue(_ queue: [VideoAsset], for slot: Int) {
        guard slots.indices.contains(slot) else { return }
        queues[slot] = queue
        scheduleSave()
    }

    /// Mélange Fisher-Yates de TOUTES les files de lecture (« Mélanger »).
    func shuffleQueues() {
        for slot in slots.indices {
            var queue = queues[slot] ?? defaultQueue(for: slot)
            guard queue.count > 1 else { continue }
            for i in stride(from: queue.count - 1, through: 1, by: -1) {
                let j = Int.random(in: 0...i)
                queue.swapAt(i, j)
            }
            queues[slot] = queue
        }
        scheduleSave()
    }

    /// Prochain asset de la file du slot, avec rotation (le premier passe en
    /// fin de file : lecture en boucle). Reconstruit la file par défaut quand
    /// elle est vide ou ne contient que la vidéo courante.
    func next(in slot: Int) -> VideoAsset? {
        guard slots.indices.contains(slot) else { return nil }
        var queue = queue(for: slot)
        let currentID = slots[slot]?.id
        if queue.isEmpty || (queue.count == 1 && queue[0].id == currentID) {
            queue = defaultQueue(for: slot)
        }
        guard !queue.isEmpty else { return slots[slot] }
        let next = queue.removeFirst()
        queues[slot] = queue + [next]
        return next
    }

    /// File par défaut d'un slot : les vidéos de la bibliothèque non déjà
    /// chargées dans un slot (boucle sur la sélection).
    private func defaultQueue(for slot: Int) -> [VideoAsset] {
        let loadedIDs = Set(slots.compactMap { $0?.id })
        return assets.filter { !loadedIDs.contains($0.id) }
    }

    /// Prochain candidat de remplacement pour un slot : tête de la file (SANS
    /// rotation — le préchargement ne doit pas modifier l'ordre de la file),
    /// sinon la première vidéo de la bibliothèque non déjà chargée, sinon la
    /// vidéo courante (relecture).
    private func nextCandidate(for slot: Int) -> VideoAsset? {
        guard slots.indices.contains(slot) else { return nil }
        if let queued = queue(for: slot).first(where: { $0.id != slots[slot]?.id }) {
            return queued
        }
        let currentID = slots[slot]?.id
        let loadedIDs = Set(slots.compactMap { $0?.id })
        if let next = assets.first(where: { $0.id != currentID && !loadedIDs.contains($0.id) }) {
            return next
        }
        return slots[slot]
    }

    // MARK: Remplacement automatique

    /// Remplacement automatique d'un slot terminé (ou en échec) : prend le
    /// prochain contenu de la file du slot et le relance synchronisé.
    /// DÉLAI ANTI-RAFALE (feature 4) : deux remplacements à moins d'une
    /// seconde d'intervalle sont espacés — le second est différé de 1 s puis
    /// re-vérifié (slot inchangé, remplacement toujours actif).
    private func autoReplace(slot: Int, failedURL: URL? = nil) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        let expectedID = slots[slot]?.id
        guard Date().timeIntervalSince(lastReplacementDate) >= 1.0 else {
            pendingReplacements[slot]?.cancel()
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pendingReplacements[slot] = nil
                // Re-vérification : le slot contient toujours la même vidéo
                // et le remplacement automatique est toujours actif.
                guard self.engine.autoReplace, self.slots.indices.contains(slot),
                      self.slots[slot]?.id == expectedID else { return }
                self.applyReplacement(slot: slot, failedURL: failedURL)
            }
            pendingReplacements[slot] = task
            return
        }
        applyReplacement(slot: slot, failedURL: failedURL)
    }

    /// Application effective d'un remplacement (immédiat ou différé).
    private func applyReplacement(slot: Int, failedURL: URL? = nil) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        lastReplacementDate = Date()

        // Feature 3 : en cas d'échec, on mémorise le fichier défaillant pour
        // détecter l'épuisement de la file. Fin naturelle = compteur propre.
        if let failedURL {
            failedURLs[slot, default: []].insert(failedURL)
        } else {
            failedURLs.removeValue(forKey: slot)
        }

        guard let next = next(in: slot) else {
            emptySlotAfterFailure(slot)
            return
        }

        // Toute la file a déjà échoué → slot vide + badge « Fichier illisible ».
        if failedURLs[slot, default: []].contains(next.url) {
            emptySlotAfterFailure(slot)
            return
        }

        slots[slot] = next
        syncEngine()
        // Relance le contenu du slot à zéro, aligné sur la lecture en cours.
        engine.joinNewSlot(slot)
    }

    /// Vide un slot après épuisement de sa file (tout est illisible) : le
    /// badge « Fichier illisible » est posé de façon persistante.
    private func emptySlotAfterFailure(_ slot: Int) {
        failedURLs.removeValue(forKey: slot)
        slots[slot] = nil
        syncEngine()
        engine.setSlotError("Fichier illisible", for: slot)
    }

    /// Échec de lecture d'un slot (.failed) : le remplacement automatique est
    /// tenté (le moteur a déjà différé de ~0,5 s). Si toute la file a échoué,
    /// le slot est vidé avec le badge « Fichier illisible ».
    private func handleSlotFailure(_ slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        autoReplace(slot: slot, failedURL: slots[slot]?.url)
    }

    // MARK: Préchargement du remplacement (feature 1)

    /// Prépare le prochain contenu d'un slot HORS lecture : même logique que
    /// le remplacement automatique, mais anticipée (déclenchée à moins de 10 s
    /// de la fin du référentiel). L'AVPlayerItem est confié au moteur
    /// (pendingItems) ; reconfigure le réutilise à la fin de lecture.
    func prepareNext(for slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot),
              let current = slots[slot] else { return }
        guard let next = nextCandidate(for: slot), next.id != current.id else { return }
        let url = next.url
        // Même configuration que addSlot (tampon court, fichiers locaux).
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 2.0
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Amorçage du pipeline AVFoundation hors lecture.
            _ = try? await item.asset.load(.duration)
            guard !Task.isCancelled else { return }
            // Attend que l'item soit prêt (borné : 3 s) pour un remplacement
            // immédiat ; sinon l'item est confié quand même — le démarrage
            // différé (startFromZeroOnReady) prend le relais.
            for _ in 0..<60 {
                if item.status == .readyToPlay { break }
                if item.status == .failed { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, self.slots.indices.contains(slot),
                  self.slots[slot]?.id == current.id else { return }
            self.engine.storePendingItem(item, for: url, slot: slot)
        }
    }

    // MARK: Persistance des files (feature 2)

    private func persistQueues() {
        // UserDefaults impose des clés String : on convertit l'index du slot.
        let encoded: [String: [String]] = Dictionary(uniqueKeysWithValues: queues.map { key, value in
            (String(key), value.map { $0.url.standardizedFileURL.absoluteString })
        })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: Self.queuesKey)
        }
    }

    private func restoreQueues() {
        guard let data = UserDefaults.standard.data(forKey: Self.queuesKey),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        for (key, urlStrings) in saved {
            guard let slot = Int(key), slots.indices.contains(slot) else { continue }
            queues[slot] = urlStrings.compactMap { urlString in
                assets.first { $0.url.standardizedFileURL.absoluteString == urlString }
            }
        }
    }

    // MARK: Chargement des métadonnées (durée, résolution, fréquence, miniature)

    private func loadMetadata(for asset: VideoAsset) async {
        let url = asset.url
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Mémoïsation : les métadonnées déjà lues (durée, taille, fréquence)
        // sont réutilisées au lieu de relire l'AVAsset à chaque affichage.
        if let cached = MetadataCache.shared.get(for: url) {
            asset.duration = CMTime(seconds: cached.duration, preferredTimescale: 600)
            asset.size = CGSize(width: cached.width, height: cached.height)
            asset.frameRate = cached.frameRate
            asset.thumbnail = await Self.generateThumbnail(for: asset)
            return
        }

        do {
            // AVURLAssetPreferPreciseDurationAndTimingKey = false : chargement
            // BEAUCOUP plus rapide des grosses vidéos (durée lue depuis les
            // métadonnées, pas de scan complet des paquets).
            let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

            asset.duration = try await avAsset.load(.duration)

            if let track = try await avAsset.loadTracks(withMediaType: .video).first {
                // Taille d'AFFICHAGE (upright) : naturalSize + transform de rotation.
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                asset.size = CGSize(
                    width: abs(natural.width * transform.a + natural.height * transform.c),
                    height: abs(natural.width * transform.b + natural.height * transform.d)
                )
                asset.frameRate = Double(try await track.load(.nominalFrameRate))
            }

            MetadataCache.shared.set(
                VideoMetadata(duration: asset.duration.seconds,
                              width: asset.size.width,
                              height: asset.size.height,
                              frameRate: asset.frameRate),
                for: url
            )

            // Vignette via le cache disque (JPEG persisté).
            asset.thumbnail = await Self.generateThumbnail(for: asset)
        } catch {
            // Échec silencieux : l'asset reste utilisable avec des métadonnées à zéro.
        }
    }

    /// Miniature de bibliothèque (16:9) via le cache disque persistant —
    /// générée une seule fois, rechargée instantanément ensuite.
    private static func generateThumbnail(for asset: VideoAsset) async -> NSImage? {
        guard asset.duration.isNumeric, asset.duration.seconds > 0 else { return nil }
        return await ThumbnailCache.shared.thumbnail(for: asset.url, variant: .landscape)
    }
}

// MARK: - Réglages (persistés dans UserDefaults)

/// Réglages utilisateur de l'affichage et de la lecture, persistés entre
/// les lancements. Injectés dans l'environnement SwiftUI.
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
        layout: "settings.layoutPreset"
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
    func validPresets(forCount count: Int) -> [LayoutPreset] {
        switch count {
        case 2: return [.auto, .sideBySide, .stacked, .masterH, .masterV]
        case 3: return [.auto, .threeColumns, .masterTwo, .threeRows]
        case 4: return [.auto, .grid2x2, .fourColumns, .masterThree]
        case 5: return [.auto, .wall32, .wall23, .fiveColumns, .masterFour]
        default: return [.auto]
        }
    }

    func isValidPreset(_ preset: LayoutPreset, forCount count: Int) -> Bool {
        validPresets(forCount: count).contains(preset)
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

    /// Slot référentiel pour le temps affiché, le scrubber et la dérive :
    /// le leader tant qu'il joue, sinon le premier slot non terminé
    /// (migration en fin de lecture partielle, cf. handleItemDidPlayToEnd).
    private var referenceSlot: Int? {
        if let leader = leaderSlot, let state = slotStates[leader], !state.ended {
            return leader
        }
        return slotStates.first(where: { !$0.value.ended })?.key
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

        // 3. Mute par défaut : seul le leader est audible, sauf réglage utilisateur explicite.
        for (slot, state) in slotStates where !state.userAdjustedMute {
            let shouldMute = (slot != newLeader)
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

        // 5. Durée du référentiel (rechargée uniquement si le référentiel a changé).
        if referenceSlot != oldLeader {
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
        pause()
        seekAll(to: .zero)
        driftText.removeAll()
    }

    /// Ré-aligne immédiatement tous les slots sur le référentiel (au-delà du seuil de dérive).
    func resync() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return }
        let target = reference.item.currentTime()
        for (slot, state) in slotStates where slot != reference.slot {
            guard !state.ended else { continue }
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
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended {
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
        // La durée du leader doit être connue pour convertir la fraction en temps.
        guard leaderDuration.isNumeric, leaderDuration.seconds.isFinite, leaderDuration.seconds > 0 else { return }
        let clamped = min(max(fraction, 0.0), 1.0)
        let target = CMTime(seconds: leaderDuration.seconds * clamped, preferredTimescale: 600)
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
        let target = slot ?? referenceSlot
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
    func position(for url: URL) -> Double {
        positions[url.path] ?? 0
    }

    /// Mémorise la position d'une vidéo (sauvegarde différée de 2 s).
    func savePosition(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds > 0 else { return }
        positions[url.path] = seconds
        schedulePositionsSave()
    }

    /// Efface la position mémorisée d'une vidéo (fin de lecture réelle,
    /// « Recommencer »).
    func clearPosition(for url: URL) {
        guard positions.removeValue(forKey: url.path) != nil else { return }
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
        let position = positions[url.path] ?? 0
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
        seekAll(to: CMTime(seconds: offer.position, preferredTimescale: 600))
        dismissResumeOffer()
    }

    /// « Recommencer » : retour à zéro et oubli de la position mémorisée.
    func declineResumeOffer() {
        guard let offer = resumeOffer else { return }
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
        for state in slotStates.values where state.slot != reference.slot && !state.ended {
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
        for (slot, state) in slotStates where slot != referenceSlot {
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
        // Feature 1 : annulation propre du préchargement éventuel du slot.
        cancelPendingItem(for: slot)
        preloadRequested.remove(slot)
        // Feature 3 : annule un remplacement d'échec encore en attente.
        failedReplacementTasks[slot]?.cancel()
        failedReplacementTasks.removeValue(forKey: slot)
        failedReplacementPending.remove(slot)
        // Feature 5 : oublie la progression du slot retiré.
        lastProgression.removeValue(forKey: slot)
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
    private func startPlayback() {
        guard !slotStates.isEmpty else { return }
        startDriftMonitor()
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended {
            state.player.setRate(currentRate, time: state.player.currentTime(), atHostTime: host)
        }
        isPlaying = true
    }

    /// Cherche la même position sur tous les players (tolérance zéro = image exacte)
    /// et met à jour leaderTime immédiatement.
    private func seekAll(to time: CMTime, completion: (() -> Void)? = nil) {
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
        for (slot, state) in slotStates where slot != reference.slot {
            // On ignore les slots terminés, en échec ou pas encore prêts : rien à réaligner.
            guard !state.ended, state.item.status == .readyToPlay else { continue }
            let otherCurrent = state.item.currentTime()
            let delta = referenceCurrent - otherCurrent
            guard delta.seconds.isFinite else { continue }
            if abs(delta.seconds) > 0.05 {
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
                positions[state.url.path] = time.seconds
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
            if startFromZeroOnReady.remove(slot) != nil {
                scheduleSlotStart(slot)
            } else if isPlaying, let reference = referenceState, !reference.ended {
                let target = reference.item.currentTime()
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
        state.ended = true
        // Purge de la dérive affichée : un slot terminé ne dérive plus.
        if driftText[slot] != nil {
            driftText.removeValue(forKey: slot)
        }
        // Fin RÉELLE de la vidéo : la position mémorisée est effacée — la
        // prochaine lecture repartira de zéro sans proposition de reprise.
        clearPosition(for: state.url)
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
        // Fin de lecture PARTIELLE : si le référentiel s'arrête alors que
        // d'autres slots jouent encore, on migre la publication du temps et la
        // dérive vers le premier slot encore actif — le scrubber reste vivant
        // et la synchro reste maîtrisée jusqu'au bout. La migration de durée
        // n'est PAS conditionnée à isPlaying : si l'app est en pause au moment
        // de la fin, l'échelle du scrubber doit rester correcte (W-A).
        if slot == referenceSlot {
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
private let accent = Color(nsColor: .controlAccentColor)

/// Lettres des emplacements (jusqu'à 5 vidéos).
private let slotLetters = ["A", "B", "C", "D", "E"]

// MARK: - Modes d'affichage vidéo

/// Mode de remplissage d'un panneau vidéo.
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
        // Quand des vidéos sont ajoutées (ouverture, dépôt, scan de source),
        // on bascule automatiquement vers la section Vidéothèque : l'ajout ne
        // lance JAMAIS la lecture, il remplit la bibliothèque.
        .onChange(of: library.assets.count) { oldCount, newCount in
            if newCount > oldCount, !session.immersiveMode {
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
        .onChange(of: session.section) { oldSection, newSection in
            if oldSection == .library, newSection != .library {
                miniPlayerHidden = false
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
            .frame(width: 360, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
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

                Text(timeString(engine.leaderTime))
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
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
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
    @EnvironmentObject private var windowController: WindowController
    var onOpenImporter: () -> Void = {}
    var onEnterImmersive: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private var filledSlots: Int { library.slots.compactMap { $0 }.count }

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
                iconButton("folder.badge.plus", "Importer des vidéos…") { onOpenImporter() }
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
                iconButton("arrow.up.left.and.arrow.down.right", "Plein écran (⌃⌘F)") {
                    windowController.window?.toggleFullScreen(nil)
                }
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
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 14)]

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
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.09 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? accent : Color.white.opacity(0.07), lineWidth: selected ? 2 : 1)
        )
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

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 14)]

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
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
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

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 14)]

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
        Text("\(timeString(engine.leaderTime)) / \(timeString(engine.leaderDuration))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 120, alignment: .leading)
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
        let time = engine.leaderTime
        let duration = engine.leaderDuration.seconds
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
            // Clic sur un bloc = source audio : ce bloc devient le slot audio
            // (volume 1.0, les autres à 0). Clic sur le MAÎTRE = retour au
            // comportement par défaut (audio sur le référentiel).
            if engine.isReferenceSlot(slot) {
                engine.setAudioSlot(nil)
            } else {
                engine.setAudioSlot(slot)
            }
        }
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
                    if isLeader {
                        leaderBadge
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
