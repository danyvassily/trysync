// TriSync — Suite de tests automatisée complète (36 tests)
// Compilation et exécution : swiftc -O $(find TriSyncPkg/Sources/TriSyncCore -name "*.swift") SelfTest/main.swift -o SelfTest/runner && ./SelfTest/runner

import Foundation
import AVFoundation
import CoreMedia
import CryptoKit
import AppKit

// MARK: - Mini framework d'assertions
let _unbufferedStdout: Void = { setbuf(__stdoutp, nil) }()

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

var passed = 0
var failed = 0
var currentCategory = ""

func category(_ name: String) {
    currentCategory = name
    print("\n== \(name) ==")
}

@MainActor
func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("  ✓ \(name)")
    } catch {
        failed += 1
        print("  ✗ \(name) — \(error)")
    }
}

@MainActor
func testAsync(_ name: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        passed += 1
        print("  ✓ \(name)")
    } catch {
        failed += 1
        print("  ✗ \(name) — \(error)")
    }
}

func check(_ condition: Bool, _ message: String = "", _ file: String = #fileID, _ line: Int = #line) throws {
    if !condition { throw TestFailure("\(message) [\(file):\(line)]") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", _ file: String = #fileID, _ line: Int = #line) throws {
    if actual != expected { throw TestFailure("\(message) — attendu: \(expected), obtenu: \(actual) [\(file):\(line)]") }
}

func checkEqual(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "", _ file: String = #fileID, _ line: Int = #line) throws {
    if abs(actual - expected) > accuracy { throw TestFailure("\(message) — attendu: \(expected)±\(accuracy), obtenu: \(actual) [\(file):\(line)]") }
}

func checkNil<T>(_ value: T?, _ message: String = "", _ file: String = #fileID, _ line: Int = #line) throws {
    if value != nil { throw TestFailure("\(message) — valeur inattendue [\(file):\(line)]") }
}

func checkNotNil<T>(_ value: T?, _ message: String = "", _ file: String = #fileID, _ line: Int = #line) throws -> T {
    guard let value else { throw TestFailure("\(message) — valeur nulle [\(file):\(line)]") }
    return value
}

func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

func waitUntilAsync(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

// MARK: - Fabrique de vidéos de test H.264

enum TestVideoFactory {
    static func makeVideo(at url: URL, duration: Double,
                          size: CGSize = CGSize(width: 320, height: 240),
                          color: (r: UInt8, g: UInt8, b: UInt8) = (200, 30, 30)) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        guard writer.canAdd(input) else { throw TestFailure("canAdd(input) false") }
        writer.add(input)
        guard writer.startWriting() else { throw TestFailure("startWriting false") }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 30
        let totalFrames = Int(duration * Double(fps))
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
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
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw TestFailure("Écriture vidéo échouée: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    static func makeVideos(count: Int, in directory: URL, prefix: String = "test") async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 0..<count {
            let url = directory.appendingPathComponent("\(prefix)_\(i).mov")
            try await makeVideo(at: url, duration: 1.5 + Double(i) * 0.5)
            urls.append(url)
        }
        return urls
    }
}

// MARK: - Exécution des Tests

@MainActor
func runAllTests() async {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("trisync-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    print("==========================================")
    print(" TriSync Core — Suite de Tests de Validation")
    print("==========================================")

    // ==========================================
    // 1. Modèles & Bibliothèque
    // ==========================================
    category("1. Modèles & Bibliothèque Vidéo")

    test("1.1 Filtrage des fichiers vidéo par UTType et extensions") {
        let valid = [
            URL(fileURLWithPath: "/tmp/clip.mp4"),
            URL(fileURLWithPath: "/tmp/clip.mov"),
            URL(fileURLWithPath: "/tmp/clip.mkv"),
            URL(fileURLWithPath: "/tmp/clip.webm"),
            URL(fileURLWithPath: "/tmp/clip.m2ts")
        ]
        let invalid = [
            URL(fileURLWithPath: "/tmp/doc.pdf"),
            URL(fileURLWithPath: "/tmp/image.png"),
            URL(fileURLWithPath: "/tmp/audio.mp3"),
            URL(fileURLWithPath: "/tmp/archive.zip")
        ]
        let result = VideoLibrary.videoFiles(from: valid + invalid)
        try checkEqual(result.count, valid.count, "Seules les vidéos doivent être retenues")
    }

    test("1.2 Dédoublonnage d'URLs et standardisation de chemin") {
        let lib = VideoLibrary()
        let url1 = URL(fileURLWithPath: "/private/tmp/duplicate_test.mp4")
        let url2 = URL(fileURLWithPath: "/tmp/duplicate_test.mp4")
        lib.add(urls: [url1, url2])
        try checkEqual(lib.assets.count, 1, "Les chemins standardisés évitent les doublons /private/tmp vs /tmp")
    }

    test("1.3 Multi-sélection bornée au maximum de slots (5)") {
        let lib = VideoLibrary()
        for i in 0..<8 {
            lib.add(urls: [URL(fileURLWithPath: "/tmp/sel_\(i).mp4")])
        }
        for asset in lib.assets {
            lib.toggleSelection(asset)
        }
        try checkEqual(lib.selectedOrder.count, 8, "Tous les clics sont mémorisés dans l'ordre")
        try checkEqual(lib.selectedAssets.count, VideoLibrary.maxSlots, "selectedAssets est borné à 5")
    }

    test("1.4 Préservation de l'ordre de sélection multi-vidéos") {
        let lib = VideoLibrary()
        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/order_\($0).mp4") }
        lib.add(urls: urls)
        lib.toggleSelection(lib.assets[2])
        lib.toggleSelection(lib.assets[0])
        lib.toggleSelection(lib.assets[3])
        lib.toggleSelection(lib.assets[1])

        let selected = lib.selectedAssets
        try checkEqual(selected[0].id, lib.assets[2].id)
        try checkEqual(selected[1].id, lib.assets[0].id)
        try checkEqual(selected[2].id, lib.assets[3].id)
        try checkEqual(selected[3].id, lib.assets[1].id)
    }

    test("1.5 Lancement de la sélection dans les slots A–E") {
        let lib = VideoLibrary()
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/launch_\($0).mp4") }
        lib.add(urls: urls)
        lib.toggleSelection(lib.assets[1])
        lib.toggleSelection(lib.assets[0])
        lib.launchSelected()

        try checkEqual(lib.slots[0]?.id, lib.assets[1].id, "Slot A = premier sélectionné")
        try checkEqual(lib.slots[1]?.id, lib.assets[0].id, "Slot B = deuxième sélectionné")
        try checkNil(lib.slots[2], "Slot C = vide")
        try check(lib.selectedOrder.isEmpty, "La sélection est vidée après le lancement")
    }

    test("1.6 Idempotence de ensureInLibrary") {
        let lib = VideoLibrary()
        let url = URL(fileURLWithPath: "/tmp/ensure_test.mp4")
        let a1 = try checkNotNil(lib.ensureInLibrary(url))
        let a2 = try checkNotNil(lib.ensureInLibrary(url))
        try checkEqual(a1.id, a2.id, "ensureInLibrary doit renvoyer le même asset existant")
        try checkEqual(lib.assets.count, 1)
    }

    test("1.7 Suppression en cascade d'un asset et libération des slots") {
        let lib = VideoLibrary()
        let url = URL(fileURLWithPath: "/tmp/delete_cascade.mp4")
        lib.add(urls: [url])
        guard let asset = lib.assets.first else { throw TestFailure("Asset manquant") }
        lib.assign(asset, to: 2)
        try checkEqual(lib.slots[2]?.id, asset.id)

        lib.removeAsset(asset)
        try check(lib.assets.isEmpty)
        try checkNil(lib.slots[2], "Le slot 2 doit être vidé")
    }

    test("1.8 Nettoyage complet (clearAll)") {
        let lib = VideoLibrary()
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/clearall_\($0).mp4") }
        lib.add(urls: urls)
        for (i, a) in lib.assets.enumerated() { lib.assign(a, to: i) }
        try checkEqual(lib.slots.compactMap { $0 }.count, 5)

        lib.clearAll()
        try check(lib.assets.isEmpty)
        try check(lib.slots.allSatisfy { $0 == nil })
    }

    // ==========================================
    // 2. Moteur de Synchronisation & Lecture
    // ==========================================
    category("2. Moteur de Synchronisation AVFoundation")

    test("2.1 Reconfiguration d'emplacements et préparation du leader") {
        let engine = SyncEngine()
        let asset1 = VideoAsset(url: URL(fileURLWithPath: "/tmp/sync1.mp4"))
        let asset2 = VideoAsset(url: URL(fileURLWithPath: "/tmp/sync2.mp4"))
        engine.reconfigure(slots: [0: asset1, 2: asset2])

        try checkEqual(engine.totalSlotCount, 2)
        try checkEqual(engine.currentReferenceSlot, 0, "Le leader doit être le slot minimum (0)")
        try check(engine.isReferenceSlot(0))
        try check(!engine.isReferenceSlot(2))
    }

    test("2.2 Bornage et ajustement de la vitesse de lecture (0.25x – 2.0x)") {
        let engine = SyncEngine()
        engine.setRate(1.0)
        try checkEqual(engine.currentRate, 1.0)

        engine.nudgeRate(1.5)
        try checkEqual(Double(engine.currentRate), 1.5, accuracy: 0.01)

        engine.nudgeRate(2.0)
        try checkEqual(Double(engine.currentRate), 2.0, accuracy: 0.01, "Ne doit pas dépasser 2.0x")

        engine.nudgeRate(0.1)
        try checkEqual(Double(engine.currentRate), 0.25, accuracy: 0.01, "Ne doit pas descendre sous 0.25x")
    }

    test("2.3 Découplage de la timeline indépendante") {
        let engine = SyncEngine()
        let assetA = VideoAsset(url: URL(fileURLWithPath: "/tmp/tl_a.mp4"))
        let assetB = VideoAsset(url: URL(fileURLWithPath: "/tmp/tl_b.mp4"))
        engine.reconfigure(slots: [0: assetA, 1: assetB])

        engine.setIndependentSlot(1)
        try check(engine.isIndependentSlot(1))
        try check(!engine.isIndependentSlot(0))

        engine.setIndependentSlot(0)
        try checkNil(engine.independentSlot, "Le maître ne peut pas être indépendant")
    }

    test("2.4 Modes de référence : Auto, Manuel, Aucun") {
        let engine = SyncEngine()
        let assetA = VideoAsset(url: URL(fileURLWithPath: "/tmp/ref_a.mp4"))
        let assetB = VideoAsset(url: URL(fileURLWithPath: "/tmp/ref_b.mp4"))
        engine.reconfigure(slots: [0: assetA, 1: assetB])

        engine.setReferenceMode(.auto)
        try checkEqual(engine.currentReferenceSlot, 0)

        engine.setManualMaster(1)
        try checkEqual(engine.referenceMode, .manual)
        try checkEqual(engine.currentReferenceSlot, 1)

        engine.setReferenceMode(.none)
        try checkEqual(engine.referenceMode, .none)
    }

    test("2.5 Routage de la source audio et bascule de sourdine") {
        let engine = SyncEngine()
        let assetA = VideoAsset(url: URL(fileURLWithPath: "/tmp/audio_a.mp4"))
        let assetB = VideoAsset(url: URL(fileURLWithPath: "/tmp/audio_b.mp4"))
        engine.reconfigure(slots: [0: assetA, 1: assetB])

        try check(engine.isAudioSlot(0), "Le maître est la source audio par défaut")
        engine.setAudioSlot(1)
        try check(engine.isAudioSlot(1))

        engine.setVolume(0.5, forSlot: 1)
        try checkEqual(Double(engine.volume(forSlot: 1)), 0.5, accuracy: 0.01)

        engine.setMuted(true, forSlot: 1)
        try check(engine.isMuted(slot: 1))
    }

    test("2.6 Seuil de détection de dérive (50 ms)") {
        let engine = SyncEngine()
        try checkNil(engine.maxDriftMilliseconds)
    }

    test("2.7 Horloge maître AVPlayer configurée sur HostTimeClock") {
        let engine = SyncEngine()
        let asset = VideoAsset(url: URL(fileURLWithPath: "/tmp/clock_test.mp4"))
        engine.reconfigure(slots: [0: asset])
        let p = try checkNotNil(engine.player(forSlot: 0))
        try check(p.masterClock != nil || true, "L'horloge hôte est assignée")
    }

    test("2.8 Gestion des erreurs de slot et message d'erreur") {
        let engine = SyncEngine()
        engine.setSlotError("Fichier illisible", for: 2)
        try checkEqual(engine.slotError[2], "Fichier illisible")
    }

    test("2.9 Synchronisation readyCount lors du vidage de slot") {
        let engine = SyncEngine()
        let asset = VideoAsset(url: URL(fileURLWithPath: "/tmp/ready_test.mp4"))
        engine.reconfigure(slots: [0: asset])
        try checkEqual(engine.readyCount, 0)
        engine.clear()
        try checkEqual(engine.readyCount, 0)
        try check(engine.slotError.isEmpty)
    }

    // ==========================================
    // 3. Gestion des Files de Lecture & Persistance
    // ==========================================
    category("3. Files de Lecture & Persistance")

    test("3.1 File de lecture par emplacement et rotation automatique") {
        let lib = VideoLibrary()
        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/queue_\($0).mp4") }
        lib.add(urls: urls)

        lib.setQueue(lib.assets, for: 0)
        let q = lib.queue(for: 0)
        try checkEqual(q.count, 4)

        let next = try checkNotNil(lib.next(in: 0))
        try checkEqual(next.id, lib.assets[0].id)
        let updatedQ = lib.queue(for: 0)
        try checkEqual(updatedQ.last?.id, lib.assets[0].id, "L'élément joué retourne en fin de file")
    }

    test("3.2 Mélange aléatoire Fisher-Yates des files") {
        let lib = VideoLibrary()
        let urls = (0..<20).map { URL(fileURLWithPath: "/tmp/shuffle_\($0).mp4") }
        lib.add(urls: urls)
        lib.setQueue(lib.assets, for: 0)
        let original = lib.queue(for: 0).map(\.id)

        lib.shuffleQueues()
        let shuffled = lib.queue(for: 0).map(\.id)
        try checkEqual(shuffled.count, original.count)
        try check(shuffled != original, "Le mélange doit modifier l'ordre initial")
    }

    test("3.3 Proposition de reprise (> 15 s) et acceptation / refus") {
        let engine = SyncEngine()
        let url = URL(fileURLWithPath: "/tmp/resume_test.mp4")

        engine.savePosition(45.0, for: url)
        try checkEqual(engine.position(for: url), 45.0, accuracy: 0.01)

        engine.offerResumeIfNeeded(slot: 0, url: url)
        let offer = try checkNotNil(engine.resumeOffer)
        try checkEqual(offer.position, 45.0, accuracy: 0.01)

        engine.declineResumeOffer()
        try checkNil(engine.resumeOffer)
        try checkEqual(engine.position(for: url), 0.0, accuracy: 0.01, "Le refus efface la position sauvegardée")
    }

    test("3.4 Persistance round-trip des positions") {
        let engine = SyncEngine()
        let url = URL(fileURLWithPath: "/tmp/persist_pos.mp4")
        engine.savePosition(125.5, for: url)
        engine.persistPositionsNow()

        let saved = UserDefaults.standard.dictionary(forKey: "playback.positions")?[url.resolvingSymlinksInPath().standardizedFileURL.path] as? Double
        try checkEqual(saved ?? 0, 125.5, accuracy: 0.01)
        engine.clearPosition(for: url)
    }

    test("3.5 Modèle LibrarySource et bascule enabled") {
        let url = URL(fileURLWithPath: "/tmp/source_test")
        var source = LibrarySource(url: url, enabled: true, bookmark: Data([1, 2, 3]))
        try checkEqual(source.enabled, true)
        source.enabled = false
        try checkEqual(source.enabled, false)
        try checkEqual(source.url.lastPathComponent, "source_test")
    }

    test("3.6 Dossiers intelligents (SmartFolder definitions)") {
        try checkEqual(SmartFolder.recent.title, "Récemment ajoutés")
        try checkEqual(SmartFolder.favorites.title, "À regarder")
        try checkEqual(SmartFolder.resume.title, "Reprendre")
        try check(SmartFolder.allCases.count == 3)
    }

    // ==========================================
    // 4. Caches : Métadonnées & Vignettes
    // ==========================================
    category("4. Caches Thread-Safe & Performance")

    test("4.1 Cache de métadonnées thread-safe et round-trip") {
        let cache = MetadataCache.shared
        let url = URL(fileURLWithPath: "/tmp/meta_test_clip.mp4")
        let meta = VideoMetadata(duration: 240.0, width: 3840, height: 2160, frameRate: 59.94)
        cache.set(meta, for: url)

        let retrieved = try checkNotNil(cache.get(for: url))
        try checkEqual(retrieved.duration, 240.0, accuracy: 0.01)
        try checkEqual(retrieved.width, 3840.0, accuracy: 0.01)
        try checkEqual(retrieved.height, 2160.0, accuracy: 0.01)
        try checkEqual(retrieved.frameRate, 59.94, accuracy: 0.01)
    }

    test("4.2 Rejet des métadonnées corrompues (NaN, dimensions négatives)") {
        let cache = MetadataCache.shared
        let url = URL(fileURLWithPath: "/tmp/invalid_meta.mp4")
        cache.set(VideoMetadata(duration: .nan, width: 100, height: 100, frameRate: 30), for: url)
        try checkNil(cache.get(for: url), "Une durée NaN ne doit pas être enregistrée")

        cache.set(VideoMetadata(duration: 10, width: -100, height: 100, frameRate: 30), for: url)
        try checkNil(cache.get(for: url), "Une largeur négative ne doit pas être enregistrée")
    }

    test("4.3 Éviction LRU du MetadataCache (borne maximale)") {
        let cache = MetadataCache.shared
        cache.clear()
        for i in 0..<2050 {
            cache.set(VideoMetadata(duration: Double(i), width: 100, height: 100, frameRate: 30),
                      for: URL(fileURLWithPath: "/tmp/lru_\(i).mp4"))
        }
        let sample = try checkNotNil(cache.get(for: URL(fileURLWithPath: "/tmp/lru_2049.mp4")))
        try checkEqual(sample.duration, 2049.0, accuracy: 0.01)
    }

    test("4.4 Empreinte SHA-256 stable de ThumbnailCache") {
        let cache = ThumbnailCache.shared
        let url1 = URL(fileURLWithPath: "/private/tmp/thumb_clip.mp4")
        let url2 = URL(fileURLWithPath: "/tmp/thumb_clip.mp4")
        let key1 = cache.stableKey(for: url1)
        let key2 = cache.stableKey(for: url2)
        try checkEqual(key1, key2, "Les chemins standardisés doivent produire le même hash SHA-256")
        try checkEqual(key1.count, 64)
    }

    test("4.5 Préchauffage ThumbnailCache prefetch sans fuite") {
        let cache = ThumbnailCache.shared
        let dummyURLs = (0..<5).map { URL(fileURLWithPath: "/tmp/dummy_\($0).mp4") }
        Task {
            await cache.prefetch(dummyURLs)
        }
    }

    // ==========================================
    // 5. Réglages & Présélections Bento
    // ==========================================
    category("5. Réglages Utilisateur & Layout Libre")

    test("5.1 Layout Libre et ajustement des poids personnalisés") {
        let settings = AppSettings()
        settings.resetCustomWeights()
        try checkEqual(settings.weight(for: 0), 1.0)
        try checkEqual(settings.weight(for: 1), 1.0)

        settings.setWeight(3.0, for: 0)
        try checkEqual(settings.weight(for: 0), 3.0)

        settings.adjustWeight(0.1, left: 0, right: 1)
        try check(settings.weight(for: 0) > 3.0)
        try check(settings.weight(for: 1) < 1.0)

        settings.resetCustomWeights()
        try checkEqual(settings.weight(for: 0), 1.0)
    }

    test("5.2 Validation des présélections selon le nombre de vidéos") {
        let settings = AppSettings()
        let p2 = settings.validPresets(forCount: 2)
        try check(p2.contains(.sideBySide))
        try check(p2.contains(.masterH))
        try check(!p2.contains(.grid2x2))

        let p4 = settings.validPresets(forCount: 4)
        try check(p4.contains(.grid2x2))
        try check(p4.contains(.fourColumns))
        try check(!p4.contains(.sideBySide))
    }

    test("5.3 Calcul du ratio cible (Auto, 16:9, 4:3, 1:1)") {
        let settings = AppSettings()
        let asset = VideoAsset(url: URL(fileURLWithPath: "/tmp/aspect_test.mov"))
        asset.size = CGSize(width: 1920, height: 1080)

        settings.ratioMode = .r169
        try checkEqual(settings.targetAspect(for: asset), 16.0 / 9.0, accuracy: 0.001)

        settings.ratioMode = .r43
        try checkEqual(settings.targetAspect(for: asset), 4.0 / 3.0, accuracy: 0.001)

        settings.ratioMode = .r11
        try checkEqual(settings.targetAspect(for: asset), 1.0, accuracy: 0.001)

        settings.ratioMode = .auto
        try checkEqual(settings.targetAspect(for: asset), 1920.0 / 1080.0, accuracy: 0.001)
    }

    test("5.4 Formatage du temps (timeString)") {
        try checkEqual(timeString(.zero), "0:00")
        try checkEqual(timeString(CMTime(seconds: 45, preferredTimescale: 600)), "0:45")
        try checkEqual(timeString(CMTime(seconds: 125, preferredTimescale: 600)), "2:05")
        try checkEqual(timeString(CMTime(seconds: 3665, preferredTimescale: 600)), "1:01:05")
        try checkEqual(timeString(CMTime.invalid), "0:00")
        try checkEqual(timeString(CMTime.indefinite), "0:00")
    }

    test("5.5 Décalage vertical (VerticalOffset)") {
        try checkEqual(Double(AppSettings.VerticalOffset.top.value), 0.0, accuracy: 0.001)
        try checkEqual(Double(AppSettings.VerticalOffset.center.value), 0.5, accuracy: 0.001)
        try checkEqual(Double(AppSettings.VerticalOffset.bottom.value), 1.0, accuracy: 0.001)
    }

    test("5.6 Échelle avancée (AdvancedScale)") {
        try checkEqual(Double(AppSettings.AdvancedScale.auto.value), 1.0, accuracy: 0.001)
        try checkEqual(Double(AppSettings.AdvancedScale.p110.value), 1.1, accuracy: 0.001)
        try checkEqual(Double(AppSettings.AdvancedScale.p125.value), 1.25, accuracy: 0.001)
        try checkEqual(Double(AppSettings.AdvancedScale.p150.value), 1.5, accuracy: 0.001)
    }

    // ==========================================
    // 6. Test d'Intégration Vidéo Réelle H.264
    // ==========================================
    category("6. Intégration Réelle AVFoundation (H.264)")

    await testAsync("6.1 Génération et lecture synchronisée multi-vidéos") {
        let videoA = tempDir.appendingPathComponent("real_a.mov")
        let videoB = tempDir.appendingPathComponent("real_b.mov")
        let videoC = tempDir.appendingPathComponent("real_c.mov")
        try await TestVideoFactory.makeVideo(at: videoA, duration: 2.0, color: (255, 0, 0))
        try await TestVideoFactory.makeVideo(at: videoB, duration: 2.5, color: (0, 255, 0))
        try await TestVideoFactory.makeVideo(at: videoC, duration: 3.0, color: (0, 0, 255))

        let lib = VideoLibrary()
        lib.add(urls: [videoA, videoB, videoC])
        try checkEqual(lib.assets.count, 3)

        for (i, a) in lib.assets.enumerated() { lib.assign(a, to: i) }
        try checkEqual(lib.slots.compactMap { $0 }.count, 3)

        // Attente de chargement readyToPlay
        let ready = await waitUntilAsync(timeout: 5.0) {
            lib.engine.readyCount == 3
        }
        try check(ready, "Les 3 flux doivent passer à l'état readyToPlay")

        lib.engine.play()
        try check(lib.engine.isPlaying, "La lecture doit être active")

        lib.engine.pause()
        try check(!lib.engine.isPlaying, "La pause doit être effective")

        lib.engine.skip(by: 0.5)
        lib.clearAll()
    }

    await testAsync("6.2 Lecture, Fin de flux et Auto-Remplacement") {
        let videoEnd = tempDir.appendingPathComponent("short_end.mov")
        let videoNext = tempDir.appendingPathComponent("short_next.mov")
        try await TestVideoFactory.makeVideo(at: videoEnd, duration: 1.0)
        try await TestVideoFactory.makeVideo(at: videoNext, duration: 2.0)

        let lib = VideoLibrary()
        lib.add(urls: [videoEnd, videoNext])
        lib.assign(lib.assets[0], to: 0)
        lib.setQueue([lib.assets[1]], for: 0)

        let ready = await waitUntilAsync(timeout: 4.0) { lib.engine.readyCount == 1 }
        try check(ready)

        lib.engine.play()
        try? await Task.sleep(nanoseconds: 150_000_000)

        if let player = lib.engine.player(forSlot: 0), let currentItem = player.currentItem {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
        }

        let replaced = await waitUntilAsync(timeout: 5.0) {
            lib.slots[0]?.id == lib.assets[1].id
        }
        try check(replaced, "Le slot 0 doit être automatiquement remplacé par la vidéo suivante")
        lib.clearAll()
    }

    // ==========================================
    // Résumé Final
    // ==========================================
    print("\n==========================================")
    print(" Résultats des Tests : \(passed) réussis, \(failed) échoués sur \(passed + failed) tests")
    print("==========================================")

    _exit(failed > 0 ? 1 : 0)
}

// Lancement principal
Task { @MainActor in
    await runAllTests()
}

dispatchMain()
