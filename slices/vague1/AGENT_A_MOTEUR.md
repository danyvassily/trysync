# RAPPORT DE PATCHS — AGENT A (MOTEUR)

Fichier cible : `/Users/danyvassily/dev/trisync-work/TriSyncPkg/Sources/TriSync/ContentView.swift` (4281 lignes)
Contraintes respectées : aucun build, aucun `setRate(atHostTime:)` modifié, `masterClock` intact, référentiel migrable intact, caches intacts, signatures UI existantes intactes (2 ajouts UI : bouton « Mélanger » + badge sur panneau vide). Swift 5.9 / macOS 14. Commentaires en français, `[weak self]`, thread principal, teardown complet.

---

### Patch 1 — VideoLibrary.init : câblage des nouveaux rappels moteur (features 1 et 3)

**Où** : `VideoLibrary.init()` — lignes 128-134.

**old_string**
```swift
    init() {
        // Remplacement automatique : quand une vidéo se termine, la
        // bibliothèque choisit une autre vidéo pour que le bloc continue.
        engine.onItemEnded = { [weak self] slot in
            self?.autoReplace(slot: slot)
        }
    }
```

**new_string**
```swift
    init() {
        // Remplacement automatique : quand une vidéo se termine, la
        // bibliothèque choisit une autre vidéo pour que le bloc continue.
        engine.onItemEnded = { [weak self] slot in
            self?.autoReplace(slot: slot)
        }
        // Feature 3 : échec de lecture → remplacement différé (0,5 s côté moteur).
        engine.onSlotFailed = { [weak self] slot in
            self?.handleSlotFailure(slot)
        }
        // Feature 1 : préchargement anticipé du prochain contenu du référentiel.
        engine.onPreloadNeeded = { [weak self] slot in
            self?.prepareNext(for: slot)
        }
    }
```

---

### Patch 2 — VideoLibrary : état des files, échecs et anti-rafale (features 2, 3 et 4)

**Où** : déclarations de persistance — lignes 123-126.

**old_string**
```swift
    private var saveWorkItem: DispatchWorkItem?
    private static let sourcesKey = "library.sources"
    private static let assetsKey = "library.assetBookmarks"
    private static let slotsKey = "library.slotURLs"
```

**new_string**
```swift
    private var saveWorkItem: DispatchWorkItem?
    private static let sourcesKey = "library.sources"
    private static let assetsKey = "library.assetBookmarks"
    private static let slotsKey = "library.slotURLs"
    private static let queuesKey = "library.queues"

    // MARK: Files de lecture par slot (feature 2)

    /// Files ordonnées par slot : ordre des remplacements automatiques.
    /// Par défaut (file absente), le prochain contenu est la première vidéo
    /// de la bibliothèque non déjà chargée (boucle sur la sélection).
    private var queues: [Int: [VideoAsset]] = [:]

    // MARK: Échecs de lecture et anti-rafale (features 3 et 4)

    /// URLs en échec consécutif par slot : quand toute la file a été tentée,
    /// le slot est vidé avec le badge « Fichier illisible ».
    private var failedURLs: [Int: Set<URL>] = [:]
    /// Remplacements différés en attente (anti-rafale), par slot.
    private var pendingReplacements: [Int: Task<Void, Never>] = [:]
    /// Horodatage du dernier remplacement appliqué (anti-rafale : deux
    /// remplacements à moins d'une seconde sont espacés).
    private var lastReplacementDate = Date.distantPast
```

---

### Patch 3 — VideoLibrary.clear(slot:) : nettoyage file/échecs/remplacement différé (features 2, 3, 4)

**Où** : `clear(slot:)` — lignes 143-147.

**old_string**
```swift
    func clear(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
        syncEngine()
    }
```

**new_string**
```swift
    func clear(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        // Nettoyage complet : file, compteur d'échecs et remplacement différé.
        queues.removeValue(forKey: slot)
        failedURLs.removeValue(forKey: slot)
        pendingReplacements[slot]?.cancel()
        pendingReplacements.removeValue(forKey: slot)
        slots[slot] = nil
        syncEngine()
    }
```

---

### Patch 4 — VideoLibrary.clearAll() : nettoyage global (features 2, 3, 4)

**Où** : `clearAll()` — lignes 149-155.

**old_string**
```swift
        for task in metadataTasks.values { task.cancel() }
        metadataTasks.removeAll()
        slots = Array(repeating: nil, count: VideoLibrary.maxSlots)
        assets = []
        engine.clear()
```

**new_string**
```swift
        for task in metadataTasks.values { task.cancel() }
        metadataTasks.removeAll()
        for task in pendingReplacements.values { task.cancel() }
        pendingReplacements.removeAll()
        queues.removeAll()
        failedURLs.removeAll()
        slots = Array(repeating: nil, count: VideoLibrary.maxSlots)
        assets = []
        engine.clear()
```

---

### Patch 5 — VideoLibrary.assign(_:to:) : reset échecs + annulation remplacement différé (features 3, 4)

**Où** : `assign(_:to:)` — lignes 157-165.

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
        // Affectation manuelle : annule un remplacement différé (anti-rafale)
        // et repart d'un compteur d'échecs propre (feature 3).
        pendingReplacements[slot]?.cancel()
        pendingReplacements.removeValue(forKey: slot)
        failedURLs.removeValue(forKey: slot)
        slots[slot] = asset
        syncEngine()
    }
```

---

### Patch 6 — VideoLibrary.saveNow() : persistance des files (feature 2)

**Où** : fin de `saveNow()` — lignes 317-318.

**old_string**
```swift
        d.set(slots.map { $0?.url.standardizedFileURL.absoluteString ?? "" }, forKey: Self.slotsKey)
    }
```

**new_string**
```swift
        d.set(slots.map { $0?.url.standardizedFileURL.absoluteString ?? "" }, forKey: Self.slotsKey)
        persistQueues()
    }
```

---

### Patch 7 — VideoLibrary.restoreLibrary() : restauration des files (feature 2)

**Où** : fin de `restoreLibrary()` — lignes 341-344.

**old_string**
```swift
        syncEngine()
        restoreSources()
        scanSources()
    }
```

**new_string**
```swift
        syncEngine()
        restoreQueues()
        restoreSources()
        scanSources()
    }
```

---

### Patch 8 — VideoLibrary : files de lecture, remplacement auto (file + anti-rafale + échecs), préchargement (features 1, 2, 3, 4)

**Où** : bloc `autoReplace` — lignes 460-473.

**old_string**
```swift
    /// Remplacement automatique d'un slot terminé : choisit la première vidéo
    /// de la bibliothèque non déjà chargée, la met dans le slot et la relance
    /// synchronisée. Si tout est déjà chargé, la même vidéo est rejouée.
    private func autoReplace(slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        let currentID = slots[slot]?.id
        let loadedIDs = Set(slots.compactMap { $0?.id })
        if let next = assets.first(where: { $0.id != currentID && !loadedIDs.contains($0.id) }) {
            slots[slot] = next
            syncEngine()
        }
        // Relance le contenu du slot à zéro, aligné sur la lecture en cours.
        engine.joinNewSlot(slot)
    }
```

**new_string**
```swift
    // MARK: Files de lecture par slot (feature 2)

    /// File de lecture du slot, nettoyée des assets retirés de la
    /// bibliothèque. Vide tant qu'aucun ordre n'a été défini.
    func queue(for slot: Int) -> [VideoAsset] {
        guard slots.indices.contains(slot), let raw = queues[slot] else { return [] }
        let live = raw.filter { asset in assets.contains(where: { $0.id == asset.id }) }
        if live.count != raw.count {
            queues[slot] = live
            scheduleSave()
        }
        return live
    }

    /// Définit la file de lecture d'un slot (ordre des remplacements).
    func setQueue(_ queue: [VideoAsset], for slot: Int) {
        guard slots.indices.contains(slot) else { return }
        queues[slot] = queue
        scheduleSave()
    }

    /// Mélange Fisher-Yates de TOUTES les files de lecture (« Mélanger »).
    func shuffleQueues() {
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

    /// Prochain asset de la file du slot, avec rotation (le premier passe en
    /// fin de file : lecture en boucle). Reconstruit la file par défaut quand
    /// elle est vide ou ne contient que la vidéo courante.
    func next(in slot: Int) -> VideoAsset? {
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

    /// File par défaut d'un slot : les vidéos de la bibliothèque non déjà
    /// chargées dans un slot (boucle sur la sélection).
    private func defaultQueue(for slot: Int) -> [VideoAsset] {
        let loadedIDs = Set(slots.compactMap { $0?.id })
        return assets.filter { !loadedIDs.contains($0.id) }
    }

    /// Prochain candidat de remplacement pour un slot : tête de la file (SANS
    /// rotation — le préchargement ne doit pas modifier l'ordre de la file),
    /// sinon la première vidéo de la bibliothèque non déjà chargée, sinon la
    /// vidéo courante (relecture).
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

    // MARK: Remplacement automatique

    /// Remplacement automatique d'un slot terminé (ou en échec) : prend le
    /// prochain contenu de la file du slot et le relance synchronisé.
    /// DÉLAI ANTI-RAFALE (feature 4) : deux remplacements à moins d'une
    /// seconde d'intervalle sont espacés — le second est différé de 1 s puis
    /// re-vérifié (slot inchangé, remplacement toujours actif).
    private func autoReplace(slot: Int, failedURL: URL? = nil) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        let expectedID = slots[slot]?.id
        guard Date().timeIntervalSince(lastReplacementDate) >= 1.0 else {
            pendingReplacements[slot]?.cancel()
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.pendingReplacements[slot] = nil
                // Re-vérification : le slot contient toujours la même vidéo
                // et le remplacement automatique est toujours actif.
                guard self.engine.autoReplace, self.slots.indices.contains(slot),
                      self.slots[slot]?.id == expectedID else { return }
                self.applyReplacement(slot: slot, failedURL: failedURL)
            }
            pendingReplacements[slot] = task
            return
        }
        applyReplacement(slot: slot, failedURL: failedURL)
    }

    /// Application effective d'un remplacement (immédiat ou différé).
    private func applyReplacement(slot: Int, failedURL: URL? = nil) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        lastReplacementDate = Date()

        // Feature 3 : en cas d'échec, on mémorise le fichier défaillant pour
        // détecter l'épuisement de la file. Fin naturelle = compteur propre.
        if let failedURL {
            failedURLs[slot, default: []].insert(failedURL)
        } else {
            failedURLs.removeValue(forKey: slot)
        }

        guard let next = next(in: slot) else {
            emptySlotAfterFailure(slot)
            return
        }

        // Toute la file a déjà échoué → slot vide + badge « Fichier illisible ».
        if let failedURL, failedURLs[slot, default: []].contains(next.url) {
            emptySlotAfterFailure(slot)
            return
        }

        slots[slot] = next
        syncEngine()
        // Relance le contenu du slot à zéro, aligné sur la lecture en cours.
        engine.joinNewSlot(slot)
    }

    /// Vide un slot après épuisement de sa file (tout est illisible) : le
    /// badge « Fichier illisible » est posé de façon persistante.
    private func emptySlotAfterFailure(_ slot: Int) {
        failedURLs.removeValue(forKey: slot)
        slots[slot] = nil
        syncEngine()
        engine.setSlotError("Fichier illisible", for: slot)
    }

    /// Échec de lecture d'un slot (.failed) : le remplacement automatique est
    /// tenté (le moteur a déjà différé de ~0,5 s). Si toute la file a échoué,
    /// le slot est vidé avec le badge « Fichier illisible ».
    private func handleSlotFailure(_ slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot) else { return }
        autoReplace(slot: slot, failedURL: slots[slot]?.url)
    }

    // MARK: Préchargement du remplacement (feature 1)

    /// Prépare le prochain contenu d'un slot HORS lecture : même logique que
    /// le remplacement automatique, mais anticipée (déclenchée à moins de 10 s
    /// de la fin du référentiel). L'AVPlayerItem est confié au moteur
    /// (pendingItems) ; reconfigure le réutilise à la fin de lecture.
    func prepareNext(for slot: Int) {
        guard engine.autoReplace, slots.indices.contains(slot),
              let current = slots[slot] else { return }
        guard let next = nextCandidate(for: slot), next.id != current.id else { return }
        let url = next.url
        // Même configuration que addSlot (tampon court, fichiers locaux).
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 2.0
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Amorçage du pipeline AVFoundation hors lecture.
            _ = try? await item.asset.load(.duration)
            guard !Task.isCancelled else { return }
            // Attend que l'item soit prêt (borné : 3 s) pour un remplacement
            // immédiat ; sinon l'item est confié quand même — le démarrage
            // différé (startFromZeroOnReady) prend le relais.
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

    // MARK: Persistance des files (feature 2)

    private func persistQueues() {
        let encoded: [String: [String]] = queues.mapValues { queue in
            queue.map { $0.url.standardizedFileURL.absoluteString }
        }
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
```

---

### Patch 9 — SyncEngine : rappels + état (features 1, 3, 5)

**Où** : bloc `autoReplace` / `onItemEnded` — lignes 1091-1098.

**old_string**
```swift
    /// Remplacement automatique des vidéos terminées (lecture continue).
    /// Quand il est actif, un slot terminé est remplacé par une vidéo de la
    /// bibliothèque et relancé — le bloc ne reste jamais vide.
    var autoReplace = true

    /// Rappel émis quand un slot atteint la fin de sa lecture (main thread) :
    /// la bibliothèque choisit une vidéo de remplacement.
    var onItemEnded: ((Int) -> Void)?
```

**new_string**
```swift
    /// Remplacement automatique des vidéos terminées (lecture continue).
    /// Quand il est actif, un slot terminé est remplacé par une vidéo de la
    /// bibliothèque et relancé — le bloc ne reste jamais vide.
    var autoReplace = true

    /// Rappel émis quand un slot atteint la fin de sa lecture (main thread) :
    /// la bibliothèque choisit une vidéo de remplacement.
    var onItemEnded: ((Int) -> Void)?

    /// Rappel émis quand un slot passe en échec (statut .failed, feature 3) :
    /// la bibliothèque tente le contenu suivant de la file.
    var onSlotFailed: ((Int) -> Void)?

    /// Rappel émis quand le référentiel approche de sa fin (feature 1) : la
    /// bibliothèque prépare le prochain item pour un remplacement instantané.
    var onPreloadNeeded: ((Int) -> Void)?

    // MARK: Préchargement du remplacement (feature 1)

    /// Item AVPlayerItem préchargé par slot, prêt à être réutilisé par
    /// reconfigure à la fin de lecture (transition sans écran noir).
    private struct PendingPreload {
        let url: URL
        let item: AVPlayerItem
    }

    /// Items préchargés par slot (feature 1) : produits par la bibliothèque
    /// (prepareNext) puis consommés par addSlot. Thread principal uniquement.
    private(set) var pendingItems: [Int: PendingPreload] = [:]

    /// Slots dont la demande de préchargement a déjà été émise : évite de
    /// re-déclencher la demande toutes les 0,1 s pendant la même lecture.
    private var preloadRequested: Set<Int> = []

    // MARK: Échecs (feature 3)

    /// Tâches de remplacement différé après échec, par slot.
    private var failedReplacementTasks: [Int: Task<Void, Never>] = [:]
    /// Slots dont le remplacement d'échec est déjà programmé (le KVO .failed
    /// peut être émis plusieurs fois pour le même item).
    private var failedReplacementPending: Set<Int> = []

    // MARK: Watchdog anti-blocage (feature 5)

    /// Dernier temps observé par slot (watchdog de blocage), avec sa date.
    private var lastProgression: [Int: (time: CMTime, date: Date)] = [:]

    /// Erreurs persistantes par slot (badge « Fichier illisible » sur un slot
    /// vidé) : ré-appliquées après chaque purge de reconfigure.
    private var persistentSlotErrors: [Int: String] = [:]
```

---

### Patch 10 — SyncEngine : méthodes préchargement, échec différé, erreur persistante, watchdog (features 1, 3, 5)

**Où** : après `clear()`, avant `// MARK: Cycle de vie des slots` — lignes 1170-1180.

**old_string**
```swift
    /// Retire tous les slots et réinitialise complètement l'état publié.
    func clear() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        wasPlayingBeforeScrub = false
        for slot in Array(slotStates.keys) {
            teardownSlot(slot)
        }
        resetPlaybackState()
    }
```

**new_string**
```swift
    /// Retire tous les slots et réinitialise complètement l'état publié.
    func clear() {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        wasPlayingBeforeScrub = false
        for slot in Array(slotStates.keys) {
            teardownSlot(slot)
        }
        resetPlaybackState()
    }

    // MARK: Préchargement du remplacement (feature 1)

    /// Confie un item préchargé au moteur pour le slot donné. Remplace un
    /// éventuel item en attente (annulation propre de l'ancien).
    func storePendingItem(_ item: AVPlayerItem, for url: URL, slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        cancelPendingItem(for: slot)
        pendingItems[slot] = PendingPreload(url: url, item: item)
    }

    /// Récupère l'item préchargé d'un slot si son URL correspond encore à la
    /// configuration demandée (le slot a pu changer entre-temps).
    func consumePendingItem(for slot: Int, url: URL) -> AVPlayerItem? {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let pending = pendingItems.removeValue(forKey: slot), pending.url == url else {
            return nil
        }
        preloadRequested.remove(slot)
        return pending.item
    }

    /// Annule le préchargement d'un slot : l'item en attente est libéré et
    /// son chargement stoppé. L'item en attente n'est jamais attaché à un
    /// player ; s'il l'avait été (cas limite), teardownSlot le détache avec
    /// replaceCurrentItem(nil).
    func cancelPendingItem(for slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        guard let pending = pendingItems.removeValue(forKey: slot) else { return }
        pending.item.asset.cancelLoading()
        preloadRequested.remove(slot)
    }

    /// PRÉCHARGEMENT ANTICIPÉ (feature 1) : à moins de 10 s de la fin du
    /// référentiel, demande à la bibliothèque de préparer le prochain
    /// candidat. Appelé depuis l'observateur périodique du référentiel
    /// (toutes les 0,1 s), une seule fois par lecture (garde preloadRequested).
    private func maybePreloadReplacement(for slot: Int, time: CMTime) {
        guard autoReplace, !preloadRequested.contains(slot), pendingItems[slot] == nil,
              let state = slotStates[slot], !state.ended,
              state.item.status == .readyToPlay else { return }
        let duration: Double
        if state.item.duration.isNumeric, state.item.duration.seconds.isFinite,
           state.item.duration.seconds > 0 {
            duration = state.item.duration.seconds
        } else if leaderDuration.isNumeric, leaderDuration.seconds.isFinite,
                  leaderDuration.seconds > 0 {
            duration = leaderDuration.seconds
        } else {
            return
        }
        let remaining = duration - time.seconds
        guard remaining.isFinite, remaining >= 0, remaining < 10 else { return }
        preloadRequested.insert(slot)
        onPreloadNeeded?(slot)
    }

    // MARK: Échec de lecture (feature 3)

    /// Programme le remplacement d'un slot en échec dans ~0,5 s (différé :
    /// laisse le système stabiliser l'échec avant de tenter la file).
    private func scheduleFailedReplacement(for slot: Int) {
        guard !failedReplacementPending.contains(slot) else { return }
        failedReplacementPending.insert(slot)
        failedReplacementTasks[slot]?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.failedReplacementPending.remove(slot)
            self.failedReplacementTasks[slot] = nil
            // Re-vérification : le slot doit exister et être toujours en échec.
            guard let state = self.slotStates[slot], state.item.status == .failed else { return }
            self.onSlotFailed?(slot)
        }
        failedReplacementTasks[slot] = task
    }

    /// Affecte une erreur persistante à un slot (badge « Fichier illisible »
    /// sur un slot vidé) : survit aux purges de reconfigure.
    func setSlotError(_ message: String, for slot: Int) {
        assert(Thread.isMainThread, "SyncEngine doit être utilisé depuis le thread principal")
        persistentSlotErrors[slot] = message
        if slotError[slot] != message {
            slotError[slot] = message
        }
    }

    // MARK: Watchdog anti-blocage (feature 5)

    /// Surveille la progression de chaque slot non référentiel pendant la
    /// lecture : un slot dont le temps n'avance pas depuis 3 s (sans être
    /// terminé ni en pause) est relancé (seek position actuelle + setRate
    /// ancré sur l'horloge hôte). Cadence : le timer du moniteur de dérive
    /// (1 s) ; s'arrête avec lui à la pause.
    private func checkFrozenSlots(now: Date = Date()) {
        guard isPlaying else { return }
        for (slot, state) in slotStates where slot != referenceSlot {
            guard !state.ended, state.item.status == .readyToPlay,
                  state.player.rate != 0 else { continue }
            let current = state.item.currentTime()
            guard current.isNumeric else { continue }
            if let last = lastProgression[slot] {
                if current.seconds != last.time.seconds {
                    lastProgression[slot] = (current, now)
                } else if now.timeIntervalSince(last.date) >= 3.0 {
                    // Blocage confirmé : relance du slot sur sa position.
                    restartFrozenSlot(slot, state: state, at: current)
                    // Remet le compteur à zéro : pas de relance en rafale.
                    lastProgression[slot] = (current, now)
                }
            } else {
                lastProgression[slot] = (current, now)
            }
        }
    }

    /// Relance un slot figé : seek sur sa position actuelle puis setRate
    /// ancré sur l'horloge hôte (même mécanique que le moniteur de dérive).
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
```

---

### Patch 11 — SyncEngine.addSlot : réutilisation de l'item préchargé (feature 1)

**Où** : tête de `addSlot(_:url:isLeader:)` — lignes 1182-1186.

**old_string**
```swift
    private func addSlot(_ slot: Int, url: URL, isLeader: Bool) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Tampon court : fichiers locaux, démarrage rapide sans attendre le remplissage.
        item.preferredForwardBufferDuration = 2.0
```

**new_string**
```swift
    private func addSlot(_ slot: Int, url: URL, isLeader: Bool) {
        // Feature 1 : réutilise l'item préchargé (remplacement anticipé) si
        // son URL correspond — transition instantanée, sans écran noir.
        let item: AVPlayerItem
        if let preloaded = consumePendingItem(for: slot, url: url) {
            item = preloaded
        } else {
            let asset = AVURLAsset(url: url)
            item = AVPlayerItem(asset: asset)
            // Tampon court : fichiers locaux, démarrage rapide sans attendre le remplissage.
            item.preferredForwardBufferDuration = 2.0
        }
        preloadRequested.remove(slot)
        // Le slot est réassigné : le badge d'erreur persistant n'a plus lieu d'être.
        persistentSlotErrors.removeValue(forKey: slot)
```

---

### Patch 12 — SyncEngine : observateur périodique → préchargement anticipé (feature 1)

**Où** : installation de l'observateur périodique dans `addSlot` — lignes 1212-1223.

**old_string**
```swift
        // Observateur périodique : seul le slot référentiel publie leaderTime.
        // Garde de changement : AVPlayer appelle ce callback même en pause
        // (0,1 s) avec la MÊME valeur — publier sans garde provoquerait un
        // re-render complet de l'UI 10×/s (100 % CPU au repos, mesuré au
        // profileur le 11/08/2026).
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        state.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.referenceSlot == slot else { return }
            if time != self.leaderTime {
                self.leaderTime = time
            }
        }
```

**new_string**
```swift
        // Observateur périodique : seul le slot référentiel publie leaderTime.
        // Garde de changement : AVPlayer appelle ce callback même en pause
        // (0,1 s) avec la MÊME valeur — publier sans garde provoquerait un
        // re-render complet de l'UI 10×/s (100 % CPU au repos, mesuré au
        // profileur le 11/08/2026).
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        state.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.referenceSlot == slot else { return }
            if time != self.leaderTime {
                self.leaderTime = time
            }
            // PRÉCHARGEMENT ANTICIPÉ DU REMPLACEMENT (feature 1) : à moins de
            // 10 s de la fin du référentiel, la bibliothèque prépare le
            // prochain item — le remplacement devient instantané.
            self.maybePreloadReplacement(for: slot, time: time)
        }
```

---

### Patch 13 — SyncEngine.teardownSlot : annulation préchargement + tâches différées (features 1, 3, 5)

**Où** : `teardownSlot(_:)` — lignes 1239-1242.

**old_string**
```swift
    private func teardownSlot(_ slot: Int) {
        guard let state = slotStates.removeValue(forKey: slot) else { return }
        Self.teardown(state)
    }
```

**new_string**
```swift
    private func teardownSlot(_ slot: Int) {
        guard let state = slotStates.removeValue(forKey: slot) else { return }
        // Feature 1 : annulation propre du préchargement éventuel du slot.
        cancelPendingItem(for: slot)
        preloadRequested.remove(slot)
        // Feature 3 : annule un remplacement d'échec encore en attente.
        failedReplacementTasks[slot]?.cancel()
        failedReplacementTasks.removeValue(forKey: slot)
        failedReplacementPending.remove(slot)
        // Feature 5 : oublie la progression du slot retiré.
        lastProgression.removeValue(forKey: slot)
        Self.teardown(state)
    }
```

---

### Patch 14 — SyncEngine.reconfigure : purge watchdog + ré-application des erreurs persistantes (features 3, 5)

**Où** : étape 4 de `reconfigure(slots:)` — lignes 928-936.

**old_string**
```swift
        // 4. Purge des états publiés orphelins + recompte.
        let validSlots = Set(slotStates.keys)
        if driftText.keys.contains(where: { !validSlots.contains($0) }) {
            driftText = driftText.filter { validSlots.contains($0.key) }
        }
        if slotError.keys.contains(where: { !validSlots.contains($0) }) {
            slotError = slotError.filter { validSlots.contains($0.key) }
        }
        updateReadyCount()
```

**new_string**
```swift
        // 4. Purge des états publiés orphelins + recompte.
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
        // Badges persistants (« Fichier illisible » sur slot vidé) :
        // ré-appliqués après la purge tant que le slot n'est pas réassigné.
        for (slot, message) in persistentSlotErrors where !validSlots.contains(slot) {
            if slotError[slot] != message {
                slotError[slot] = message
            }
        }
        updateReadyCount()
```

---

### Patch 15 — SyncEngine : timer de dérive → watchdog anti-blocage (feature 5)

**Où** : `startDriftMonitor()` — lignes 1341-1348.

**old_string**
```swift
    private func startDriftMonitor() {
        stopDriftMonitor()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkDrift()
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }
```

**new_string**
```swift
    private func startDriftMonitor() {
        stopDriftMonitor()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkDrift()
            // Feature 5 : watchdog anti-blocage, même cadence (1 s), arrêté
            // avec le moniteur de dérive à la pause.
            self?.checkFrozenSlots()
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }
```

---

### Patch 16 — SyncEngine.checkDrift : la correction de dérive repousse le compteur du watchdog (feature 5)

**Où** : ré-ancrage dans `checkDrift()` — lignes 1365-1370.

**old_string**
```swift
            if abs(delta.seconds) > 0.05 {
                // Ré-ancrage sans saut : on repositionne l'item sur le temps du
                // référentiel (other + delta == reference) au prochain tick de l'horloge hôte.
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(currentRate, time: otherCurrent + delta, atHostTime: host)
            }
```

**new_string**
```swift
            if abs(delta.seconds) > 0.05 {
                // Ré-ancrage sans saut : on repositionne l'item sur le temps du
                // référentiel (other + delta == reference) au prochain tick de l'horloge hôte.
                let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
                state.player.setRate(currentRate, time: otherCurrent + delta, atHostTime: host)
                // Feature 5 : la correction de dérive compte comme progression —
                // on repousse le compteur du watchdog pour ce slot.
                lastProgression[slot] = (otherCurrent + delta, Date())
            }
```

---

### Patch 17 — SyncEngine.pause() : arrêt du watchdog (feature 5)

**Où** : `pause()` — lignes 998-1000.

**old_string**
```swift
        cancelPendingPlaybackStart()
        stopDriftMonitor()
        for state in slotStates.values {
```

**new_string**
```swift
        cancelPendingPlaybackStart()
        stopDriftMonitor()
        // Feature 5 : le watchdog s'arrête avec la lecture (progression oubliée).
        lastProgression.removeAll()
        for state in slotStates.values {
```

---

### Patch 18 — SyncEngine.resetPlaybackState : purge erreurs persistantes + watchdog (features 3, 5)

**Où** : `resetPlaybackState()` — lignes 1331-1336.

**old_string**
```swift
        isPlaying = false
        leaderTime = .zero
        leaderDuration = .zero
        driftText.removeAll()
        slotError.removeAll()
        updateReadyCount()
```

**new_string**
```swift
        isPlaying = false
        leaderTime = .zero
        leaderDuration = .zero
        driftText.removeAll()
        slotError.removeAll()
        persistentSlotErrors.removeAll()
        lastProgression.removeAll()
        updateReadyCount()
```

---

### Patch 19 — SyncEngine.handleStatusChange : cas .failed → remplacement auto différé (feature 3)

**Où** : `handleStatusChange(slot:)`, cas `.failed` — lignes 1423-1425.

**old_string**
```swift
        case .failed:
            slotError[slot] = state.item.error?.localizedDescription ?? "Erreur de lecture inconnue"
        case .unknown:
            break
```

**new_string**
```swift
        case .failed:
            let message = state.item.error?.localizedDescription ?? "Fichier illisible"
            if slotError[slot] != message {
                slotError[slot] = message
            }
            // Feature 3 : remplacement automatique différé (~0,5 s) — laisse
            // le système stabiliser l'échec avant de tenter la file.
            if autoReplace {
                scheduleFailedReplacement(for: slot)
            }
        case .unknown:
            break
```

---

### Patch 20 — SyncEngine.deinit : libération des items préchargés (feature 1)

**Où** : `deinit` — lignes 877-881.

**old_string**
```swift
    deinit {
        // Nettoyage complet, même si le deinit survient hors du thread principal.
        stopDriftMonitor()
        let states = Array(slotStates.values)
```

**new_string**
```swift
    deinit {
        // Nettoyage complet, même si le deinit survient hors du thread principal.
        stopDriftMonitor()
        // Feature 1 : libère les items préchargés (chargements annulés).
        for pending in pendingItems.values {
            pending.item.asset.cancelLoading()
        }
        pendingItems.removeAll()
        let states = Array(slotStates.values)
```

---

### Patch 21 — TransportBar : bouton « Mélanger » (feature 2)

**Où** : barre de transport, après le bouton Resynchroniser — lignes 3834-3835.

**old_string**
```swift
            BarIconButton(systemName: "arrow.triangle.2.circlepath", help: "Resynchroniser") { engine.resync() }
            ratePicker
```

**new_string**
```swift
            BarIconButton(systemName: "arrow.triangle.2.circlepath", help: "Resynchroniser") { engine.resync() }
            BarIconButton(systemName: "shuffle", help: "Mélanger les files de lecture") { library.shuffleQueues() }
            ratePicker
```

---

### Patch 22 — StagePane : badge « Fichier illisible » sur panneau vide (feature 3)

**Où** : `emptyPane` — lignes 4206-4228.

**old_string**
```swift
    /// Panneau d'attente : invite au glisser-déposer vers cet emplacement.
    private var emptyPane: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Glisser une vidéo ici")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Emplacement \\(slotLetters[slot])")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            )
    }
```

**new_string**
```swift
    /// Panneau d'attente : invite au glisser-déposer vers cet emplacement.
    /// Affiche le badge « Fichier illisible » si le slot a été vidé après
    /// échec de toute la file (feature 3).
    private var emptyPane: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Glisser une vidéo ici")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Emplacement \\(slotLetters[slot])")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                    }
                )
            if let error = engine.slotError[slot], !error.isEmpty {
                Text("Fichier illisible")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(10)
                    .help(error)
            }
        }
    }
```

---

## VÉRIFICATIONS

Chaque `old_string` a été lu dans le fichier (`read_file`) et confirmé UNIQUE dans `ContentView.swift` (`search_files`) :

| Patch | Ancre | Fichier : lignes |
|---|---|---|
| 1 | `engine.onItemEnded = { [weak self] slot in` | ContentView.swift:131-134 |
| 2 | `private static let slotsKey = "library.slotURLs"` | ContentView.swift:123-126 |
| 3 | `func clear(slot: Int)` (unique) | ContentView.swift:143-147 |
| 4 | `for task in metadataTasks.values { task.cancel() }` + `engine.clear()` | ContentView.swift:149-155 |
| 5 | `func assign(_ asset: VideoAsset, to slot: Int)` + `slots[slot] = asset` (unique) | ContentView.swift:157-165 |
| 6 | `d.set(slots.map { $0?.url.standardizedFileURL.absoluteString ?? "" }, ...)` (unique) | ContentView.swift:317-318 |
| 7 | `syncEngine()` + `restoreSources()` + `scanSources()` (séquence unique ; la déclaration `private func restoreSources()` est à la ligne 351) | ContentView.swift:341-344 |
| 8 | `private func autoReplace(slot: Int)` (unique) | ContentView.swift:460-473 |
| 9 | `var autoReplace = true` + `var onItemEnded: ((Int) -> Void)?` (unique) | ContentView.swift:1091-1098 |
| 10 | `func clear()` (unique, SyncEngine) | ContentView.swift:1170-1178 |
| 11 | `let asset = AVURLAsset(url: url)` + commentaire « Tampon court » (unique) | ContentView.swift:1182-1186 |
| 12 | `let interval = CMTime(seconds: 0.1, preferredTimescale: 10)` + garde `if time != self.leaderTime` (unique) | ContentView.swift:1212-1223 |
| 13 | `private func teardownSlot(_ slot: Int)` (unique) | ContentView.swift:1239-1242 |
| 14 | `// 4. Purge des états publiés orphelins + recompte.` (unique) | ContentView.swift:928-936 |
| 15 | `let timer = Timer(timeInterval: 1.0, repeats: true)` (unique) | ContentView.swift:1341-1348 |
| 16 | `if abs(delta.seconds) > 0.05 {` (unique) | ContentView.swift:1365-1370 |
| 17 | `cancelPendingPlaybackStart()` + `stopDriftMonitor()` + `for state in slotStates.values {` (séquence unique) | ContentView.swift:998-1000 |
| 18 | `isPlaying = false` + `leaderTime = .zero` + `slotError.removeAll()` (séquence unique) | ContentView.swift:1331-1336 |
| 19 | `case .failed:` (unique, 1 occurrence) | ContentView.swift:1423-1425 |
| 20 | `deinit {` + `stopDriftMonitor()` + `let states = Array(slotStates.values)` (unique, 1 seul deinit) | ContentView.swift:877-881 |
| 21 | `help: "Resynchroniser"` (unique, 1 occurrence) | ContentView.swift:3834-3835 |
| 22 | `Text("Emplacement \\(slotLetters[slot])")` (unique, 1 occurrence) | ContentView.swift:4206-4228 |

Note : le fichier contient des keypaths Swift `\.` (ex. ligne 972 `filter(\.ended)`) ; aucun `old_string` ne les inclut — aucun risque d'ambiguïté d'échappement.
