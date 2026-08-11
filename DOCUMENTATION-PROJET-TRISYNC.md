# 🎬 TriSync — Vidéothèque macOS à lecture synchronisée
### Documentation complète du projet : historique, problèmes résolus, architecture

> **Version actuelle : v7.2** — macOS 14+, Apple Silicon (M3), SwiftUI + AVFoundation
> Dernière mise à jour : 11/08/2026

---

## 1. Le projet en une phrase

**TriSync** est une vidéothèque macOS de type Infuse permettant de sélectionner **jusqu'à 5 vidéos** (par ⌘+clic) et de les lire **parfaitement synchronisées** en split-screen, avec des dizaines de fonctionnalités de confort (files de lecture, reprise, timeline indépendante, maître choisi, layout libre…).

### Ce que souhaitait Dany (demandes au fil du temps)

| # | Demande | Statut |
|---|---|---|
| 1 | Application macOS prête pour Xcode : bibliothèque + lecture de 3 vidéos en split-screen synchronisées | ✅ v1 |
| 2 | Vidéos portrait/paysage **sans barres noires**, remplissage total du bloc | ✅ v2 |
| 3 | Grille de vignettes type **Infuse** (screenshots), ajout sans lancement auto | ✅ v3 |
| 4 | Jusqu'à **5 vidéos** synchronisées (slots A–E), sélection ⌘+clic | ✅ v4 |
| 5 | **Réglages** : ratio, cadrage, décalage, échelle | ✅ v5 |
| 6 | Zoom/pan au clavier + souris, plein écran, mode immersif | ✅ v5 |
| 7 | **Multi-sources** (Mac + disque externe, bookmarks) | ✅ v6 |
| 8 | Navigation dossiers + grille complète + favoris | ✅ v6 |
| 9 | **Analyse complète + tests** (objectif 9,8/10) | ✅ 9,8/10, 22 tests |
| 10 | 13 features : préchargement, files de lecture, reprise, clic=son, capture PNG, mini-lecteur, recherche/tri, dossiers intelligents, détection auto, drag&drop, .failed, anti-rafale, watchdog | ✅ v7.0 |
| 11 | **Timeline indépendante** : avancer UNE vidéo sans toucher les autres | ✅ v7.1 |
| 12 | **Choisir le maître** : auto / manuel / aucun | ✅ v7.2 |
| 13 | **Redimensionner les blocs** à la souris + clavier (layout Libre) | ✅ v7.2 |
| 14 | Logo + icône de l'application | ✅ v7.2 |
| 15 | Vérification complète « exigeante avec les agents » + corrections | ✅ 4+22+8 corrigés |
| 16 | Découpage du code en modules, iCloud, multi-écran, XCTest (quand licence Xcode) | ✅ sauf XCTest |

---

## 2. Architecture

### Fichiers (découpés en 3 modules — v7.1)

| Fichier | Rôle | ~Lignes |
|---|---|---|
| `ContentView.swift` | UI complète (scène, transport, bibliothèque, réglages, mini-lecteur) + App | 4 100 |
| `VideoLibrary.swift` | Bibliothèque : assets, slots, sources/bookmarks, caches, files, autoReplace, watcher | 870 |
| `EngineAndSettings.swift` | SyncEngine (cœur), AppSettings, WindowController, fenêtre | 1 760 |

### Le cœur : SyncEngine (synchronisation à la trame près)

- **`AVPlayer.setRate(_:time:atHostTime:)`** : tous les players démarrent/se re-posent sur la **même cible d'horloge hôte future** (`CMClockGetHostTimeClock`, `CACurrentMediaTime() + 0,25 s`)
- **Moniteur de dérive** (1 s, seuil 50 ms) : re-ancre les flux déviants sur le référentiel
- **Watchdog** (3 s) : détecte et relance un slot figé
- **Référentiel migrable** : si le maître se termine, la timeline migre vers le premier slot actif
- **5 slots** : mute par défaut (seul le référentiel est audible), remplacement auto en fin de lecture

### Le découpage en modules

Le fichier monolithique (6 100 lignes) a été découpé en 3 fichiers **mécaniquement** (types contigus, aucune extension top-level, accolades vérifiées par script). Deux pièges corrigés au build :
1. **Imports manquants** dans les fichiers extraits (SwiftUI/AVFoundation/Combine/…) — cause des 436 erreurs initiales
2. **Globales `private` → internal** (`accent`, `slotLetters`) : les globales `private` au niveau fichier ne sont pas visibles cross-fichier

---

## 3. Les problèmes rencontrés et comment ils ont été résolus

### 🔴 Crashs (tous résolus et testés)

| Version | Problème | Cause | Solution |
|---|---|---|---|
| v6.3 | Crash au lancement | `EnvironmentObject` manquant dans une vue conditionnelle | Injection **racine** dans TriSyncApp |
| v6.4 | **SIGABRT** pendant lecture | `AVPlayer.setRate(_:time:atHostTime:)` appelé sur un item **non prêt** (exception Objective-C) | v6.5 : **démarrage différé** — attente `.readyToPlay`, puis départ à zéro ancré horloge hôte ; gardes dans TOUS les chemins (`setRate`, `resync`, `startPlayback`) |
| v7.0 | Crash mini-lecteur | `miniPlayerView` rendu sans `SyncEngine` injecté (les `.sheet`/vues conditionnelles n'héritent pas des injections secondaires) | Injection racine réappliquée (leçon v6.3) |
| Audit | 3 SIGABRT potentiels (B1/B2/B3) | Mêmes gardes manquantes dans `setRate(_:)`, `resync()`, `startPlayback()` | Gardes `readyToPlay` systématiques par slot |
| Audit | Crash au lancement (B4) | `restoreLibrary` écrivait `slots[index]` sans borne (UserDefaults corrompu) | `guard slots.indices.contains(index)` |

### 🟠 Bugs de comportement majeurs

| Problème | Cause | Solution |
|---|---|---|
| **CPU 100 % au repos** (RSS qui monte) | 2 boucles de re-render : time observer publiait `leaderTime` identique 10×/s + `WindowAccessor` réassignait `windowController.window` à chaque re-render | Gardes `if time != leaderTime` et `if window !== window` → **CPU 0,0 %, RSS 12 Mo** |
| **Vidéos perdues au relaunch** | Résolution de bookmark → chemin canonique `/private/var/…` ≠ `/var/…` stocké | Comparaison systématique sur **chemins standardisés** (`standardizedFileURL`) |
| **Boucle infinie de changement de vidéos** (11/08) | Le moniteur de dérive re-calait un slot court **au-delà de sa durée** → fin instantanée → remplacement → re-cale → ∞ | Garde **anti-boucle** : un slot ne rejoint jamais une position > sa durée − 0,2 s (il joue sa course, re-synchro quand le référentiel revient) |
| **Audio muet après fin du leader** (audit M3) | Branche de migration = **code mort** (`ended=true` posé avant le check `slot == referenceSlot`) + durée jamais rafraîchie après remplacement en place | Capture `wasReference` **AVANT** `ended` + reconfigure compare l'ITEM du référentiel |
| **Silence total** (audit M2) | `setAudioSlot(stale)` sur slot retiré → toutes les volumes à 0 | Blindage : slot inexistant → repli sur le référentiel |
| **Doublons garantis** + « Retirer la source » inopérant après relaunch (audit M1/M2) | Dédup par URL brute (non standardisée) + attribution source perdue à la restauration | Dédup par chemin standardisé + ré-attribution par préfixe de chemin |
| **Menu bento inaccessible** (audit M1 UI) | La TopBar contenant le menu n'était **jamais rendue** (dead code) | Menu « Composition » réintégré dans la barre latérale + raccourcis ⌘O / ⌃⌘F / ⇧⌘F branchés |
| **Watcher qui éjectait de la lecture** (audit M2 UI) | `.onChange(assets.count)` basculait en Vidéothèque à chaque ajout d'arrière-plan | Garde `!engine.isPlaying` |
| **Mini-lecteur perdu hors écran** (audit M3 UI) | Offset non borné, jamais réinitialisé | Reset `miniOffset` au changement de section |
| **Grille qui déborde / se superpose** | Colonnes adaptives (130-200 px) → largeurs/hauteurs variables → rangées désalignées + aperçus qui empiètent | Colonnes 128-152 px + **vignettes à hauteur fixe 148 px** + `.clipped()` sur vignettes ET cartes + hauteurs totales figées (210 px) |
| **Fichier temporairement illisible banni** (audit M6) | `failedURLs` sans expiration | **Expiration 5 min** : un fichier revenu est retenté |
| **Positions jamais vues par « Reprendre »** (audit M4) | Clés incohérentes (moteur brut vs bibliothèque standardisée) | `standardizedFileURL.path` partout |

### 🟡 Perfs & mémoire

| Problème | Solution |
|---|---|
| UI gelée à l'ingestion de grosses sources (5000 stats sur le MainActor) | `addFiltered` (entrée pré-filtrée) + Set de dédup O(1) |
| Fuites : `metadataTasks` terminées jamais retirées, `assetSource` jamais nettoyé | Tâches auto-nettoyantes à capture faible + nettoyage dans removeAsset/clearAll/removeSourceVideos |
| Vignettes/métadonnées obsolètes pour un fichier ré-encodé au même chemin | Clés de cache avec **taille + mtime** + écriture atomique |
| Lecture définitivement bloquée si une complétion de rewind ne revient pas | Watchdog de rewind (2 s) |

---

## 4. Les grandes fonctionnalités livrées (v7.x)

- **Timeline indépendante** : clic sur un bloc → bordure orange + badge « TIMELINE » → scrubber et ←/→ ne pilotent QUE ce bloc ; le moniteur de dérive et le watchdog l'ignorent ; clic sur le maître ou « Resynchroniser » → retour global ; le maître ne peut jamais être indépendant
- **Maître configurable** (menu « Maître 👑 » + clic droit) :
  - **Auto** : premier bloc actif (historique)
  - **Manuel** : bloc choisi (badge déplacé, timeline + audio par défaut suivent)
  - **Aucun** : pas de bloc privilégié, badge masqué, n'importe quel bloc peut être indépendant
- **Layout Libre** : poignées de redimensionnement entre les blocs (curseur ↔, drag incrémental), raccourcis **⌥← / ⌥→** (bloc sélectionné ±10 %) et **⌥0** (reset), poids persistés avec bornes [15 %, 85 %]
- **Files de lecture** par slot (persistées, « Mélanger »), **préchargement** du remplacement (< 10 s restants → transition instantanée)
- **Reprise** : positions mémorisées, bandeau « Reprendre à 3:24 » / « Recommencer », badge « Repris », dossier intelligent « Reprendre »
- **Audio par bloc** : clic = source audio, volume individuel (menu contextuel), badge 🔊
- **Mini-lecteur flottant** draggable (compact 280×158, fond opaque)
- **Capture PNG** ⌘⇧S, **drag&drop** Finder → bloc, **détection auto** des sources (5 s), **anti-rafale**, **.failed → badge « Fichier illisible »**, **watchdog** slots figés
- **Bibliothèque** : recherche, tri (nom/date/durée), mode liste, dossiers intelligents (Récemment ajoutés ★ / À regarder / Reprendre), favoris, 1186+ vidéos sans ralentir
- **iCloud** : miroir des réglages (`cloud.*`, no-op sans entitlement) ; **Écran externe** : bouton TopBar ; **restauration de fenêtre** (`setFrameAutosaveName`)
- **Icône** : logo généré (3 panneaux + timeline), `AppIcon.icns` appliqué, `Assets.xcassets` pour Xcode

---

## 5. Qualité : tests et vérifications

### Suite de tests autonome (`SelfTest/runner`) — 29/29 ✓

L'**XCTest officiel est impossible** (licence Xcode non acceptée → SDK CLT sans framework XCTest). Solution : un **runner autonome en pur Swift** qui fabrique de **vraies vidéos H.264** via `AVAssetWriter` et teste le vrai moteur.

```bash
cd ~/dev/trisync-work/SelfTest && ./runner
```

Couverture : synchronisation (départ ancré, dérive, migration), remplacement auto E2E, fichier corrompu → .failed → file, files de lecture (rotation, mélange), positions round-trip, timeline indépendante, maître (auto/manuel/aucun), layout Libre (poids, bornes), persistance round-trip (`/private/var`), anti-boucle (pas de rafale de remplacements)…

### Vérification « exigeante avec les agents » (11/08/2026)

3 agents de revue statique ligne à ligne (moteur / bibliothèque / UI) → **4 BLOCKERS + 22 MAJEURS + 39 MINEURS** → **tous les BLOCKERS et MAJEURS corrigés**, re-vérifiés par :
- Build release : **0 erreur, 0 warning**
- **29/29 tests** (zéro régression)
- Smoke test : app vivante, **CPU 0,0 %, RSS ~20 Mo** au repos, zéro crash report

### Le saviez-vous ? (pièges techniques mémorisés)

- `AVPlayer.setRate(_:time:atHostTime:)` sur un item non `.readyToPlay` → **exception Objective-C → SIGABRT** (garde partout)
- Les globales `private` au niveau fichier Swift ne sont pas visibles cross-fichier
- `AVPlayerItem.duration` peut être `.indefinite` → toujours vérifier `isNumeric`
- La résolution de bookmark peut renvoyer `/private/var/…` → **toujours** comparer des chemins standardisés
- `@Published` réassigné avec une valeur identique = boucle de re-render infinie (garde `!=` partout)

---

## 6. Structure du projet

```
~/dev/trisync-work/
├── TriSync.app                      ← l'app compilée (double-clic)
├── TriSyncPkg/Sources/TriSync/      ← les 3 fichiers sources + Package.swift
├── TriSync-v7.1-FINAL/              ← livrable Xcode (3 fichiers + Assets.xcassets)
├── SelfTest/                        ← runner de tests (29) + vidéos de test
├── slices/vague1/ + vague2/         ← rapports des agents + sauvegardes + scripts
├── Branding/                        ← logo, icônes, make_icon.swift
├── RAPPORT-ANALYSE-TRISYNC.md       ← audit 9,8/10
├── slices/vague2/RAPPORT-VERIFICATION.md ← audit exigeant agents (4+22+8)
├── DOCUMENTATION-PROJET-TRISYNC.md  ← ce document
└── SETUP_XCODE.md                   ← guide d'installation Xcode
```

### Installation dans Xcode (quand la licence sera acceptée)

1. Nouveau projet macOS App (SwiftUI) → **supprimer** les fichiers générés (ContentView, TriSyncApp.swift…)
2. Glisser les **3 fichiers** de `TriSync-v7.1-FINAL/` + `Assets.xcassets` (AppIcon)
3. Sandbox **ON** + *User Selected File Read-Only* (pour les bookmarks security-scoped)
4. Build & Run. (Le mode `swift build` du package SwiftPM fonctionne aussi)

---

## 7. Ce qui reste en attente (Phase 3)

- **XCTest officiel** (bloqué par la licence Xcode — le runner autonome couvre le besoin)
- **Notarisation + Sparkle** (mises à jour automatiques) quand le certificat Apple Developer sera disponible
- Éventuels dossiers/sous-titres, boucle A-B, préférences de lecture par vidéo

---

*Document généré et maintenu par Hermes Agent — reflète l'historique réel des décisions et corrections (v1 → v7.2).*
