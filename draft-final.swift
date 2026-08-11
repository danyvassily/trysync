import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Modèle vidéo

final class VideoAsset: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var duration: CMTime = .zero
    var frameRate: Double = 0
    var size: CGSize = .zero
    var thumbnail: NSImage?

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Bibliothèque vidéo

@MainActor
final class VideoLibrary: ObservableObject {
    static let shared = VideoLibrary()
    static let maxSlots = 3

    @Published var slots: [VideoAsset?] = Array(repeating: nil, count: 3)
    @Published var assets: [VideoAsset] = []
    @Published var selectedSlot = 0

    let engine = SyncEngine()

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "ts", "m2ts"]

    static func isVideo(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .movie) || type.conforms(to: .video)
        }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    func select(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        selectedSlot = slot
    }

    func clear(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
        syncEngine()
    }

    func clearAll() {
        slots = Array(repeating: nil, count: 3)
        assets = []
        engine.clear()
    }

    func assign(_ asset: VideoAsset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = asset
        syncEngine()
    }

    func removeAsset(_ asset: VideoAsset) {
        assets.removeAll { $0.id == asset.id }
        for i in slots.indices where slots[i]?.id == asset.id { slots[i] = nil }
        syncEngine()
    }

    func ingest(_ urls: [URL]) {
        let videos = urls.filter { Self.isVideo($0) }
        guard !videos.isEmpty else { return }
        let existing = Set(assets.map(\.url))
        for url in videos where !existing.contains(url) {
            let asset = VideoAsset(url: url)
            assets.append(asset)
            loadMetadata(for: asset)
            let slot = (slots[selectedSlot] == nil) ? selectedSlot : (firstEmptySlot() ?? selectedSlot)
            slots[slot] = asset
        }
        syncEngine()
    }

    private func firstEmptySlot() -> Int? {
        slots.firstIndex(where: { $0 == nil })
    }

    private func loadMetadata(for asset: VideoAsset) {
        Task { @MainActor in
            let accessing = asset.url.startAccessingSecurityScopedResource()
            defer { if accessing { asset.url.stopAccessingSecurityScopedResource() } }
            do {
                let avAsset = AVURLAsset(url: asset.url)
                asset.duration = try await avAsset.load(.duration)
                if let track = try await avAsset.loadTracks(withMediaType: .video).first {
                    asset.size = try await track.load(.naturalSize)
                    asset.frameRate = Double(try await track.load(.nominalFrameRate))
                }
                if asset.duration.seconds > 0 {
                    let gen = AVAssetImageGenerator(asset: avAsset)
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 640, height: 360)
                    let t = CMTime(seconds: min(0.5, asset.duration.seconds / 2), preferredTimescale: 600)
                    let (cg, _) = try await gen.image(at: t)
                    asset.thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            } catch {
                // Métadonnées indisponibles : l'asset reste utilisable pour la lecture
            }
            objectWillChange.send()
        }
    }

    private func syncEngine() {
        var dict: [Int: VideoAsset] = [:]
        for (i, asset) in slots.enumerated() where asset != nil { dict[i] = asset }
        engine.reconfigure(slots: dict)
    }
}

// MARK: - Moteur de synchronisation (cœur AVFoundation / Media Engine M3)

final class SyncEngine: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentRate: Float = 1.0
    @Published private(set) var leaderTime: CMTime = .zero
    @Published private(set) var leaderDuration: CMTime = .zero
    @Published private(set) var readyCount = 0
    @Published private(set) var driftText: [Int: String] = [:]
    @Published private(set) var slotError: [Int: String] = [:]

    private struct Slot {
        let index: Int
        let asset: VideoAsset
        let player: AVPlayer
        let item: AVPlayerItem
        var timeObserver: Any?
        var statusObservation: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
        var volume: Float = 1.0
        var muted = false
        var ended = false
    }

    private var slots: [Int: Slot] = [:]
    private var driftTimer: Timer?
    private var wasPlayingBeforeScrub = false
    private var lastLeaderIndex: Int?
    private let hostClock = CMClockGetHostTimeClock()

    private var leaderIndex: Int { slots.keys.min() ?? 0 }
    var totalSlotCount: Int { slots.count }

    // MARK: Configuration

    func reconfigure(slots newSlots: [Int: VideoAsset]) {
        // 1. Démonter les slots supprimés ou dont l'URL a changé
        let stale = slots.filter { newSlots[$0.key]?.url != $0.value.asset.url }
        for (index, slot) in stale {
            teardown(slot)
            slots.removeValue(forKey: index)
        }
        // 2. Créer les nouveaux slots
        let targetLeader = newSlots.keys.min() ?? 0
        for (index, asset) in newSlots where slots[index] == nil {
            let item = AVPlayerItem(asset: AVURLAsset(url: asset.url))
            item.preferredForwardBufferDuration = 2.0
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false // fichiers locaux : démarrage immédiat
            player.masterClock = hostClock                       // timebase hôte commune avant toute lecture
            player.volume = 1.0
            var slot = Slot(index: index, asset: asset, player: player, item: item)
            slot.muted = (index != targetLeader)
            player.isMuted = slot.muted
            attachObservers(to: &slot)
            player.playImmediately(atRate: 0) // préchauffage du pipeline de décodage matériel
            slots[index] = slot
        }
        refreshReadyCount()
        refreshLeaderDuration()
        applyLeaderAudioPolicy()
        // 3. Contenu modifié pendant la lecture : re-anchor silencieux
        if isPlaying {
            let host = CMTime(seconds: CACurrentMediaTime() + 0.2, preferredTimescale: 1000)
            for slot in slots.values where slot.item.status == .readyToPlay {
                slot.player.setRate(currentRate, time: slot.item.currentTime(), atHostTime: host)
            }
        }
    }

    func player(forSlot slot: Int) -> AVPlayer? { slots[slot]?.player }

    // MARK: Transport

    func play() {
        guard !slots.isEmpty, slots.values.allSatisfy({ $0.item.status == .readyToPlay }) else { return }
        // Date d'ancrage unique sur l'horloge hôte : tous les players démarrent au même instant
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for slot in slots.values {
            let time = slot.ended ? CMTime.zero : slot.item.currentTime()
            slots[slot.index]?.ended = false
            slot.player.setRate(currentRate, time: time, atHostTime: host)
        }
        isPlaying = true
        startDriftMonitor()
    }

    func pause() {
        for slot in slots.values { slot.player.pause() }
        isPlaying = false
        driftTimer?.invalidate()
        driftTimer = nil
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func stop() {
        for slot in slots.values {
            slot.player.pause()
            slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            slots[slot.index]?.ended = false
        }
        isPlaying = false
        leaderTime = .zero
        driftTimer?.invalidate()
        driftTimer = nil
    }

    func resync() {
        guard isPlaying else { return }
        let host = CMTime(seconds: CACurrentMediaTime() + 0.15, preferredTimescale: 1000)
        for slot in slots.values {
            slot.player.setRate(currentRate, time: slot.item.currentTime(), atHostTime: host)
        }
    }

    func setRate(_ rate: Float) {
        currentRate = rate
        guard isPlaying else { return }
        let host = CMTime(seconds: CACurrentMediaTime() + 0.12, preferredTimescale: 1000)
        for slot in slots.values {
            slot.player.setRate(rate, time: slot.item.currentTime(), atHostTime: host)
        }
    }

    func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    func endScrub(atFraction fraction: Double) {
        let target = CMTime(seconds: leaderDuration.seconds * fraction, preferredTimescale: 600)
        for slot in slots.values {
            slot.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            slots[slot.index]?.ended = false
        }
        leaderTime = target
        if wasPlayingBeforeScrub { play() }
    }

    // MARK: Audio par fenêtre

    func setVolume(_ volume: Float, forSlot slot: Int) {
        guard let s = slots[slot] else { return }
        s.player.volume = volume
        slots[slot]?.volume = volume
    }

    func setMuted(_ muted: Bool, forSlot slot: Int) {
        guard let s = slots[slot] else { return }
        s.player.isMuted = muted
        slots[slot]?.muted = muted
    }

    func isMuted(slot: Int) -> Bool { slots[slot]?.muted ?? true }
    func volume(forSlot slot: Int) -> Float { slots[slot]?.volume ?? 1.0 }

    func clear() {
        for slot in slots.values { teardown(slot) }
        slots.removeAll()
        driftTimer?.invalidate()
        driftTimer = nil
        isPlaying = false
        leaderTime = .zero
        leaderDuration = .zero
        readyCount = 0
        driftText = [:]
        slotError = [:]
    }

    // MARK: Observateurs

    private func attachObservers(to slot: inout Slot) {
        let index = slot.index
        slot.timeObserver = slot.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 10), queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item, self.leaderIndex == index else { return }
            self.leaderTime = item.currentTime()
        }
        slot.statusObservation = slot.item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .failed {
                let msg = item.error?.localizedDescription ?? "Erreur de décodage"
                DispatchQueue.main.async { self.slotError[index] = msg }
            } else if item.status == .readyToPlay {
                DispatchQueue.main.async { self.slotError.removeValue(forKey: index) }
            }
            DispatchQueue.main.async { self.refreshReadyCount() }
        }
        slot.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: slot.item, queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem else { return }
            self.markEnded(item: item)
        }
    }

    private func markEnded(item: AVPlayerItem) {
        guard let idx = slots.first(where: { $0.value.item === item })?.key else { return }
        slots[idx]?.ended = true
        if slots.values.allSatisfy(\.ended) {
            for slot in slots.values { slot.player.pause() }
            isPlaying = false
            driftTimer?.invalidate()
            driftTimer = nil
        }
    }

    private func refreshReadyCount() {
        readyCount = slots.values.filter { $0.item.status == .readyToPlay }.count
    }

    private func refreshLeaderDuration() {
        guard let leader = slots[leaderIndex] else { leaderDuration = .zero; return }
        let leaderItem = leader.item
        Task { @MainActor in
            guard let d = try? await leaderItem.asset.load(.duration), d.isNumeric,
                  self.slots[self.leaderIndex]?.item === leaderItem else { return }
            self.leaderDuration = d
        }
    }

    private func applyLeaderAudioPolicy() {
        let newLeader = leaderIndex
        if let last = lastLeaderIndex, last != newLeader {
            slots[newLeader]?.player.isMuted = false
            slots[newLeader]?.muted = false
        }
        lastLeaderIndex = newLeader
    }

    // MARK: Correction de dérive (anti-désynchronisation)

    private func startDriftMonitor() {
        driftTimer?.invalidate()
        driftTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.monitorDrift()
        }
    }

    private func monitorDrift() {
        guard isPlaying, let leader = slots[leaderIndex] else { return }
        let leaderCurrent = leader.item.currentTime()
        for slot in slots.values where slot.index != leaderIndex {
            let delta = leaderCurrent - slot.item.currentTime()
            let absDelta = abs(delta.seconds)
            if absDelta > 0.05 {
                let corrected = slot.item.currentTime() + delta
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                slot.player.setRate(currentRate, time: corrected, atHostTime: host)
            }
            let text = absDelta >= 0.01 ? String(format: "Δ %.0f ms", absDelta * 1000) : nil
            if driftText[slot.index] != text {
                if let text { driftText[slot.index] = text } else { driftText.removeValue(forKey: slot.index) }
            }
        }
    }

    // MARK: Nettoyage

    private func teardown(_ slot: Slot) {
        slot.player.pause()
        if let token = slot.timeObserver { slot.player.removeTimeObserver(token) }
        slot.statusObservation?.invalidate()
        if let obs = slot.endObserver { NotificationCenter.default.removeObserver(obs) }
        slot.player.replaceCurrentItem(with: nil) // libère item + sessions VideoToolbox
    }

    deinit {
        driftTimer?.invalidate()
        for slot in slots.values { teardown(slot) }
    }
}

// MARK: - Rendu vidéo (AVPlayerLayer, couche hôte)

final class PlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        didSet { if playerLayer.player !== player { playerLayer.player = player } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 12
        playerLayer.masksToBounds = true
        layer = playerLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas supporté") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { playerLayer.player = nil } // libère la couche de rendu
    }
}

struct VideoPaneView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView(frame: .zero) }
    func updateNSView(_ nsView: PlayerLayerView, context: Context) { nsView.player = player }
}

// MARK: - Accès fenêtre

struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

// MARK: - Accès aux fichiers (Sandbox)

func openVideosPanel() -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.prompt = "Ajouter"
    panel.message = "Choisissez jusqu'à 3 vidéos"
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}

func ingestVideos(_ urls: [URL]) {
    Task { @MainActor in
        VideoLibrary.shared.ingest(urls)
    }
}

// MARK: - Helpers

func timeString(_ time: CMTime) -> String {
    guard time.isNumeric, time.seconds.isFinite, time.seconds >= 0 else { return "0:00" }
    let total = Int(time.seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Vues

struct ContentView: View {
    @EnvironmentObject private var library: VideoLibrary
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                TopBar()
                if library.assets.isEmpty {
                    Spacer(minLength: 0)
                    EmptyStateView()
                    Spacer(minLength: 0)
                } else {
                    GalleryStrip()
                    stage
                    TransportBar()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowAccessor { window in
            window?.isMovableByWindowBackground = true
        })
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isDropTargeted = targeted }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.06, blue: 0.09), Color(red: 0.02, green: 0.02, blue: 0.035)],
                startPoint: .top, endPoint: .bottom
            )
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(10)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var stage: some View {
        let filled = library.slots.indices.filter { library.slots[$0] != nil }
        GeometryReader { _ in
            switch filled.count {
            case 1:
                VideoPane(slotIndex: filled[0]).padding(6)
            case 2:
                HStack(spacing: 8) {
                    VideoPane(slotIndex: filled[0])
                    VideoPane(slotIndex: filled[1])
                }
                .padding(6)
            case 3:
                HStack(spacing: 8) {
                    VideoPane(slotIndex: filled[0])
                    VStack(spacing: 8) {
                        VideoPane(slotIndex: filled[1])
                        VideoPane(slotIndex: filled[2])
                    }
                }
                .padding(6)
            default:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: filled)
    }

    private func addDropped(_ urls: [URL]) {
        Task { @MainActor in VideoLibrary.shared.ingest(urls) }
    }
}

struct TopBar: View {
    @EnvironmentObject private var library: VideoLibrary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("TriSync").font(.system(size: 15, weight: .bold))
                Text("Lecture synchronisée · Apple Silicon").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !library.assets.isEmpty {
                Text("\(library.assets.count) vidéo\(library.assets.count > 1 ? "s" : "") · \(library.slots.filter { $0 != nil }.count)/3 fenêtres")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { addVideos() } label: {
                Label("Ouvrir…", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command])
            .help("Ajouter des vidéos (⌘O)")
            if !library.assets.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { library.clearAll() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Tout effacer")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func addVideos() {
        let urls = openVideosPanel()
        if !urls.isEmpty { ingestVideos(urls) }
    }
}

struct GalleryStrip: View {
    @EnvironmentObject private var library: VideoLibrary

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(library.assets) { asset in
                    chip(for: asset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(height: 122)
    }

    private func chip(for asset: VideoAsset) -> some View {
        let slots = library.slots.indices.filter { library.slots[$0]?.id == asset.id }
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumb(for: asset)
                if !slots.isEmpty {
                    Text(slots.map { ["A", "B", "C"][$0] }.joined(separator: " "))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .padding(4)
                }
            }
            Text(asset.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(slots.isEmpty ? Color.white.opacity(0.03) : Color.white.opacity(0.07))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .onTapGesture { library.assign(asset, to: library.selectedSlot) }
        .help("Cliquer : placer dans la fenêtre \(["A", "B", "C"][library.selectedSlot])")
    }

    @ViewBuilder private func thumb(for asset: VideoAsset) -> some View {
        if let img = asset.thumbnail {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 150, height: 84)
                .clipped()
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.black.opacity(0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film").foregroundStyle(.secondary)
            }
            .frame(width: 150, height: 84)
        }
    }
}

struct VideoPane: View {
    @EnvironmentObject private var library: VideoLibrary
    let slotIndex: Int

    private var asset: VideoAsset? { library.slots[slotIndex] }
    private var isLeader: Bool { library.slots.firstIndex(where: { $0 != nil }) == slotIndex }

    var body: some View {
        ZStack(alignment: .bottom) {
            videoLayer
            overlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    library.selectedSlot == slotIndex ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.07),
                    lineWidth: library.selectedSlot == slotIndex ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { library.select(slot: slotIndex) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    @ViewBuilder private var videoLayer: some View {
        if let player = library.engine.player(forSlot: slotIndex) {
            VideoPaneView(player: player)
        } else {
            ZStack {
                Color.black.opacity(0.5)
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text("Chargement…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var overlay: some View {
        VStack {
            HStack {
                if isLeader {
                    Label("MAÎTRE", systemImage: "timer")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if let err = library.engine.slotError[slotIndex] {
                    Text(err).font(.system(size: 10)).foregroundStyle(.red)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                } else if let drift = library.engine.driftText[slotIndex] {
                    Text(drift).font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(10)
            Spacer()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset?.title ?? "—").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let asset {
                        Text(asset.size.width > 0 ? "\(Int(asset.size.width))×\(Int(asset.size.height)) · \(timeString(asset.duration))" : timeString(asset.duration))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let asset {
                    Button {
                        library.engine.setMuted(!library.engine.isMuted(slot: slotIndex), forSlot: slotIndex)
                    } label: {
                        Image(systemName: library.engine.isMuted(slot: slotIndex) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Couper le son")
                    Slider(value: volumeBinding, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 90)
                        .help("Volume")
                    Button { library.clear(slot: slotIndex) } label: {
                        Image(systemName: "xmark").frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .help("Retirer de la fenêtre")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(10)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(library.engine.volume(forSlot: slotIndex)) },
            set: { library.engine.setVolume(Float($0), forSlot: slotIndex) }
        )
    }
}

struct TransportBar: View {
    @EnvironmentObject private var library: VideoLibrary
    @State private var scrub: Double = 0
    @State private var isScrubbing = false

    private var engine: SyncEngine { library.engine }
    private var activeSlots: Int { library.slots.filter { $0 != nil }.count }
    private var allReady: Bool { engine.readyCount >= activeSlots }

    var body: some View {
        HStack(spacing: 14) {
            Button { engine.togglePlay() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(engine.isPlaying ? Color.white.opacity(0.12) : Color.accentColor, in: Circle())
                    .foregroundStyle(engine.isPlaying ? .primary : .white)
            }
            .buttonStyle(.plain)
            .disabled(!allReady)
            .keyboardShortcut(.space, modifiers: [])
            .help(allReady ? "Lecture / Pause (espace)" : "Chargement…")

            Button { engine.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!allReady)
            .help("Arrêter (retour au début)")

            Button { engine.resync() } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!engine.isPlaying)
            .help("Re-synchroniser les flux")

            Spacer()

            Text(timeString(engine.leaderTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Slider(value: $scrub, in: 0...1, onEditingChanged: { editing in
                if editing {
                    isScrubbing = true
                    engine.beginScrub()
                } else {
                    isScrubbing = false
                    engine.endScrub(atFraction: scrub)
                }
            })
            .frame(maxWidth: 320)
            .disabled(!allReady || engine.leaderDuration.seconds <= 0)
            .onChange(of: engine.leaderTime) { _, newTime in
                if !isScrubbing, engine.leaderDuration.seconds > 0 {
                    scrub = min(max(newTime.seconds / engine.leaderDuration.seconds, 0), 1)
                }
            }
            Text(timeString(engine.leaderDuration))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Picker("Vitesse", selection: rateBinding) {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Text(rateLabel(r)).tag(r)
                }
            }
            .labelsHidden()
            .frame(width: 72)
            .disabled(!allReady)
            .help("Vitesse de lecture")

            Spacer()

            statusText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var rateBinding: Binding<Double> {
        Binding(get: { Double(engine.currentRate) }, set: { engine.setRate(Float($0)) })
    }

    private func rateLabel(_ r: Double) -> String {
        if r == 1.0 { return "1×" }
        return (r == r.rounded()) ? "\(Int(r))×" : String(format: "%.2f×", r).replacingOccurrences(of: ".", with: ",")
    }

    @ViewBuilder private var statusText: some View {
        if engine.isPlaying {
            Label("Lecture synchronisée", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else if !allReady {
            Label("Chargement \(engine.readyCount)/\(activeSlots)…", systemImage: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("Prêt").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView: View {
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .opacity(pulsing ? 0.55 : 1)
                .scaleEffect(pulsing ? 0.94 : 1)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
            VStack(spacing: 6) {
                Text("Jusqu'à 3 vidéos, parfaitement synchronisées")
                    .font(.system(size: 20, weight: .semibold))
                Text("Glissez vos fichiers dans la fenêtre, ou ajoutez-les depuis votre Mac. Le décodage est accéléré par le Media Engine de votre puce Apple Silicon.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
            Button {
                let urls = openVideosPanel()
                if !urls.isEmpty { ingestVideos(urls) }
            } label: {
                Label("Choisir des vidéos…", systemImage: "folder.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Point d'entrée

@main
struct TriSyncApp: App {
    @StateObject private var library = VideoLibrary.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .preferredColorScheme(.dark)
    }
}
