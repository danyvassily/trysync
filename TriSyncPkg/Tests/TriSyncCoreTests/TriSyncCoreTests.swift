import Testing
import Foundation
import CoreMedia
@testable import TriSyncCore

@Suite("TriSyncCore Tests")
struct TriSyncCoreTests {

    @Test("Filtrage des fichiers vidéo")
    func testVideoFiltering() {
        let valid = [
            URL(fileURLWithPath: "/tmp/video1.mp4"),
            URL(fileURLWithPath: "/tmp/video2.mov"),
            URL(fileURLWithPath: "/tmp/video3.mkv")
        ]
        let invalid = [
            URL(fileURLWithPath: "/tmp/doc.txt"),
            URL(fileURLWithPath: "/tmp/photo.jpg")
        ]
        let filtered = VideoLibrary.videoFiles(from: valid + invalid)
        #expect(filtered.count == 3)
    }

    @Test("Formatage du temps")
    func testTimeFormatting() {
        #expect(timeString(.zero) == "0:00")
        #expect(timeString(CMTime(seconds: 65, preferredTimescale: 600)) == "1:05")
        #expect(timeString(CMTime(seconds: 3661, preferredTimescale: 600)) == "1:01:01")
        #expect(timeString(CMTime.invalid) == "0:00")
        #expect(timeString(CMTime.indefinite) == "0:00")
    }

    @Test("Cache de métadonnées thread-safe")
    func testMetadataCache() {
        let cache = MetadataCache.shared
        let url = URL(fileURLWithPath: "/tmp/trisync_test_video.mp4")
        let meta = VideoMetadata(duration: 120.5, width: 1920, height: 1080, frameRate: 60.0)
        cache.set(meta, for: url)

        let retrieved = cache.get(for: url)
        #expect(retrieved != nil)
        #expect(retrieved?.duration == 120.5)
        #expect(retrieved?.width == 1920)
        #expect(retrieved?.height == 1080)
        #expect(retrieved?.frameRate == 60.0)
    }

    @Test("ThumbnailCache SHA-256 stable key")
    func testThumbnailCacheKey() {
        let cache = ThumbnailCache.shared
        let url1 = URL(fileURLWithPath: "/tmp/test.mp4")
        let url2 = URL(fileURLWithPath: "/tmp/test.mp4")
        let key1 = cache.stableKey(for: url1)
        let key2 = cache.stableKey(for: url2)
        #expect(key1 == key2)
        #expect(key1.count == 16)
    }

    @Test("AppSettings Layout Libre et custom weights")
    @MainActor
    func testCustomWeights() {
        let settings = AppSettings()
        settings.resetCustomWeights()
        #expect(settings.weight(for: 0) == 1.0)
        #expect(settings.weight(for: 1) == 1.0)

        settings.setWeight(2.5, for: 0)
        #expect(settings.weight(for: 0) == 2.5)

        settings.adjustWeight(0.1, left: 0, right: 1)
        #expect(settings.weight(for: 0) > 2.5)
        #expect(settings.weight(for: 1) < 1.0)

        settings.resetCustomWeights()
        #expect(settings.weight(for: 0) == 1.0)
    }
}
