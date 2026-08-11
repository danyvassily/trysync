import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import Combine

/// Moteur de synchronisation multi-vidéos pour TriSync (jusqu'à 5 flux).
/// Synchronisé sur horloge hôte à la trame près (M3 / VideoToolbox).
@MainActor
public final class SyncEngine: NSObject, ObservableObject {

    // MARK: - État publié pour SwiftUI

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentRate: Float = 1.0
    @Published public private(set) var leaderTime: CMTime = .zero
    @Published public private(set) var leaderDuration: CMTime = .zero
    @Published public private(set) var readyCount = 0
    @Published public private(set) var driftText: [Int: String] = [:]
    @Published public private(set) var slotError: [Int: String] = [:]
    @Published public private(set) var audioSlot: Int?
    @Published public private(set) var independentSlot: Int?
    @Published public private(set) var referenceMode: ReferenceMode = .auto
    @Published public private(set) var manualReferenceSlot: Int?

    // MARK: - Proposition de Reprise

    public struct ResumeOffer: Equatable, Sendable {
        public let slot: Int
        public let url: URL
        public let position: Double
        public var label: String { timeString(CMTime(seconds: position, preferredTimescale: 600)) }

        public init(slot: Int, url: URL, position: Double) {
            self.slot = slot
            self.url = url
            self.position = position
        }
    }

    @Published public private(set) var resumeOffer: ResumeOffer?

    // MARK: - État interne

    private var slotStates: [Int: SlotState] = [:]
    private var driftTimer: Timer?
    private var positions: [String: Double] = [:]
    private var positionSaveWork: DispatchWorkItem?
    private var resumeDismissWork: DispatchWorkItem?
    private var wasPlayingBeforeScrub = false
    private var playRequestedWhileRewinding = false
    private var rewindPendingSlots: Set<Int> = []
    private var seekGeneration = 0
    private static let positionsKey = "playback.positions"

    // Callbacks vers la bibliothèque
    public var autoReplace = true
    public var onItemEnded: ((Int) -> Void)?
    public var onSlotFailed: ((Int) -> Void)?
    public var onPreloadNeeded: ((Int) -> Void)?

    // Préchargement
    public struct PendingPreload: @unchecked Sendable {
        public let url: URL
        public let item: AVPlayerItem
    }
    public private(set) var pendingItems: [Int: PendingPreload] = [:]
    private var preloadRequested: Set<Int> = []

    // Gestion des échecs & watchdog
    private var failedReplacementTasks: [Int: Task<Void, Never>] = [:]
    private var failedReplacementPending: Set<Int> = []
    private var lastProgression: [Int: (time: CMTime, date: Date)] = [:]
    private var persistentSlotErrors: [Int: String] = [:]
    private var startFromZeroOnReady: Set<Int> = []

    // MARK: - Propriétés de référence

    private var leaderSlot: Int? { slotStates.keys.min() }
    private var leaderState: SlotState? {
        guard let slot = leaderSlot else { return nil }
        return slotStates[slot]
    }

    public var currentReferenceSlot: Int? { referenceSlot }

    private var referenceSlot: Int? {
        if referenceMode == .manual, let manual = manualReferenceSlot,
           let state = slotStates[manual], !state.ended {
            return manual
        }
        if let leader = leaderSlot, let state = slotStates[leader], !state.ended {
            return leader
        }
        return slotStates.first(where: { !$0.value.ended })?.key
    }

    private var referenceState: SlotState? {
        guard let slot = referenceSlot else { return nil }
        return slotStates[slot]
    }

    public var totalSlotCount: Int { slotStates.count }

    private var isReadyToPlayAll: Bool {
        !slotStates.isEmpty && slotStates.values.allSatisfy { $0.item.status == .readyToPlay }
    }

    // MARK: - Initialisation & Déinit

    public override init() {
        super.init()
        loadPositions()
    }

    deinit {
        driftTimer?.invalidate()
        let pendings = Array(pendingItems.values)
        let states = Array(slotStates.values)
        DispatchQueue.main.async {
            for pending in pendings {
                pending.item.asset.cancelLoading()
            }
            states.forEach { Self.teardown($0) }
        }
    }

    // MARK: - Configuration des Slots

    public func reconfigure(slots newSlots: [Int: VideoAsset]) {
        let oldLeader = leaderSlot
        let newLeader = newSlots.keys.min()
        let oldReferenceItem = referenceState?.item

        let removed = slotStates.keys.filter { slot in
            guard let asset = newSlots[slot] else { return true }
            guard let state = slotStates[slot] else { return true }
            return state.url != asset.url || state.item.status == .failed
        }
        if !removed.isEmpty {
            cancelPendingPlaybackStart()
            for slot in removed {
                teardownSlot(slot)
            }
        }

        for (slot, asset) in newSlots where slotStates[slot] == nil {
            addSlot(slot, url: asset.url, isLeader: slot == newLeader)
        }

        let refSlot = referenceSlot
        for (slot, state) in slotStates where !state.userAdjustedMute {
            let shouldMute = (slot != refSlot)
            if state.muted != shouldMute {
                state.muted = shouldMute
                state.player.isMuted = shouldMute
            }
        }

        if audioSlot != nil {
            setAudioSlot(audioSlot)
        }

        let validSlots = Set(slotStates.keys)
        if driftText.keys.contains(where: { !validSlots.contains($0) }) {
            driftText = driftText.filter { validSlots.contains($0.key) }
        }
        if slotError.keys.contains(where: { !validSlots.contains($0) }) {
            slotError = slotError.filter { validSlots.contains($0.key) }
        }
        if lastProgression.keys.contains(where: { !validSlots.contains($0) }) {
            lastProgression = lastProgression.filter { validSlots.contains($0.key) }
        }

        for (slot, message) in persistentSlotErrors where !validSlots.contains(slot) {
            if slotError[slot] != message { slotError[slot] = message }
        }
        updateReadyCount()

        if referenceSlot != oldLeader || referenceState?.item !== oldReferenceItem {
            refreshReferenceDuration()
        }

        if slotStates.isEmpty {
            resetPlaybackState()
        } else if isPlaying {
            if isReadyToPlayAll {
                startPlayback()
            }
        }
    }

    public func player(forSlot slot: Int) -> AVPlayer? {
        slotStates[slot]?.player
    }

    public func isReferenceSlot(_ slot: Int) -> Bool {
        referenceSlot == slot
    }

    public func referencePlayer() -> AVPlayer? {
        guard let slot = referenceSlot else { return nil }
        return slotStates[slot]?.player
    }

    // MARK: - Contrôle de Lecture

    public func play() {
        guard !slotStates.isEmpty, !isPlaying, !playRequestedWhileRewinding,
              isReadyToPlayAll, currentRate > 0 else { return }

        let toRewind = slotStates.values.filter(\.ended).map(\.slot)
        guard !toRewind.isEmpty else {
            startPlayback()
            return
        }

        playRequestedWhileRewinding = true
        rewindPendingSlots = Set(toRewind)

        let rewindWatchdog = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playRequestedWhileRewinding else { return }
                self.rewindPendingSlots.removeAll()
                self.playRequestedWhileRewinding = false
                self.startPlayback()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: rewindWatchdog)

        for slot in toRewind {
            guard let state = slotStates[slot] else { continue }
            state.ended = false
            state.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.playRequestedWhileRewinding else { return }
                    self.rewindPendingSlots.remove(slot)
                    if self.rewindPendingSlots.isEmpty {
                        self.playRequestedWhileRewinding = false
                        self.startPlayback()
                    }
                }
            }
        }
    }

    public func pause() {
        cancelPendingPlaybackStart()
        stopDriftMonitor()
        lastProgression.removeAll()

        for state in slotStates.values where !state.ended {
            let time = state.player.currentTime()
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                savePosition(time.seconds, for: state.url)
            }
        }
        for state in slotStates.values {
            state.player.pause()
        }
        isPlaying = false
        if currentRate == 0 { currentRate = 1.0 }
    }

    public func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    public func stop() {
        setIndependentSlot(nil)
        pause()
        seekAll(to: .zero)
        for state in slotStates.values {
            clearPosition(for: state.url)
        }
        driftText.removeAll()
    }

    public func resync() {
        setIndependentSlot(nil)
        guard let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return }
        let target = reference.item.currentTime()
        for (slot, state) in slotStates where slot != reference.slot && !state.ended {
            guard state.item.status == .readyToPlay else { continue }
            if isPlaying {
                state.player.setRate(
                    currentRate,
                    time: target,
                    atHostTime: CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                )
            } else {
                state.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            publishDrift((target - state.item.currentTime()).seconds, for: slot)
        }
        leaderTime = target
    }

    public func setRate(_ rate: Float) {
        currentRate = rate
        guard isPlaying else { return }
        if rate == 0 {
            pause()
            return
        }
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended && state.item.status == .readyToPlay {
            state.player.setRate(rate, time: state.player.currentTime(), atHostTime: host)
        }
    }

    public func nudgeRate(_ factor: Float) {
        setRate(min(max(currentRate * factor, 0.25), 2.0))
    }

    public func skip(by seconds: Double) {
        if let slot = independentSlot, let state = slotStates[slot], !state.ended {
            let current = state.item.currentTime()
            let duration = state.item.duration.isNumeric ? state.item.duration.seconds : 0
            var target = current.seconds + seconds
            if duration > 0, duration.isFinite { target = min(max(target, 0), duration) }
            seekSlot(slot, to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
            return
        }
        guard let reference = referenceState, reference.item.status == .readyToPlay else { return }
        let current = reference.item.currentTime()
        let duration = leaderDuration.isNumeric && leaderDuration.seconds.isFinite ? leaderDuration.seconds : 0
        var target = current.seconds + seconds
        if duration > 0 { target = min(max(target, 0), duration) }
        seekAll(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
    }

    // MARK: - Scrubbing & Navigation

    public func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    public func endScrub(atFraction fraction: Double) {
        guard timelineDuration.isNumeric, timelineDuration.seconds.isFinite, timelineDuration.seconds > 0 else { return }
        let clamped = min(max(fraction, 0.0), 1.0)
        let target = CMTime(seconds: timelineDuration.seconds * clamped, preferredTimescale: 600)
        let resume = wasPlayingBeforeScrub
        wasPlayingBeforeScrub = false
        seekAll(to: target) { [weak self] in
            guard let self, resume else { return }
            self.play()
        }
    }

    public var timelineTime: CMTime {
        if let slot = independentSlot, let state = slotStates[slot], !state.ended {
            return state.item.currentTime()
        }
        return leaderTime
    }

    public var timelineDuration: CMTime {
        if let slot = independentSlot, let state = slotStates[slot], !state.ended {
            let duration = state.item.duration
            return duration.isNumeric ? duration : leaderDuration
        }
        return leaderDuration
    }

    // MARK: - Volume & Audio

    public func setVolume(_ volume: Float, forSlot slot: Int) {
        guard let state = slotStates[slot] else { return }
        state.volume = min(max(volume, 0.0), 1.0)
        state.player.volume = state.volume
    }

    public func volume(forSlot slot: Int) -> Float {
        slotStates[slot]?.volume ?? 1.0
    }

    public func setMuted(_ muted: Bool, forSlot slot: Int) {
        guard let state = slotStates[slot] else { return }
        state.userAdjustedMute = true
        state.muted = muted
        state.player.isMuted = muted
    }

    public func isMuted(slot: Int) -> Bool {
        slotStates[slot]?.muted ?? false
    }

    public func setAudioSlot(_ slot: Int?) {
        let target: Int?
        if let slot, slotStates[slot] != nil {
            target = slot
        } else {
            target = referenceSlot
        }
        for (index, state) in slotStates {
            let isAudio = (index == target)
            if isAudio {
                state.muted = false
                state.player.isMuted = false
            }
            let desired: Float = isAudio ? 1.0 : 0.0
            if state.volume != desired {
                state.volume = desired
                state.player.volume = desired
            }
        }
        if audioSlot != slot {
            audioSlot = slot
        }
    }

    public func isAudioSlot(_ slot: Int) -> Bool {
        (audioSlot ?? referenceSlot) == slot
    }

    // MARK: - Maître & Mode Référentiel

    public func setReferenceMode(_ mode: ReferenceMode) {
        if referenceMode != mode { referenceMode = mode }
        if mode != .manual && manualReferenceSlot != nil { manualReferenceSlot = nil }
    }

    public func setManualMaster(_ slot: Int?) {
        guard let slot, let state = slotStates[slot], !state.ended else { return }
        if referenceMode != .manual { referenceMode = .manual }
        if manualReferenceSlot != slot { manualReferenceSlot = slot }
        if independentSlot == slot { independentSlot = nil }
    }

    public func setIndependentSlot(_ slot: Int?) {
        if let slot, slotStates[slot] == nil || (slot == referenceSlot && referenceMode != .none) {
            independentSlot = nil
            return
        }
        if independentSlot != slot { independentSlot = slot }
    }

    public func isIndependentSlot(_ slot: Int) -> Bool {
        independentSlot == slot
    }

    // MARK: - Dérive & Watchdog

    public var maxDriftMilliseconds: Int? {
        guard let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return nil }
        let refTime = reference.item.currentTime()
        var maxMs: Int?
        for state in slotStates.values where state.slot != reference.slot && state.slot != independentSlot && !state.ended {
            guard state.item.status == .readyToPlay else { continue }
            let delta = abs((refTime - state.item.currentTime()).seconds)
            guard delta.isFinite else { continue }
            let ms = Int((delta * 1000).rounded())
            if let current = maxMs {
                if ms > current { maxMs = ms }
            } else {
                maxMs = ms
            }
        }
        return maxMs
    }

    private func startDriftMonitor() {
        stopDriftMonitor()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDrift()
                self?.checkFrozenSlots()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }

    private func stopDriftMonitor() {
        driftTimer?.invalidate()
        driftTimer = nil
    }

    private func checkDrift() {
        guard isPlaying, let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return }
        let referenceCurrent = reference.item.currentTime()
        for (slot, state) in slotStates where slot != reference.slot && slot != independentSlot {
            guard !state.ended, state.item.status == .readyToPlay else { continue }
            let otherCurrent = state.item.currentTime()
            let delta = referenceCurrent - otherCurrent
            guard delta.seconds.isFinite else { continue }
            if abs(delta.seconds) > 0.05 {
                let duration = state.item.duration
                if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0.5,
                   (otherCurrent + delta).seconds > duration.seconds - 0.2 {
                    continue
                }
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(currentRate, time: otherCurrent + delta, atHostTime: host)
                lastProgression[slot] = (otherCurrent + delta, Date())
            }
            publishDrift(delta.seconds, for: slot)
        }

        for (_, state) in slotStates where !state.ended {
            let time = state.player.currentTime()
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                positions[canonicalPath(for: state.url)] = time.seconds
            }
        }
        schedulePositionsSave()
    }

    private func publishDrift(_ deltaSeconds: Double, for slot: Int) {
        guard deltaSeconds.isFinite else { return }
        let magnitude = abs(deltaSeconds)
        if magnitude >= 0.01 {
            let text = String(format: "Δ %.0f ms", magnitude * 1000.0)
            if driftText[slot] != text { driftText[slot] = text }
        } else if magnitude < 0.005 {
            if driftText[slot] != nil { driftText.removeValue(forKey: slot) }
        }
    }

    private func checkFrozenSlots(now: Date = Date()) {
        guard isPlaying else { return }
        for (slot, state) in slotStates where slot != referenceSlot && slot != independentSlot {
            guard !state.ended, state.item.status == .readyToPlay, state.player.rate != 0 else { continue }
            let current = state.item.currentTime()
            guard current.isNumeric else { continue }
            if let last = lastProgression[slot] {
                if current.seconds != last.time.seconds {
                    lastProgression[slot] = (current, now)
                } else if now.timeIntervalSince(last.date) >= 3.0 {
                    restartFrozenSlot(slot, state: state, at: current)
                    lastProgression[slot] = (current, now)
                }
            } else {
                lastProgression[slot] = (current, now)
            }
        }
    }

    private func restartFrozenSlot(_ slot: Int, state: SlotState, at time: CMTime) {
        state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying,
                      self.slotStates[slot]?.item === state.item,
                      !state.ended, state.item.status == .readyToPlay else { return }
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(self.currentRate, time: state.item.currentTime(), atHostTime: host)
            }
        }
    }

    // MARK: - Reprise & Positions

    private func loadPositions() {
        positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
    }

    public func position(for url: URL) -> Double {
        positions[canonicalPath(for: url)] ?? 0
    }

    public func savePosition(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds > 0 else { return }
        positions[canonicalPath(for: url)] = seconds
        schedulePositionsSave()
    }

    public func clearPosition(for url: URL) {
        guard positions.removeValue(forKey: canonicalPath(for: url)) != nil else { return }
        persistPositionsNow()
    }

    private func schedulePositionsSave() {
        positionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistPositionsNow() }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    public func persistPositionsNow() {
        positionSaveWork?.cancel()
        positionSaveWork = nil
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    public func offerResumeIfNeeded(slot: Int, url: URL) {
        let pos = positions[canonicalPath(for: url)] ?? 0
        guard pos > 15 else { return }
        let offer = ResumeOffer(slot: slot, url: url, position: pos)
        if resumeOffer != offer { resumeOffer = offer }
        resumeDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissResumeOffer() }
        resumeDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    public func acceptResumeOffer() {
        guard let offer = resumeOffer else { return }
        setIndependentSlot(nil)
        seekAll(to: CMTime(seconds: offer.position, preferredTimescale: 600))
        dismissResumeOffer()
    }

    public func declineResumeOffer() {
        guard let offer = resumeOffer else { return }
        setIndependentSlot(nil)
        clearPosition(for: offer.url)
        seekAll(to: .zero)
        dismissResumeOffer()
    }

    private func dismissResumeOffer() {
        resumeDismissWork?.cancel()
        resumeDismissWork = nil
        if resumeOffer != nil { resumeOffer = nil }
    }

    // MARK: - Gestion des Items Préchargés

    public func storePendingItem(_ item: AVPlayerItem, for url: URL, slot: Int) {
        cancelPendingItem(for: slot)
        pendingItems[slot] = PendingPreload(url: url, item: item)
    }

    public func consumePendingItem(for slot: Int, url: URL) -> AVPlayerItem? {
        guard let pending = pendingItems.removeValue(forKey: slot), pending.url == url else { return nil }
        preloadRequested.remove(slot)
        return pending.item
    }

    public func cancelPendingItem(for slot: Int) {
        guard let pending = pendingItems.removeValue(forKey: slot) else { return }
        pending.item.asset.cancelLoading()
        preloadRequested.remove(slot)
    }

    private func maybePreloadReplacement(for slot: Int, time: CMTime) {
        guard autoReplace, !preloadRequested.contains(slot), pendingItems[slot] == nil,
              let state = slotStates[slot], !state.ended, state.item.status == .readyToPlay else { return }
        let duration: Double
        if state.item.duration.isNumeric, state.item.duration.seconds.isFinite, state.item.duration.seconds > 0 {
            duration = state.item.duration.seconds
        } else if leaderDuration.isNumeric, leaderDuration.seconds.isFinite, leaderDuration.seconds > 0 {
            duration = leaderDuration.seconds
        } else {
            return
        }
        let remaining = duration - time.seconds
        guard remaining.isFinite, remaining >= 0, remaining < 10 else { return }
        preloadRequested.insert(slot)
        onPreloadNeeded?(slot)
    }

    // MARK: - Erreurs & Nouveaux Slots

    public func setSlotError(_ message: String, for slot: Int) {
        persistentSlotErrors[slot] = message
        if slotError[slot] != message { slotError[slot] = message }
    }

    public func joinNewSlot(_ slot: Int) {
        guard let state = slotStates[slot] else { return }
        state.ended = false
        if state.item.status == .readyToPlay {
            scheduleSlotStart(slot)
        } else {
            startFromZeroOnReady.insert(slot)
        }
    }

    private func scheduleSlotStart(_ slot: Int) {
        guard let state = slotStates[slot], !state.ended, isPlaying else { return }
        guard state.item.status == .readyToPlay else {
            startFromZeroOnReady.insert(slot)
            return
        }
        state.item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        state.player.setRate(currentRate, time: .zero, atHostTime: host)
    }

    public func clear() {
        wasPlayingBeforeScrub = false
        for slot in Array(slotStates.keys) {
            teardownSlot(slot)
        }
        resetPlaybackState()
    }

    // MARK: - Méthodes Privées

    private func addSlot(_ slot: Int, url: URL, isLeader: Bool) {
        let item: AVPlayerItem
        let asset: AVURLAsset
        if let preloaded = consumePendingItem(for: slot, url: url) {
            item = preloaded
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url)
            item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2.0
        }
        preloadRequested.remove(slot)
        persistentSlotErrors.removeValue(forKey: slot)

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.masterClock = CMClockGetHostTimeClock()
        player.playImmediately(atRate: 0)

        let state = SlotState(slot: slot, url: url, asset: asset, item: item, player: player)
        state.muted = !isLeader
        state.volume = 1.0
        player.isMuted = state.muted
        player.volume = 1.0

        state.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleStatusChange(slot: slot)
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        state.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.referenceSlot == slot else { return }
                if time != self.leaderTime {
                    self.leaderTime = time
                }
                self.maybePreloadReplacement(for: slot, time: time)
            }
        }

        state.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let endedItem = note.object as? AVPlayerItem else { return }
                self.handleItemDidPlayToEnd(item: endedItem)
            }
        }

        slotStates[slot] = state
        updateReadyCount()
    }

    private func teardownSlot(_ slot: Int) {
        guard let state = slotStates.removeValue(forKey: slot) else { return }
        if independentSlot == slot { independentSlot = nil }
        if audioSlot == slot { audioSlot = nil }
        cancelPendingItem(for: slot)
        preloadRequested.remove(slot)
        failedReplacementTasks[slot]?.cancel()
        failedReplacementTasks.removeValue(forKey: slot)
        failedReplacementPending.remove(slot)
        lastProgression.removeValue(forKey: slot)
        cancelPendingPlaybackStart()
        Self.teardown(state)
    }

    private static func teardown(_ state: SlotState) {
        state.statusObservation?.invalidate()
        state.statusObservation = nil
        if let observer = state.endObserver {
            NotificationCenter.default.removeObserver(observer)
            state.endObserver = nil
        }
        if let token = state.timeObserver {
            state.player.removeTimeObserver(token)
            state.timeObserver = nil
        }
        state.player.pause()
        state.player.replaceCurrentItem(with: nil)
    }

    private func startPlayback() {
        guard !slotStates.isEmpty else { return }
        startDriftMonitor()
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended && state.item.status == .readyToPlay {
            state.player.setRate(currentRate, time: state.player.currentTime(), atHostTime: host)
        }
        isPlaying = true
    }

    private func seekAll(to time: CMTime, completion: (() -> Void)? = nil) {
        if let slot = independentSlot, slotStates[slot] != nil {
            leaderTime = time
            seekSlot(slot, to: time)
            completion?()
            return
        }
        leaderTime = time
        seekGeneration += 1
        let generation = seekGeneration
        let slots = Array(slotStates.keys)
        guard !slots.isEmpty else {
            completion?()
            return
        }
        var remaining = slots.count
        let watchdog = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.seekGeneration == generation, remaining > 0 else { return }
                remaining = 0
                completion?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
        for slot in slots {
            guard let state = slotStates[slot] else {
                remaining -= 1
                continue
            }
            state.ended = false
            state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.seekGeneration == generation else { return }
                    remaining -= 1
                    if remaining == 0 { completion?() }
                }
            }
        }
    }

    private func seekSlot(_ slot: Int, to time: CMTime) {
        guard let state = slotStates[slot] else { return }
        state.ended = false
        state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.slotStates[slot]?.item === state.item else { return }
                if self.leaderTime != time { self.leaderTime = time }
                if self.isPlaying, state.item.status == .readyToPlay, !state.ended {
                    let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                    state.player.setRate(self.currentRate, time: state.item.currentTime(), atHostTime: host)
                }
            }
        }
    }

    private func cancelPendingPlaybackStart() {
        playRequestedWhileRewinding = false
        rewindPendingSlots.removeAll()
        seekGeneration += 1
    }

    private func resetPlaybackState() {
        cancelPendingPlaybackStart()
        wasPlayingBeforeScrub = false
        isPlaying = false
        leaderTime = .zero
        leaderDuration = .zero
        driftText.removeAll()
        slotError.removeAll()
        persistentSlotErrors.removeAll()
        lastProgression.removeAll()
        independentSlot = nil
        audioSlot = nil
        updateReadyCount()
    }

    private func handleStatusChange(slot: Int) {
        guard let state = slotStates[slot] else { return }
        switch state.item.status {
        case .readyToPlay:
            if slotError[slot] != nil { slotError.removeValue(forKey: slot) }
            if startFromZeroOnReady.remove(slot) != nil || independentSlot == slot {
                scheduleSlotStart(slot)
            } else if isPlaying, let reference = referenceState, !reference.ended {
                var target = reference.item.currentTime()
                let duration = state.item.duration
                if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0.5,
                   target.seconds > duration.seconds - 0.2 {
                    target = .zero
                }
                seekGeneration += 1
                let generation = seekGeneration
                state.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.seekGeneration == generation, self.isPlaying else { return }
                        let host = CMTime(seconds: CACurrentMediaTime() + 0.15, preferredTimescale: 1000)
                        state.player.setRate(self.currentRate, time: target, atHostTime: host)
                    }
                }
            }
        case .failed:
            let message = state.item.error?.localizedDescription ?? "Fichier illisible"
            if slotError[slot] != message { slotError[slot] = message }
            if autoReplace { scheduleFailedReplacement(for: slot) }
        case .unknown:
            break
        @unknown default:
            break
        }
        updateReadyCount()
    }

    private func scheduleFailedReplacement(for slot: Int) {
        guard !failedReplacementPending.contains(slot) else { return }
        failedReplacementPending.insert(slot)
        failedReplacementTasks[slot]?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.failedReplacementPending.remove(slot)
            self.failedReplacementTasks[slot] = nil
            guard let state = self.slotStates[slot], state.item.status == .failed else { return }
            self.onSlotFailed?(slot)
        }
        failedReplacementTasks[slot] = task
    }

    private func handleItemDidPlayToEnd(item: AVPlayerItem) {
        guard let slot = slotStates.first(where: { $0.value.item === item })?.key,
              let state = slotStates[slot] else { return }
        let wasReference = (slot == referenceSlot)
        state.ended = true
        if driftText[slot] != nil { driftText.removeValue(forKey: slot) }
        clearPosition(for: state.url)
        if independentSlot == slot { independentSlot = nil }
        if let independent = independentSlot, independent == referenceSlot { independentSlot = nil }

        if autoReplace {
            onItemEnded?(slot)
            return
        }
        if slotStates.values.allSatisfy(\.ended) {
            pause()
            return
        }
        if wasReference {
            refreshReferenceDuration()
            if let newRef = referenceState, !newRef.userAdjustedMute, newRef.muted {
                newRef.muted = false
                newRef.player.isMuted = false
            }
        }
    }

    private func refreshReferenceDuration() {
        guard let reference = referenceState else {
            if leaderDuration != .zero { leaderDuration = .zero }
            return
        }
        let item = reference.item
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let duration = try? await item.asset.load(.duration) else { return }
            if self.referenceState?.item === item {
                self.leaderDuration = duration
            }
        }
    }

    private func updateReadyCount() {
        let count = slotStates.values.filter { $0.item.status == .readyToPlay }.count
        if count != readyCount { readyCount = count }
    }
}
