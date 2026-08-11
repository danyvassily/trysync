import Foundation
import AppKit
import AVFoundation
import CryptoKit

/// Cache d'images et générateur de vignettes persisté sur disque.
public actor ThumbnailCache {
    public static let shared = ThumbnailCache()

    public enum Variant: String, Sendable {
        case portrait = "p"   // cartes du navigateur (3:4)
        case landscape = "l"  // vignettes de bibliothèque (16:9)
    }

    private let memory = NSCache<NSString, NSImage>()
    private let diskDir: URL
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]
    private var activeGenerations = 0
    private let maxConcurrentGenerations = 4

    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDir = base.appendingPathComponent("TriSync/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// Clé d'empreinte SHA-256 stable du chemin standardisé canonique.
    public nonisolated func stableKey(for url: URL) -> String {
        let path = canonicalPath(for: url)
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskFile(for url: URL, variant: Variant) -> URL {
        diskDir.appendingPathComponent("\(stableKey(for: url))_\(variant.rawValue).jpg")
    }

    /// Récupère ou génère la vignette demandée.
    public func thumbnail(for url: URL, variant: Variant = .portrait) async -> NSImage? {
        let file = diskFile(for: url, variant: variant)
        let memKey = file.lastPathComponent as NSString

        if let image = memory.object(forKey: memKey) {
            return image
        }

        if let image = NSImage(contentsOf: file) {
            memory.setObject(image, forKey: memKey)
            return image
        }

        let taskKey = "\(url.standardizedFileURL.path)_\(variant.rawValue)"
        if let existing = inFlightTasks[taskKey] {
            return await existing.value
        }

        let generationTask = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.generateAndCacheThumbnail(for: url, variant: variant, file: file, memKey: memKey)
        }

        inFlightTasks[taskKey] = generationTask
        let result = await generationTask.value
        inFlightTasks.removeValue(forKey: taskKey)
        return result
    }

    private func generateAndCacheThumbnail(for url: URL, variant: Variant, file: URL, memKey: NSString) async -> NSImage? {
        while activeGenerations >= maxConcurrentGenerations {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        activeGenerations += 1
        defer { activeGenerations -= 1 }

        if let image = memory.object(forKey: memKey) {
            return image
        }
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

        // Sauvegarde disque JPEG
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
            try? data.write(to: file, options: .atomic)
        }
        return image
    }

    /// Préchauffage des vignettes d'une liste d'URLs.
    public func prefetch(_ urls: [URL], limit: Int = 4) async {
        let pending = urls.filter { url in
            let file = diskFile(for: url, variant: .portrait)
            let memKey = file.lastPathComponent as NSString
            return memory.object(forKey: memKey) == nil && !FileManager.default.fileExists(atPath: file.path)
        }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for url in pending.prefix(500) {
                group.addTask(priority: .utility) {
                    _ = await self.thumbnail(for: url, variant: .portrait)
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
