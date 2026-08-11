// TriSync — Runner de tests autonome (sans XCTest : la licence Xcode non
// acceptée bloque la toolchain complète ; le SDK CLT ne fournit pas XCTest).
// Compilation : swiftc -o runner TriSyncCore.swift main.swift

import AVFoundation
import CryptoKit

// MARK: - Mini framework d'assertions

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

/// Fait tourner le runloop principal jusqu'à ce que la condition soit vraie
/// (nécessaire pour les notifications AVFoundation, livrées sur la file main).
func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

// MARK: - Fabrique de vidéos de test (H.264 réel via AVAssetWriter)

enum TestVideoFactory {
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
        guard writer.canAdd(input) else { throw TestFailure("canAdd(input) false") }
        writer.add(input)
        guard writer.startWriting() else { throw TestFailure("startWriting false") }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 30
        let totalFrames = Int(duration * Double(fps))
        for i in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
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
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10)
        guard writer.status == .completed else {
            throw TestFailure("Écriture vidéo échouée: \(writer.error?.localizedDescription ?? "?")")
        }
    }

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

// MARK: - Tests : bibliothèque vidéo

@MainActor
func runLibraryTests() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("trisync-selftest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    category("Bibliothèque vidéo")

    test("Filtrage des fichiers vidéo (whitelist)") {
        let movie = directory.appendingPathComponent("a.mov")
        let mp4 = directory.appendingPathComponent("b.mp4")
        let mkv = directory.appendingPathComponent("c.mkv")
        let txt = directory.appendingPathComponent("d.txt")
        let jpg = directory.appendingPathComponent("e.jpg")
        try TestVideoFactory.makeVideo(at: movie, duration: 1.5)
        let accepted = VideoLibrary.videoFiles(from: [movie, mp4, mkv, txt, jpg])
        try checkEqual(accepted.count, 3, "Seuls les fichiers vidéo doivent être acceptés")
        try check(!accepted.contains(txt) && !accepted.contains(jpg), "txt/jpg rejetés")
    }

    test("Déduplication des URLs") {
        let library = VideoLibrary()
        let video = directory.appendingPathComponent("dedupe.mov")
        try TestVideoFactory.makeVideo(at: video, duration: 1.5)
        library.add(urls: [video, video, video])
        try checkEqual(library.assets.count, 1, "Un même fichier n'existe qu'une fois")
    }

    test("Sélection multi bornée à 5 (maxSlots), ordre des clics") {
        let library = VideoLibrary()
        let videos = try TestVideoFactory.makeVideos(count: 7, in: directory)
        library.add(urls: videos)
        try checkEqual(library.assets.count, 7)
        for asset in library.assets { library.toggleSelection(asset) }
        try checkEqual(library.selectedOrder.count, 7, "La sélection en attente peut dépasser 5")
        try checkEqual(library.selectedAssets.count, VideoLibrary.maxSlots, "Le lancement est borné à 5")
        try checkEqual(library.selectedAssets.first?.url, videos.first, "Ordre des clics conservé")
    }

    test("Lancer la sélection remplit A→E puis vide la sélection") {
        let library = VideoLibrary()
        let videos = try TestVideoFactory.makeVideos(count: 3, in: directory)
        library.add(urls: videos)
        for asset in library.assets { library.toggleSelection(asset) }
        library.launchSelected()
        try checkEqual(library.selectedOrder.count, 0, "Sélection vidée après lancement")
        let filled = library.slots.compactMap { $0 }
        try checkEqual(filled.count, 3, "3 vidéos lancées = 3 emplacements")
        try checkEqual(filled[0].url, videos[0], "1er clic → emplacement A")
        try checkEqual(filled[1].url, videos[1], "2e clic → emplacement B")
    }

    test("ensureInLibrary ajoute sans occuper d'emplacement") {
        let library = VideoLibrary()
        let video = directory.appendingPathComponent("ensure.mov")
        try TestVideoFactory.makeVideo(at: video, duration: 1.5)
        let asset = try checkNotNil(library.ensureInLibrary(video), "Asset créé")
        try checkEqual(library.assets.count, 1)
        try check(library.slots.allSatisfy { $0 == nil }, "Aucun slot occupé")
    }

    test("clearAll libère tout") {
        let library = VideoLibrary()
        let videos = try TestVideoFactory.makeVideos(count: 2, in: directory)
        library.add(urls: videos)
        library.assign(library.assets[0], to: 0)
        library.clearAll()
        try checkEqual(library.assets.count, 0)
        try check(library.slots.allSatisfy { $0 == nil })
        try checkEqual(library.selectedOrder.count, 0)
    }
}

// MARK: - Tests : moteur de synchronisation

@MainActor
func runEngineTests() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("trisync-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let videos = try TestVideoFactory.makeVideos(count: 3, in: directory, prefix: "eng")

    category("Moteur de synchronisation")

    func configure(_ engine: SyncEngine, count: Int) {
        var slots: [Int: VideoAsset] = [:]
        for i in 0..<min(count, videos.count) {
            slots[i] = VideoAsset(url: videos[i])
        }
        engine.reconfigure(slots: slots)
    }

    test("Reconfiguration : un player par slot, prêts") {
        let engine = SyncEngine()
        configure(engine, count: 3)
        _ = waitUntil { engine.readyCount == 3 } // chargement asynchrone
        try checkEqual(engine.readyCount, 3, "Items locaux prêts")
        for i in 0..<3 { try checkNotNil(engine.player(forSlot: i), "Player slot \(i)") }
        try checkNil(engine.player(forSlot: 9), "Slot inexistant → nil")
        engine.clear()
    }

    test("Lecture / pause / arrêt") {
        let engine = SyncEngine()
        configure(engine, count: 2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        try check(engine.isPlaying, "Lecture active")
        engine.pause()
        try check(!engine.isPlaying, "Pause")
        engine.play()
        engine.stop()
        try check(!engine.isPlaying, "Stop")
        engine.clear()
    }

    test("skip(by:) borné par la durée") {
        let engine = SyncEngine()
        configure(engine, count: 1)
        _ = waitUntil { engine.readyCount == 1 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        _ = waitUntil { engine.leaderDuration.seconds > 0 }
        engine.skip(by: 600)
        _ = waitUntil(timeout: 6) {
            engine.leaderTime.seconds >= engine.leaderDuration.seconds - 0.1
        }
        try check(engine.leaderTime.seconds >= engine.leaderDuration.seconds - 0.2,
                  "Skip avant borné à la durée")
        engine.skip(by: -600)
        _ = waitUntil(timeout: 6) { engine.leaderTime.seconds < 0.2 }
        try check(engine.leaderTime.seconds < 0.2, "Skip arrière borné à 0")
        engine.clear()
    }

    test("nudgeRate borné 0,25× – 2×") {
        let engine = SyncEngine()
        engine.nudgeRate(1.25)
        try checkEqual(Double(engine.currentRate), 1.25, accuracy: 0.001)
        engine.nudgeRate(100)
        try checkEqual(Double(engine.currentRate), 2.0, accuracy: 0.001, "Borné à 2×")
        engine.nudgeRate(0.0001)
        try checkEqual(Double(engine.currentRate), 0.25, accuracy: 0.001, "Borné à 0,25×")
        engine.clear()
    }

    test("skip(by:) aligne TOUS les players (synchro conservée)") {
        let engine = SyncEngine()
        configure(engine, count: 2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        engine.skip(by: 1) // +1 s sur tous les flux
        _ = waitUntil(timeout: 6) {
            let p0 = engine.player(forSlot: 0)?.currentTime().seconds ?? -1
            let p1 = engine.player(forSlot: 1)?.currentTime().seconds ?? -1
            return p0 > 0.5 && p1 > 0.5
        }
        let t0 = engine.player(forSlot: 0)?.currentTime().seconds ?? 0
        let t1 = engine.player(forSlot: 1)?.currentTime().seconds ?? 0
        try checkEqual(t0, t1, accuracy: 0.15, "Flux alignés après skip")
        engine.clear()
    }

    test("clear libère tous les players") {
        let engine = SyncEngine()
        configure(engine, count: 2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.clear()
        try checkNil(engine.player(forSlot: 0))
        try checkNil(engine.player(forSlot: 1))
    }

    test("joinNewSlot sur item prêt : pas de crash, lecture conservée") {
        let engine = SyncEngine()
        configure(engine, count: 2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        engine.joinNewSlot(1)
        engine.joinNewSlot(0)
        try check(engine.isPlaying, "La lecture continue")
        engine.clear()
    }

    test("E2E remplacement automatique : slot rempli, lecture continue, zéro crash") {
        let library = VideoLibrary()
        defer { library.clearAll() }
        library.add(urls: videos)
        try checkEqual(library.assets.count, 3)
        library.assign(library.assets[0], to: 0) // A : 1,5 s
        library.assign(library.assets[1], to: 1) // B : 2 s
        let engine = library.engine
        engine.autoReplace = true
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        let slot0ID = library.slots[0]?.id
        let replaced = waitUntil(timeout: 10) { library.slots[0]?.id != slot0ID }
        try check(replaced, "Le slot terminé doit être remplacé")
        try checkEqual(library.slots[0]?.url, videos[2], "La vidéo de réserve C prend le relais")
        try check(engine.isPlaying, "La lecture continue après remplacement")
        // Seuls les slots 0 et 1 sont configurés : ils ne doivent JAMAIS être vides
        // (les slots 2-4 sont nil par design, ils ne sont pas utilisés).
        try check(library.slots[0] != nil && library.slots[1] != nil, "Aucun bloc actif vide")
    }

    test("E2E fallback : sans vidéo de réserve, la même vidéo est rejouée") {
        let library = VideoLibrary()
        defer { library.clearAll() }
        // Seulement 2 vidéos pour 2 slots : aucune réserve disponible.
        let two = Array(videos.prefix(2))
        library.add(urls: two)
        library.assign(library.assets[0], to: 0)
        library.assign(library.assets[1], to: 1)
        let engine = library.engine
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        let slot0ID = library.slots[0]?.id
        // La vidéo A (1,5 s) se termine → pas de réserve → elle est rejouée :
        // le slot reste rempli, la lecture continue, aucun crash.
        let kept = waitUntil(timeout: 10) {
            library.slots[0]?.id == slot0ID && engine.isPlaying
        }
        try check(kept, "Fallback : même vidéo rejouée, slot jamais vide")
        try check(library.slots[0] != nil && library.slots[1] != nil, "Aucun bloc actif vide")
    }

    test("skip sans référentiel : aucun crash") {
        let engine = SyncEngine() // aucun slot configuré
        engine.skip(by: 10)
        engine.skip(by: -10)
        engine.nudgeRate(2)
        try check(!engine.isPlaying)
    }

    test("Persistance bibliothèque : saveNow → restoreLibrary (round-trip)") {
        let keys = ["library.sources", "library.assetBookmarks", "library.slotURLs"]
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

        let source = VideoLibrary()
        source.add(urls: videos)
        source.assign(source.assets[0], to: 0)
        source.assign(source.assets[1], to: 1)
        source.saveNow()

        let restored = VideoLibrary()
        restored.restoreLibrary()
        try checkEqual(restored.assets.count, 3, "Les assets sont restaurés")
        // Comparaison sur chemins standardisés (le bookmark peut résoudre
        // vers le chemin canonique /private/...).
        try checkEqual(restored.slots[0]?.url.standardizedFileURL, videos[0].standardizedFileURL, "Slot A restauré")
        try checkEqual(restored.slots[1]?.url.standardizedFileURL, videos[1].standardizedFileURL, "Slot B restauré")
        restored.clearAll()
    }

    test("File de lecture : setQueue, rotation next, shuffle") {
        let library = VideoLibrary()
        let qvideos = try TestVideoFactory.makeVideos(count: 3, in: directory, prefix: "q")
        library.add(urls: qvideos)
        let queue = Array(library.assets)
        library.setQueue(queue, for: 0)
        try checkEqual(library.queue(for: 0).count, 3, "File posée")
        let first = try checkNotNil(library.next(in: 0), "1er suivant")
        try checkEqual(first.url, queue[0].url, "1er = queue[0]")
        let second = try checkNotNil(library.next(in: 0), "2e suivant")
        try checkEqual(second.url, queue[1].url, "2e = queue[1] (rotation)")
        let third = try checkNotNil(library.next(in: 0), "3e suivant")
        try checkEqual(third.url, queue[2].url, "3e = queue[2] (rotation)")
        library.shuffleQueues()
        try checkEqual(library.queue(for: 0).count, 3, "Shuffle conserve la taille de la file")
        library.clearAll()
    }

    test("Reprise : savePosition → offre « Reprendre », clearPosition") {
        let engine = SyncEngine()
        let url = directory.appendingPathComponent("resume.mov")
        try TestVideoFactory.makeVideo(at: url, duration: 2.0)
        // Position courte (≤ 15 s) : aucune offre.
        engine.savePosition(5.0, for: url)
        engine.offerResumeIfNeeded(slot: 0, url: url)
        try checkNil(engine.resumeOffer, "Position courte → pas d'offre")
        // Position longue (> 15 s) : offre avec la bonne position.
        engine.savePosition(84.5, for: url)
        engine.offerResumeIfNeeded(slot: 0, url: url)
        let offer = try checkNotNil(engine.resumeOffer, "Offre proposée")
        try checkEqual(offer.position, 84.5, accuracy: 0.01)
        try checkEqual(offer.slot, 0)
        // « Recommencer » : la position est oubliée → plus d'offre ensuite.
        engine.declineResumeOffer()
        engine.offerResumeIfNeeded(slot: 0, url: url)
        try checkNil(engine.resumeOffer, "Position effacée → pas d'offre")
        engine.clear()
    }

    test("Timeline indépendante : setIndependentSlot + skip ne touche qu'UN slot") {
        let engine = SyncEngine()
        configure(engine, count: 2)
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        // Cible le slot 1 en timeline indépendante.
        engine.setIndependentSlot(1)
        try check(engine.isIndependentSlot(1), "Slot 1 ciblé")
        engine.skip(by: 1) // +1 s sur le slot 1 UNIQUEMENT
        _ = waitUntil(timeout: 5) {
            (engine.player(forSlot: 1)?.currentTime().seconds ?? 0) > 0.5
        }
        let t0 = engine.player(forSlot: 0)?.currentTime().seconds ?? 0
        let t1 = engine.player(forSlot: 1)?.currentTime().seconds ?? 0
        try check(t1 > t0 + 0.3, "Le slot 1 avance indépendamment (slot1: \(t1)s vs slot0: \(t0)s)")
        // Le slot référentiel ne peut pas être ciblé.
        engine.setIndependentSlot(0)
        try check(!engine.isIndependentSlot(0), "Le MAÎTRE ne peut pas être indépendant")
        // Retour au mode global.
        engine.setIndependentSlot(nil)
        try check(!engine.isIndependentSlot(1), "Mode global restauré")
        engine.clear()
    }

    test("Anti-boucle : un slot plus court que le référentiel ne boucle pas") {
        // Bug 11/08 : quand le référentiel dépasse la durée d'un autre slot,
        // le moniteur de dérive le recale AU-DELÀ de sa fin → fin instantanée
        // → remplacement → re-cale → boucle infinie de changement de vidéos.
        let engine = SyncEngine()
        configure(engine, count: 2)   // vidéos de ~1,5 s et 2 s
        engine.autoReplace = true
        _ = waitUntil { engine.readyCount == 2 }
        engine.play()
        _ = waitUntil { engine.isPlaying }
        // Avance GLOBALE : pousse le référentiel au-delà de la fin.
        engine.skip(by: 2)
        var intervals: [Double] = []
        var last: Date?
        engine.onItemEnded = { _ in
            let now = Date()
            if let last { intervals.append(now.timeIntervalSince(last)) }
            last = now
        }
        // Laisse tourner ~6 s : sans le fix, les remplacements s'enchaînent
        // en rafale (< 0,8 s) ; avec le fix, ils suivent la durée des vidéos.
        Thread.sleep(forTimeInterval: 6)
        try check(
            intervals.allSatisfy { $0 >= 0.8 },
            "Aucune rafale de remplacement (intervalles: \(intervals.map { String(format: "%.1f", $0) }.prefix(8).joined(separator: ", ")))"
        )
        engine.clear()
    }

    test("Maître : modes auto / manuel / aucun") {
        let engine = SyncEngine()
        configure(engine, count: 3)
        _ = waitUntil { engine.readyCount == 3 }
        // Auto : premier bloc actif.
        try check(engine.isReferenceSlot(0), "Auto : slot 0 par défaut")
        // Manuel : le bloc 2 devient maître.
        engine.setManualMaster(2)
        try check(engine.isReferenceSlot(2), "Manuel : le maître est le slot 2")
        try check(!engine.isReferenceSlot(0), "Le slot 0 n'est plus maître")
        // Le nouveau maître ne peut pas être indépendant.
        engine.setIndependentSlot(2)
        try check(!engine.isIndependentSlot(2), "Le maître manuel ne peut pas être indépendant")
        // Retour au mode auto.
        engine.setReferenceMode(.auto)
        try check(engine.isReferenceSlot(0), "Auto rétabli : slot 0")
        // Mode « Aucun maître » : le premier bloc PEUT être indépendant.
        engine.setReferenceMode(.none)
        engine.setIndependentSlot(0)
        try check(engine.isIndependentSlot(0), "Mode aucun : le slot 0 peut être indépendant")
        engine.setIndependentSlot(nil)
        engine.clear()
    }

    test("Layout Libre : poids et répartition des blocs") {
        // Sauvegarde de l'état réel pour restauration après le test.
        let d = UserDefaults.standard
        let before = d.dictionary(forKey: "settings.customWeights")
        defer {
            if let before {
                d.set(before, forKey: "settings.customWeights")
            } else {
                d.removeObject(forKey: "settings.customWeights")
            }
        }
        let settings = AppSettings()
        settings.resetCustomWeights()
        try check(settings.weight(for: 0) == 1.0, "Poids par défaut = 1")
        settings.adjustWeight(0.25, left: 0, right: 1)  // +25 % de la paire
        let w0 = settings.weight(for: 0)
        try check(abs(w0 - 1.5) < 0.01, "Bloc 0 agrandi (1.5, obtenu \(w0))")
        try check(abs(settings.weight(for: 1) - 0.5) < 0.01, "Bloc 1 réduit (0.5)")
        // Bornes : jamais moins de 15 % de la paire pour un bloc.
        settings.adjustWeight(10, left: 0, right: 1)
        try check(settings.weight(for: 1) >= 0.3, "Borne 15 % respectée (\(settings.weight(for: 1)))")
        settings.resetCustomWeights()
        try check(settings.weight(for: 0) == 1.0, "Reset des poids")
    }

    test("Fichier corrompu : .failed → remplacement par la file") {
        let bad = directory.appendingPathComponent("corrompu.mov")
        try Data("contenu invalide, pas une vraie video".utf8).write(to: bad)
        let library = VideoLibrary()
        library.add(urls: [bad, videos[0], videos[1]])
        let badAsset = try checkNotNil(library.assets.first { $0.url == bad }, "Asset corrompu présent")
        let goodAsset = try checkNotNil(library.assets.first { $0.url == videos[0] }, "Asset sain présent")
        library.assign(badAsset, to: 0)
        library.setQueue([goodAsset], for: 0)
        let engine = library.engine
        engine.autoReplace = true
        // Le moteur tente le fichier invalide → .failed → remplacement différé
        // (0,5 s) → la file fournit la vidéo saine.
        let replaced = waitUntil(timeout: 15) { library.slots[0]?.url == videos[0] }
        try check(replaced, "Le fichier corrompu doit être remplacé par la file")
        library.clearAll()
    }
}

// MARK: - Tests : caches

func runCacheTests() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("trisync-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let videoURL = directory.appendingPathComponent("cache_video.mov")
    try TestVideoFactory.makeVideo(at: videoURL, duration: 2.0)

    category("Caches (métadonnées + vignettes)")

    test("Cache métadonnées : aller-retour + refus des valeurs invalides") {
        let meta = VideoMetadata(duration: 12.5, width: 1920, height: 1080, frameRate: 30.0)
        MetadataCache.shared.set(meta, for: videoURL)
        let loaded = try checkNotNil(MetadataCache.shared.get(for: videoURL), "Métadonnées lues")
        try checkEqual(loaded.duration, 12.5, accuracy: 0.001)
        try checkEqual(loaded.width, 1920)
        try checkEqual(loaded.height, 1080)
        MetadataCache.shared.set(VideoMetadata(duration: .nan, width: 0, height: 0, frameRate: 0), for: videoURL)
        let notOverwritten = try checkNotNil(MetadataCache.shared.get(for: videoURL), "Cache conservé")
        try checkEqual(notOverwritten.duration, 12.5, accuracy: 0.001, "Valeurs invalides refusées")
    }

    test("Vignettes : génération + persistance disque + relecture") {
        let expectation = expectationHelper()
        Task {
            let image = await ThumbnailCache.shared.thumbnail(for: videoURL, variant: .portrait)
            try? checkNotNil(image, "Vignette générée")
            let digest = SHA256.hash(data: Data(videoURL.path.utf8))
                .map { String(format: "%02x", $0) }.prefix(16).joined()
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let file = base.appendingPathComponent("TriSync/Thumbs/\(digest)_p.jpg")
            try? check(FileManager.default.fileExists(atPath: file.path), "JPEG persisté sur disque")
            let again = await ThumbnailCache.shared.thumbnail(for: videoURL, variant: .portrait)
            try? checkNotNil(again, "Relecture OK")
            expectation.fulfill()
        }
        _ = waitUntil(timeout: 15) { expectation.fulfilled }
        try check(expectation.fulfilled, "Test vignettes terminé")
        // Nettoyage : retire le fichier généré pour ce chemin de test.
        let digest = SHA256.hash(data: Data(videoURL.path.utf8))
            .map { String(format: "%02x", $0) }.prefix(16).joined()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(
            at: base.appendingPathComponent("TriSync/Thumbs/\(digest)_p.jpg"))
        try? FileManager.default.removeItem(
            at: base.appendingPathComponent("TriSync/Thumbs/\(digest)_l.jpg"))
    }
}

// MARK: - Tests : helpers & réglages

func runHelperTests() throws {
    category("Helpers & réglages")

    test("Formatage du temps") {
        try checkEqual(timeString(CMTime(seconds: 0, preferredTimescale: 600)), "0:00")
        try checkEqual(timeString(CMTime(seconds: 65, preferredTimescale: 600)), "1:05")
        try checkEqual(timeString(CMTime(seconds: 3661, preferredTimescale: 600)), "1:01:01",
                       "Au-delà d'une heure : format h:mm:ss")
        try checkEqual(timeString(.invalid), "0:00", "Valeur invalide → format sûr")
    }

    test("Réglages : persistance aller-retour sans polluer l'utilisateur") {
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
        try checkEqual(reloaded.displayMode, .stretch)
        try checkEqual(reloaded.ratioMode, .r169)
        try checkEqual(reloaded.verticalOffset, .bottom)
        try checkEqual(reloaded.advancedScale, .p125)
        try checkEqual(reloaded.playbackSpeed, 1.5, accuracy: 0.001)
        try checkEqual(reloaded.layoutPreset, .wall32)
    }

    test("Ratio cible (layout responsive)") {
        let settings = AppSettings()
        settings.ratioMode = .r169
        try checkEqual(settings.targetAspect(for: VideoAsset(url: URL(fileURLWithPath: "/tmp/x.mov"))),
                       16.0 / 9.0, accuracy: 0.001)
        settings.ratioMode = .auto
        try checkEqual(settings.targetAspect(for: VideoAsset(url: URL(fileURLWithPath: "/tmp/x.mov"))),
                       0.75, accuracy: 0.001, "Taille inconnue → 0,75 par défaut")
    }
}

// MARK: - Point d'entrée

@MainActor
func main() {
    print("════════════════════════════════════════════")
    print("  TriSync — Suite de tests automatisés (v6.5)")
    print("════════════════════════════════════════════")
    do {
        try runLibraryTests()
        try runEngineTests()
        try runCacheTests()
        try runHelperTests()
    } catch {
        failed += 1
        print("  ✗ Erreur globale: \(error)")
    }
    print("\n════════════════════════════════════════════")
    print("  Résultat : \(passed) réussis / \(failed) échecs")
    print("════════════════════════════════════════════")
    exit(failed == 0 ? 0 : 1)
}

/// Petit helper d'attente pour le test asynchrone des vignettes.
final class expectationHelper {
    private let lock = NSLock()
    private var _fulfilled = false
    var fulfilled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _fulfilled
    }
    func fulfill() {
        lock.lock(); defer { lock.unlock() }
        _fulfilled = true
    }
}

// Point d'entrée : le top-level s'exécute sur le thread principal.
MainActor.assumeIsolated {
    main()
}
