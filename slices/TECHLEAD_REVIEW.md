# Revue de code TECH LEAD — TriSync `ContentView.swift`

**Fichier revu** : `TriSyncPkg/Sources/TriSync/ContentView.swift` (1702 lignes, fusion des agents Système / AVFoundation / SwiftUI)
**Contexte** : vidéothèque macOS 14+, jusqu'à 3 AVPlayer synchronisés à la trame près (M3 / VideoToolbox), Swift 5, build OK, lancement sans crash.
**Date** : revue statique exhaustive, ligne par ligne (fuites, perf M3, synchro, concurrence, edge cases, UI).

---

## 1. VERDICT GLOBAL

**Note : 13/20 — « Compile, tourne, mais la synchro a trois défauts fonctionnels qui se déclenchent exactement dans les scénarios d'usage réel. »**

Le code est propre, discipliné (asserts main thread, `[weak self]` systématique, teardown complet des slots, hystérésis de publication). Aucune fuite mémoire majeure n'a été trouvée : le cycle de vie AVPlayer/AVPlayerItem/observers est correctement géré. La technique d'ancrage hôte (`masterClock` + `setRate(_:time:atHostTime:)` sur cible commune) est la bonne et est correctement implémentée.

Mais **3 BLOCKERS** cassent des promesses du produit (« parfaitement synchronisé ») dans des cas quotidiens : échec d'un fichier en cours de lecture, ajout d'une vidéo pendant la lecture, fin de lecture partielle. Le moniteur de dérive — pièce maîtresse — a des trous dans ses gardes. Aucun de ces bugs ne crashe ; tous dégradent la synchro ou l'état affiché.

| Domaine | Verdict |
|---|---|
| Fuites mémoire | ✅ RAS majeur — teardown méthodique |
| Perf M3 | ✅ Décodage matériel préservé ; 1 warning material |
| Synchronisation | ❌ 3 BLOCKERS (gardes du moniteur, join à chaud, fin partielle) |
| Concurrence | ⚠️ OK sur le fond ; races de complétion de seek non couvertes |
| Edge cases | ⚠️ Couverts ~70 % ; doublon d'assignation, slot failed ré-assigné |
| UI/UX | ⚠️ Fonctionnelle ; état mensonger en fin partielle, accessibilité minimale |

---

## 2. BLOCKERS (à corriger avant release)

### B1 — `checkDrift` ne vérifie jamais le statut du leader → rembobinage brutal ou moniteur muet
**Lignes** : 767–783 (guard ligne 768)
**Problème** : `guard isPlaying, let leader = leaderState, !leader.ended` — le statut `.failed` du leader n'est pas contrôlé. Si l'item du leader passe `.failed` en cours de lecture (fichier supprimé du disque, erreur de décodage, disque retiré — scénarios réels avec des fichiers locaux), `leader.item.currentTime()` renvoie un temps invalide (NaN) ou `.zero` selon l'implémentation AVFoundation :
- temps `.zero` → `delta = 0 - otherCurrent`, `|Δ| > 0.05` dès que la vidéo a avancé → **tous les slots sains sont ré-ancrés vers t=0** : rembobinage brutal de la lecture en cours ;
- temps invalide → delta NaN → aucune correction, moniteur muet silencieusement.
Les slots non-leaders, eux, sont correctement protégés par `state.item.status == .readyToPlay` (l. 772) : la protection existe, elle est juste oubliée pour le leader.
**Impact** : pendant un échec, l'utilisateur voit ses vidéos se rembobiner ou la synchro se figer sans aucun message (le `slotError` est publié mais le moniteur continue de tourner avec des données invalides).
**Correctif** :
```swift
guard isPlaying, let leader = leaderState, !leader.ended,
      leader.item.status == .readyToPlay else { return }
```
Et dans `publishDrift` (l. 786), ignorer les deltas non finis : `guard deltaSeconds.isFinite else { return }`.

### B2 — Un slot ajouté pendant la lecture ne démarre jamais immédiatement (gel ~1 s, ou jamais si le leader se termine)
**Lignes** : 444–452 (reconfigure), 803–818 (`handleStatusChange`), 767–783 (`checkDrift`)
**Problème** : quand un slot est ajouté pendant `isPlaying`, `addSlot` le crée à rate 0 (`playImmediately(atRate: 0)`, l. 625). Le passage `.readyToPlay` (KVO → `handleStatusChange`) ne fait que `updateReadyCount()` : **rien ne donne un taux > 0 au nouveau player**. Le seul chemin de démarrage est le moniteur de dérive, qui n'applique `setRate` que si `|Δ| > 50 ms` (l. 775) :
- cas courant : gel sur l'image 0 pendant 0 à ~1 s (jusqu'au prochain tick où Δ dépasse 50 ms) — inacceptable pour un outil promettant une synchro à la trame près ;
- cas bloquant : si le leader se termine avant que Δ ne dépasse le seuil (vidéo courte, ou ajout en fin de lecture), `guard !leader.ended` (l. 768) coupe le moniteur → **le nouveau slot reste noir/figé indéfiniment** jusqu'à la prochaine pause+lecture manuelle.
**Impact** : le scénario « je regarde deux vidéos, j'en ajoute une troisième » produit un panneau noir pendant ~1 s, ou définitivement, sans aucune indication.
**Correctif** : dans `handleStatusChange`, cas `.readyToPlay` :
```swift
if isPlaying, state.player.rate == 0, let leaderTime = leaderState?.item.currentTime() {
    state.player.setRate(currentRate, time: leaderTime,
                         atHostTime: CMTime(seconds: CACurrentMediaTime() + 0.1, preferredTimescale: 1000))
}
```
(ou `startPlayback()` si tous les slots sont prêts).

### B3 — Fin de lecture partielle : leader terminé → scrubber et compteur gelés, dérive non corrigée
**Lignes** : 820–828 (`handleItemDidPlayToEnd`) + 767–768 (moniteur)
**Problème** : quand un slot non-leader continue de jouer alors que le leader a atteint sa fin (durées différentes — cas le plus courant avec 3 vidéos), `state.ended = true` pour le leader, mais `isPlaying` reste `true`, le time observer du leader ne ticke plus (timebase arrêté) et le moniteur de dérive sort via `guard !leader.ended` :
- le scrubber reste bloqué à 100 % et le compteur `timeLabel` figé, **pendant que les autres vidéos continuent** (potentiellement plusieurs minutes si les durées diffèrent beaucoup) — l'état affiché est mensonger ;
- plus aucune correction de dérive pour les slots restants, qui peuvent diverger librement jusqu'à leur propre fin.
**Impact** : état UI faux + dérive non maîtrisée exactement dans le scénario « fin de lecture partielle » listé dans les exigences.
**Correctif** : à la fin du leader, migrer la publication du temps vers un slot non terminé (par ex. `leaderSlot` → prochain slot `!ended`, ou garder le temps figé mais afficher un badge « Leader terminé » + re-migrer `checkDrift` sur un autre référence) ; au minimum : si `leader.ended` et qu'il reste des slots actifs, choisir un nouveau référentiel de temps/de dérive parmi les slots non terminés.

---

## 3. WARNINGS (à traiter en itération 2)

### W1 — `play()` ré-entrant pendant le rembobinage différé → départ à la fin de la vidéo
**Lignes** : 461–489. Double-clic sur Lecture pendant un rewind : `state.ended` a déjà été mis à `false` → `toRewind` vide au 2ᵉ appel → `startPlayback()` immédiat pendant que les seeks vers 0 sont en vol → les players partent de la **fin**, re-terminent instantanément (pause), puis la complétion du seek relance un `startPlayback()` parasite. **Correctif** : `guard !playRequestedWhileRewinding` en tête de `play()`.

### W2 — `seekAll` : complétion jamais appelée si le player est détruit en vol → reprise de scrub perdue
**Lignes** : 705–732. Si un slot est retiré (`teardownSlot` → player libéré) pendant qu'un `seek` est en vol, la complétion de seek n'est jamais invoquée (comportement AVPlayer connu) → `remaining` ne passe jamais à 0 → la `completion` (reprise de lecture après scrub, l. 569–572) n'est jamais appelée : l'app reste en pause sans raison. **Correctif** : watchdog (`DispatchWorkItem` de secours ~2 s) ou décrément de `remaining` dans `teardownSlot`.

### W3 — `resync()` ne protège pas contre un leader `.failed` (ou pas prêt)
**Lignes** : 517–535. Même trou que B1 : `guard let leader = leaderState, !leader.ended` sans vérification du statut. Avec un leader en échec, le bouton « Resynchroniser » cherche tous les slots vers `currentTime()` du leader (invalide/.zero). **Correctif** : ajouter `leader.item.status == .readyToPlay` au guard.

### W4 — `startAccessingSecurityScopedResource` déséquilibré (leak d'extensions sandbox)
**Lignes** : 236–241 (panel) vs 186–193 (loadMetadata). Le panel fait `start` sur **tous** les URLs sélectionnés ; le `stop` n'a lieu que dans `loadMetadata` des fichiers réellement ingérés. Les fichiers filtrés par `videoFiles` (non-vidéos) et les doublons (dédupliqués l. 120) reçoivent un `start` jamais équilibré. Aujourd'hui no-op hors sandbox (Package.swift sans entitlements), mais ce sera un vrai leak d'extensions le jour où l'app sera embarquée sandboxée. **Correctif** : ne faire le `startAccessing` que dans `loadMetadata` (l'accès session est déjà accordé par NSOpenPanel) ou équilibrer dans `add(urls:)`.

### W5 — `assign()` permet le même asset dans deux slots (doublon)
**Lignes** : 102–106 + 1224. Cliquer le chip d'un asset déjà en slot A alors que B est sélectionné duplique l'asset en B : deux players sur le même fichier, `slotLetter` n'affiche que A, `removeAsset` retire les deux d'un coup. **Correctif** : si l'asset est déjà dans un slot, le déplacer (`slots[old] = nil`) au lieu de dupliquer.

### W6 — `reconfigure` conserve un slot dont l'item est `.failed` si l'URL est inchangée
**Lignes** : 404–407. Ré-assigner le même fichier sur un slot en échec ne recrée pas le player (diff sur URL seulement) → l'erreur persiste, `isReadyToPlayAll` reste faux, Lecture bloquée. **Correctif** : inclure `slotStates[slot]?.item.status == .failed` dans la condition de remplacement.

### W7 — Material `.ultraThinMaterial` au-dessus du flux vidéo (infoBar)
**Lignes** : 1550–1553. La barre d'infos par panneau pose un blur au-dessus de l'AVPlayerLayer : composition GPU par frame sur la zone. Surface petite et statique, le M3 encaisse, mais c'est une entorse à la règle maison « aucun material au-dessus des vidéos » et ça s'aggrave si la barre grandit. **Correctif** : fond opaque semi-transparent (comme l'emptyPane, l. 1629) ou material une seule fois, mis en cache.

### W8 — Tasks de `loadMetadata` non stockées / non annulables
**Lignes** : 124–127. `Task { @MainActor … }` sans référence : un « Tout effacer » pendant l'ingestion laisse les tâches finir (miniatures générées pour des assets orphelins, `objectWillChange.send()` inutile). Avec 50 fichiers déposés, 50 tâches concurrentes de thumbnail. **Correctif** : stocker les Tasks (dict par asset) et `cancel()` dans `clearAll`/`removeAsset`.

### W9 — `refreshLeaderDuration` : Task capture `self` fortement
**Lignes** : 839–847. Sans conséquence aujourd'hui (le moteur vit aussi longtemps que l'app via `VideoLibrary`), mais si le cycle de vie change, la Task retiendra le moteur jusqu'à la fin du `load(.duration)`. **Correctif** : `Task { [weak self] @MainActor in … }`.

### W10 — Divers mineurs
- **L. 463** : `guard … currentRate > 0` rend `play()` définitivement inerte si `currentRate == 0` (atteignable via `setRate(0)` l. 541–544) ; l'UI ne peut pas produire 0 aujourd'hui, piège pour demain. Remettre le taux à 1.0 dans `pause()` si `rate == 0`.
- **L. 258–270 + 980–982** : `WindowAccessor` re-dispatche sur main à chaque `updateNSView` ; trivial, mais filtrer si `window?.isMovableByWindowBackground == true` évite le bruit.
- **L. 641–645** : le time observer (10 Hz) est enregistré sur les 3 players ; 2 d'entre eux ne font qu'un guard raté à chaque tick. Négligeable, mais on peut n'observer que le leader et ré-enregistrer au changement.
- **Accessibilité** : icônes-only avec `.help` mais sans `accessibilityLabel`/`accessibilityHint` ; les sliders n'ont pas de label VoiceOver. Correctifs en 5 minutes.

---

## 4. POINTS FORTS (pour être honnête)

1. **Cycle de vie AV irréprochable** : `teardown` (l. 669–687) invalide la KVO, retire le NotificationCenter observer, retire le time observer, `pause()` puis `replaceCurrentItem(with: nil)` — les sessions VideoToolbox sont réellement rendues. Aucune fuite AVPlayer/AVPlayerItem/AVAsset trouvée, `[weak self]` partout, timer invalidé dans `pause()` et `deinit`, `deinit` thread-safe (dispatch main).
2. **Anchrage hôte correct** : `masterClock = CMClockGetHostTimeClock()` posé **avant** toute lecture (l. 621), `setRate(_:time:atHostTime:)` avec la même cible `CACurrentMediaTime() + 0.25` et `time: currentTime()` propre à chaque item (l. 696–699), timebase cohérente (CACurrentMediaTime et horloge hôte = mach). C'est exactement la technique préconisée par Apple.
3. **Anti-races bien pensées** : compteur de génération des seeks (l. 353, 707–708, 724), `cancelPendingPlaybackStart()` systématique (pause/reconfigure/reset), rembobinage différé via complétions, signe du delta correct (`leader - other`, l. 774).
4. **Pas de spam `@Published`** : hystérésis de publication de la dérive (5/10 ms, l. 785–799), comparaison avant affectation (`readyCount`, `driftText`), seuls `leaderTime` ticke à 10 Hz (nécessaire pour le scrubber).
5. **Perf M3 préservée** : aucun `videoComposition`, AVPlayerLayer en layer-hosting direct avec `didSet` anti-no-op (l. 888–893), `automaticallyWaitsToMinimizeStalling = false` + buffer 2 s (source locale), pré-chauffage `playImmediately(atRate: 0)`, thumbnails limités à 640×360, materials uniquement sur le chrome (sauf W7).
6. **Edge cases bien couverts** : gate `readyToPlay` avant play (l. 463), `canPlay` côté UI, erreurs publiées par slot, dédupe à l'ingestion (l. 120), filtrage des dossiers et non-vidéos au drop, ré-ancrage sans saut d'image, slots terminés ignorés par le moniteur, rewind au replay, `stop()` propre, layout 1/2/3 réactif, fenêtre draggable avec `hiddenTitleBar`.

---

*Revue statique exhaustive — 1702 lignes lues intégralement, aucune conclusion sans vérification dans le code. Les numéros de ligne correspondent au fichier fusionné actuel.*
