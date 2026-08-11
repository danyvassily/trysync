# Revue statique exigeante — VideoLibrary.swift + intégration moteur (AGENT R2)

**Périmètre audité** : `TriSyncPkg/Sources/TriSync/VideoLibrary.swift` (838 l.), `EngineAndSettings.swift` (SyncEngine, 1605 l.), `ContentView.swift` (caches, sidebar, grille, navigateur de dossiers, 3840 l.).
**Méthode** : revue statique ligne à ligne (build impossible, licence Xcode bloquée). Aucun fichier modifié.

---

## BLOCKERS

### B1 — Crash au lancement si UserDefaults contient > maxSlots entrées de slots
**VideoLibrary.swift:423-429** — `restoreLibrary()` :
```swift
for (index, urlString) in slotURLs.enumerated() where !urlString.isEmpty {
    if let asset = assets.first(...) {
        slots[index] = asset   // ← index non borné
    }
}
```
`slots` a exactement 5 cases ; `slotURLs` vient de UserDefaults (écrit par saveNow à 5 entrées, mais corruptible : préférences éditées, version antérieure, migration, plist endommagée). Une 6ᵉ entrée = **crash `index out of range` au lancement** — l'app ne démarre plus, et l'utilisateur ne peut pas corriger sans effacer les préférences.

**Correction** (1 ligne) :
```swift
for (index, urlString) in slotURLs.enumerated() where !urlString.isEmpty {
    guard slots.indices.contains(index) else { continue }   // ← borné (défensif)
    if let asset = assets.first(where: { $0.url.standardizedFileURL.absoluteString == urlString }) {
        slots[index] = asset
    }
}
```

---

## MAJEURS

### M1 — Déduplication par URL brute (non standardisée) → doublons garantis après restauration
**VideoLibrary.swift:202** (`add`), **:534** (`ensureInLibrary`), **:225** (`addSource`) :
```swift
guard !assets.contains(where: { $0.url == url }) else { continue }   // :202
if let existing = assets.first(where: { $0.url == url }) { return existing }   // :534
if sources.contains(where: { $0.url == url }) { return }   // :225
```
Or `saveNow` (l. 401-404) documente que la résolution de bookmark retourne le chemin **canonique** (`/private/var/...` ≠ `/var/...`) et que la comparaison doit être standardisée. Scénario réel : source ajoutée sous `/var/Movies` → assets restaurés au relaunch avec `/private/var/Movies/...` (bookmark résolu) → le scan de la source re-trouve `/var/Movies/...` → `$0.url == url` est **faux** → **doublon créé** (visible dans la grille, sélectionnable, jouable). Même problème avec les symlinks et la casse (APFS/HFS+ insensible à la casse : `A.mp4` vs `a.mp4` = même fichier, 2 assets).

**Correction** — normalisation unique + dédup O(1) (évite aussi l'O(n²) pour les scans de 5000 fichiers) :
```swift
// Dans add(urls:source:)
var known = Set(assets.map { $0.url.standardizedFileURL.path })
for url in Self.videoFiles(from: urls) {
    let key = url.standardizedFileURL.path
    guard !known.contains(key) else { continue }
    let asset = VideoAsset(url: url)
    assets.append(asset)
    known.insert(key)
    ...
}
// ensureInLibrary :
if let existing = assets.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
    return existing
}
// addSource : sources.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })
```

### M2 — Attribution source perdue à la restauration → removeSource / toggleSource inopérants après un relaunch
**VideoLibrary.swift:420-421** — `restoreLibrary` ré-ingère TOUS les assets (bookmarks, toutes sources confondues) via `add(urls: urls, source: nil)` → `assetSource[asset.id] = nil` pour chaque asset restauré. Ensuite le scan de la source re-tombe sur les mêmes fichiers, mais **le dédup (M1) les ignore** → `assetSource` ne sera **jamais** re-rempli. Conséquence : après le premier relaunch, « Retirer la source » et la désactivation (`toggleSource` → `removeSourceVideos`) ne suppriment **plus rien** — les vidéos de la source restent à vie dans la bibliothèque.

**Correction** — ré-attribuer par préfixe de chemin après `restoreSources()`, et ré-attribuer dans `add()` quand l'asset existait déjà :
```swift
// restoreLibrary, après restoreSources() (l. 432) :
for asset in assets where assetSource[asset.id] == nil {
    let path = asset.url.standardizedFileURL.path
    if let source = sources.first(where: {
        path.hasPrefix($0.url.standardizedFileURL.path + "/")
    }) {
        assetSource[asset.id] = source.id
    }
}

// add(urls:source:) : au lieu de « continue » muet sur doublon :
if let existing = assets.first(where: { $0.url.standardizedFileURL.path == key }) {
    if let source, assetSource[existing.id] == nil { assetSource[existing.id] = source }
    continue
}
```

### M3 — Race retrait/désactivation de source vs scan en vol → vidéos « fantômes » ré-ajoutées après suppression
**VideoLibrary.swift:317-323** — la complétion du scan (`MainActor.run`) ajoute les résultats **sans vérifier que la source existe encore** :
```swift
await MainActor.run { [weak self] in
    guard let self else { return }
    self.add(urls: result, source: sourceID)          // ← source peut avoir été retirée
    self.sourceFingerprints[sourceID] = Self.modificationDate(of: url)
    ...
}
```
Scénario : `removeSource(id:)` (ou `toggleSource` off) pendant qu'un scan de cette source est en cours (scan déclenché manuellement, par réactivation, ou par le watcher) → les vidéos sont ré-ajoutées **après** le retrait, avec `assetSource` pointant vers un UUID mort → impossibles à retirer (M2), doublons potentiels au prochain scan.

**Correction** — garder la validité de la source avant d'ingérer, et ne mettre à jour l'empreinte que si l'énumération a réellement eu lieu :
```swift
let result = found
let enumerated = found.count > 0 || enumerator != nil   // ou booléen dédié
await MainActor.run { [weak self] in
    guard let self else { return }
    if self.sources.contains(where: { $0.id == sourceID && $0.enabled }) {
        self.add(urls: result, source: sourceID)
        if enumerated {
            self.sourceFingerprints[sourceID] = Self.modificationDate(of: url)
        }
    }
    self.activeScans -= 1
    if self.activeScans == 0 { self.isScanning = false }
}
```

### M4 — Clés de positions de lecture incohérentes : `url.path` brut (moteur) vs `standardizedFileURL.path` (bibliothèque)
- **EngineAndSettings.swift:887, 893, 900, 1427** : `positions[url.path]` (brut), écrit par `checkDrift` à 1 Hz pendant la lecture.
- **VideoLibrary.swift:552** : `playbackPosition(for:)` lit `url.standardizedFileURL.path`.

Pour tout fichier dont le chemin stocké n'est pas canonique (`/var/...`, symlink — précisément le cas produit par la résolution de bookmark), la clé écrite par le moteur (`/var/x.mp4`) ≠ clé lue par le dossier intelligent « Reprise » (`/private/var/x.mp4`) → **la vidéo n'apparaît jamais dans « Reprise »** alors qu'une position > 15 s est enregistrée (et le bandeau de reprise, lui, fonctionne car `offerResumeIfNeeded` utilise le même `url.path` brut). Incohérence silencieuse entre deux lecteurs du même dict.

**Correction** — standardiser dans le moteur :
```swift
// SyncEngine
private func positionKey(_ url: URL) -> String { url.standardizedFileURL.path }
func position(for url: URL) -> Double { positions[positionKey(url)] ?? 0 }
func savePosition(_ seconds: Double, for url: URL) { ... positions[positionKey(url)] = seconds ... }
func clearPosition(for url: URL) { guard positions.removeValue(forKey: positionKey(url)) != nil ... }
// checkDrift (l. 1427) : positions[positionKey(state.url)] = time.seconds
```

### M5 — saveNow : échec silencieux de `bookmarkData` → asset définitivement perdu au relaunch
**VideoLibrary.swift:393-399** :
```swift
if let data = try? asset.url.bookmarkData(options: .withSecurityScope, ...) {
    bookmarks.append(data.base64EncodedString())
}   // ← sinon : asset omis SANS AUCUNE trace
```
Un bookmark security-scoped peut échouer (URL session-scoped issue d'un NSOpenPanel dont l'extension a expiré, fichier sur un volume momentanément inaccessible, droits sandbox) → l'asset disparaît silencieusement de la bibliothèque au redémarrage, sans log ni message. C'est exactement le « échec silencieux → asset perdu » de la zone d'audit.

**Correction** — filet de sécurité : persister aussi le chemin et logguer l'échec.
```swift
var bookmarks: [String] = []
var fallbackPaths: [String] = []          // aligné sur bookmarks ("" si bookmark OK)
for asset in assets {
    if let data = try? asset.url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
        bookmarks.append(data.base64EncodedString())
        fallbackPaths.append("")
    } else {
        NSLog("TriSync: bookmark impossible pour %@ — repli sur chemin", asset.url.path)
        bookmarks.append("")              // trou conservé pour l'alignement
        fallbackPaths.append(asset.url.standardizedFileURL.path)
    }
}
d.set(bookmarks, forKey: Self.assetsKey)
d.set(fallbackPaths, forKey: "library.assetFallbackPaths")
```
et dans `restoreLibrary` (l. 413-419) : si la résolution échoue à l'index `i`, utiliser `fallbackPaths[i]` pour recréer l'asset par chemin (`URL(fileURLWithPath:)`) — l'asset reste visible, les métadonnées échouent proprement, et le prochain `saveNow` retentera le bookmark.

### M6 — `failedURLs` jamais nettoyés : un fichier temporairement illisible est banni du slot pour toute la session
**VideoLibrary.swift:677-692** — `applyReplacement` insère l'URL en échec dans `failedURLs[slot]` (définitif, sans date ni compteur) ; le slot passe à la vidéo suivante ; si `next.url ∈ failedURLs` → `emptySlotAfterFailure`. Le set n'est vidé que par `assign`/`clear`/fin naturelle. Scénario : fichier verrouillé 2 s par Dropbox/iCloud Drive, volume externe qui se reconnecte, fichier en cours de copie → l'URL reste dans `failedURLs` **pour toujours** : le slot vide son slot avec badge « Fichier illisible » au lieu de retenter le fichier revenu. Aucun mécanisme « le fichier réapparaît → on retente ».

**Correction** — expirer les échecs (retentative après 5 min) :
```swift
/// URLs en échec par slot, avec date du premier échec (expiration 5 min).
private var failedURLs: [Int: [URL: Date]] = [:]

// applyReplacement :
if let failedURL {
    failedURLs[slot, default: [:]][failedURL] = Date()
} else {
    failedURLs.removeValue(forKey: slot)
}
// Purge des échecs anciens : un fichier revenu entre-temps est RETENTÉ.
let now = Date()
let recent = failedURLs[slot, default: [:]].filter { now.timeIntervalSince($0.value) < 300 }
failedURLs[slot] = recent
if recent.keys.contains(next.url) {
    emptySlotAfterFailure(slot)
    return
}
```

### M7 — Fuites : `removeSourceVideos` n'annule pas les `metadataTasks` ; `assetSource` jamais nettoyé (removeAsset, clearAll, removeSourceVideos)
- **VideoLibrary.swift:263-271** (`removeSourceVideos`, appelé par `toggleSource` off) : retire les assets **sans** `metadataTasks[id]?.cancel()` ni `assetSource.removeValue` — contrairement à `removeSource` (l. 238-241). Les tâches continuent de charger des métadonnées/vignettes pour des assets orphelins (travail gaspillé + entrées dict retenues).
- **VideoLibrary.swift:175-183** (`removeAsset`) : `assetSource.removeValue(forKey:)` **absent** → fuite d'une entrée par asset retiré.
- **VideoLibrary.swift:144-154** (`clearAll`) : vide `assets`, `slots`, dicts… mais **pas `assetSource`** → toutes les entrées accumulées depuis le lancement restent (croissance non bornée).
- **VideoLibrary.swift:206-212** : les tâches de `metadataTasks` **terminées ne sont jamais retirées du dict** et capturent `self` implicitement (`objectWillChange.send()`) → cycle `Task → self → metadataTasks → Task` persistant (bénin ici car la bibliothèque est un StateObject app-lifetime, mais fuite réelle dans tout scénario de test/libération).

**Corrections** :
```swift
// removeSourceVideos — aligner sur removeSource :
for asset in doomed {
    metadataTasks[asset.id]?.cancel()
    metadataTasks.removeValue(forKey: asset.id)
    assetSource.removeValue(forKey: asset.id)
    assets.removeAll { $0.id == asset.id }
    for i in slots.indices where slots[i]?.id == asset.id { slots[i] = nil }
}
// removeAsset : ajouter assetSource.removeValue(forKey: asset.id)
// clearAll : ajouter assetSource.removeAll()

// add() — tâche auto-nettoyante + capture faible (casse le cycle) :
let task = Task { @MainActor [weak self] in
    await self?.loadMetadata(for: asset)
    self?.metadataTasks[asset.id] = nil
    if !Task.isCancelled { self?.objectWillChange.send() }
}
metadataTasks[asset.id] = task
```

### M8 — `add()` re-filtre `videoFiles(from:)` (I/O disque par fichier) sur le MainActor pour jusqu'à 5000 URLs → hitch UI au premier scan
**VideoLibrary.swift:201 + 319** — le scan a déjà filtré chaque fichier sur la tâche détachée (l. 313), puis `MainActor.run` rappelle `add(urls: result, source:)` qui **refait** `Self.videoFiles(from: urls)` → `resourceValues(.contentTypeKey)` = un stat par fichier, **sur le thread principal**, jusqu'à 5000 fois (volumes réseau : secondes). L'UI gèle pendant l'ingestion d'une grosse source.

**Correction** — entrée pré-filtrée :
```swift
// scanSource : self.addFiltered(urls: result, source: sourceID)
/// Comme add(urls:source:), mais sans re-filtrage UTType
/// (l'appelant a déjà filtré — scan de source).
private func addFiltered(urls: [URL], source: UUID?) {
    var known = Set(assets.map { $0.url.standardizedFileURL.path })
    for url in urls {
        let key = url.standardizedFileURL.path
        guard !known.contains(key) else { continue }
        ... // identique à add()
    }
    syncEngine(); scheduleSave()
}
```

### M9 — Caches (métadonnées + vignettes) indexés par chemin seul : un fichier remplacé au même chemin affiche des données obsolètes pour toujours
- **ContentView.swift:1483-1489** (`MetadataCache.get/set`) : clé = `url.path` brut — fichier ré-encodé/remplacé au même chemin → durée/résolution/fréquence **périmées définitivement** (mémoire + UserDefaults).
- **ContentView.swift:1558-1565, 1600-1603** (`ThumbnailCache`) : clé disque = SHA-256 du chemin seul, écriture **non atomique** (`try? data.write(to:)`), aucun purge, aucune invalidation → vignette de l'ancienne version du fichier affichée pour toujours (mémoire + disque).

**Correction** — inclure l'identité du fichier (taille + mtime) dans les clés, et écrire atomiquement :
```swift
// MetadataCache
private func key(for url: URL) -> String {
    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return "\(url.path)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
}
// get/set → cache[key(for: url)]

// ThumbnailCache.stableKey — hash du chemin + identité du fichier
private func stableKey(_ url: URL) -> String {
    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let identity = "\(url.path)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    let digest = SHA256.hash(data: Data(identity.utf8))
    return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
}
// Écriture atomique (l. 1602) :
try? data.write(to: file, options: .atomic)
```
(Coût : un stat par appel — négligeable ; un fichier ré-encodé change de taille/mtime → nouvelle clé → nouvelle vignette.)

---

## MINEURS

1. **VideoLibrary.swift:382-387** — `DispatchWorkItem` non isolé qui appelle `saveNow()` (isolé MainActor) : compilable en mode Swift 5 (fermeture formée en contexte MainActor, exécutée sur la main queue → correct à l'exécution), mais **erreur en mode Swift 6**. Même motif : EngineAndSettings.swift:906-908, 929-931, 1276-1283. Prévoir `MainActor.assumeIsolated` ou migrer vers `Task { @MainActor in }`.
2. **VideoLibrary.swift:345-368** — `checkSourcesForChanges` relance un scan complet sur **toute** modification de date du dossier (`.DS_Store`, fichier non-vidéo, sous-dossier) : énumération complète (jusqu'à 5000 entrées) à chaque fois. Acceptable (le dédup absorbe), mais une empreinte « nombre de vidéos + date » ou un scan incrémental réduirait la charge. Par ailleurs, la tolérance 1,5 s est saine.
3. **VideoLibrary.swift:320** — l'empreinte est mise à jour même si l'énumération a échoué (dossier lisible mais refusé en sous-dossier, erreur FS transitoire) : la source ne sera plus rescannée tant que sa date ne change pas. Correction incluse dans M3 (`enumerated`).
4. **EngineAndSettings.swift:1011-1018** — `consumePendingItem` retire l'item préchargé du dict **même si l'URL ne correspond pas**, sans `cancelLoading()` explicite : le chargement AVURLAsset continue jusqu'à la déallocation. Ajouter `pending.item.asset.cancelLoading()` sur le chemin mismatch.
5. **VideoLibrary.swift:427 vs 171** — les slots restaurés au lancement ne passent pas par `assign()` → pas de `offerResumeIfNeeded` : le bandeau « Reprendre » n'apparaît pas pour les vidéos restaurées avec position > 15 s (les positions sont bien chargées dans le moteur, cf. positives). Comportement discutable, à confirmer comme voulu.
6. **VideoLibrary.swift:762-771** — `restoreQueues` filtre les assets morts mais ne persiste pas le résultat (pas de `scheduleSave`) : idempotent, sans gravité, mais le UserDefaults garde des entrées mortes.
7. **ContentView.swift:1509-1529** — `ThumbGenLimiter` : `waiters` non borné (5000 requêtes → 5000 continuations) et `acquire()` non sensible à l'annulation : une tâche annulée pendant l'attente est réveillée puis **génère quand même la vignette** (pas de `Task.isCancelled` après `acquire`). Ajouter un check après l'acquire.
8. **EngineAndSettings.swift:400-401 / 886-916** — le dict `positions` n'est jamais purgé (fichiers retirés de la bibliothèque) : croissance lente et permanente. Purger à `removeAsset`/`removeSource` (par clé standardisée, cf. M4).
9. **VideoLibrary.swift:37-50** — `library.favorites` garde des chemins orphelins après `removeAsset` (inoffensif, croissance lente). Purge optionnelle dans `removeAsset`.
10. **VideoLibrary.swift:533-537** — `ensureInLibrary` n'applique pas `videoFiles()` : OK aujourd'hui (les 2 call sites filtrent, ContentView.swift:2153), mais tout futur appelant peut injecter un non-vidéo. Ajouter le filtre par défense.
11. **VideoLibrary.swift:284, 332-341** — `sourceWatcherTask` n'est jamais annulé explicitement (pas de `deinit` possible sur classe @MainActor) : il s'arrête seul via `[weak self]` quand la bibliothèque est libérée — correct car la bibliothèque vit pour toute la durée de l'app ; prévoir une API `stopSourceWatcher()` si un jour la bibliothèque devient jetable.
12. **VideoLibrary.swift:309-314** — cap de 5000 fichiers par scan silencieux : un dossier > 5000 vidéos est tronqué sans avertissement (à documenter dans l'UI).
13. **VideoLibrary.swift:206-212** — 5000 `AVURLAsset.load(.duration)` lancés simultanément au premier scan d'une grosse source (le limiter ne borne que les vignettes) : pic mémoire AVFoundation. Borner les chargements de métadonnées (même pattern que ThumbGenLimiter) si constaté en pratique.

---

## VÉRIFICATIONS POSITIVES (concis)

- **Persistance des slots/queues entièrement en chemins standardisés** : `saveNow` (l. 405), restauration (l. 426), `persistQueues` (l. 755), `restoreQueues` (l. 768) — le bug `/private/var` est correctement traité **pour ces quatre chemins** (le commentaire l. 401-404 est exact) ; les favoris aussi (l. 38-45, clé standardisée dans les deux sens) → les favoris survivent au round-trip ✓.
- **restoreLibrary : ordre correct** — assets (l. 420-422) AVANT slots (l. 423-429), puis `syncEngine()` (l. 430, déclenche bien `engine.reconfigure`), puis queues, sources, scan ✓. Positions chargées dans le moteur à l'init (EngineAndSettings.swift:459) et écrites à la sortie (ContentView.swift:31) ✓.
- **Anti-rafale solide** : `pendingReplacements[slot]` annulé dans `clear` (l. 138-139), `assign` (l. 164-165) et `clearAll` (l. 147-148) ; la tâche différée re-vérifie `slots[slot]?.id == expectedID` + `engine.autoReplace` avant d'appliquer ✓.
- **Préchargement réutilisé par le remplacement** : `nextCandidate` ne fait PAS tourner la file (l. 629) = tête de file, et `next(in:)` rend aussi la tête → `consumePendingItem(for:url:)` (EngineAndSettings.swift:1011) matche l'URL → l'item préchargé est consommé par `addSlot` ✓. `prepareNext` re-vérifie `slots[slot]?.id == current.id` avant `storePendingItem` (l. 744-746) et `teardownSlot` → `cancelPendingItem` ✓.
- **Scan/threads** : `Task.detached(priority: .utility)` + `[weak self]` + `MainActor.run` avec re-check `guard let self` ✓ ; `start/stopAccessingSecurityScopedResource` équilibrés dans tous les chemins (scan l. 302-303, metadata l. 777-782, modificationDate l. 373-374) ✓ ; garde anti-double-scan `isScanning`/`activeScans` ✓ (l. 289, 297-298, 346) ; cap 5000 ✓.
- **Moteur** : `reconfigure` par diff avec teardown complet (KVO, observateurs, time observer, `replaceCurrentItem(nil)`), purge des `@Published` orphelins + ré-application des badges persistants (EngineAndSettings.swift:524-542) ✓ ; `joinNewSlot`/`startFromZeroOnReady` sécurisent `setRate(atHostTime:)` contre les items non prêts (crash 11/08 corrigé) ✓ ; `deinit` libère `pendingItems` + teardown hors main thread ✓ ; tous les callbacks vers la bibliothèque en `[weak self]` ✓.
- **Bornes** : `maxSlots = 5` respecté partout — `selectedAssets` tronque à 5 (l. 525), `launchSelected` (l. 561), `assign`/`place`/`next`/`queue` bounds-checkés, `slotLetters` = 5 ✓ ; `add()` filtre `videoFiles` ✓ ; `FolderBrowserView` filtre avant `ensureInLibrary` (ContentView.swift:2153) ✓ ; `prefetch` borné (500 items, 4 concurrents) ✓ ; `MetadataCache` éviction à 2000 ✓.
- **Favoris** : persistance immédiate dans le setter `isFavorite` (l. 43) + `favoritesRevision` pour l'UI ✓ ; cohérents avec les assets restaurés (clé standardisée) ✓.
- **Divers** : `saveWorkItem` différé annulé/replanifié ✓ ; `applicationWillTerminate` → `saveNow` + `persistPositionsNow` ✓ ; `emptySlotAfterFailure` pose un badge persistant qui survit aux purges de reconfigure ✓ ; `seekAll` avec compteur de génération + watchdog 2 s (pas de pause bloquée si un player est détruit en vol) ✓ ; `checkDrift` écrit les positions à 1 Hz avec persistance différée 2 s (pas d'écriture UserDefaults en continu) ✓.

---

**Comptage** : 1 BLOCKER (B1) · 9 MAJEURS (M1-M9) · 13 MINEURS — **23 problèmes au total**.
**Les 3 plus critiques** : **B1** (crash au lancement sur données de préférences corrompues/longues), **M1+M2** (dédup non standardisée → doublons garantis après restauration, et retrait de source définitivement cassé après le premier relaunch), **M4** (clés de positions incohérentes moteur/bibliothèque → dossier « Reprise » muet pour les chemins `/var`).
