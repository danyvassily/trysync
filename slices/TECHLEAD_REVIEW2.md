# TECH LEAD — Revue Round 2 (ContentView.swift, TriSync)

**Fichier revu** : `TriSyncPkg/Sources/TriSync/ContentView.swift` (1782 lignes, fusion System/SyncEngine/UI)
**Build** : exit 0 annoncé par l'équipe — non re-vérifié ici (licence Xcode non acceptée dans l'environnement d'exécution).
**Périmètre** : vérification B1/B2/B3 + W1–W10, recherche de régressions, nouveaux verdict.

---

## 1) VERDICT GLOBAL : **15,5 / 20**

Les trois BLOCKERS du round 1 sont corrigés de façon substantielle et correcte dans les chemins principaux ; les 10 warnings sont traités. Le concept de slot référentiel (B3) est proprement implémenté (observateur de temps, dérive, resync, durée). Il reste **aucun BLOCKER**, mais **7 warnings**, dont un sérieux : une résurgence partielle du B3 dans un cas limite (fin de lecture + pause simultanées → mauvaise durée au scrubber), et une incohérence B2 (rattrapage vers le *leader*, pas le *référentiel*). Aucune régression bloquante. Progression : 13 → 15,5.

---

## 2) BLOCKERS restants

**Aucun.**

---

## 3) WARNINGS restants

### W-A (sérieux) — Migration de durée manquante si la notification de fin arrive pendant `isPlaying == false` — l. 898
`handleItemDidPlayToEnd` ne déclenche `refreshReferenceDuration()` que si `isPlaying` est vrai. Si l'utilisateur clique **pause** dans la fenêtre (~100 ms) où l'item du référentiel atteint sa fin, la notification arrive après `pause()` → `ended = true`, migration du référentiel vers le premier slot non terminé, mais `leaderDuration` **garde la durée de l'ancien référentiel**. Le time observer du nouveau référentiel publie `leaderTime` (ex. 57 s) sur une durée erronée (60 s au lieu de 120 s) → scrubber à ~95 % et échelle fausse ; pire, `endScrub` (l. 600-602) convertira la fraction avec la mauvaise durée → positions réellement fausses pour les autres slots. C'est une résurgence en cas limite du B3 d'origine.
**Correctif** : retirer la condition `isPlaying` (l. 898) et recharger la durée dès que `slot == referenceSlot` (le `refreshReferenceDuration` est déjà idempotent et vérifie l'identité de l'item, l. 918) ; ou détecter le changement de `referenceSlot` dans le time observer.

### W-B — `handleStatusChange` rattrape vers le **leader**, pas le **référentiel** — l. 863-864
Le code cherche vers `leaderState` (`!leader.ended`) alors que l'énoncé B2 dit « temps du référentiel ». Conséquence concrète : en fin partielle (leader terminé, référentiel = slot 1), un slot ajouté pendant la lecture ne rejoint **pas** via B2 ; il reste en pause jusqu'au prochain tick du moniteur de dérive (≤ 1 s) qui le démarre via `setRate` (l. 827). Comportement final correct, latence acceptable, mais incohérence code/énoncé et dépendance cachée à checkDrift.
**Correctif** : `if isPlaying, let reference = referenceState, !reference.ended` + `target = reference.item.currentTime()`.

### W-C — Badge « MAÎTRE » et drift résiduel après migration — l. 1598-1600, 1634-1637
Le badge reste affiché sur le slot leader (index min) même quand celui-ci est terminé et que le temps/scrubber suivent un autre slot (référentiel). L'utilisateur voit « MAÎTRE » sur une vidéo figée à la fin pendant que le compteur suit une autre vidéo. Idem : `driftText[slot]` des slots `ended` n'est jamais purgé (checkDrift les ignore, l. 819) → un « Δ xx ms » peut rester affiché sur un slot terminé.
**Correctif** : baser le badge sur `engine.referenceSlot` (à exposer) et purger `driftText` pour les slots `ended` dans `handleItemDidPlayToEnd`.

### W-D — Fin du leader → silence total (mute non migré) — l. 451-458, 885-901
Quand le leader se termine naturellement, les autres slots (muets par défaut, « seul le leader est audible ») continuent de jouer **en silence** : aucun transfert du son vers le nouveau référentiel. (Noter que le son est correctement transféré si le leader est *retiré* : reconfigure étape 3 le ré-audibilise.) UX discutable, à trancher produit.
**Correctif** : à la migration, si le nouveau référentiel n'a pas de `userAdjustedMute`, l'audibiliser et rendre l'ancien muet.

### W-E — Watchdog de 2 s dans `seekAll` : double appel exclu, mais tir prématuré possible — l. 751-761
Vérification anti-double-appel : **propre** — le watchdog garde `remaining > 0` puis force `remaining = 0` ; les complétions tardives de même génération font passer `remaining` à −1 sans jamais rappeler `completion` (l. 770-775). Aucun data race (tout est rapatrié sur le main). Reste : sur fichiers 4K/HDD lents, un seek > 2 s fait démarrer la lecture (`play()` de `endScrub`, l. 605-608) sur des positions intermédiaires → désynchro temporaire que checkDrift corrige. Bénin, mais le seuil est serré.
**Correctif** (optionnel) : passer le watchdog à 4-5 s ou le faire déclencher un `resync()` au lieu de la complétion.

### W-F — `resync()` publie le drift avant l'effet du ré-ancrage — l. 568
`publishDrift` est appelé juste après `setRate(…atHostTime:)`, or le repositionnement est asynchrone (tick hôte +0,1 s) : `currentTime()` n'a pas encore bougé → la valeur publiée reflète le décalage pré-correction, affichée ~1 s avant que checkDrift ne la remplace. Cosmétique.

### W-G — `startPlayback` relance les slots `ended` dans le chemin reconfigure — l. 478-483, 729-737
Si `isPlaying` avec un slot `ended` (fin partielle) et qu'une reconfiguration sans retrait survient (ré-assignation d'un asset identique), `startPlayback()` fait `setRate` sur le slot terminé → re-déclenche la notification de fin (boucle `ended = true` inoffensive) et `play()` ne rewind pas dans ce chemin. Bénin (pas de blocage), mais fragile : `startPlayback` devrait ignorer les slots `ended` ou passer par `play()`.

---

## 4) RÉGRESSIONS détectées

**Aucune régression bloquante.** Vérifications ciblées demandées :

- **startPlayback vs slots `ended`** : dans le chemin `play()` normal, les slots terminés sont d'abord rewound (`toRewind`, l. 499-520) donc `startPlayback` ne les voit pas ; seul le chemin `reconfigure` étape 6 peut le faire (W-G, bénin). Pas de gel possible.
- **Migration leader retiré/reconfiguré** : retrait du leader → `removed` → `cancelPendingPlaybackStart` + teardown (l. 439-443), nouveau `referenceSlot` ≠ `oldLeader` → `refreshReferenceDuration` (l. 471-473). Tous les cas de figure analysés (retrait leader, retrait référentiel non-leader, ajout, remplacement) rafraîchissent correctement la durée. L'étape 5 est robuste.
- **Watchdog double completion** : impossible (cf. W-E).
- **metadataTasks @MainActor-safe** : oui — `VideoLibrary` est `@MainActor`, les tâches sont créées en `Task { @MainActor in … }`, et `add(urls:)` s'exécute de bout en bout sur le main thread (aucune fenêtre entre création et enregistrement de la tâche, l. 136-142). Annulation dans `clearAll` (l. 101-102) et `removeAsset` (l. 119-120). ✓
- **Seek B2 vs seekAll : générations partagées** — l'incrément de `seekGeneration` dans `handleStatusChange` (l. 865) invalide proprement les seeks concurrents dans les deux sens ; aucun setRate orphelin (guard `isPlaying` + génération, l. 869). ✓
- **Fin partielle + pause** : `pause()` → les slots terminés restent `ended` ; `play()` les rewind (l. 499-503) → retour cohérent au début. ✓
- **Retrait d'un slot pendant un seek en vol** : la complétion de `endScrub` peut être perdue (l'app reste en pause) — comportement bénin, l'utilisateur reclique lecture. ✓

---

## 5) POINTS FORTS

- **B1 réellement corrigé** : checkDrift est gardé par `isPlaying` + référentiel vivant + `readyToPlay` (l. 814-815), et `publishDrift` filtre les non-finis (l. 833-834). Plus aucun dérive sur état mort.
- **B3 bien conçu** : `referenceSlot` (l. 382-387) avec migration dans `handleItemDidPlayToEnd` (l. 885-901), observateur de temps filtré (l. 678-681), `refreshReferenceDuration` idempotent avec garde d'identité d'item (l. 918). Le scrubber reste vivant en fin partielle — le bug central du round 1 est traité dans le chemin nominal.
- **W2 excellent** : watchdog avec garde anti-double-appel par `remaining` + génération ; aucune complétion dupliquée possible (démontré par analyse d'entrelacement).
- **W4 propre** : start/stop `SecurityScopedResource` équilibrés via `defer` dans `loadMetadata` (l. 203-208), retiré d'`openVideosPanel` avec commentaire explicatif (l. 251-254).
- **W8 exemplaire** : tâches de métadonnées traquées, annulées aux deux points de suppression, publication conditionnelle à `!Task.isCancelled` (l. 138).
- **W7 conforme à la règle perf** : infoBar opaque `black 0.55` (l. 1629), dégradé simple (non-material) au-dessus de la vidéo (l. 1575-1580).
- Nettoyage systématique des états publiés orphelins dans `reconfigure` (l. 461-467), `deinit` sûr hors main thread (l. 409-421).

---

## Synthèse pour l'équipe

Corriger en priorité **W-A** (retirer `isPlaying` de la condition l. 898) et **W-B** (utiliser `referenceState` l. 863) : ce sont deux petits changements qui referment les dernières failles du référentiel. W-C/W-D sont des décisions UX. Le reste est cosmétique. Le moteur est maintenant sain sur les chemins principaux ; un test manuel ciblé « fin partielle avec pause au moment exact de la fin » est recommandé avant release.
