import XCTest
import AVFoundation
import CryptoKit
@testable import TriSync

// MARK: - Fabrique de vidéos de test

enum TestVideoFactory {
    static func makeVideo(
        at url: URL,
        duration: Double,
        size: CGSize = CGSize(width: 320, height: 240),
        color: (r: UInt8, g: UInt8, b: UInt8) = (200, 30, 30)
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
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
        for frame in 0..<Int(duration * Double(fps)) {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
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
                        let pixel = row.advanced(by: x * 4)
                        pixel.storeBytes(of: color.b, as: UInt8.self)
                        pixel.advanced(by: 1).storeBytes(of: color.g, as: UInt8.self)
                        pixel.advanced(by: 2).storeBytes(of: color.r, as: UInt8.self)
                        pixel.advanced(by: 3).storeBytes(of: 255, as: UInt8.self)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw NSError(domain: "TestVideoFactory", code: 4)
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10)
        guard writer.status == .completed else {
            throw NSError(
                domain: "TestVideoFactory",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Écriture vidéo échouée"]
            )
        }
    }

    static func makeVideos(count: Int, in directory: URL, prefix: String = "test") throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let url = directory.appendingPathComponent("\(prefix)_\(index).mov")
            try makeVideo(at: url, duration: 1.5 + Double(index) * 0.5)
            return url
        }
    }
}

@discardableResult
func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

// MARK: - VideoLibrary

final class VideoLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trisync-library-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    func testVideoFileFiltering() throws {
        let movie = directory.appendingPathComponent("a.mov")
        try TestVideoFactory.makeVideo(at: movie, duration: 1.5)
        let mp4 = directory.appendingPathComponent("b.mp4")
        let mkv = directory.appendingPathComponent("c.mkv")
        let text = directory.appendingPathComponent("d.txt")
        let image = directory.appendingPathComponent("e.jpg")
        let accepted = VideoLibrary.videoFiles(from: [movie, mp4, mkv, text, image])
        XCTAssertEqual(accepted.count, 3)
        XCTAssertFalse(accepted.contains(text))
        XCTAssertFalse(accepted.contains(image))
    }

    @MainActor
    func testDeduplication() throws {
        let library = VideoLibrary()
        defer { library.clearAll() }
        let video = directory.appendingPathComponent("dedupe.mov")
        try TestVideoFactory.makeVideo(at: video, duration: 1.5)
        library.add(urls: [video, video, video])
        XCTAssertEqual(library.assets.count, 1)
    }

    @MainActor
    func testSelectionCappedAtFive() throws {
        let library = VideoLibrary()
        defer { library.clearAll() }
        let videos = try TestVideoFactory.makeVideos(count: 7, in: directory)
        library.add(urls: videos)
        for asset in library.assets { library.toggleSelection(asset) }
        XCTAssertEqual(library.selectedOrder.count, 7)
        XCTAssertEqual(library.selectedAssets.count, VideoLibrary.maxSlots)
        XCTAssertEqual(library.selectedAssets.first?.url, videos.first)
    }

    @MainActor
    func testLaunchSelectedFillsSlots() throws {
        let library = VideoLibrary()
        defer { library.clearAll() }
        let videos = try TestVideoFactory.makeVideos(count: 3, in: directory)
        library.add(urls: videos)
        for asset in library.assets { library.toggleSelection(asset) }
        library.launchSelected()
        XCTAssertTrue(library.selectedOrder.isEmpty)
        let filled = library.slots.compactMap { $0 }
        XCTAssertEqual(filled.count, 3)
        XCTAssertEqual(filled[0].url, videos[0])
        XCTAssertEqual(filled[1].url, videos[1])
    }

    @MainActor
    func testEnsureInLibraryDoesNotOccupySlot() throws {
        let library = VideoLibrary()
        defer { library.clearAll() }
        let video = directory.appendingPathComponent("ensure.mov")
        try TestVideoFactory.makeVideo(at: video, duration: 1.5)
        XCTAssertNotNil(library.ensureInLibrary(video))
        XCTAssertEqual(library.assets.count, 1)
        XCTAssertTrue(library.slots.allSatisfy { $0 == nil })
    }

    @MainActor
    func testClearAll() throws {
        let library = VideoLibrary()
        let videos = try TestVideoFactory.makeVideos(count: 2, in: directory)
        library.add(urls: videos)
        library.assign(library.assets[0], to: 0)
        library.clearAll()
        XCTAssertTrue(library.assets.isEmpty)
        XCTAssertTrue(library.slots.allSatisfy { $0 == nil })
        XCTAssertTrue(library.selectedOrder.isEmpty)
    }

    func testVideoFileFilteringIsCaseInsensitive() {
        let upper = URL(fileURLWithPath: "/tmp/TriSync-Test.MKV")
        XCTAssertEqual(VideoLibrary.videoFiles(from: [upper]), [upper])
    }

    @MainActor
    func testToggleSelectionIsReversible() {
        let library = VideoLibrary()
        defer { library.clearAll() }
        let asset = VideoAsset(url: URL(fileURLWithPath: "/tmp/toggle.mov"))
        library.toggleSelection(asset)
        XCTAssertEqual(library.selectedOrder, [asset.id])
        library.toggleSelection(asset)
        XCTAssertTrue(library.selectedOrder.isEmpty)
    }

    @MainActor
    func testPlaceUsesFirstFreeSlot() throws {
        let library = VideoLibrary()
        defer { library.clearAll() }
        let videos = try TestVideoFactory.makeVideos(count: 2, in: directory, prefix: "place")
        library.add(urls: videos)
        library.place(library.assets[0])
        library.place(library.assets[1])
        XCTAssertEqual(library.slots[0]?.url, videos[0])
        XCTAssertEqual(library.slots[1]?.url, videos[1])
    }
}

// MARK: - SyncEngine

final class SyncEngineTests: XCTestCase {
    private var directory: URL!
    private var engine: SyncEngine!
    private var videos: [URL]!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trisync-engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        for index in 0..<min(count, videos.count) {
            slots[index] = VideoAsset(url: videos[index])
        }
        engine.reconfigure(slots: slots)
    }

    func testReconfigureCreatesPlayers() {
        configure(3)
        XCTAssertTrue(waitUntil { engine.readyCount == 3 })
        for index in 0..<3 { XCTAssertNotNil(engine.player(forSlot: index)) }
        XCTAssertNil(engine.player(forSlot: 9))
    }

    func testPlayPauseStop() {
        configure(2)
        XCTAssertTrue(waitUntil { engine.readyCount == 2 })
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        engine.stop()
        XCTAssertFalse(engine.isPlaying)
    }

    func testSkipClampedToDuration() {
        configure(1)
        XCTAssertTrue(waitUntil { engine.readyCount == 1 })
        XCTAssertTrue(waitUntil { engine.leaderDuration.seconds > 0 })
        engine.play()
        engine.skip(by: 600)
        XCTAssertTrue(waitUntil(timeout: 4) {
            engine.leaderTime.seconds >= engine.leaderDuration.seconds - 0.1
        })
        engine.skip(by: -600)
        XCTAssertTrue(waitUntil(timeout: 4) { engine.leaderTime.seconds < 0.2 })
    }

    func testNudgeRateClamped() {
        configure(1)
        engine.nudgeRate(1.25)
        XCTAssertEqual(engine.currentRate, 1.25, accuracy: 0.001)
        engine.nudgeRate(100)
        XCTAssertEqual(engine.currentRate, 2, accuracy: 0.001)
        engine.nudgeRate(0.0001)
        XCTAssertEqual(engine.currentRate, 0.25, accuracy: 0.001)
    }

    func testPublicScrubAlignsAllPlayers() {
        configure(2)
        XCTAssertTrue(waitUntil { engine.readyCount == 2 })
        XCTAssertTrue(waitUntil { engine.leaderDuration.seconds > 0 })
        engine.beginScrub()
        engine.endScrub(atFraction: 0.5)
        XCTAssertTrue(waitUntil(timeout: 4) {
            let a = engine.player(forSlot: 0)?.currentTime().seconds ?? -1
            let b = engine.player(forSlot: 1)?.currentTime().seconds ?? -1
            return a > 0.4 && b > 0.4
        })
        let a = engine.player(forSlot: 0)?.currentTime().seconds ?? 0
        let b = engine.player(forSlot: 1)?.currentTime().seconds ?? 0
        XCTAssertEqual(a, b, accuracy: 0.15)
    }

    func testClearReleasesPlayers() {
        configure(2)
        XCTAssertTrue(waitUntil { engine.readyCount == 2 })
        engine.clear()
        XCTAssertNil(engine.player(forSlot: 0))
        XCTAssertNil(engine.player(forSlot: 1))
    }

    func testJoinNewSlotWhenReady() {
        configure(2)
        XCTAssertTrue(waitUntil { engine.readyCount == 2 })
        engine.play()
        engine.joinNewSlot(1)
        XCTAssertTrue(engine.isPlaying)
    }

    @MainActor
    func testAutoReplaceEndToEnd() {
        let library = VideoLibrary()
        defer { library.clearAll() }
        library.add(urls: videos)
        XCTAssertEqual(library.assets.count, 3)
        library.assign(library.assets[0], to: 0)
        library.assign(library.assets[1], to: 1)
        let localEngine = library.engine
        localEngine.autoReplace = true
        XCTAssertTrue(waitUntil { localEngine.readyCount == 2 })
        localEngine.play()

        let originalID = library.slots[0]?.id
        XCTAssertTrue(waitUntil(timeout: 8) { library.slots[0]?.id != originalID })
        XCTAssertEqual(library.slots[0]?.url, videos[2])
        XCTAssertTrue(localEngine.isPlaying)
        XCTAssertNotNil(library.slots[0])
        XCTAssertNotNil(library.slots[1])
    }

    func testManualMasterRejectsMissingSlot() {
        configure(2)
        engine.setManualMaster(9)
        XCTAssertEqual(engine.referenceMode, .auto)
        XCTAssertNil(engine.manualReferenceSlot)
    }

    func testReferenceModeResetClearsManualMaster() {
        configure(2)
        engine.setManualMaster(1)
        XCTAssertEqual(engine.referenceMode, .manual)
        XCTAssertEqual(engine.manualReferenceSlot, 1)
        engine.setReferenceMode(.auto)
        XCTAssertEqual(engine.referenceMode, .auto)
        XCTAssertNil(engine.manualReferenceSlot)
    }

    func testPositionPersistenceRoundTrip() {
        let url = URL(fileURLWithPath: "/tmp/trisync-position-\(UUID().uuidString).mov")
        let first = SyncEngine()
        first.savePosition(42.5, for: url)
        first.persistPositionsNow()
        let second = SyncEngine()
        XCTAssertEqual(second.position(for: url), 42.5, accuracy: 0.001)
        second.clearPosition(for: url)
    }
}

// MARK: - Caches

final class CachesTests: XCTestCase {
    private var directory: URL!
    private var videoURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trisync-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        videoURL = directory.appendingPathComponent("cache.mov")
        try? TestVideoFactory.makeVideo(at: videoURL, duration: 2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testMetadataCacheRoundTrip() {
        let metadata = VideoMetadata(duration: 12.5, width: 1920, height: 1080, frameRate: 30)
        MetadataCache.shared.set(metadata, for: videoURL)
        let loaded = MetadataCache.shared.get(for: videoURL)
        XCTAssertEqual(loaded?.duration ?? .nan, 12.5, accuracy: 0.001)
        XCTAssertEqual(loaded?.width, 1920)
        XCTAssertEqual(loaded?.height, 1080)
        MetadataCache.shared.set(
            VideoMetadata(duration: .nan, width: 0, height: 0, frameRate: 0),
            for: videoURL
        )
        XCTAssertEqual(MetadataCache.shared.get(for: videoURL)?.duration ?? .nan, 12.5, accuracy: 0.001)
    }

    func testThumbnailCachePersistsToDisk() async {
        let first = await ThumbnailCache.shared.thumbnail(for: videoURL, variant: .portrait)
        XCTAssertNotNil(first)
        let digest = SHA256.hash(data: Data(videoURL.path.utf8))
            .map { String(format: "%02x", $0) }.prefix(16).joined()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let file = base.appendingPathComponent("TriSync/Thumbs/\(digest)_p.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let second = await ThumbnailCache.shared.thumbnail(for: videoURL, variant: .portrait)
        XCTAssertNotNil(second)
    }
}

// MARK: - Helpers / réglages

final class HelpersTests: XCTestCase {
    func testTimeString() {
        XCTAssertEqual(timeString(CMTime(seconds: 0, preferredTimescale: 600)), "0:00")
        XCTAssertEqual(timeString(CMTime(seconds: 65, preferredTimescale: 600)), "1:05")
        XCTAssertEqual(timeString(CMTime(seconds: 3661, preferredTimescale: 600)), "1:01:01")
        XCTAssertEqual(timeString(.invalid), "0:00")
    }

    func testSettingsPersistenceRoundTrip() {
        let keys = [
            "settings.displayMode", "settings.ratioMode", "settings.verticalOffset",
            "settings.advancedScale", "settings.playbackSpeed", "settings.layoutPreset",
            "settings.customWeights"
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

    func testTargetAspect() {
        let settings = AppSettings()
        let asset = VideoAsset(url: URL(fileURLWithPath: "/tmp/x.mov"))
        settings.ratioMode = .r169
        XCTAssertEqual(settings.targetAspect(for: asset), 16.0 / 9.0, accuracy: 0.001)
        settings.ratioMode = .auto
        XCTAssertEqual(settings.targetAspect(for: asset), 0.75, accuracy: 0.001)
    }

    func testValidPresetsBySlotCount() {
        let settings = AppSettings()
        XCTAssertEqual(settings.validPresets(forCount: 1), [.auto])
        XCTAssertTrue(settings.validPresets(forCount: 2).contains(.sideBySide))
        XCTAssertTrue(settings.validPresets(forCount: 3).contains(.masterTwo))
        XCTAssertTrue(settings.validPresets(forCount: 4).contains(.grid2x2))
        XCTAssertTrue(settings.validPresets(forCount: 5).contains(.wall32))
    }

    func testCustomWeightClamp() {
        let settings = AppSettings()
        settings.resetCustomWeights()
        settings.setWeight(-10, for: 0)
        XCTAssertEqual(settings.weight(for: 0), 0.1, accuracy: 0.001)
        settings.setWeight(100, for: 0)
        XCTAssertEqual(settings.weight(for: 0), 10, accuracy: 0.001)
        settings.resetCustomWeights()
    }

    func testAdjustWeightPreservesPairTotal() {
        let settings = AppSettings()
        settings.resetCustomWeights()
        let before = settings.weight(for: 0) + settings.weight(for: 1)
        settings.adjustWeight(0.2, left: 0, right: 1)
        let after = settings.weight(for: 0) + settings.weight(for: 1)
        XCTAssertEqual(after, before, accuracy: 0.001)
        XCTAssertGreaterThan(settings.weight(for: 0), settings.weight(for: 1))
        settings.resetCustomWeights()
    }

    func testTimeStringRoundsToNearestSecond() {
        XCTAssertEqual(timeString(CMTime(seconds: 59.6, preferredTimescale: 600)), "1:00")
    }
}
