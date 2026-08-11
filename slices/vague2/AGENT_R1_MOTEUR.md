# AGENT R1 — Revue statique exigeante du moteur TriSync

**Fichier audité** : `TriSyncPkg/Sources/TriSync/EngineAndSettings.swift` (moteur complet, 1605 l.)
**Interactions vérifiées** : `VideoLibrary.swift` (autoReplace/prepareNext/handleSlotFailure/syncEngine) et `ContentView.swift` (TransportBar 3121-3330, MiniPlayer 690-770, bloc vidéo 3390-3570).
**Méthode** : revue statique ligne à ligne (build impossible, licence Xcode bloquée). Les crashs `setRate(_:time:atHostTime:)` sur item non prêt sont documentés dans le code lui-même (commentaire l. 762-764, « crash 2026-08-11 ») — pris comme acquis.

---

## BLOCKERS (crash / perte de données)

### B1. `setRate(_:)` — setRate(_:time:atHostTime:) sans garde `readyToPlay` → SIGABRT
**EngineAndSettings.swift:665-679** (boucle l. 676-678)
```swift
let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
for state in slotStates.values where !state.ended {
    state.player.setRate(rate, time: state.player.currentTime(), atHostTime: host)
}
```
**Scénario** : pendant la lecture, un slot a un item non prêt (remplacement auto en cours de chargement après `.failed`, ou slot venant d'être ajouté via reconfigure alors qu'on jouait) → l'utilisateur change la vitesse (picker, l. 3178 `engine.setRate`) ou presse un raccourci vitesse (`nudgeRate`, ContentView.swift:3521) → `setRate(_:time:atHostTime:)` sur un item `status != .readyToPlay` → exception Objective-C → SIGABRT. C'est exactement le crash que `joinNewSlot`/`scheduleSlotStart` évitent déjà — mais ce chemin-ci ne l'évite pas.
**Correction** :
```swift
for state in slotStates.values where !state.ended && state.item.status == .readyToPlay {
    state.player.setRate(rate, time: state.player.currentTime(), atHostTime: host)
}
// Les slots non prêts rejoindront via handleStatusChange (readyToPlay) → scheduleSlotStart/join.
```

### B2. `resync()` — même absence de garde dans la boucle de ré-ancrage
**EngineAndSettings.swift:649-661** (setRate l. 652-656)
```swift
for (slot, state) in slotStates where slot != reference.slot {
    guard !state.ended else { continue }
    if isPlaying {
        state.player.setRate(currentRate, time: target, atHostTime: ...)   // ← non gardé
    } else {
        state.player.seek(to: target, ...)
    }
    publishDrift(...)
}
```
**Scénario** : l'utilisateur clique « Resynchroniser » (ContentView.swift:3148) pendant qu'un slot est en chargement (remplacement différé, échec, ajout à chaud) → SIGABRT. Le guard `reference.item.status == .readyToPlay` (l. 647) ne protège que le référentiel, pas les cibles.
**Correction** :
```swift
for (slot, state) in slotStates where slot != reference.slot && !state.ended {
    guard state.item.status == .readyToPlay else { continue }
    if isPlaying { ... setRate ... } else { ... seek ... }
    publishDrift(...)
}
```

### B3. `startPlayback()` — garde manquante dans la boucle de démarrage (fenêtre TOCTOU au call-site)
**EngineAndSettings.swift:1244-1252**
```swift
for state in slotStates.values where !state.ended {
    state.player.setRate(currentRate, time: state.player.currentTime(), atHostTime: host)
}
```
Les call-sites (`play()` l. 573-574, `reconfigure` l. 553-554) vérifient `isReadyToPlayAll`, mais le chemin *rewind* de `play()` (l. 578-599) a une fenêtre : les items sont prêts à l'entrée de `play()`, mais le seek de rembobinage est asynchrone ; entre-temps un slot peut être remplacé (assign manuel → reconfigure → nouvel item non prêt) ou passer `.failed`. La complétion du rewind appelle alors `startPlayback()` → setRate sur item non prêt → SIGABRT.
**Correction** (défense en profondeur dans `startPlayback`) :
```swift
private func startPlayback() {
    guard !slotStates.isEmpty else { return }
    startDriftMonitor()
    let host = CMTime(seconds: CACurrentMediaTime() + 0.25, preferredTimescale: 1000)
    for state in slotStates.values where !state.ended && state.item.status == .readyToPlay {
        state.player.setRate(currentRate, time: state.player.currentTime(), atHostTime: host)
    }
    // Slots non prêts : rejoindront via handleStatusChange (readyToPlay).
    isPlaying = true
}
```

---

## MAJEURS (comportement incorrect)

### M1. `independentSlot` et `audioSlot` périmés après clear/reconfigure — réactivation silencieuse
**EngineAndSettings.swift:1365-1376 (`resetPlaybackState`), 1203-1215 (`teardownSlot`), 485-558 (`reconfigure`)**
`resetPlaybackState()` (appelé par `clear()` et par `reconfigure` quand `slotStates` devient vide) ne réinitialise ni `independentSlot` ni `audioSlot` ; `teardownSlot` non plus.
**Scénario 1** : mode indépendant sur le slot 2 → `clear()` → nouveaux fichiers → 2 vidéos (slots 0-1) : la timeline semble globale (timelineTime retombe sur leaderTime), puis l'utilisateur ajoute une 3ᵉ vidéo → le slot 2 réapparaît → le mode indépendant se réactive TOUT SEUL (scrubber/←/→ ne pilotent plus que ce bloc) sans action utilisateur.
**Scénario 2** : slot indépendant = 2, on retire le slot 0 (leader) pendant la lecture → `referenceSlot` migre vers 2 (= le slot indépendant) sans aucun événement de fin → le slot « indépendant » devient le référentiel global : `checkDrift` corrige les autres slots sur SA position (l'indépendance est annulée par la porte de derrière) et `setIndependentSlot` refuse désormais de le décrocher proprement (l. 1326 : `slot == referenceSlot` → nil — c'est le seul cas où ça se répare).
**Correction** :
```swift
// Dans teardownSlot, après slotStates.removeValue :
if independentSlot == slot { independentSlot = nil }
if audioSlot == slot { audioSlot = nil }

// Dans resetPlaybackState :
if independentSlot != nil { independentSlot = nil }
if audioSlot != nil { audioSlot = nil }

// Dans reconfigure, après le retrait (et après le calcul de referenceSlot) :
if let indep = independentSlot, indep == referenceSlot { independentSlot = nil }
```

### M2. `audioSlot` périmé → SILENCE TOTAL après retrait du slot audio
**EngineAndSettings.swift:518-522 (reconfigure 3bis) + 855-875 (`setAudioSlot`)**
`setAudioSlot(_ slot:)` avec `slot` non-nil fait `target = slot` ; si ce slot n'existe plus dans `slotStates`, `isAudio` est faux pour tous → **toutes les volumes passent à 0.0** (l. 866-870). Or `reconfigure` ré-applique `setAudioSlot(audioSlot)` à chaque reconfiguration (l. 520-522) même si `audioSlot` est périmé.
**Scénario** : clic sur le bloc C (audio + timeline sur le slot 2) → l'utilisateur vide le slot C (`VideoLibrary.clear(slot:)`) → `reconfigure` → `setAudioSlot(2)` → tous les `player.volume = 0` → plus AUCUN son (le leader reste « audible » dans l'UI via `isAudioSlot` mais volume 0), jusqu'à ce que l'utilisateur reclique un bloc. Idem si le slot audio est remplacé par échec puis vidé (`emptySlotAfterFailure`).
**Correction** : voir M1 (nil-ifier `audioSlot` dans `teardownSlot`). En complément, blindage dans `setAudioSlot` :
```swift
let target = (slot != nil && slotStates[slot!] != nil) ? slot : referenceSlot
```

### M3. Durée du référentiel jamais rafraîchie après remplacement du leader en place + branche de migration morte → scrubber à la mauvaise échelle et audio muet après fin du leader
**EngineAndSettings.swift:544-547 (reconfigure) et 1540-1549 (handleItemDidPlayToEnd)**
- `reconfigure` compare `referenceSlot != oldLeader` **par index**. Quand le leader est remplacé EN PLACE par l'auto-replace (même index 0, nouvel item), `referenceSlot == oldLeader == 0` → `refreshReferenceDuration()` non appelé → `leaderDuration` reste la durée de l'ANCIENNE vidéo → l'échelle du scrubber (`timelineDuration`/`endScrub`/`skip`) est fausse jusqu'à la prochaine migration.
- Dans `handleItemDidPlayToEnd`, le bloc `if slot == referenceSlot` (l. 1540) est **du code mort** : `state.ended = true` est posé à la l. 1502 AVANT, et `referenceSlot` (computed, l. 433-438) ignore les slots ended → `slot == referenceSlot` n'est jamais vrai. Conséquences : (a) la migration de durée ne se fait jamais quand autoReplace est désactivé (fin partielle) ; (b) le unmute du nouveau référentiel (W-D, l. 1545-1548) ne s'applique jamais → après la fin du leader (autoReplace off), le référentiel migré reste `muted` (seul le leader était audible) → **silence jusqu'au prochain clic utilisateur** ; avec autoReplace on, silence pendant toute la durée de chargement du remplacement.
**Correction** :
```swift
// handleItemDidPlayToEnd — capturer le référentiel AVANT de poser ended :
guard let slot = ..., let state = ... else { return }
let wasReference = (slot == referenceSlot)
state.ended = true
...
if wasReference {
    refreshReferenceDuration()
    if let newRef = referenceState, !newRef.userAdjustedMute, newRef.muted {
        newRef.muted = false
        newRef.player.isMuted = false
    }
}

// reconfigure — comparer l'ITEM du référentiel, pas l'index :
// (en tête de fonction) let oldRefItem = referenceState?.item
// (étape 5) if referenceState?.item !== oldRefItem { refreshReferenceDuration() }
```

### M4. `handleStatusChange` ré-aligne le slot INDÉPENDANT sur le référentiel — indépendance annulée en silence
**EngineAndSettings.swift:1467-1479**
Quand l'item du slot indépendant est remplacé à chaud (assign manuel d'une nouvelle vidéo sur le bloc ciblé pendant la lecture), `reconfigure` → `addSlot` (sans `joinNewSlot`) → l'item devient `.readyToPlay` → la branche « join à chaud » (l. 1469-1479) le **seeks sur la position du référentiel** et le re-ancré. Le slot reste marqué indépendant (bordure orange, scrubber ciblé) mais sa position vient d'être écrasée par celle du groupe — le mode indépendant est silencieusement détruit (le chemin autoReplace, lui, passe par `joinNewSlot`/`startFromZeroOnReady` et démarre à zéro, donc il n'est pas concerné).
**Correction** :
```swift
if startFromZeroOnReady.remove(slot) != nil || independentSlot == slot {
    // Nouveau contenu d'un slot indépendant : démarrage à zéro, comme l'autoReplace.
    scheduleSlotStart(slot)
} else if isPlaying, let reference = referenceState, !reference.ended {
    ...
}
```

### M5. `stop()` en mode indépendant ne rembobine que le slot ciblé + position fantôme (reprise proposée au lancement suivant)
**EngineAndSettings.swift:634-638**
```swift
func stop() {
    pause()                 // ← sauvegarde les positions de TOUS les slots (l. 610-615)
    seekAll(to: .zero)      // ← routé vers le slot indépendant uniquement (l. 1258-1263)
    driftText.removeAll()
}
```
**Scénario** : mode indépendant actif → « Arrêter » → seul le bloc ciblé revient à zéro ; les autres flux restent à leur position. Et comme `pause()` a persisté les positions AVANT le rewind, la prochaine ouverture de ces vidéos proposera « Reprendre » à l'ancienne position — alors que l'utilisateur a explicitement tout arrêté (position fantôme).
**Correction** :
```swift
func stop() {
    // « Arrêter » est une action GLOBALE : on sort du mode indépendant d'abord.
    setIndependentSlot(nil)
    pause()
    seekAll(to: .zero)
    // Rembobiner = repartir de zéro la prochaine fois : on oublie les positions.
    for state in slotStates.values {
        clearPosition(for: state.url)
    }
    driftText.removeAll()
}
```

### M6. Scrubber/label figés après un scrub EN PAUSE en mode indépendant
**EngineAndSettings.swift:1304-1318 (`seekSlot`) + ContentView.swift:3177, 3317-3323**
`syncScrub()` lit `engine.timelineTime` (computed → `state.item.currentTime()`), mais il n'est déclenché que par `.onChange(of: engine.leaderTime.seconds)`. En mode indépendant, `seekSlot` ne publie RIEN à la fin du seek (contrairement au mode global où `seekAll` publie `leaderTime = target`, l. 1264). Si la lecture est en pause : le seek aboutit, la vidéo est bien à la cible, mais `leaderTime` ne bouge plus (l'observateur périodique publie la même valeur, garde l. 1180) → l'UI reste affichée à l'ancienne position (slider ET label) indéfiniment. En lecture, ça se répare au tick suivant (0,1 s).
**Correction** — publier la position cible dans la complétion de `seekSlot` :
```swift
state.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
    DispatchQueue.main.async {
        guard let self, self.slotStates[slot]?.item === state.item else { return }
        if self.leaderTime != time { self.leaderTime = time }   // ← publie pour l'UI
        if self.isPlaying, state.item.status == .readyToPlay, !state.ended {
            let host = CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000)
            state.player.setRate(self.currentRate, time: state.item.currentTime(), atHostTime: host)
        }
    }
}
```
(Le tick suivant de l'observateur du leader republiera la vraie valeur du leader — pas d'effet de bord.)

### M7. `maxDriftMilliseconds` n'exclut pas le slot indépendant → badge Δ trompeur
**EngineAndSettings.swift:970-987** (boucle l. 975)
`checkDrift` et `checkFrozenSlots` excluent `independentSlot`, mais pas `maxDriftMilliseconds` : en mode indépendant, le mini-lecteur affiche « Δ 30000 ms » (l'écart volontaire du slot découplé) en permanence.
**Correction** :
```swift
for state in slotStates.values where state.slot != reference.slot
    && state.slot != independentSlot && !state.ended {
```

### M8. `acceptResumeOffer`/`declineResumeOffer` routés via `seekAll` → la reprise ne s'applique pas en mode indépendant
**EngineAndSettings.swift:935-947**
`seekAll` en mode indépendant ne seeke que le slot ciblé (l. 1258-1263). Scénario : mode indépendant actif (bloc C) → l'utilisateur assigne une vidéo (slot A) avec une position mémorisée → bandeau « Reprendre » → clic → seul le bloc C bouge ; la vidéo qu'on voulait reprendre reste à zéro. (`resync()` a bien le `setIndependentSlot(nil)` — la reprise devrait faire pareil.)
**Correction** :
```swift
func acceptResumeOffer() {
    guard let offer = resumeOffer else { return }
    setIndependentSlot(nil)   // la reprise est une action globale
    seekAll(to: CMTime(seconds: offer.position, preferredTimescale: 600))
    dismissResumeOffer()
}
// idem declineResumeOffer : setIndependentSlot(nil) avant clearPosition + seekAll(.zero)
```

### M9. `play()` — chemin de rembobinage sans watchdog : lecture définitivement bloquée si une complétion de seek ne revient pas
**EngineAndSettings.swift:578-599 + 573**
```swift
guard !slotStates.isEmpty, !isPlaying, !playRequestedWhileRewinding, ... else { return }
```
Si la complétion d'un `seek(to: .zero)` du rewind ne revient jamais (player remplacé/détruit en vol — `AVPlayer` ne garantit pas l'appel après `replaceCurrentItem(nil)`), `rewindPendingSlots` ne se vide jamais et `playRequestedWhileRewinding` reste `true` → **le bouton Lecture est mort pour la session** (garde l. 573). `seekAll` a son watchdog 2 s (l. 1276-1283), pas le rewind. En complément, `teardownSlot` n'appelle pas `cancelPendingPlaybackStart()` (seuls `reconfigure` l. 498 et `clear` via `resetPlaybackState` le font).
**Correction** :
```swift
// Dans play(), après la boucle de rewind :
let watchdog = DispatchWorkItem { [weak self] in
    DispatchQueue.main.async {
        guard let self, self.playRequestedWhileRewinding else { return }
        self.rewindPendingSlots.removeAll()
        self.playRequestedWhileRewinding = false
        self.startPlayback()   // désormais protégé (B3)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)

// Dans teardownSlot :
cancelPendingPlaybackStart()
```

---

## MINEURS (style, robustesse, perf)

- **EngineAndSettings.swift:806-808** (`skip(by:)` indépendant) : `state.item.duration` peut être `.indefinite` (durée non chargée) → pas de borne haute ; un skip au-delà de la fin est clampé par AVPlayer mais déclenche `didPlayToEnd` → autoReplace inattendu. Préférer `state.asset.load(.duration)` en fallback, ou accepter et documenter.
- **EngineAndSettings.swift:814** (`skip(by:)` global) : utilise `leaderDuration`, qui peut être périmée (M3) → borne haute fausse tant que M3 n'est pas corrigé.
- **EngineAndSettings.swift:1258-1263** (`seekAll` indépendant) : `completion?()` est appelé SYNCHRONE avant la fin du seek → `endScrub` relance `play()` avec l'ancienne position (`startPlayback` lit `currentTime()` pré-seek) → glitch ~0,25 s possible. Déférer la complétion dans la complétion de `seekSlot` (ajouter un paramètre `completion` à `seekSlot`).
- **EngineAndSettings.swift:1258** : la branche indépendante de `seekAll` ne vérifie pas `!state.ended` (contrairement à `skip`) → un scrub sur un slot indépendant terminé le réactive à la position cherchée. Incohérent ; ajouter la garde ou documenter.
- **EngineAndSettings.swift:1324-1333** : `setIndependentSlot` accepte un slot `ended` (incohérent avec `skip` qui le refuse) ; refuser les slots ended.
- **EngineAndSettings.swift:610-615** (`pause()`) : sauvegarde les positions de slots en plein seek (position pré-seek capturée) — décalage mineur de la reprise.
- **EngineAndSettings.swift:368-479** : `SyncEngine` repose sur `assert(Thread.isMainThread)` sans annotation `@MainActor` ; `deinit` non-isolé peut toucher `slotStates`/`pendingItems` hors main pendant qu'une méthode main les muté → race théorique. Annoter la classe `@MainActor` (les `Task { @MainActor }` internes restent valides).
- **EngineAndSettings.swift:1424-1430** (`checkDrift`) : `positions[...] = time.seconds` 1×/s + `schedulePositionsSave()` recréé 1×/s (churn de DispatchWorkItem) ; ne ré-armer le save que si une valeur a changé.
- **EngineAndSettings.swift:793-795** (`scheduleSlotStart`) : seek explicite suivi de `setRate(time: .zero)` — `setRate(time:)` implique déjà le seek ; redondant mais inoffensif.
- **EngineAndSettings.swift:1540-1549** : le commentaire W-D décrit le unmute du nouveau référentiel — le code est mort (M3) ; la correction M3 le rend vivant.
- **VideoLibrary.swift:551-554** (`playbackPosition`) : lit UserDefaults directement (2 s de retard sur le dict mémoire du moteur) — acceptable, mais le dossier intelligent « Reprendre » peut être à retardement.

---

## VÉRIFICATIONS POSITIVES (solide)

- **`seekAll` branche indépendante appelle bien `completion`** (l. 1261) ✓ (le trou redouté n'existe pas).
- **`seekSlot` re-ancrage bien gardé** : `isPlaying && readyToPlay && !ended` + vérification d'identité d'item (`slotStates[slot]?.item === state.item`) avant setRate (l. 1309-1315) ✓.
- **`checkDrift` (l. 1401) et `checkFrozenSlots` (l. 1094) excluent `independentSlot`** ✓.
- **`handleItemDidPlayToEnd` libère le mode indépendant** : slot indépendant terminé → nil (l. 1512-1514) ; migration du référentiel sur le slot indépendant → nil (l. 1518-1520) — les deux AVANT `onItemEnded` ✓.
- **`resync()` sort du mode indépendant** (l. 645) ✓.
- **Garde anti-spam @Published** : `leaderTime` (l. 1180), `driftText` (l. 1439-1446), `slotError` (l. 1083/1456/1483), `resumeOffer` (l. 925), `readyCount` (l. 1575), `independentSlot` (l. 1330), `audioSlot` (l. 872) — toutes gardées ✓. `positions` est un dict privé non publié ✓.
- **`scheduleFailedReplacement`** : re-vérifie slot existant + item toujours `.failed` après les 0,5 s (l. 1068-1069) ; anti-doublon `failedReplacementPending` ; annulé dans `teardownSlot` (l. 1209-1211) ✓. Le remplacement manuel entre-temps est couvert (nouvel item non `.failed` → garde) ✓.
- **Teardown complet** : KVO invalidé, notification retirée, timeObserver retiré, `pause()`, `replaceCurrentItem(nil)` (l. 1220-1238) ; `deinit` non-main dispatché proprement sans capture de self (l. 462-479) ✓.
- **Captures faibles partout** : timer dérive (l. 1382), KVO (l. 1166), notification fin (l. 1194), observateur périodique (l. 1178), Tasks (l. 1063, 1561), complétions de seek (l. 589, 1290, 1307) ✓.
- **`seekAll` watchdog 2 s** anti-complétion perdue (l. 1276-1283) + invalidation par génération (`seekGeneration`) ✓.
- **Cycle de vie du préchargement** : `consumePendingItem` vérifie l'URL (l. 1011-1018), `cancelPendingItem` dans `teardownSlot` (l. 1206), `preloadRequested` purgé dans addSlot/consume/cancel/teardown (l. 1016/1028/1144/1207), re-préchargement possible après consommation ✓.
- **Anti-rafale autoReplace** : 1 s + re-vérification `expectedID` et `engine.autoReplace` (VideoLibrary.swift:652-666) ✓ ; `emptySlotAfterFailure` + badge persistant (l. 702-707, ré-appliqué en reconfigure l. 537-541) ✓.
- **`refreshReferenceDuration`** : re-vérifie l'identité d'item avant de publier (l. 1567) ✓.
- **`pause()`** : sauvegarde uniquement des temps numériques finis > 0 (l. 610-615) ; `clearPosition` à la fin RÉELLE (l. 1509) ✓.
- **`timeString`** tolère les CMTime non numériques (« 0:00 », ContentView.swift:459-460) → pas de crash UI sur timelineTime invalide ✓.

---

## Synthèse

| Catégorie | Nombre |
|---|---|
| BLOCKERS | 3 |
| MAJEURS | 9 |
| MINEURS | 11 |

**Top 3 à corriger en priorité** :
1. **B1+B2+B3** (même famille) : tout `setRate(_:time:atHostTime:)` doit être gardé par `item.status == .readyToPlay` — 3 chemins non gardés (setRate, resync, startPlayback) → SIGABRT reproductible.
2. **M2+M3** : `audioSlot` périmé → silence total ; référentiel migré jamais démuté + durée jamais rafraîchie → scrubber faux et audio muet après fin du leader.
3. **M1** : `independentSlot`/`audioSlot` non réinitialisés à la destruction d'un slot → réactivation silencieuse du mode indépendant (ou du routage audio) sur réutilisation de l'index.
