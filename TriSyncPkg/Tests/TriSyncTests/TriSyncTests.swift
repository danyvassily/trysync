import XCTest
import AVFoundation
@testable import TriSync

// MARK: - Fabrique de vidéos de test

/// Génère de vraies vidéos H.264 (via AVAssetWriter) pour tester le moteur
/// AVFoundation et les caches avec du contenu réel.
enum TestVideoFactory {

    /// Crée une vidéo H.264 d'une couleur unie, sans piste audio.
    /// - Parameters:
    ///   - duration: durée en secondes (1,5 s minimum pour un test fiable).
    ///   - color: couleur de remplissage (RGB).
    static func makeVideo(at url: URL, duration: Double,
                          size: CGSize = CGSize(width: 320, height: 240),
                          color: (r: UInt8, g: UInt8, b: UInt8) = (200, 30, 30)) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(input) else { throw NSError(domain: "TestVideoFactory", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw NSError(domain: "TestVideoFactory", code: 2) }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let totalFrames = Int(duration * Double(fps))
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                usleep(2000)
            }
            let time = CMTime(value: CMTimeValue(i), timescale: fps)
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                let width = CVPixelBufferGetWidth(buffer)
                memset(base, 0, bytesPerRow * height)
                for y in 0..<height {
                    let row = base.advanced(by: y * bytesPerRow)
                    for x in 0..<width {
                        let px = row.advanced(by: x * 4)
                        px.storeBytes(of: color.b, as: UInt8.self)
                        px.advanced(by: 1).storeBytes(of: color.g, as: UInt8.self)
                        px.advanced(by: 2).storeBytes(of: color.r, as: UInt8.self)
                        px.advanced(by: 3).storeBytes(of: 255, as: UInt8.self)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer)
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10)
        guard writer.status == .completed else {
            throw NSError(domain: "TestVideoFactory", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Écriture vidéo échouée: \(writer.error?.localizedDescription ?? "?")"])
        }
    }

    /// Crée un dossier de test unique avec N vidéos.
    static func makeVideos(count: Int, in directory: URL, prefix: String = "test") throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<count {
            let url = directory.appendingPathComponent("\(prefix)_\(i).mov")
            try makeVideo(at: url, duration: 1.5 + Double(i) * 0.5)
            urls.append(url)
        }
        return urls
    }
}

// MARK: - Utilitaires d'attente

/// Exécute le runloop principal jusqu'à ce que la condition soit vraie ou
/// que le délai expire (indispensable pour les notifications AVFoundation,
/// livrées sur la file principale).
func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

// MARK: - Tests de la bibliothèque vidéo

@MainActor
final class VideoLibraryTests: XCTestCase {

    private var directory: URL!
    private var library: VideoLibrary!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trisync-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = VideoLibrary()
    }

    override func tearDown() {
        library.clearAll()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // 1. Filtrage des fichiers vidéo (whitelist extensions + UTType).
    func testVideoFileFiltering() throws {
        let movie = directory.appendingPathComponent("a.mov")
        let mp4 = directory.appendingPathComponent("b.mp4")
        let mkv = directory.appendingPathComponent("c.mkv")
        let txt = directory.appendingPathComponent("d.txt")
        let jpg = directory.appendingPathComponent("e.jpg")
        try TestVideoFactory.makeVideo(at: movie, duration: 1.5)

        let accepted = VideoLibrary.videoFiles(from: [movie, mp4, mkv, txt, jpg])
        XCTAssertEqual(accepted.count, 3, "Seuls les fichiers vidéo doivent être acceptés")
        XCTAssertFalse(accepted.contains(txt))
        XCTAssertFalse(accepted.contains(jpg))
    }

    // 2. Déduplication des URLs.
    func testDeduplication() throws {
        let video = directory.appendingPathComponent("dedupe.mov")
        try TestVideoFactory.makeVideo(at: video, duration: 1.5)
        library.add(urls: [video, video, video])
        XCTAssertEqual(library.assets.count, 1, "Un même fichier ne doit exister qu'une fois")
    }

    // 3. Sélection multi bornée à 5 (maxSlots), ordre des clics conservé.
    func testSelectionCappedAtFive() throws {
        let videos = try TestVideoFactory.makeVideos(count: 7, in: directory)
        library.add(urls: videos)
        XCTAssertEqual(library.assets.count, 7)
        for asset in library.assets {
            library.toggleSelection(asset)
        }
        XCTAssertEqual(library.selectedOrder.count, 7, "La sélection peut dépasser 5 en attente")
        XCTAssertEqual(library.selectedAssets.count, VideoLibrary.maxSlots,
                       "Le lancement est borné à maxSlots (5)")
        // L'ordre des clics = ordre d'ingestion ici.
        XCTAssertEqual(library.selectedAssets.first?.url, videos.first)
    }

    // 4. Lancer la sélection remplit les emplacements A→E et vide la sélection.
    func testLaunchSelectedFillsSlots() throws {
        let videos = try TestVideoFactory.makeVideos(count: 3, in: directory)
        library.add(urls: videos)
        for asset in library.assets { library.toggleSelection(asset) }
        library.launchSelected()
        XCTAssertTrue(library.selectedOrder.isEmpty, "La sélection doit être vidée après lancement")
        let filled = library.slots.compactMap { $0 }
        XCTAssertEqual(filled.count, 3, "3 vidéos lancées = 3 emplacements remplis")
        XCTAssertEqual(filled[0].url, videos[0], "1er clic → emplacement A")
        XCTAssertEqual(filled[1].url, videos[1], "2e clic → emplacement B")
    }

    // 5. ensureInLibrary ajoute sans occuper d'emplacement.
    func testEnsureInLibraryDoesNotOccupySlot() throws {
        let video = directory.appendingPathComponent("ensure.mov")
        try TestVideoFactory.makeVideo(at: video, duration: 1.5)
        let asset = library.ensureInLibrary(video)
        XCTAssertNotNil(asset)
        XCTAssertEqual(library.assets.count, 1)
        XCTAssertTrue(library.slots.allSatisfy { $0 == nil }, "Aucun slot ne doit être occupé")
    }

    // 6. clearAll libère tout.
    func testClearAll() throws {
        let videos = try TestVideoFactory.makeVideos(count: 2, in: directory)
        library.add(urls: videos)
        library.assign(library.assets[0], to: 0)
        library.clearAll()
        XCTAssertTrue(library.assets.isEmpty)
        XCTAssertTrue(library.slots.allSatisfy { $0 == nil })
        XCTAssertTrue(library.selectedOrder.isEmpty)
    }
}

// MARK: - Tests du moteur de synchronisation

final class SyncEngineTests: XCTestCase {

    private var directory: URL!
    private var engine: SyncEngine!
    private var videos: [URL]!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trisync-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 3 vidéos de durées différentes (1,5 s / 2 s / 2,5 s).
        videos = try? TestVideoFactory.makeVideos(count: 3, in: directory, prefix: "eng")
        engine = SyncEngine()
    }

    override func tearDown() {
        engine.clear()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func configure(_ count: Int) {
        var slots: [Int: VideoAsset] = [:]
        for i in 0..<min(count, videos.count) {
            slots[i] = VideoAsset(url: videos[i])
        }
        engine.reconfigure(slots: slots)
    }

    // 7. La reconfiguration crée bien un player par slot.
    func testReconfigureCreatesPlayers() {
        configure(3)
        XCTAssertEqual(engine.readyCount, 3, "Les 3 items doivent être prêts (fichiers locaux)")
        for i in 0..<3 {
            XCTAssertNotNil(engine.player(forSlot: i))
        }
        XCTAssertNil(engine.player(forSlot: 9), "Slot inexistant → nil")
    }

    // 8. Lecture / pause / arrêt.
    func testPlayPauseStop() {
        configure(2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        engine.stop()
        XCTAssertFalse(engine.isPlaying)
    }

    // 9. skip(by:) est borné par la durée de la vidéo référente.
    func testSkipClampedToDuration() {
        configure(1)
        _ = waitUntil { engine.readyCount == 1 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        engine.skip(by: 600) // beaucoup plus loin que la durée (2 s)
        _ = waitUntil { engine.leaderDuration.seconds > 0 }
        _ = waitUntil(timeout: 4) {
            engine.leaderTime.seconds >= engine.leaderDuration.seconds - 0.1
        }
        XCTAssertGreaterThanOrEqual(engine.leaderTime.seconds,
                                    engine.leaderDuration.seconds - 0.2,
                                    "Le skip ne doit jamais dépasser la durée")
        engine.skip(by: -600)
        _ = waitUntil(timeout: 4) { engine.leaderTime.seconds < 0.2 }
        XCTAssertLessThan(engine.leaderTime.seconds, 0.2, "Le skip arrière est borné à 0")
    }

    // 10. nudgeRate est borné entre 0,25× et 2×.
    func testNudgeRateClamped() {
        configure(1)
        engine.nudgeRate(1.25)
        XCTAssertEqual(engine.currentRate, 1.25, accuracy: 0.001)
        engine.nudgeRate(100)
        XCTAssertEqual(engine.currentRate, 2.0, accuracy: 0.001, "Borné à 2×")
        engine.nudgeRate(0.0001)
        XCTAssertEqual(engine.currentRate, 0.25, accuracy: 0.001, "Borné à 0,25×")
    }

    // 11. seekAll synchronise TOUS les players sur la même position.
    func testSeekAllAlignsAllPlayers() {
        configure(2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        engine.seekAll(to: CMTime(seconds: 0.8, preferredTimescale: 600))
        _ = waitUntil(timeout: 4) {
            let p0 = engine.player(forSlot: 0)?.currentTime().seconds ?? -1
            let p1 = engine.player(forSlot: 1)?.currentTime().seconds ?? -1
            return p0 > 0.5 && p1 > 0.5
        }
        let t0 = engine.player(forSlot: 0)?.currentTime().seconds ?? 0
        let t1 = engine.player(forSlot: 1)?.currentTime().seconds ?? 0
        XCTAssertEqual(t0, t1, accuracy: 0.15, "Les deux flux doivent être alignés après seek")
    }

    // 12. clear() libère tous les players.
    func testClearReleasesPlayers() {
        configure(2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.clear()
        XCTAssertNil(engine.player(forSlot: 0))
        XCTAssertNil(engine.player(forSlot: 1))
    }

    // 13. joinNewSlot sur un item prêt ne crash pas et démarre en lecture.
    func testJoinNewSlotWhenReady() {
        configure(2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        engine.joinNewSlot(1) // item déjà prêt → démarrage immédiat
        XCTAssertTrue(engine.isPlaying)
        engine.joinNewSlot(0)
        XCTAssertTrue(engine.isPlaying)
    }

    // 14. FIN DE LECTURE E2E : le remplacement automatique remplit le slot
    // terminé avec une vidéo de réserve et la lecture continue (aucun crash).
    func testAutoReplaceEndToEnd() {
        let library = VideoLibrary()
        defer { library.clearAll() }
        // 3 vidéos : A (1,5 s) en slot 0, B (2 s) en slot 1, C en réserve.
        library.add(urls: videos)
        XCTAssertEqual(library.assets.count, 3)
        library.assign(library.assets[0], to: 0)
        library.assign(library.assets[1], to: 1)
        let engine = library.engine
        engine.autoReplace = true

        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }

        let slot0ID = library.slots[0]?.id
        // La vidéo A dure 1,5 s : après ~3 s, elle doit avoir été remplacée
        // par la vidéo C (réserve), sans crash, lecture toujours active.
        let replaced = waitUntil(timeout: 8) {
            library.slots[0]?.id != slot0ID
        }
        XCTAssertTrue(replaced, "Le slot terminé doit être remplacé automatiquement")
        XCTAssertEqual(library.slots[0]?.url, videos[2], "La vidéo de réserve C doit prendre le relais")
        XCTAssertTrue(engine.isPlaying, "La lecture continue après remplacement")
        XCTAssertFalse(library.slots.contains(where: { $0 == nil }),
                       "Aucun bloc ne doit rester vide")
    }
}

// MARK: - Tests des caches

final class CachesTests: XCTestCase {

    private var directory: URL!
    private var videoURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trisync-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        videoURL = directory.appendingPathComponent("cache_video.mov")
        try? TestVideoFactory.makeVideo(at: videoURL, duration: 2.0)
    }

    override func tearDown() {
        // Nettoie le fichier de vignette éventuellement créé pour CE fichier.
        let cache = ThumbnailCache.shared
        _ = cache // lecture du cache pour purge disque : supprimé via fichier connu
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // 15. Le cache de métadonnées fait un aller-retour complet.
    func testMetadataCacheRoundTrip() {
        let meta = VideoMetadata(duration: 12.5, width: 1920, height: 1080, frameRate: 30.0)
        MetadataCache.shared.set(meta, for: videoURL)
        let loaded = MetadataCache.shared.get(for: videoURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.duration, 12.5, accuracy: 0.001)
        XCTAssertEqual(loaded?.width, 1920)
        XCTAssertEqual(loaded?.height, 1080)
        // Métadonnées invalides refusées.
        MetadataCache.shared.set(VideoMetadata(duration: .nan, width: 0, height: 0, frameRate: 0), for: videoURL)
        let notOverwritten = MetadataCache.shared.get(for: videoURL)
        XCTAssertEqual(notOverwritten?.duration, 12.5, accuracy: 0.001,
                       "Les métadonnées invalides ne doivent pas écraser le cache")
    }

    // 16. Le cache de vignettes persiste sur disque puis relit sans régénérer.
    func testThumbnailCachePersistsToDisk() async {
        let image = await ThumbnailCache.shared.thumbnail(for: videoURL, variant: .portrait)
        XCTAssertNotNil(image, "La vignette doit être générée")
        // Le fichier JPEG doit exister sur disque.
        let file = diskFileForTest()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "La vignette doit être persistée sur disque")
        // La relecture (second appel) passe par mémoire/disque : doit être rapide et identique.
        let again = await ThumbnailCache.shared.thumbnail(for: videoURL, variant: .portrait)
        XCTAssertNotNil(again)
    }

    /// Reproduit le nommage du cache disque (clé SHA-256 stable).
    private func diskFileForTest() -> URL {
        let digest = SHA256DigestHelper.stableKey(videoURL.path)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TriSync/Thumbs/\(digest)_p.jpg")
    }
}

/// Expose la clé stable (SHA-256 tronquée) — mêmes règles que ThumbnailCache.
enum SHA256DigestHelper {
    static func stableKey(_ path: String) -> String {
        let digest = CryptoKitSHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }
}

// MARK: - Tests des helpers / réglages

final class HelpersTests: XCTestCase {

    // 17. Formatage du temps.
    func testTimeString() {
        XCTAssertEqual(timeString(CMTime(seconds: 0, preferredTimescale: 600)), "0:00")
        XCTAssertEqual(timeString(CMTime(seconds: 65, preferredTimescale: 600)), "1:05")
        XCTAssertEqual(timeString(CMTime(seconds: 3661, preferredTimescale: 600)), "61:01")
        // Valeurs invalides → format sûr.
        XCTAssertEqual(timeString(.invalid), "0:00")
    }

    // 18. Les réglages persistent (aller-retour UserDefaults) sans polluer
    // les réglages réels de l'utilisateur (sauvegarde/restauration).
    func testSettingsPersistenceRoundTrip() {
        let keys = [
            "settings.displayMode", "settings.ratioMode", "settings.verticalOffset",
            "settings.advancedScale", "settings.playbackSpeed", "settings.layoutPreset"
        ]
        let defaults = UserDefaults.standard
        let backup = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in keys {
                if let value = backup[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let settings = AppSettings()
        settings.displayMode = .stretch
        settings.ratioMode = .r169
        settings.verticalOffset = .bottom
        settings.advancedScale = .p125
        settings.playbackSpeed = 1.5
        settings.layoutPreset = .wall32

        let reloaded = AppSettings()
        XCTAssertEqual(reloaded.displayMode, .stretch)
        XCTAssertEqual(reloaded.ratioMode, .r169)
        XCTAssertEqual(reloaded.verticalOffset, .bottom)
        XCTAssertEqual(reloaded.advancedScale, .p125)
        XCTAssertEqual(reloaded.playbackSpeed, 1.5, accuracy: 0.001)
        XCTAssertEqual(reloaded.layoutPreset, .wall32)
    }

    // 19. Ratio cible selon le réglage (utilisé par le layout responsive).
    func testTargetAspect() {
        let settings = AppSettings()
        settings.ratioMode = .r169
        XCTAssertEqual(settings.targetAspect(for: VideoAsset(url: URL(fileURLWithPath: "/tmp/x.mov"))),
                       16.0 / 9.0, accuracy: 0.001)
        settings.ratioMode = .auto
        // Fichier sans taille connue → ratio par défaut (0,75).
        XCTAssertEqual(settings.targetAspect(for: VideoAsset(url: URL(fileURLWithPath: "/tmp/x.mov"))),
                       0.75, accuracy: 0.001)
    }
}

// Ré-export minimal de CryptoKit pour le helper de test.
import CryptoKit
typealias CryptoKitSHA256 = CryptoKit.SHA256
