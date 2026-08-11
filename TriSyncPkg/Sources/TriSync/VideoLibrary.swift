// TriSync — Bibliothèque vidéo
// Découpage en modules (v7.1) : même target SwiftPM, aucune visibilité modifiée.

import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import CryptoKit


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

    /// URLs en échec consécutif par slot avec DATE du premier échec :
    /// quand toute la file a été tentée, le slot est vidé avec le badge
    /// « Fichier illisible ». Les échecs de plus de 5 min EXPIRENT : un
    /// fichier revenu entre-temps (volume reconnecté, copie terminée) est
    /// retenté au lieu d'être banni pour la session (M6).
    private var failedURLs: [Int: [URL: Date]] = [:]
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
        // M7 : l'attribution source est aussi vidée (croissance non bornée).
        assetSource.removeAll()
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
        // M7 : l'entrée source est nettoyée (fuite sinon).
        assetSource.removeValue(forKey: asset.id)
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
    /// M1 : déduplication sur chemins STANDARDISÉS (la résolution de bookmark
    /// retourne /private/var/... ≠ /var/...) + Set O(1) pour les gros scans.
    private func add(urls: [URL], source: UUID?) {
        var known = Set(assets.map { $0.url.standardizedFileURL.path })
        for url in Self.videoFiles(from: urls) {
            let key = url.standardizedFileURL.path
            if let existing = assets.first(where: { $0.url.standardizedFileURL.path == key }) {
                // M2 : l'asset existait déjà — on attribue la source si elle
                // n'en avait pas (ré-attribution après restauration).
                if let source, assetSource[existing.id] == nil {
                    assetSource[existing.id] = source
                }
                continue
            }
            let asset = VideoAsset(url: url)
            assets.append(asset)
            assetSource[asset.id] = source
            known.insert(key)
            // M7 : tâche auto-nettoyante + capture faible (pas de cycle).
            let task = Task { @MainActor [weak self] in
                await self?.loadMetadata(for: asset)
                self?.metadataTasks[asset.id] = nil
                if !Task.isCancelled {
                    self?.objectWillChange.send()
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
        if sources.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) { return }
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
            // M7 : annule les métadonnées en vol + nettoie la source (fuites).
            metadataTasks[asset.id]?.cancel()
            metadataTasks.removeValue(forKey: asset.id)
            assetSource.removeValue(forKey: asset.id)
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
                // M3 : la source peut avoir été retirée/désactivée pendant le
                // scan — ne ré-ingérer que si elle existe ET est activée
                // (sinon « vidéos fantômes » ré-ajoutées après suppression).
                if self.sources.contains(where: { $0.id == sourceID && $0.enabled }) {
                    self.add(urls: result, source: sourceID)
                    self.sourceFingerprints[sourceID] = Self.modificationDate(of: url)
                }
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
            // B1 : index BORNÉ (UserDefaults peut contenir plus de 5 entrées
            // corrompues → crash index out of range au lancement sinon).
            guard slots.indices.contains(index) else { continue }
            // Comparaison sur chemins standardisés (voir saveNow).
            if let asset = assets.first(where: { $0.url.standardizedFileURL.absoluteString == urlString }) {
                slots[index] = asset
            }
        }
        syncEngine()
        restoreQueues()
        restoreSources()
        // M2 : ré-attribue la source d'origine par préfixe de chemin — sinon
        // removeSource/toggleSource ne suppriment plus rien après un relaunch
        // (les assets restaurés n'ont pas de source, et le dédup empêche le
        // scan de les ré-attribuer).
        for asset in assets where assetSource[asset.id] == nil {
            let path = asset.url.standardizedFileURL.path
            if let source = sources.first(where: { path.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
                assetSource[asset.id] = source.id
            }
        }
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
        // M1 : comparaison sur chemin STANDARDISÉ (bookmarks résolus en
        // /private/... sinon doublon créé).
        if let existing = assets.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            return existing
        }
        add(urls: [url], source: nil)
        return assets.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })
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

        // Feature 3 : en cas d'échec, on mémorise le fichier défaillant avec
        // sa date (M6 : expiration 5 min). Fin naturelle = compteur propre.
        if let failedURL {
            failedURLs[slot, default: [:]][failedURL] = Date()
        } else {
            failedURLs.removeValue(forKey: slot)
        }

        guard let next = next(in: slot) else {
            emptySlotAfterFailure(slot)
            return
        }

        // M6 : purge des échecs anciens — un fichier revenu est RETENTÉ.
        let now = Date()
        let recent = failedURLs[slot, default: [:]].filter { now.timeIntervalSince($0.value) < 300 }
        failedURLs[slot] = recent
        // Toute la file a déjà échoué (récemment) → slot vide + badge.
        if recent.keys.contains(next.url) {
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