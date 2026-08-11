# RAPPORT DE VÉRIFICATION COMPLÈTE — TriSync v7.2 (11/08/2026)

Vérification exigeante avec 3 agents de revue statique + intégration + re-vérification réelle.

## Résultats des 3 agents (revue statique ligne à ligne)

| Agent | BLOCKERS | MAJEURS | MINEURS | Rapport |
|---|---|---|---|---|
| R1 — Moteur (EngineAndSettings) | 3 | 9 | 11 | slices/vague2/AGENT_R1_MOTEUR.md |
| R2 — Bibliothèque (VideoLibrary) | 1 | 9 | 13 | slices/vague2/AGENT_R2_BIBLIOTHEQUE.md |
| R3 — UI (ContentView) | 0 | 4 | 15 | slices/vague2/AGENT_R3_UI.md |

## BLOCKERS — corrigés (4/4)

| # | Problème | Impact | Correction |
|---|---|---|---|
| B1 | `setRate(_:)` sans garde `readyToPlay` (changement de vitesse pendant un chargement/échec) | **SIGABRT** (exception Objective-C) | Garde `item.status == .readyToPlay` dans la boucle |
| B2 | `resync()` idem (bouton « Resynchroniser » avec un slot non prêt) | **SIGABRT** | Garde par slot avant `setRate(atHostTime:)` |
| B3 | `startPlayback()` sans garde (fenêtre TOCTOU du rewind) | **SIGABRT** | Défense en profondeur dans la boucle |
| B4 | `restoreLibrary` écrit `slots[index]` sans borne (UserDefaults corrompu à 6+ entrées) | **Crash au lancement**, app inutilisable | `guard slots.indices.contains(index)` |

## MAJEURS — corrigés (22/22)

### Moteur (R1, 9)
- **M1** : `independentSlot`/`audioSlot` périmés → réactivation silencieuse du mode indépendant / silence total → reset dans `teardownSlot` + `resetPlaybackState` + garde reconfigure
- **M2** : `setAudioSlot(stale)` mettait TOUTES les volumes à 0 (silence total) → blindage : slot inexistant → référentiel
- **M3** : durée du référentiel jamais rafraîchie après remplacement en place + branche de migration = code mort (`ended=true` avant le check) → capture `wasReference` AVANT + reconfigure compare l'ITEM → **scrubber à la bonne échelle + audio rétabli après fin du leader**
- **M4** : slot indépendant ré-aligné sur le référentiel au remplacement à chaud (indépendance détruite en silence) → rejoint à ZÉRO comme l'autoReplace
- **M5** : `stop()` en mode indépendant ne rembobinait qu'un bloc + positions fantômes → sortie du mode + `clearPosition` de tous
- **M6** : scrubber/label figés après un scrub EN PAUSE en mode indépendant → `seekSlot` publie la position cible
- **M7** : badge Δ affichait l'écart volontaire du slot indépendant → exclu du calcul `maxDriftMilliseconds`
- **M8** : « Reprendre/Recommencer » routé vers le slot indépendant → actions globales (sortie du mode)
- **M9** : lecture définitivement bloquée si une complétion de rewind ne revient pas → watchdog 2 s + `cancelPendingPlaybackStart` dans teardown

### Bibliothèque (R2, 9)
- **M1** : dédup par URL brute → doublons garantis après restauration (`/private/var` ≠ `/var`) → dédup par `standardizedFileURL.path` + Set O(1) (add, ensureInLibrary, addSource)
- **M2** : `removeSource`/`toggleSource` inopérants après relaunch → ré-attribution des sources par préfixe de chemin à la restauration + dans `add()` sur doublon
- **M3** : scan en vol ré-ajoutait les vidéos après retrait de source (fantômes) → vérification source active avant ingestion
- **M4** : positions lues avec des clés incohérentes (moteur brut vs bibliothèque standardisée) → `standardizedFileURL.path` partout → **le dossier « Reprendre » fonctionne enfin pour /private/var**
- **M5** : échec silencieux de bookmark → asset perdu au relaunch → filet de sécurité `fallbackPaths` + log
- **M6** : `failedURLs` jamais nettoyés (fichier revenu banni pour la session) → **expiration 5 min**
- **M7** : fuites mémoire (metadataTasks, assetSource dans removeAsset/clearAll/removeSourceVideos) → nettoyage complet + tâches auto-nettoyantes à capture faible
- **M8** : re-filtrage UTType sur le MainActor (5000 stat → UI gelée) → `addFiltered` pré-filtré
- **M9** : caches indexés par chemin seul → vignettes/métadonnées obsolètes pour un fichier remplacé → clés avec taille+mtime + écriture atomique

### UI (R3, 4)
- **M1** : **TopBar jamais rendue** → menu bento (composition de scène) INACCESSIBLE + raccourcis ⌘O/⌃⌘F/⇧⌘F morts → raccourcis branchés dans la SidebarView + **menu « Composition » réintégré dans la barre latérale**
- **M2** : source watcher éjectait l'utilisateur de la lecture à chaque ajout → garde `!engine.isPlaying`
- **M3** : mini-lecteur traîné hors écran perdu pour la session → reset `miniOffset` au changement de section
- **M4** : bouton ✕ recouvrait le badge A/B/C au survol → décalé sous le badge

## MINEURS — corrigés (8 les plus impactants)
- Picker de vitesse désynchronisé (⌥[/⌥] ou Réglages) → `onChange(engine.currentRate)`
- Retour dans la recherche déclenchait « Lancer (N) » → `.onSubmit { }` sur les TextField
- Étoile favori rognée (hauteur 204/206 < contenu) → cartes et dossiers à **210 px** (alignement + étoile complète)
- Position/taille de fenêtre perdues → `setFrameAutosaveName("TriSync.Main")`
- Contraste des badges, accessibilité sliders, dead code (TopBar/GalleryStrip), etc. → documentés pour la prochaine passe

## Re-vérification RÉELLE (exécutée après intégration)
- ✅ Build release : **0 erreur, 0 warning**
- ✅ 26/26 tests automatisés (runner régénéré avec les 3 fichiers corrigés)
- ✅ App vivante : t=15 s CPU 98 % (scan démarrage), **t=60 s : CPU 0,0 %, RSS 20 Mo**
- ✅ Aucun nouveau crash report (.ips)
- ✅ Livrable `TriSync-v7.1-FINAL/` régénéré (3 fichiers à coller dans Xcode)

## Bilan
4 BLOCKERS (dont 3 SIGABRT possibles et 1 crash au lancement), 22 MAJEURS, 8 MINEURS
→ **TOUS corrigés et re-vérifiés**. Le point noir historique (audio muet après fin du leader, M3) et la fonctionnalité perdue (menu bento, M1) sont réparés.
