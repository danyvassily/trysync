# 📐 TriSync Architecture & Design Manual

## 1. Vue d'Ensemble du Système

TriSync est conçu selon les standards les plus exigeants de l'écosystème Apple :
- **Séparation Stricte des Responsabilités** : isolation du moteur de lecture (`SyncEngine`), de la gestion d'état de la vidéothèque (`VideoLibrary`), des caches concurrents (`MetadataCache`, `ThumbnailCache`) et des vues SwiftUI/AppKit.
- **Concurrence Moderne (Swift Concurrency & Actors)** : `@MainActor` pour les états UI et les instances de lecture, `actor` pour la génération et le stockage des vignettes, `os_unfair_lock` pour le cache de métadonnées sans blocage.
- **Synchronisation Matérielle Trame par Trame** : utilisation de `AVPlayer.setRate(_:time:atHostTime:)` adossé à l'horloge hôte `CMClockGetHostTimeClock()`.

---

## 2. Diagramme de Composants

```
+-------------------------------------------------------------------------+
|                              TriSyncApp                                 |
|          (@main SwiftUI Entrypoint + NSApplicationDelegate)            |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                              ContentView                                |
|        (Glassmorphic Window, Floating Controls & State Container)       |
+-------------------------------------------------------------------------+
         |                                           |
         v                                           v
+-----------------------+                 +-------------------------------+
|      SidebarView      |                 |    StageView (Bento Layout)   |
| (Navigation & Sources)|                 |  +-------------------------+  |
+-----------------------+                 |  |      StagePane (A..E)   |  |
         |                                |  | +---------------------+ |  |
         v                                |  | |   PlayerLayerView   | |  |
+-----------------------+                 |  | | (AVPlayerLayer/Host)| |  |
|      LibraryView      |                 |  | +---------------------+ |  |
|  (Infuse Grid/Smart)  |                 |  +-------------------------+  |
+-----------------------+                 +-------------------------------+
         |                                           |
         +--------------------+----------------------+
                              |
                              v
+-------------------------------------------------------------------------+
|                            VideoLibrary                                 |
|  - Multi-Selection (⌘-Click, Shift-Click)                               |
|  - Queues & Shuffle (Fisher-Yates)                                      |
|  - Security-Scoped Bookmarks & External Storage                         |
|  - Auto-Replacement & Failure Recovery                                  |
+-------------------------------------------------------------------------+
         |                                           |
         v                                           v
+-----------------------+                 +-------------------------------+
|     SyncEngine        |                 |        Caches & Models        |
| - Master Clock Sync   |                 | - MetadataCache (O(1) LRU)    |
| - 50ms Drift Monitor  |                 | - ThumbnailCache (Actor SHA)  |
| - 3.0s Watchdog       |                 | - PathCanonicalizer           |
| - Independent Mode    |                 | - AppSettings & Presets       |
+-----------------------+                 +-------------------------------+
```

---

## 3. Détails des Sous-Systèmes Clés

### 3.1 Synchronisation AVFoundation (`SyncEngine.swift`)
- **Horloge Maître** : Tous les `AVPlayer` sont initialisés avec `automaticallyWaitsToMinimizeStalling = false`.
- **Top de Départ Coordonné** : Le déclenchement de la lecture s'effectue via `setRate(targetRate, time: targetTime, atHostTime: hostTime)` calculé avec un delta futur (`CMClockGetTime(CMClockGetHostTimeClock()) + 0.15s`), garantissant un alignement trame par trame.
- **Surveillance de Dérive** : Un moniteur régulier calcule l'écart de temps absolu entre chaque suiveur et le leader. Si l'écart dépasse 50 ms (`driftThreshold = 0.05`), un recalage automatique non-bloquant est appliqué.
- **Watchdog Anti-Blocage** : En cas de décodeur bloqué pendant 3.0 secondes consécutives en mode lecture, le watchdog relance le décodeur sans interrompre la session utilisateur.

### 3.2 Cache de Métadonnées & Vignettes (`Caches/`)
- **`MetadataCache`** : Protégé par `os_unfair_lock`, il garantit un accès instantané sans allocation de thread pool. Les entrées sont limitées à 2000 items avec une stratégie d'éviction LRU stricte. Les valeurs corrompues (durées `NaN`, dimensions nulles ou négatives) sont automatiquement rejetées.
- **`ThumbnailCache`** : Actor Swift isolé générant des aperçus JPEG 720p avec `AVAssetImageGenerator(asset:)` configuré en `requestedTimeToleranceBefore = .zero` et `requestedTimeToleranceAfter = .zero` pour une fidélité visuelle maximale. Les clés de hachage sont dérivées par SHA-256 à partir du chemin canonique.

### 3.3 Normalisation & Sécurité des Chemins (`PathCanonicalizer.swift`)
- Sur macOS, les répertoires `/tmp` et `/var` pointent vers `/private/tmp` et `/private/var`. La fonction `canonicalPath(for:)` normalise systématiquement les URL, prévenant toute duplication dans les dictionnaires d'assets, sets de sélection ou clés de cache.

### 3.4 Expérience Utilisateur Apple HIG
- **Bento Grids & Layout Libre** : Les proportions des vidéos peuvent être redimensionnées de manière fluide avec poignées magnétiques et raccourcis clavier (`⌥←`, `⌥→`, `⌥0`).
- **Mode Immersif & Mini-Lecteur PiP** : Transition instantanée vers un lecteur flottant Always-on-Top (`MiniPlayerView`) avec contrôles de transport intégrés.
- **Raccourcis Clavier macOS Standard** : Navigation fluide, mute instantané, basculement de canal audio 1–5, et capture d'écran ⌘⇧S.

---

## 4. Tests et Qualité

Le projet intègre un banc d'essai complet (`SelfTest/main.swift`) exécutant 36 tests d'intégration stricts, incluant la synthèse à chaud de flux vidéo H.264 réels avec `AVAssetWriter`.
