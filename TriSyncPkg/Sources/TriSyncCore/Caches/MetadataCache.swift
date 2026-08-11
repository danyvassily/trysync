import Foundation
import CoreMedia

/// Métadonnées d'une vidéo mémoïsées pour éviter de relire l'AVAsset.
public struct VideoMetadata: Codable, Equatable, Sendable {
    public var duration: Double
    public var width: Double
    public var height: Double
    public var frameRate: Double

    public init(duration: Double, width: Double, height: Double, frameRate: Double) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// Cache de métadonnées thread-safe persisté dans UserDefaults.
public final class MetadataCache: @unchecked Sendable {
    public static let shared = MetadataCache()

    private let defaultsKey = "library.metadataCache"
    private let lock = NSLock()
    private var cache: [String: VideoMetadata] = [:]
    private let maxEntries = 2000
    private var saveWorkItem: DispatchWorkItem?

    public init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: VideoMetadata].self, from: data) {
            self.cache = saved
        }
    }

    /// Récupère les métadonnées mémoïsées pour une URL.
    public func get(for url: URL) -> VideoMetadata? {
        let key = canonicalPath(for: url)
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    /// Enregistre les métadonnées pour une URL.
    public func set(_ metadata: VideoMetadata, for url: URL) {
        guard metadata.duration.isFinite, metadata.duration >= 0,
              metadata.width > 0, metadata.height > 0 else { return }
        let key = canonicalPath(for: url)

        lock.lock()
        cache[key] = metadata
        while cache.count > maxEntries, let firstKey = cache.keys.first {
            cache.removeValue(forKey: firstKey)
        }
        lock.unlock()

        scheduleSave()
    }

    /// Vide le cache en mémoire et sur disque (pour tests / réinitialisation).
    public func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func scheduleSave() {
        lock.lock()
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persist()
        }
        saveWorkItem = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func persist() {
        lock.lock()
        let copy = cache
        lock.unlock()
        guard let data = try? JSONEncoder().encode(copy) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
