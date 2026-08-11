# AGENT B — Rapport de patchs UX Lecture (TriSync)

**Fichier cible** : `TriSyncPkg/Sources/TriSync/ContentView.swift` (4281 lignes, fichier UNIQUE)
**Ne modifie JAMAIS le fichier** : ce rapport fournit les patchs, l'orchestrateur compile.
**Cibles** : SyncEngine (814–1499), VideoLibrary (104–536), AppDelegate (22–28), PlayerLayerView/VideoPaneView (1567–1855), ContentView (1874–2346), TransportBar (3811–3952), BrowserVideoCard (3201–3301), LibraryCard (3378–3489), StagePane (4008–4228).
**Conventions** : UI/comments FRANÇAIS, `[weak self]`, main thread, Swift 5.9 / macOS 14, aucune dépendance, `player.volume` (Float) — jamais `isMuted` pour le routage audio.

---

## FEATURE 1 — Reprise des positions (patchs partagés P1–P5, puis P6–P15)

### Patch P1 — SyncEngine : état publié `audioSlot` + stockage des positions + `ResumeOffer`
**Où** : après `@Published private(set) var slotError…` (l. 824) et dans le bloc « État interne » (l. 826–829).

**old_string**
```swift
    @Published private(set) var slotError: [Int: String] = [:]

    // MARK: État interne

    private var slotStates: [Int: SlotState] = [:]
    private var driftTimer: Timer?
```

**new_string**
```swift
    @Published private(set) var slotError: [Int: String] = [:]
    /// Source audio de la session : nil = comportement par défaut (le slot
    /// référentiel est le seul audible). Choisi par clic sur un bloc.
    @Published private(set) var audioSlot: Int?

    // MARK: État interne

    private var slotStates: [Int: SlotState] = [:]
    private var driftTimer: Timer?

    // MARK: Reprise des positions de lecture

    /// Positions mémorisées par chemin de fichier, persistées dans
    /// UserDefaults sous « playback.positions » (sauvegarde différée 2 s).
    private var positions: [String: Double] = [:]
    private var positionSaveWork: DispatchWorkItem?
    private static let positionsKey = "playback.positions"

    /// Proposition de reprise affichée par la barre de transport (6 s).
    struct ResumeOffer: Equatable {
        let slot: Int
        let url: URL
        let position: Double
        var label: String { timeString(CMTime(seconds: position, preferredTimescale: 600)) }
    }
    @Published private(set) var resumeOffer: ResumeOffer?
    private var resumeDismissWork: DispatchWorkItem?
```

### Patch P2 — SyncEngine : chargement des positions à l'init
**Où** : `override init()` (l. 873–875).

**old_string**
```swift
    override init() {
        super.init()
    }
```

**new_string**
```swift
    override init() {
        super.init()
        // Restaure les positions de lecture mémorisées (reprise).
        loadPositions()
    }
```

### Patch P3 — SyncEngine : méthodes (source audio, positions, reprise, accès référentiel)
**Où** : après `func volume(forSlot:)` (l. 1166–1168).

**old_string**
```swift
    func volume(forSlot slot: Int) -> Float {
        slotStates[slot]?.volume ?? 1.0
    }
```

**new_string**
```swift
    func volume(forSlot slot: Int) -> Float {
        slotStates[slot]?.volume ?? 1.0
    }

    // MARK: Source audio (clic sur un bloc)

    /// Vrai si le slot est la source audio courante : le slot choisi par
    /// l'utilisateur ou, par défaut, le slot référentiel.
    func isAudioSlot(_ slot: Int) -> Bool {
        (audioSlot ?? referenceSlot) == slot
    }

    /// Fait de `slot` la source audio de la session : volume 1.0 sur ce bloc,
    /// volume 0.0 sur les autres, en passant par player.volume (PAS isMuted)
    /// pour ne pas perturber la synchro audio des autres flux.
    /// `nil` (clic sur le bloc maître) revient au comportement par défaut :
    /// seul le slot référentiel est audible.
    func setAudioSlot(_ slot: Int?) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        let target = slot ?? referenceSlot
        for (index, state) in slotStates {
            let isAudio = (index == target)
            if isAudio {
                // Le slot choisi doit être audible même s'il n'est pas le
                // leader (le moteur mute les non-leaders par défaut).
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

    // MARK: Reprise des positions de lecture

    /// Restaure les positions mémorisées depuis UserDefaults.
    private func loadPositions() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        positions = stored
    }

    /// Position de lecture mémorisée pour une URL (0 si aucune).
    func position(for url: URL) -> Double {
        positions[url.path] ?? 0
    }

    /// Mémorise la position d'une vidéo (sauvegarde différée de 2 s).
    func savePosition(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds > 0 else { return }
        positions[url.path] = seconds
        schedulePositionsSave()
    }

    /// Efface la position mémorisée d'une vidéo (fin de lecture réelle,
    /// « Recommencer »).
    func clearPosition(for url: URL) {
        guard positions.removeValue(forKey: url.path) != nil else { return }
        persistPositionsNow()
    }

    private func schedulePositionsSave() {
        positionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistPositionsNow() }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Écrit immédiatement les positions dans UserDefaults (thread principal).
    func persistPositionsNow() {
        positionSaveWork?.cancel()
        positionSaveWork = nil
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    /// Propose la reprise d'une vidéo au lancement (position > 15 s) : la
    /// lecture démarre à zéro et un bandeau temporaire (6 s) propose
    /// « Reprendre » ou « Recommencer ».
    func offerResumeIfNeeded(slot: Int, url: URL) {
        let position = positions[url.path] ?? 0
        guard position > 15 else { return }
        let offer = ResumeOffer(slot: slot, url: url, position: position)
        if resumeOffer != offer {
            resumeOffer = offer
        }
        resumeDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissResumeOffer() }
        resumeDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: work)
    }

    /// « Reprendre » : aligne tous les flux sur la position proposée.
    func acceptResumeOffer() {
        guard let offer = resumeOffer else { return }
        seekAll(to: CMTime(seconds: offer.position, preferredTimescale: 600))
        dismissResumeOffer()
    }

    /// « Recommencer » : retour à zéro et oubli de la position mémorisée.
    func declineResumeOffer() {
        guard let offer = resumeOffer else { return }
        clearPosition(for: offer.url)
        seekAll(to: .zero)
        dismissResumeOffer()
    }

    private func dismissResumeOffer() {
        resumeDismissWork?.cancel()
        resumeDismissWork = nil
        if resumeOffer != nil {
            resumeOffer = nil
        }
    }

    // MARK: Accès référentiel (mini-lecteur flottant)

    /// Indice du slot référentiel courant (temps affiché, audio par défaut).
    var currentReferenceSlot: Int? { referenceSlot }

    /// Player du slot référentiel (réutilisé par le mini-lecteur flottant).
    func referencePlayer() -> AVPlayer? {
        guard let slot = referenceSlot else { return nil }
        return slotStates[slot]?.player
    }

    /// Dérive maximale (ms) entre le référentiel et les autres slots actifs
    /// (badge Δ du mini-lecteur). Nil si rien d'actif ou pas de dérive.
    var maxDriftMilliseconds: Int? {
        guard let reference = referenceState, !reference.ended,
              reference.item.status == .readyToPlay else { return nil }
        let refTime = reference.item.currentTime()
        var maxMs: Int?
        for state in slotStates.values where state.slot != reference.slot && !state.ended {
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
```

### Patch P4 — SyncEngine : reconfigure ré-applique le routage audio choisi
**Où** : bloc « 3. Mute par défaut » de `reconfigure` (l. 919–926).

**old_string**
```swift
        // 3. Mute par défaut : seul le leader est audible, sauf réglage utilisateur explicite.
        for (slot, state) in slotStates where !state.userAdjustedMute {
            let shouldMute = (slot != newLeader)
            if state.muted != shouldMute {
                state.muted = shouldMute
                state.player.isMuted = shouldMute
            }
        }
```

**new_string**
```swift
        // 3. Mute par défaut : seul le leader est audible, sauf réglage utilisateur explicite.
        for (slot, state) in slotStates where !state.userAdjustedMute {
            let shouldMute = (slot != newLeader)
            if state.muted != shouldMute {
                state.muted = shouldMute
                state.player.isMuted = shouldMute
            }
        }

        // 3 bis. Source audio choisie par l'utilisateur : on ré-applique le
        // routage (volume 1.0 / 0.0) pour intégrer les nouveaux slots.
        if audioSlot != nil {
            setAudioSlot(audioSlot)
        }
```

### Patch P5 — SyncEngine : `pause()` mémorise les positions (pause/arrêt)
**Où** : `func pause()` (l. 996–1003).

**old_string**
```swift
    func pause() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        cancelPendingPlaybackStart()
        stopDriftMonitor()
        for state in slotStates.values {
            state.player.pause()
        }
        isPlaying = false
```

**new_string**
```swift
    func pause() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        cancelPendingPlaybackStart()
        stopDriftMonitor()
        // Reprise : mémorise la position de chaque slot encore en cours
        // avant la pause (sauvegarde différée 2 s). `stop()` passe ici aussi.
        for state in slotStates.values where !state.ended {
            let time = state.player.currentTime()
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                positions[state.url.path] = time.seconds
            }
        }
        schedulePositionsSave()
        for state in slotStates.values {
            state.player.pause()
        }
        isPlaying = false
```

### Patch P6 — SyncEngine : enregistrement des positions pendant la lecture (1 Hz)
**Où** : fin de `checkDrift` (l. 1371–1373).

**old_string**
```swift
            publishDrift(delta.seconds, for: slot)
        }
    }
```

**new_string**
```swift
            publishDrift(delta.seconds, for: slot)
        }

        // Reprise : enregistre la position courante de chaque slot (1 Hz) ;
        // la persistance reste différée (2 s) pour ne pas écrire UserDefaults
        // en continu pendant la lecture.
        for (slot, state) in slotStates where !state.ended {
            let time = state.player.currentTime()
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                positions[state.url.path] = time.seconds
            }
        }
        schedulePositionsSave()
    }
```

### Patch P7 — SyncEngine : fin RÉELLE de lecture → position effacée
**Où** : `handleItemDidPlayToEnd` (l. 1436–1440).

**old_string**
```swift
        state.ended = true
        // Purge de la dérive affichée : un slot terminé ne dérive plus.
        if driftText[slot] != nil {
            driftText.removeValue(forKey: slot)
        }
```

**new_string**
```swift
        state.ended = true
        // Purge de la dérive affichée : un slot terminé ne dérive plus.
        if driftText[slot] != nil {
            driftText.removeValue(forKey: slot)
        }
        // Fin RÉELLE de la vidéo : la position mémorisée est effacée — la
        // prochaine lecture repartira de zéro sans proposition de reprise.
        clearPosition(for: state.url)
```

### Patch P8 — VideoLibrary : `assign` propose la reprise au lancement
**Où** : `func assign(_:to:)` (l. 157–165). Couvre `launchSelected`, double-clic (BrowserVideoCard/LibraryCard), `place`, AssetChip.

**old_string**
```swift
    func assign(_ asset: VideoAsset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        // W5 : un asset déjà affiché dans un slot est DÉPLACÉ, jamais dupliqué.
        if let old = slots.firstIndex(where: { $0?.id == asset.id }), old != slot {
            slots[old] = nil
        }
        slots[slot] = asset
        syncEngine()
    }
```

**new_string**
```swift
    func assign(_ asset: VideoAsset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        // W5 : un asset déjà affiché dans un slot est DÉPLACÉ, jamais dupliqué.
        if let old = slots.firstIndex(where: { $0?.id == asset.id }), old != slot {
            slots[old] = nil
        }
        slots[slot] = asset
        // Reprise : si une position de lecture a été mémorisée pour cette
        // vidéo (> 15 s), la lecture démarre à zéro et la barre de transport
        // affiche un bandeau « Reprendre / Recommencer » (6 s).
        engine.offerResumeIfNeeded(slot: slot, url: asset.url)
        syncEngine()
    }
```

### Patch P9 — TransportBar : emplacement du bandeau de reprise
**Où** : chaîne background/overlay du `body` (l. 3843–3852).

**old_string**
```swift
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
```

**new_string**
```swift
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        // Bandeau temporaire de reprise de lecture (6 s), au-dessus du transport.
        .overlay(alignment: .top) {
            resumeBanner
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
```

### Patch P10 — TransportBar : vue `resumeBanner`
**Où** : après `private var statusText` (l. 3927–3933).

**old_string**
```swift
    private var statusText: String {
        if engine.isPlaying { return "Lecture synchronisée" }
        if loadedCount > 0 && engine.readyCount < loadedCount {
            return "Chargement \(engine.readyCount)/\(loadedCount)…"
        }
        return "Prêt"
    }
```

**new_string**
```swift
    private var statusText: String {
        if engine.isPlaying { return "Lecture synchronisée" }
        if loadedCount > 0 && engine.readyCount < loadedCount {
            return "Chargement \(engine.readyCount)/\(loadedCount)…"
        }
        return "Prêt"
    }

    // MARK: Bandeau de reprise

    /// Bandeau temporaire proposant de reprendre la lecture à la position
    /// mémorisée (« Reprendre ») ou de repartir de zéro (« Recommencer »).
    /// Affiché 6 s par le moteur après le lancement d'une vidéo interrompue.
    @ViewBuilder
    private var resumeBanner: some View {
        if let offer = engine.resumeOffer {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                Text("Reprendre à \(offer.label)")
                    .font(.system(size: 12, weight: .semibold))
                Button {
                    engine.acceptResumeOffer()
                } label: {
                    Text("Reprendre")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                Button {
                    engine.declineResumeOffer()
                } label: {
                    Text("Recommencer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
```

### Patch P11 — AppDelegate : écriture immédiate des positions à la sortie
**Où** : `applicationWillTerminate` (l. 23–27).

**old_string**
```swift
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            sharedLibrary?.saveNow()
        }
    }
```

**new_string**
```swift
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            sharedLibrary?.saveNow()
            // Positions de lecture : écriture immédiate à la sortie (quit).
            sharedLibrary?.engine.persistPositionsNow()
        }
    }
```

### Patch P12 — BrowserVideoCard : environnement moteur + position mémorisée
**Où** : déclaration de la struct (l. 3203–3206) et après `cachedDuration` (l. 3219–3223).

**old_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    let url: URL
    var showThumbnail = true
```

**new_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var engine: SyncEngine
    let url: URL
    var showThumbnail = true
```

**old_string**
```swift
    /// Durée affichée depuis le cache de métadonnées (sans ouvrir l'AVAsset).
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }
```

**new_string**
```swift
    /// Durée affichée depuis le cache de métadonnées (sans ouvrir l'AVAsset).
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }

    /// Position de lecture mémorisée (> 15 s) → badge « Repris ».
    private var resumePosition: Double? {
        let position = engine.position(for: url)
        return position > 15 ? position : nil
    }
```

### Patch P13 — BrowserVideoCard : badge « Repris 3:24 » sur la vignette
**Où** : ZStack des badges (l. 3252–3261).

**old_string**
```swift
                if let letter = slotLetter {
                    Text(letter)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(accent))
                        .padding(6)
                }
            }
            Text(url.deletingPathExtension().lastPathComponent)
```

**new_string**
```swift
                if let letter = slotLetter {
                    Text(letter)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(accent))
                        .padding(6)
                }
                if let position = resumePosition {
                    Text("Repris \(timeString(CMTime(seconds: position, preferredTimescale: 600)))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(url.deletingPathExtension().lastPathComponent)
```

### Patch P14 — LibraryCard : environnement moteur + position mémorisée
**Où** : déclaration de la struct (l. 3380–3382) et après `selected` (l. 3385–3387).

**old_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    let asset: VideoAsset
    var onDoubleClick: () -> Void = {}
```

**new_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    let asset: VideoAsset
    var onDoubleClick: () -> Void = {}
```

**old_string**
```swift
    /// Vrai quand la carte fait partie de la sélection multi (⌘+clic).
    private var selected: Bool {
        library.selectedOrder.contains(asset.id)
    }
```

**new_string**
```swift
    /// Vrai quand la carte fait partie de la sélection multi (⌘+clic).
    private var selected: Bool {
        library.selectedOrder.contains(asset.id)
    }

    /// Position de lecture mémorisée (> 15 s) → badge « Repris ».
    private var resumePosition: Double? {
        let position = engine.position(for: asset.url)
        return position > 15 ? position : nil
    }
```

### Patch P15 — LibraryCard : badge « Repris 3:24 » sur la vignette
**Où** : ZStack des badges (l. 3414–3430).

**old_string**
```swift
                if hovering {
                    Button {
                        library.removeAsset(asset)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer de la bibliothèque")
                    .help("Retirer de la bibliothèque")
                }
            }
            Text(asset.title)
```

**new_string**
```swift
                if hovering {
                    Button {
                        library.removeAsset(asset)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer de la bibliothèque")
                    .help("Retirer de la bibliothèque")
                }
                if let position = resumePosition {
                    Text("Repris \(timeString(CMTime(seconds: position, preferredTimescale: 600)))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            Text(asset.title)
```

---

## FEATURE 2 — Clic sur un bloc = son (état `audioSlot`/`setAudioSlot`/`isAudioSlot` déjà dans P1/P3/P4)

### Patch P16 — StagePane : clic = source audio + menu contextuel (volume, audio, capture, ⌘⇧S)
**Où** : `body` de StagePane (l. 4035–4039).

**old_string**
```swift
        .animation(.easeInOut(duration: 0.15), value: library.selectedSlot)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { library.select(slot: slot) }
        .transition(.opacity.combined(with: .scale(0.96)))
    }
```

**new_string**
```swift
        .animation(.easeInOut(duration: 0.15), value: library.selectedSlot)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            library.select(slot: slot)
            // Clic sur un bloc = source audio : ce bloc devient le slot audio
            // (volume 1.0, les autres à 0). Clic sur le MAÎTRE = retour au
            // comportement par défaut (audio sur le référentiel).
            if engine.isReferenceSlot(slot) {
                engine.setAudioSlot(nil)
            } else {
                engine.setAudioSlot(slot)
            }
        }
        .contextMenu {
            // Volume individuel du bloc (0–100 %).
            Slider(
                value: Binding(
                    get: { Double(engine.volume(forSlot: slot) * 100) },
                    set: { engine.setVolume(Float($0 / 100), forSlot: slot) }
                ),
                in: 0...100
            ) {
                Text("Volume")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("100")
            }
            .frame(width: 180)
            .padding(.horizontal, 10)
            .help("Volume du bloc")

            Divider()

            Button {
                engine.setAudioSlot(engine.isAudioSlot(slot) ? nil : slot)
            } label: {
                if engine.isAudioSlot(slot) {
                    Label("Rétablir l'audio automatique (maître)", systemImage: "speaker.slash")
                } else {
                    Label("Utiliser comme source audio", systemImage: "speaker.wave.2.fill")
                }
            }
            .help("Fait de ce bloc la source audio de la session")

            Button {
                capturePane()
            } label: {
                Label("Capture du bloc…", systemImage: "camera")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Enregistrer une capture PNG du bloc (⌘⇧S)")
        }
        // Raccourci global ⌘⇧S : capture ce bloc (bouton invisible, toujours
        // présent dans la hiérarchie pour enregistrer l'équivalent clavier).
        .background(
            Button { capturePane() } label: { EmptyView() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .transition(.opacity.combined(with: .scale(0.96)))
    }
```

### Patch P17 — StagePane : badge discret « 🔊 » sur le bloc audio actif
**Où** : `infoBar`, après le badge MAÎTRE (l. 4090–4092).

**old_string**
```swift
                    if isLeader {
                        leaderBadge
                    }
```

**new_string**
```swift
                    if isLeader {
                        leaderBadge
                    }
                    if engine.isAudioSlot(slot) {
                        Text("🔊")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .help("Source audio de la session — clic sur un autre bloc pour changer")
                    }
```

---

## FEATURE 3 — Capture du bloc (PNG sur le Bureau + fallback NSSavePanel)

### Patch P18 — VideoPaneView : propriété `onViewCreated`
**Où** : déclaration de `VideoPaneView` (l. 1825–1830).

**old_string**
```swift
    var immersiveMode = false
    var seekOnArrows = false
    var onStateChange: ((CGFloat) -> Void)?
    var onShortcut: ((ShortcutAction) -> Void)?

    func makeNSView(context: Context) -> PlayerLayerView {
```

**new_string**
```swift
    var immersiveMode = false
    var seekOnArrows = false
    var onStateChange: ((CGFloat) -> Void)?
    var onShortcut: ((ShortcutAction) -> Void)?
    /// Notifie la vue AppKit créée (utilisée pour la capture PNG du bloc).
    var onViewCreated: ((PlayerLayerView) -> Void)?

    func makeNSView(context: Context) -> PlayerLayerView {
```

### Patch P19 — VideoPaneView : `updateNSView` notifie la vue
**Où** : `func updateNSView` (l. 1844–1854).

**old_string**
```swift
    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
        nsView.displayMode = displayMode
        nsView.videoSize = videoSize
        nsView.cropOffset = cropOffset
        nsView.zoom = zoom
        nsView.immersiveMode = immersiveMode
        nsView.seekOnArrows = seekOnArrows
        nsView.onStateChange = onStateChange
        nsView.onShortcut = onShortcut
    }
```

**new_string**
```swift
    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
        nsView.displayMode = displayMode
        nsView.videoSize = videoSize
        nsView.cropOffset = cropOffset
        nsView.zoom = zoom
        nsView.immersiveMode = immersiveMode
        nsView.seekOnArrows = seekOnArrows
        nsView.onStateChange = onStateChange
        nsView.onShortcut = onShortcut
        if let onViewCreated {
            onViewCreated(nsView)
        }
    }
```

### Patch P20 — StagePane : `@State paneView` (référence pour la capture)
**Où** : états de StagePane (l. 4017–4019).

**old_string**
```swift
    @State private var speakerHover = false
    @State private var clearHover = false
    @State private var paneZoom: CGFloat = 1
```

**new_string**
```swift
    @State private var speakerHover = false
    @State private var clearHover = false
    @State private var paneZoom: CGFloat = 1
    /// Vue AppKit du bloc, retenue pour la capture PNG (⌘⇧S / menu contextuel).
    @State private var paneView: PlayerLayerView?
```

### Patch P21 — StagePane : branche `onViewCreated` sur le `VideoPaneView`
**Où** : appel de `VideoPaneView` dans `videoPane(asset:)` (l. 4045–4052).

**old_string**
```swift
            VideoPaneView(
                player: engine.player(forSlot: slot),
                displayMode: settings.displayMode.videoMode,
                videoSize: asset.size,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: session.immersiveMode,
                seekOnArrows: engine.isPlaying,
```

**new_string**
```swift
            VideoPaneView(
                player: engine.player(forSlot: slot),
                displayMode: settings.displayMode.videoMode,
                videoSize: asset.size,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: session.immersiveMode,
                seekOnArrows: engine.isPlaying,
                onViewCreated: { view in
                    if paneView !== view {
                        paneView = view
                    }
                },
```

### Patch P22 — StagePane : `capturePane()` (Bureau + fallback NSSavePanel)
**Où** : avant `// MARK: Emplacement vide` (l. 4203).

**old_string**
```swift
    // MARK: Emplacement vide
```

**new_string**
```swift
    // MARK: Capture du bloc

    /// Capture la vue du bloc en PNG sur le Bureau
    /// (~/Desktop/TriSync-Capture-AAAA-MM-JJ-HHMMSS.png) + bip de confirmation.
    /// Si l'écriture échoue (app sandboxée), bascule sur NSSavePanel.
    private func capturePane() {
        guard let view = paneView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "TriSync-Capture-\(formatter.string(from: Date())).png"

        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let url = desktop.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
                NSSound.beep()
                return
            } catch {
                // Bureau inaccessible (sandbox) : panneau de sauvegarde ci-dessous.
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
            NSSound.beep()
        }
    }

    // MARK: Emplacement vide
```

---

## FEATURE 4 — Mini-lecteur flottant (accès référentiel déjà dans P3)

### Patch P23 — ContentView : environnement moteur + état du mini-lecteur
**Où** : déclaration de `ContentView` (l. 1876–1883).

**old_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController
    @EnvironmentObject private var session: SessionState
    @State private var isDropTargeted = false
    @State private var showSettings = false
    @State private var controlsVisible = true
    @State private var hideControlsWork: DispatchWorkItem?
```

**new_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var engine: SyncEngine
    @State private var isDropTargeted = false
    @State private var showSettings = false
    @State private var controlsVisible = true
    @State private var hideControlsWork: DispatchWorkItem?
    /// Mini-lecteur flottant : masqué par l'utilisateur (la lecture continue).
    @State private var miniPlayerHidden = false
    /// Décalage du mini-lecteur (glisser-déposer).
    @State private var miniOffset: CGSize = .zero
```

### Patch P24 — ContentView : `mainLayout` en ZStack avec le mini-lecteur
**Où** : `private var mainLayout` (l. 1940–1963).

**old_string**
```swift
    /// Fenêtre principale : barre latérale (sections + sources) + contenu.
    private var mainLayout: some View {
        HStack(spacing: 0) {
            SidebarView(
                onOpenImporter: {
                    let urls = openVideosPanel()
                    if !urls.isEmpty { ingestVideos(urls) }
                },
                onEnterImmersive: { enterImmersive() },
                onOpenSettings: { showSettings = true }
            )
            .frame(width: 212)

            Divider().opacity(0.35)

            Group {
                if session.section == .library {
                    librarySection
                } else {
                    playbackSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
```

**new_string**
```swift
    /// Fenêtre principale : barre latérale (sections + sources) + contenu,
    /// avec le mini-lecteur flottant au-dessus de la section Vidéothèque.
    private var mainLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                SidebarView(
                    onOpenImporter: {
                        let urls = openVideosPanel()
                        if !urls.isEmpty { ingestVideos(urls) }
                    },
                    onEnterImmersive: { enterImmersive() },
                    onOpenSettings: { showSettings = true }
                )
                .frame(width: 212)

                Divider().opacity(0.35)

                Group {
                    if session.section == .library {
                        librarySection
                    } else {
                        playbackSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if session.section == .library, !miniPlayerHidden, showMiniPlayer {
                miniPlayerView
                    .padding(16)
                    .offset(miniOffset)
                    .zIndex(10)
            }
        }
        // Le mini-lecteur réapparaît à chaque retour dans la Vidéothèque.
        .onChange(of: session.section) { oldSection, newSection in
            if oldSection == .library, newSection != .library {
                miniPlayerHidden = false
            }
        }
    }
```

### Patch P25 — ContentView : vue `miniPlayerView` + helpers
**Où** : avant le commentaire « Mode immersif » (l. 2022).

**old_string**
```swift
    /// Mode immersif (« super fullscreen ») : uniquement les vidéos. La barre
```

**new_string**
```swift
    // MARK: Mini-lecteur flottant

    /// Le mini-lecteur apparaît dans la Vidéothèque dès qu'une vidéo est
    /// chargée ou en cours de lecture. Il réutilise le PlayerLayerView du
    /// slot référentiel (même AVPlayer : les players restent vivants en
    /// naviguant — aucune reconfiguration du moteur au changement de section).
    private var showMiniPlayer: Bool {
        engine.isPlaying || !library.slots.compactMap({ $0 }).isEmpty
    }

    /// Taille d'affichage du slot référentiel (cadrage du mini-lecteur).
    private var referenceVideoSize: CGSize {
        guard let slot = engine.currentReferenceSlot,
              library.slots.indices.contains(slot),
              let asset = library.slots[slot] else { return .zero }
        return asset.size
    }

    private var miniPlayerView: some View {
        VStack(spacing: 0) {
            VideoPaneView(
                player: engine.referencePlayer(),
                displayMode: settings.displayMode.videoMode,
                videoSize: referenceVideoSize,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: false,
                seekOnArrows: false
            )
            .frame(width: 360, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )

            // Barre de contrôle : lecture/pause, temps, dérive Δ, fermeture.
            // Le glisser-déposer du panneau se fait par cette barre (la zone
            // vidéo garde ses interactions de pan/zoom).
            HStack(spacing: 10) {
                Button {
                    engine.togglePlay()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(engine.isPlaying ? "Pause" : "Lecture")

                Text(timeString(engine.leaderTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let drift = engine.maxDriftMilliseconds, drift >= 5 {
                    Text("Δ \(drift) ms")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .help("Dérive maximale entre les flux")
                }

                Spacer(minLength: 4)

                Button {
                    // Fermer ne stoppe PAS la lecture : le mini-lecteur est
                    // simplement masqué (il réapparaîtra au prochain passage
                    // dans la Vidéothèque).
                    withAnimation(.easeOut(duration: 0.2)) { miniPlayerHidden = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Masquer le mini-lecteur")
                .help("Masquer le mini-lecteur (la lecture continue)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        miniOffset = value.translation
                    }
                    .onEnded { value in
                        miniOffset = value.translation
                    }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .frame(width: 360)
    }

    /// Mode immersif (« super fullscreen ») : uniquement les vidéos. La barre
```

---

## VÉRIFICATIONS (chaque old_string confirmé dans le fichier)

| Patch | Ancre | Ligne(s) | Statut |
|---|---|---|---|
| P1 | `slotError` + `// MARK: État interne` + `slotStates` + `driftTimer` | 824–829 | ✓ unique |
| P2 | `override init() { super.init() }` | 873–875 | ✓ unique |
| P3 | `func volume(forSlot slot: Int)` | 1166–1168 | ✓ unique |
| P4 | « 3. Mute par défaut… » bloc reconfigure | 919–926 | ✓ unique |
| P5 | `func pause()` jusqu'à `isPlaying = false` | 996–1003 | ✓ unique |
| P6 | `publishDrift(delta.seconds, for: slot)` + fermetures | 1371–1373 | ✓ unique (seul `delta.seconds` ; resync utilise une autre expression) |
| P7 | `state.ended = true` + purge dérive | 1436–1440 | ✓ unique (`state.ended = true` n'apparaît qu'ici) |
| P8 | `func assign(_:to:)` complet | 157–165 | ✓ unique |
| P9 | `.fill(.ultraThinMaterial)` + overlays TransportBar | 3843–3852 | ✓ unique (seul cornerRadius 14 + ultraThinMaterial) |
| P10 | `private var statusText` | 3927–3933 | ✓ unique |
| P11 | `applicationWillTerminate` | 23–27 | ✓ unique |
| P12 | env BrowserVideoCard (library+session+`let url`) | 3203–3206 | ✓ unique |
| P12b | `private var cachedDuration` | 3219–3223 | ✓ unique |
| P13 | badge lettre BrowserVideoCard (`foregroundStyle(.black)`) | 3252–3261 | ✓ unique (variante LibraryCard différente) |
| P14 | env LibraryCard (library+`let asset`) | 3380–3382 | ✓ unique (AssetChip différent) |
| P14b | `private var selected` (LibraryCard, avec doc) | 3385–3387 | ✓ unique (BVC a `guard let asset`) |
| P15 | bloc hovering-remove LibraryCard | 3414–3430 | ✓ unique |
| P16 | `.onTapGesture { library.select(slot: slot) }` | 4035–4039 | ✓ unique |
| P17 | `if isLeader { leaderBadge }` | 4090–4092 | ✓ unique |
| P18 | props VideoPaneView | 1825–1830 | ✓ unique |
| P19 | `func updateNSView` (VideoPaneView) | 1844–1854 | ✓ unique |
| P20 | `@State private var speakerHover…` | 4017–4019 | ✓ unique |
| P21 | appel `VideoPaneView(` dans StagePane | 4045–4052 | ✓ unique |
| P22 | `// MARK: Emplacement vide` | 4203 | ✓ unique |
| P23 | env + états ContentView | 1876–1883 | ✓ unique |
| P24 | `private var mainLayout` complet | 1940–1963 | ✓ unique |
| P25 | commentaire « Mode immersif » | 2022 | ✓ unique |

Aucune collision d'identifiants : `audioSlot`, `resumeOffer`, `positionsKey`, `onViewCreated`, `capturePane`, `miniPlayer*`, `maxDriftMilliseconds` — 0 occurrence existante (grep confirmé).

## Vérifications conceptuelles
- **Players vivants en naviguant** : les AVPlayer vivent dans `library.engine` (let de VideoLibrary, durée de vie = app). Le changement de section ne fait que monter/démonter les VUES ; `PlayerLayerView.viewDidMoveToWindow` détache la couche quand la vue quitte la fenêtre mais ne touche pas le player du moteur → la lecture (audio inclus) continue en Bibliothèque. ✓
- **Pas de @Published réassigné identique en boucle** : `audioSlot` (garde `!=`), `resumeOffer` (garde `!=`), positions non publiées, `dismissResumeOffer` garde nil. ✓
- **Pas de Timer en pause** : reprise = DispatchWorkItem (6 s) ; enregistrement 1 Hz dans le moniteur de dérive existant (déjà stoppé en pause). ✓
- **Observateurs** : aucun nouvel observer NotificationCenter ; `clearPosition` branché sur la notification `AVPlayerItemDidPlayToEndTime` existante. ✓
