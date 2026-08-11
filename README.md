# 🎬 TriSync

**Vidéothèque macOS à lecture synchronisée** — jusqu'à 5 vidéos en split-screen, parfaitement alignées à la trame près.

SwiftUI + AVFoundation · macOS 14+ · Apple Silicon (M3)

## ✨ Fonctionnalités

- **5 slots synchronisés** (A–E) via `AVPlayer.setRate(_:time:atHostTime:)` sur horloge hôte : départ et re-calage à la trame près
- **Moniteur de dérive** (50 ms) + **watchdog** anti-blocage + référentiel migrable
- **Timeline indépendante** : clic sur un bloc → la barre de temps ne pilote QUE ce bloc
- **Maître configurable** : Auto / Manuel (bloc choisi) / Aucun
- **Layout Libre** : redimensionnement des blocs à la souris (poignées) et au clavier (⌥← / ⌥→ / ⌥0)
- **Vidéothèque type Infuse** : grille uniforme, recherche, tri, mode liste, favoris, dossiers intelligents
- **Multi-sources** : Mac + disques externes (bookmarks security-scoped), détection automatique
- **Files de lecture** par slot + Mélanger, **préchargement** du remplacement (transition instantanée)
- **Reprise des positions** (bandeau « Reprendre »), **audio par bloc**, volume individuel
- **Mini-lecteur flottant**, **capture PNG** ⌘⇧S, **drag&drop** Finder → bloc
- Remplissage **sans barres noires** (portrait/paysage), zoom/pan, plein écran, mode immersif, iCloud (réglages)

## 🗂️ Structure

| Chemin | Contenu |
|---|---|
| `TriSyncPkg/` | Package SwiftPM + les 3 fichiers sources (ContentView, VideoLibrary, EngineAndSettings) |
| `TriSync-v7.1-FINAL/` | Livrable Xcode : 3 fichiers + `Assets.xcassets` (icône) + documentation |
| `SelfTest/` | Suite de tests autonome (29 tests, vraies vidéos H.264) |
| `Branding/` | Logo + icônes (icns, iconset, générateur) |
| `slices/` | Rapports des agents de revue + sauvegardes |

## 🛠️ Build

```bash
cd TriSyncPkg
swift build -c release
```

## ✅ Tests (sans XCTest — licence Xcode non requise)

```bash
cd SelfTest
./runner        # 29 tests : synchro, files, reprise, maître, layout libre, anti-boucle…
```

## 📚 Documentation

- [`DOCUMENTATION-PROJET-TRISYNC.md`](DOCUMENTATION-PROJET-TRISYNC.md) — historique complet : demandes, problèmes, solutions
- [`slices/vague2/RAPPORT-VERIFICATION.md`](slices/vague2/RAPPORT-VERIFICATION.md) — audit exigeant (4 BLOCKERS, 22 MAJEURS, 8 MINEURS corrigés)
- [`RAPPORT-ANALYSE-TRISYNC.md`](RAPPORT-ANALYSE-TRISYNC.md) — audit 9,8/10
- [`SETUP_XCODE.md`](SETUP_XCODE.md) — installation dans Xcode (Sandbox + User Selected File)

---
*Projet personnel — développé avec Hermes Agent (multi-agents).*
