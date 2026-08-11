import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

/// Bibliothèque centrale de vidéos et gestionnaire des emplacements A–E.
@MainActor
public final class VideoLibrary: ObservableObject {
    public static let maxSlots = 5

    @Published public var slots: [VideoAsset?] = Array(repeating: nil, count: VideoLibrary.maxSlots)
    @Published public var assets: [VideoAsset] = []
    @Published public var selectedSlot = 0
    @Published public var sources: [LibrarySource] = []
    @Published public var selectedOrder: [UUID] = []
    @Published public private(set) var favoritesRevision = 0
    @Published public private(set) var isScanning = false

    public let engine = SyncEngine()

    private var metadataTasks: [UUID: Task<Void, Never>] = [:]
    private var assetSource: [UUID: UUID] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private var queues: [Int: [VideoAsset]] = [:]
    private var failedURLs: [Int: [URL: Date]] = [:]
    private var pendingReplacements: [Int: Task<Void, Never>] = [:]
    private var lastReplacementDate = Date.distantPast
    private var sourceFingerprints: [UUID: Date] = [:]
    private var activeScans = 0
    private var sourceWatcherTask: Task<Void, Never>?

    private static let sourcesKey = "library.sources"
    private static let assetsKey = "library.assetBookmarks"
    private static let slotsKey = "library.slotURLs"
    private static let queuesKey = "library.queues"

    public init() {
        engine.onItemEnded = { [weak self] slot in
            self?.autoReplace(slot: slot)
        }
        engine.onSlotFailed = { [weak self] slot in
            self?.handleSlotFailure(slot)
        }
        engine.onPreloadNeeded = { [weak self] slot in
            self?.prepareNext(for: slot)
        }
        startSourceWatcher()
    }

    // MARK: - Gestion des Slots

    public func select(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        selectedSlot = slot
    }

    public func clear(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        queues.removeValue(forKey: slot)
        failedURLs.removeValue(forKey: slot)
        pendingReplacements[slot]?.cancel()
        pendingReplacements.removeValue(forKey: slot)
        slots[slot] = nil
        syncEngine()
    }

    public func clearAll() {
        for task in metadataTasks.values { task.cancel() }
        metadataTasks.removeAll()
        for task in pendingReplacements.values { task.cancel() }
        pendingReplacements.removeAll()
        queues.removeAll()
        failedURLs.removeAll()
        assetSource.removeAll()
        slots = Array(repeating: nil, count: VideoLibrary.maxSlots)
        assets = []
        engine.clear()
    }

    public func assign(_ asset: VideoAsset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        if let old = slots.firstIndex(where: { $0?.id == asset.id }), old != slot {
            slots[old] = nil
        }
        pendingReplacements[slot]?.cancel()
        pendingReplacements.removeValue(forKey: slot)
        failedURLs.removeValue(forKey: slot)
        slots[slot] = asset
        engine.offerResumeIfNeeded(slot: slot, url: asset.url)
        syncEngine()
    }

    public func place(_ asset: VideoAsset, preferredSlot: Int? = nil) {
        guard slots.indices.contains(preferredSlot ?? 0) else { return }
        if let empty = slots.firstIndex(where: { $0 == nil }) {
            assign(asset, to: empty)
        } else {
            assign(asset, to: preferredSlot ?? 0)
        }
    }

    public func removeAsset(_ asset: VideoAsset) {
        metadataTasks[asset.id]?.cancel()
        metadataTasks.removeValue(forKey: asset.id)
        assetSource.removeValue(forKey: asset.id)
        assets.removeAll { $0.id == asset.id }
        for index in slots.indices where slots[index]?.id == asset.id {
            slots[index] = nil
        }
        syncEngine()
    }

    // MARK: - Ingestion de Fichiers

    public func add(urls: [URL]) {
        add(urls: urls, source: nil)
    }

    public func ingest(_ urls: [URL]) {
        add(urls: urls, source: nil)
    }

    private func add(urls: [URL], source: UUID?) {
        var known = Set(assets.map { canonicalPath(for: $0.url) })
        for url in Self.videoFiles(from: urls) {
            let key = canonicalPath(for: url)
            if let existing = assets.first(where: { canonicalPath(for: $0.url) == key }) {
                if let source, assetSource[existing.id] == nil {
                    assetSource[existing.id] = source
                }
                continue
            }
            let asset = VideoAsset(url: url)
            assets.append(asset)
            assetSource[asset.id] = source
            known.insert(key)

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

    // MARK: - Sources & Surveillance

    public func addSource(url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        if sources.contains(where: { canonicalPath(for: $0.url) == canonicalPath(for: url) }) { return }
        sources.append(LibrarySource(id: UUID(), url: url, enabled: true, bookmark: bookmark))
        persistSources()
        scanSources()
    }

    public func removeSource(id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        persistSources()
        sourceFingerprints.removeValue(forKey: id)
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

    public func toggleSource(id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled.toggle()
        persistSources()
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
            metadataTasks[asset.id]?.cancel()
            metadataTasks.removeValue(forKey: asset.id)
            assetSource.removeValue(forKey: asset.id)
            assets.removeAll { $0.id == asset.id }
            for i in slots.indices where slots[i]?.id == asset.id { slots[i] = nil }
        }
        syncEngine()
        scheduleSave()
    }

    public func scanSources() {
        guard !isScanning else { return }
        for source in sources where source.enabled {
            scanSource(source)
        }
    }

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
                if self.sources.contains(where: { $0.id == sourceID && $0.enabled }) {
                    self.add(urls: result, source: sourceID)
                    self.sourceFingerprints[sourceID] = Self.modificationDate(of: url)
                }
                self.activeScans -= 1
                if self.activeScans == 0 { self.isScanning = false }
            }
        }
    }

    public func startSourceWatcher() {
        guard sourceWatcherTask == nil else { return }
        sourceWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkSourcesForChanges()
            }
        }
    }

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
                sourceFingerprints[source.id] = current
                scanSource(source)
                continue
            }
            if abs(current.timeIntervalSince(known)) > 1.5 {
                sourceFingerprints[source.id] = current
                scanSource(source)
            }
        }
    }

    nonisolated private static func modificationDate(of url: URL) -> Date {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    // MARK: - Sélection Multi (⌘+Clic)

    public func toggleSelection(_ asset: VideoAsset) {
        if let index = selectedOrder.firstIndex(of: asset.id) {
            selectedOrder.remove(at: index)
        } else {
            selectedOrder.append(asset.id)
        }
    }

    public func selectOnly(_ asset: VideoAsset) {
        selectedOrder = [asset.id]
    }

    public func clearSelection() {
        selectedOrder = []
    }

    public var selectedAssets: [VideoAsset] {
        selectedOrder.prefix(VideoLibrary.maxSlots).compactMap { id in
            assets.first { $0.id == id }
        }
    }

    public func launchSelected() {
        let selected = selectedAssets
        guard !selected.isEmpty else { return }
        for (index, asset) in selected.enumerated() {
            assign(asset, to: index)
        }
        clearSelection()
    }

    public func ensureInLibrary(_ url: URL) -> VideoAsset? {
        let key = canonicalPath(for: url)
        if let existing = assets.first(where: { canonicalPath(for: $0.url) == key }) {
            return existing
        }
        add(urls: [url], source: nil)
        return assets.first(where: { canonicalPath(for: $0.url) == key })
    }

    public func toggleFavorite(_ asset: VideoAsset) {
        asset.isFavorite.toggle()
        favoritesRevision += 1
    }

    public func playbackPosition(for url: URL) -> Double {
        let key = canonicalPath(for: url)
        return UserDefaults.standard.dictionary(forKey: "playback.positions")?[key] as? Double ?? 0
    }

    // MARK: - Files de Lecture par Slot

    public func queue(for slot: Int) -> [VideoAsset] {
        guard slots.indices.contains(slot), let raw = queues[slot] else { return [] }
        let live = raw.filter { asset in assets.contains(where: { $0.id == asset.id }) }
        if live.count != raw.count {
            queues[slot] = live
            scheduleSave()
        }
        return live
    }

    public func setQueue(_ queue: [VideoAsset], for slot: Int) {
        guard slots.indices.contains(slot) else { return }
        queues[slot] = queue
        scheduleSave()
    }

    public func shuffleQueues() {
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

    public func next(in slot: Int) -> VideoAsset? {
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

    private func defaultQueue(for slot: Int) -> [VideoAsset] {
        let loadedIDs = Set(slots.compactMap { $0?.id })
        return assets.filter { !loadedIDs.contains($0.id) }
    }

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

    // MARK: - Remplacement Automatique & Préchargement

    private func autoReplace(slot: Int, failedURL: URL? = nil) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        let expectedID = slots[slot]?.id
        guard Date().timeIntervalSince(lastReplacementDate) >= 1.0 else {
            pendingReplacements[slot]?.cancel()
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pendingReplacements[slot] = nil
                guard self.engine.autoReplace, self.slots.indices.contains(slot),
                      self.slots[slot]?.id == expectedID else { return }
                self.applyReplacement(slot: slot, failedURL: failedURL)
            }
            pendingReplacements[slot] = task
            return
        }
        applyReplacement(slot: slot, failedURL: failedURL)
    }

    private func applyReplacement(slot: Int, failedURL: URL? = nil) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        lastReplacementDate = Date()

        if let failedURL {
            failedURLs[slot, default: [:]][failedURL] = Date()
        } else {
            failedURLs.removeValue(forKey: slot)
        }

        guard let next = next(in: slot) else {
            emptySlotAfterFailure(slot)
            return
        }

        let now = Date()
        let recent = failedURLs[slot, default: [:]].filter { now.timeIntervalSince($0.value) < 300 }
        failedURLs[slot] = recent
        if recent.keys.contains(next.url) {
            emptySlotAfterFailure(slot)
            return
        }

        slots[slot] = next
        syncEngine()
        engine.joinNewSlot(slot)
    }

    private func emptySlotAfterFailure(_ slot: Int) {
        failedURLs.removeValue(forKey: slot)
        slots[slot] = nil
        syncEngine()
        engine.setSlotError("Fichier illisible", for: slot)
    }

    private func handleSlotFailure(_ slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        autoReplace(slot: slot, failedURL: slots[slot]?.url)
    }

    public func prepareNext(for slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot),
              let current = slots[slot] else { return }
        guard let next = nextCandidate(for: slot), next.id != current.id else { return }
        let url = next.url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 2.0
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await item.asset.load(.duration)
            guard !Task.isCancelled else { return }
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

    // MARK: - Persistance

    public func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    public func saveNow() {
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
        d.set(slots.map { $0?.url.standardizedFileURL.absoluteString ?? "" }, forKey: Self.slotsKey)
        persistQueues()
    }

    public func restoreLibrary() {
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
            guard slots.indices.contains(index) else { continue }
            if let asset = assets.first(where: { $0.url.standardizedFileURL.absoluteString == urlString }) {
                slots[index] = asset
            }
        }
        syncEngine()
        restoreQueues()
        restoreSources()
        for asset in assets where assetSource[asset.id] == nil {
            let path = canonicalPath(for: asset.url)
            if let source = sources.first(where: { path.hasPrefix(canonicalPath(for: $0.url) + "/") }) {
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

    private func persistQueues() {
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

    private func syncEngine() {
        var configuration: [Int: VideoAsset] = [:]
        for (index, asset) in slots.enumerated() {
            guard let asset else { continue }
            configuration[index] = asset
        }
        engine.reconfigure(slots: configuration)
        scheduleSave()
    }

    // MARK: - Filtrage Vidéo & Métadonnées

    nonisolated private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "ts", "m2ts"]

    nonisolated private static func fileType(of url: URL) -> UTType? {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    nonisolated public static func videoFiles(from urls: [URL]) -> [URL] {
        urls.filter { url in
            if let type = Self.fileType(of: url) {
                return type.conforms(to: .movie) || type.conforms(to: .video)
            }
            return videoExtensions.contains(url.pathExtension.lowercased())
        }
    }

    private func loadMetadata(for asset: VideoAsset) async {
        let url = asset.url
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        if let cached = MetadataCache.shared.get(for: url) {
            asset.duration = CMTime(seconds: cached.duration, preferredTimescale: 600)
            asset.size = CGSize(width: cached.width, height: cached.height)
            asset.frameRate = cached.frameRate
            asset.thumbnail = await ThumbnailCache.shared.thumbnail(for: asset.url, variant: .landscape)
            return
        }

        do {
            let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            asset.duration = try await avAsset.load(.duration)

            if let track = try await avAsset.loadTracks(withMediaType: .video).first {
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
            asset.thumbnail = await ThumbnailCache.shared.thumbnail(for: asset.url, variant: .landscape)
        } catch {}
    }
}
