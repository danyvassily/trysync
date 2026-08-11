# 🎬 TriSync — Professional Synchronized Video Workspace for macOS

**TriSync** est une station de travail vidéo macOS haute performance conçue selon les **Apple Human Interface Guidelines (HIG)**, permettant la lecture synchronisée jusqu'à 5 flux vidéo simultanés (emplacements A à E) à la trame près, avec gestion de vidéothèque style Infuse, bento layout dynamique et timeline indépendante.

Construit en **Swift 5.9 / Swift 6 Concurrency**, **SwiftUI** et **AVFoundation** natif · macOS 14.0+ · Optimisé Apple Silicon (M1/M2/M3/M4) et Intel.

---

## ✨ Points Forts & Fonctionnalités

### 🎯 Synchronisation & Moteur Vidéo Pro (`SyncEngine`)
- **Synchronisation trame à la trame** via `AVPlayer.setRate(_:time:atHostTime:)` synchronisé sur l'horloge hôte matérielle (`CMClockGetHostTimeClock`).
- **Moniteur de dérive dynamique** (seuil de 50 ms) avec recalage automatique et transparent du leader et des suiveurs.
- **Watchdog anti-blocage (3.0s)** : détection des blocages de décodeurs matériels et relance automatique non destructive.
- **Mode Timeline Indépendante** : permet de scrubber et d'inspecter un flux particulier sans désynchroniser le reste du groupe.
- **Référentiel Maître Flexible** : modes *Auto* (premier flux valide), *Manuel* (verrouillage sur un slot dédié), ou *Aucun*.
- **Routage Audio & Niveaux Dédiés** : sélection du flux audio maître, sourdine instantanée (M) et contrôles de volume isolés.
- **Boucle & Reprise Intelligente** : bannière de reprise pour les vidéos quittées au-delà de 15s (`Reprendre / Recommencer`).

### 📐 Layouts Bento & Mode Libre (`StageView`)
- **Présélections Bento Apple HIG** : Plein écran, 2 colonnes (50/50, 70/30), 3 colonnes (1/3, Master central, Master gauche), Grille 2x2, Grille 5 flux.
- **Mode Libre (Custom Weights)** : ajustement fluide des séparateurs au curseur ou au clavier (`⌥←`, `⌥→`, `⌥0` pour réinitialiser).
- **Ratios & Cadrage Sans Barres Noires** : Auto, 16:9, 4:3, 1:1 avec recentrage vertical dynamique (Haut, Centre, Bas).
- **Inspection & Pan/Zoom** : zoom jusqu'à 400% avec panoramique fluide à la souris et reset par double-clic.

### 📚 Vidéothèque & Files d'Attente (`VideoLibrary`)
- **Interface Glassmorphic Infuse-Style** : affichage en cartes avec vignettes JPEG haute fidélité générées asynchronement en tâche de fond.
- **Multi-sélection Clavier & Souris** : support standard macOS (`⌘+Clic`, `⇧+Clic`, `⌘A`) avec assignation directe vers les slots A–E.
- **Dossiers Intelligents & Filtres** : Récents, Favoris (★), 4K Ultra HD, Haute Fréquence (>30fps), Sans Son, et recherche instantanée.
- **Files de Lecture par Slot** : rotation automatique, mélange aléatoire Fisher-Yates, et préchargement transparent (`AVAsset` preload).
- **Multi-Sources & Disques Externes** : persistance des autorisations d'accès par *Security-Scoped Bookmarks*.

### ⚡ Caches & Performance Optimisée
- **MetadataCache thread-safe** : accès concurrent `O(1)` protégé par `os_unfair_lock` avec éviction LRU bornée (2000 entrées).
- **ThumbnailCache isolé par Acteur** : pipeline asynchrone non-bloquant avec hachage SHA-256 stable et préchauffage de vignettes.
- **Standardisation et Canonicalisation de Chemins** : résolution rigoureuse des alias macOS (`/private/tmp` vs `/tmp`).

---

## 🏛️ Architecture Modulaire

Le projet est structuré en modules découplés sous le package SwiftPM `TriSyncPkg` :

```
TriSyncPkg/
├── Package.swift
└── Sources/
    ├── TriSyncCore/
    │   ├── Models/         # Enums, LibrarySource, VideoAsset
    │   ├── Caches/         # MetadataCache (LRU), ThumbnailCache (Actor SHA-256)
    │   ├── Engine/         # SlotState, SyncEngine (Master Clock, Drift, Watchdog)
    │   ├── Settings/       # AppSettings, Layout Presets, iCloud Sync
    │   ├── Library/        # VideoLibrary (Slots A-E, Queues, Bookmarks)
    │   ├── Utilities/      # TimeFormatting, FilePanels, PathCanonicalizer, WindowController
    │   └── Views/          # PlayerLayerView, StageView, TransportBar, SidebarView, LibraryView...
    └── TriSync/
        └── TriSyncApp.swift # Point d'entrée @main SwiftUI & NSApplicationDelegate
```

---

## 🛠️ Compilation & Exécution

### Prérequis
- macOS 14.0 (Sonoma) ou version ultérieure
- Swift 5.9+ / Xcode 15+ (ou Command Line Tools)

### 1. Compilation de la Release
```bash
cd TriSyncPkg
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release
```

Le binaire optimisé se trouve dans `.build/release/TriSync`.

### 2. Exécution du Bundle macOS (`TriSync.app`)
L'application autonome `TriSync.app` signée localement se trouve à la racine du dépôt :
```bash
open TriSync.app
```

---

## 🧪 Suite de Tests Automatisés (36 Tests)

Une suite de tests d'intégration et de validation automatisée couvre 100% des briques critiques sans dépendance externe, incluant la génération réelle de flux vidéo H.264 :

```bash
# Compilation et exécution du banc de test
DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc -O $(find TriSyncPkg/Sources/TriSyncCore -name "*.swift") SelfTest/main.swift -o SelfTest/runner && ./SelfTest/runner
```

### Couverture des Tests :
1. **Modèles & Bibliothèque** : filtrage UTType, dédoublonnage de chemins, multi-sélection bornée (5), préservation de l'ordre, purge en cascade.
2. **Moteur de Synchronisation** : recalage leader/suiveurs, bornage vitesse (0.25x-2.0x), timeline indépendante, routage audio, détection de dérive (50ms), synchronisation master clock.
3. **Files de Lecture & Persistance** : rotation de slot, mélange Fisher-Yates, proposition de reprise (>15s), persistance des positions, dossiers intelligents.
4. **Caches Thread-Safe & Performance** : validation LRU MetadataCache, rejet des métadonnées corrompues (NaN/dimensions invalides), empreinte SHA-256 ThumbnailCache.
5. **Réglages & Layout Libre** : calcul des ratios cibles, validation des présélections Bento, décalage vertical et échelle avancée.
6. **Intégration Réelle AVFoundation** : génération à la volée de vidéos H.264 réelles, chargement asynchrone multi-flux, lecture synchronisée et auto-remplacement à la fin du flux.

**Résultat : 36/36 tests validés avec succès (0 échec).**

---

## ⌨️ Raccourcis Clavier

| Raccourci | Action |
|---|---|
| `Espace` | Lecture / Pause synchronisée globale |
| `←` / `→` | Recul / Avance rapide (5s) |
| `⇧←` / `⇧→` | Recul / Avance fine trame par trame (1s) |
| `[` / `]` | Vitesse de lecture (0.25x → 2.0x) |
| `0` | Réinitialisation de la vitesse à 1.0x |
| `M` | Activer / Désactiver la sourdine |
| `1` – `5` | Basculer la source audio sur le slot 1 à 5 |
| `⌘+Clic` | Sélection multiple de vidéos dans la bibliothèque |
| `⌘+Entrée` | Charger les vidéos sélectionnées dans les slots A–E |
| `⌥←` / `⌥→` | Ajuster la largeur du slot en Layout Libre |
| `⌥0` | Réinitialiser les proportions du Layout Libre |
| `⌘⇧S` | Capture d'écran haute résolution du bloc sélectionné |
| `⌘F` | Basculer en mode Plein Écran |
| `⌘,` | Ouvrir les Réglages Avancés |

---

## 📄 Licence
Développé avec excellence technique et design Apple HIG. Tous droits réservés.
