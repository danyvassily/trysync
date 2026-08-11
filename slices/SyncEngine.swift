// SyncEngine.swift
//
// TriSync — moteur de synchronisation de lecture multi-vidéos.
// Jusqu'à 3 vidéos locales lues simultanément, synchronisées à la trame près
// sur le Media Engine des puces Apple Silicon (M3).
//
// Stratégie de synchronisation :
// • Horloge maître commune : AVPlayer.masterClock = CMClockGetHostTimeClock(),
//   définie AVANT toute lecture (prérequis de setRate(_:time:atHostTime:)).
// • Départ simultané : setRate(_:time:atHostTime:) appelé sur CHAQUE player avec
//   la MÊME cible d'horloge hôte future (CACurrentMediaTime() + 0,25 s). Un simple
//   .play() laisse chaque player démarrer sur son propre runloop → 50 à 300 ms de
//   gigue entre les vidéos ; l'ancrage sur l'horloge hôte garantit un départ au tick.
// • Correction de dérive : moniteur périodique (1 s) qui ré-ancre les slots en
//   retard (|Δ| > 50 ms) via setRate(_:time:atHostTime:) — repositionnement sans
//   saut d'image et sans interruption des sessions de décodage matériel.

import AVFoundation
import Combine
import CoreMedia
import Foundation
import QuartzCore

// MARK: - État interne d'un slot

/// Regroupe toutes les ressources AV d'un slot de lecture.
/// La libération complète (player, item, asset) rend les sessions de décodage
/// matériel VideoToolbox du Media Engine au système.
private final class SlotState {
    let slot: Int
    let url: URL
    let asset: AVAsset
    let item: AVPlayerItem
    let player: AVPlayer

    var timeObserver: Any?
    var statusObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    var volume: Float = 1.0
    var muted = false
    /// Vrai dès que l'utilisateur a réglé le mute manuellement :
    /// son choix est alors préservé lors d'un changement de leader.
    var userAdjustedMute = false
    /// Vrai quand l'item a atteint la fin de sa lecture.
    var ended = false

    init(slot: Int, url: URL, asset: AVAsset, item: AVPlayerItem, player: AVPlayer) {
        self.slot = slot
        self.url = url
        self.asset = asset
        self.item = item
        self.player = player
    }
}

// MARK: - Moteur de synchronisation

/// Moteur de synchronisation de TriSync : jusqu'à 3 AVPlayer démarrés
/// simultanément sur la même cible d'horloge hôte (précision à la trame près).
final class SyncEngine: NSObject, ObservableObject {

    // MARK: État publié (consommé par SwiftUI)

    @Published private(set) var isPlaying = false
    @Published private(set) var currentRate: Float = 1.0
    @Published private(set) var leaderTime: CMTime = .zero
    @Published private(set) var leaderDuration: CMTime = .zero
    @Published private(set) var readyCount = 0
    @Published private(set) var driftText: [Int: String] = [:]
    @Published private(set) var slotError: [Int: String] = [:]

    // MARK: État interne

    private var slotStates: [Int: SlotState] = [:]
    private var driftTimer: Timer?
    private var wasPlayingBeforeScrub = false
    private var playRequestedWhileRewinding = false
    private var rewindPendingSlots: Set<Int> = []
    /// Compteur de génération des seeks : invalide les complétions obsolètes
    /// (scrub rapide, pause ou reconfiguration pendant un seek en vol).
    private var seekGeneration = 0

    /// Slot leader : index le plus bas parmi les slots configurés.
    private var leaderSlot: Int? {
        slotStates.keys.min()
    }

    private var leaderState: SlotState? {
        guard let slot = leaderSlot else { return nil }
        return slotStates[slot]
    }

    /// Nombre de slots actuellement configurés.
    var totalSlotCount: Int {
        slotStates.count
    }

    private var isReadyToPlayAll: Bool {
        !slotStates.isEmpty && slotStates.values.allSatisfy { $0.item.status == .readyToPlay }
    }

    // MARK: Cycle de vie

    override init() {
        super.init()
    }

    deinit {
        // Nettoyage complet, même si le deinit survient hors du thread principal.
        stopDriftMonitor()
        let states = Array(slotStates.values)
        if Thread.isMainThread {
            states.forEach { Self.teardown($0) }
        } else {
            DispatchQueue.main.async {
                // Aucune capture de self ici : le moteur est déjà en cours de libération.
                states.forEach { Self.teardown($0) }
            }
        }
    }

    // MARK: API publique

    /// Reconfigure les slots par diff : les players dont l'URL est inchangée
    /// sont conservés, les autres sont remplacés ou retirés.
    func reconfigure(slots newSlots: [Int: VideoAsset]) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        let oldLeader = leaderSlot
        let newLeader = newSlots.keys.min()

        // 1. Retrait des slots supprimés ou dont l'URL change.
        let removed = slotStates.keys.filter { slot in
            guard let asset = newSlots[slot] else { return true }
            return slotStates[slot]?.url != asset.url
        }
        if !removed.isEmpty {
            cancelPendingPlaybackStart()
            for slot in removed {
                teardownSlot(slot)
            }
        }

        // 2. Ajout des nouveaux slots.
        for (slot, asset) in newSlots where slotStates[slot] == nil {
            addSlot(slot, url: asset.url, isLeader: slot == newLeader)
        }

        // 3. Mute par défaut : seul le leader est audible, sauf réglage utilisateur explicite.
        for (slot, state) in slotStates where !state.userAdjustedMute {
            let shouldMute = (slot != newLeader)
            if state.muted != shouldMute {
                state.muted = shouldMute
                state.player.isMuted = shouldMute
            }
        }

        // 4. Purge des états publiés orphelins + recompte.
        let validSlots = Set(slotStates.keys)
        if driftText.keys.contains(where: { !validSlots.contains($0) }) {
            driftText = driftText.filter { validSlots.contains($0.key) }
        }
        if slotError.keys.contains(where: { !validSlots.contains($0) }) {
            slotError = slotError.filter { validSlots.contains($0.key) }
        }
        updateReadyCount()

        // 5. Durée du leader (rechargée uniquement si le leader a changé).
        if leaderSlot != oldLeader {
            refreshLeaderDuration()
        }

        // 6. Reprise de la lecture si elle était en cours.
        if slotStates.isEmpty {
            resetPlaybackState()
        } else if isPlaying {
            if isReadyToPlayAll {
                startPlayback()
            }
            // Sinon : le moniteur de dérive intégrera chaque nouveau slot dès qu'il sera prêt.
        }
    }

    func player(forSlot slot: Int) -> AVPlayer? {
        slotStates[slot]?.player
    }

    /// Démarre la lecture synchronisée. Ne fait rien tant que tous les items
    /// ne sont pas prêts (bouton désactivé côté UI) ou si la lecture est déjà en cours.
    func play() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard !slotStates.isEmpty, !isPlaying, isReadyToPlayAll, currentRate > 0 else { return }

        // Rembobinage différé des slots terminés : le départ synchronisé n'intervient
        // qu'une fois tous les seeks revenus à zéro.
        let toRewind = slotStates.values.filter(\.ended).map(\.slot)
        guard !toRewind.isEmpty else {
            startPlayback()
            return
        }

        playRequestedWhileRewinding = true
        rewindPendingSlots = Set(toRewind)
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

    func pause() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        cancelPendingPlaybackStart()
        for state in slotStates.values {
            state.player.pause()
        }
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Arrête la lecture et revient au début de la vidéo.
    func stop() {
        pause()
        seekAll(to: .zero)
        driftText.removeAll()
    }

    /// Ré-aligne immédiatement tous les slots sur le leader (au-delà du seuil de dérive).
    func resync() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let leader = leaderState, !leader.ended else { return }
        let target = leader.item.currentTime()
        for (slot, state) in slotStates where slot != leader.slot {
            guard !state.ended else { continue }
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

    func setRate(_ rate: Float) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        currentRate = rate
        guard isPlaying else { return }
        if rate == 0 {
            // Taux nul = pause.
            pause()
            return
        }
        // Ré-ancrage de tous les players sur la même cible d'horloge hôte future.
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values where !state.ended {
            state.player.setRate(rate, time: state.player.currentTime(), atHostTime: host)
        }
    }

    /// Mémorise l'état de lecture puis met en pause (préparation du scrub).
    func beginScrub() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        wasPlayingBeforeScrub = isPlaying
        pause()
    }

    /// Cherche la fraction demandée sur tous les slots, puis reprend si on jouait.
    func endScrub(atFraction fraction: Double) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        // La durée du leader doit être connue pour convertir la fraction en temps.
        guard leaderDuration.isNumeric, leaderDuration.seconds.isFinite, leaderDuration.seconds > 0 else { return }
        let clamped = min(max(fraction, 0.0), 1.0)
        let target = CMTime(seconds: leaderDuration.seconds * clamped, preferredTimescale: 600)
        let resume = wasPlayingBeforeScrub
        wasPlayingBeforeScrub = false
        seekAll(to: target) { [weak self] in
            guard let self, resume else { return }
            self.play()
        }
    }

    func setVolume(_ volume: Float, forSlot slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let state = slotStates[slot] else { return }
        state.volume = min(max(volume, 0.0), 1.0)
        state.player.volume = state.volume
    }

    func setMuted(_ muted: Bool, forSlot slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let state = slotStates[slot] else { return }
        state.userAdjustedMute = true
        state.muted = muted
        state.player.isMuted = muted
    }

    func isMuted(slot: Int) -> Bool {
        slotStates[slot]?.muted ?? false
    }

    func volume(forSlot slot: Int) -> Float {
        slotStates[slot]?.volume ?? 1.0
    }

    /// Retire tous les slots et réinitialise complètement l'état publié.
    func clear() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        wasPlayingBeforeScrub = false
        for slot in Array(slotStates.keys) {
            teardownSlot(slot)
        }
        resetPlaybackState()
    }

    // MARK: Cycle de vie des slots

    private func addSlot(_ slot: Int, url: URL, isLeader: Bool) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Tampon court : fichiers locaux, démarrage rapide sans attendre le remplissage.
        item.preferredForwardBufferDuration = 2.0

        let player = AVPlayer(playerItem: item)
        // Pas d'attente anti-stall : sources locales, on privilégie la réactivité.
        player.automaticallyWaitsToMinimizeStalling = false
        // Horloge maître = horloge hôte. À définir AVANT toute lecture : c'est elle qui
        // permet à setRate(_:time:atHostTime:) d'aligner tous les players sur le même timebase.
        player.masterClock = CMClockGetHostTimeClock()

        // Pré-chauffage : initialise le pipeline de décodage (sessions VideoToolbox
        // du M3) sans démarrer la lecture — élimine le hoquet de la première image.
        player.playImmediately(atRate: 0)

        let state = SlotState(slot: slot, url: url, asset: asset, item: item, player: player)
        state.muted = !isLeader
        state.volume = 1.0
        player.isMuted = state.muted
        player.volume = 1.0

        // Observation KVO du statut (prêt / échec), publiée sur le thread principal.
        state.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleStatusChange(slot: slot)
            }
        }

        // Observateur périodique : seul le slot leader publie leaderTime.
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        state.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.leaderSlot == slot else { return }
            self.leaderTime = time
        }

        // Fin de lecture : notification par item, reçue sur le thread principal.
        state.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self, let endedItem = note.object as? AVPlayerItem else { return }
            self.handleItemDidPlayToEnd(item: endedItem)
        }

        slotStates[slot] = state
        updateReadyCount()
    }

    private func teardownSlot(_ slot: Int) {
        guard let state = slotStates.removeValue(forKey: slot) else { return }
        Self.teardown(state)
    }

    /// Libère intégralement les ressources d'un slot : observations invalidées,
    /// observateurs retirés, item détaché, puis références relâchées (les sessions
    /// de décodage VideoToolbox sont alors rendues au système).
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
        // Détache l'item : AVPlayer, AVPlayerItem et AVAsset sont libérés quand
        // SlotState disparaît → sessions de décodage matériel libérées.
        state.player.replaceCurrentItem(with: nil)
    }

    // MARK: Lecture synchronisée

    /// Démarre tous les players sur la MÊME cible d'horloge hôte future :
    /// c'est le cœur de la synchronisation à la trame près.
    private func startPlayback() {
        guard !slotStates.isEmpty else { return }
        startDriftMonitor()
        let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
        for state in slotStates.values {
            state.player.setRate(currentRate, time: state.player.currentTime(), atHostTime: host)
        }
        isPlaying = true
    }

    /// Cherche la même position sur tous les players (tolérance zéro = image exacte)
    /// et met à jour leaderTime immédiatement.
    private func seekAll(to time: CMTime, completion: (() -> Void)? = nil) {
        leaderTime = time
        seekGeneration += 1
        let generation = seekGeneration
        let slots = Array(slotStates.keys)
        guard !slots.isEmpty else {
            completion?()
            return
        }
        // Compteur partagé par les complétions, toutes rapatriées sur le thread principal.
        var remaining = slots.count
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
                    if remaining == 0 {
                        completion?()
                    }
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
        updateReadyCount()
    }

    // MARK: Moniteur de dérive

    private func startDriftMonitor() {
        stopDriftMonitor()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkDrift()
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }

    private func stopDriftMonitor() {
        driftTimer?.invalidate()
        driftTimer = nil
    }

    private func checkDrift() {
        guard isPlaying, let leader = leaderState, !leader.ended else { return }
        let leaderCurrent = leader.item.currentTime()
        for (slot, state) in slotStates where slot != leader.slot {
            // On ignore les slots terminés, en échec ou pas encore prêts : rien à réaligner.
            guard !state.ended, state.item.status == .readyToPlay else { continue }
            let otherCurrent = state.item.currentTime()
            let delta = leaderCurrent - otherCurrent
            if abs(delta.seconds) > 0.05 {
                // Ré-ancrage sans saut : on repositionne l'item sur le temps du leader
                // (other + delta == leader) au prochain tick de l'horloge hôte.
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(currentRate, time: otherCurrent + delta, atHostTime: host)
            }
            publishDrift(delta.seconds, for: slot)
        }
    }

    private func publishDrift(_ deltaSeconds: Double, for slot: Int) {
        let magnitude = abs(deltaSeconds)
        if magnitude >= 0.01 {
            let text = String(format: "Δ %.0f ms", magnitude * 1000.0)
            // Comparaison avant affectation : évite de spammer @Published.
            if driftText[slot] != text {
                driftText[slot] = text
            }
        } else if magnitude < 0.005 {
            if driftText[slot] != nil {
                driftText.removeValue(forKey: slot)
            }
        }
        // Entre 0.005 s et 0.01 s : hystérésis, on laisse la valeur précédente.
    }

    // MARK: Observations KVO et notifications

    private func handleStatusChange(slot: Int) {
        guard let state = slotStates[slot] else { return }
        switch state.item.status {
        case .readyToPlay:
            if slotError[slot] != nil {
                slotError.removeValue(forKey: slot)
            }
        case .failed:
            slotError[slot] = state.item.error?.localizedDescription ?? "Erreur de lecture inconnue"
        case .unknown:
            break
        @unknown default:
            break
        }
        updateReadyCount()
    }

    private func handleItemDidPlayToEnd(item: AVPlayerItem) {
        guard let slot = slotStates.first(where: { $0.value.item === item })?.key,
              let state = slotStates[slot] else { return }
        state.ended = true
        // Quand TOUS les slots configurés sont terminés, on coupe tout.
        if slotStates.values.allSatisfy(\.ended) {
            pause()
        }
    }

    /// Charge la durée du leader de manière asynchrone et la publie.
    private func refreshLeaderDuration() {
        guard let leader = leaderState else {
            if leaderDuration != .zero {
                leaderDuration = .zero
            }
            return
        }
        let item = leader.item
        Task { @MainActor in
            guard let duration = try? await item.load(.duration) else { return }
            // Le leader a pu changer pendant le chargement : on ne publie que si
            // l'item est toujours celui du leader actuel.
            if self.leaderState?.item === item {
                self.leaderDuration = duration
            }
        }
    }

    private func updateReadyCount() {
        let count = slotStates.values.filter { $0.item.status == .readyToPlay }.count
        if count != readyCount {
            readyCount = count
        }
    }
}
