# AGENT R3 — Revue STATIQUE exigeante de l'UI (ContentView.swift + moteur/bibliothèque)

**Périmètre** : `TriSyncPkg/Sources/TriSync/ContentView.swift` (3840 l.), `EngineAndSettings.swift` (1605 l.), `VideoLibrary.swift` (838 l.). Cible macOS 14 (Package.swift), Swift tools 5.9. Revue sans build (licence Xcode bloquée) — analyse statique ligne à ligne.

---

## BLOCKERS

**Aucun.** En particulier :
- **EnvironmentObject** : aucune vue `@EnvironmentObject` rendue hors de la portée des injections racines (TriSyncApp ContentView.swift:59-70 : library, settings, windowController, session, engine). Le seul sheet (SettingsSheet, :536-539) hérite de l'environnement de ContentView + ré-injecte `library.engine` ; les contextMenu héritent de l'environnement. **Aucun risque d'EXC_BREAKPOINT « No ObservableObject of type SyncEngine found ».**
- Aucun index de tableau non borné (tous les accès `slots[i]`, `slotLetters[i]`, `NSScreen.screens[1]` sont gardés).

---

## MAJEURS

### M1 — TopBar n'est JAMAIS rendue : raccourcis ⌘O / ⌃⌘F / ⇧⌘F morts + menu « bento » (composition de scène) INACCESSIBLE
- **Fichier:ligne** : ContentView.swift:1105-1335 (TopBar) ; SidebarView 1638-1835 (boutons sans `.keyboardShortcut`) ; seuls usages de `keyboardShortcut("o"/"f"...)` : lignes 1150, 1168, 1197 — tous dans TopBar, jamais instanciée (aucun `TopBar(` dans le code).
- **Scénario** : l'aide affichée promet « ⌘O », « ⌃⌘F », « ⇧⌘F » (help texts des boutons SidebarView :1720-1724 et du libellé « Mode immersif (⇧⌘F) ») mais aucun raccourci n'est branché. Pire : le **menu bento** (choix de composition Auto/Côte à côte/Maître+détail/…, :1223-1256) n'existe QUE dans TopBar → l'utilisateur ne peut plus changer `settings.layoutPreset` (le moteur de layout :891-975 le respecte, mais aucune UI n'y mène). Fonctionnalité perdue + 3 raccourcis annoncés morts.
- **Correction** : ajouter les raccourcis aux boutons de SidebarView (et réintégrer ou supprimer TopBar) :
```swift
// SidebarView, bloc « Actions » (~ligne 1720)
iconButton("viewfinder", "Mode immersif (⇧⌘F)") { onEnterImmersive() }
    .keyboardShortcut("f", modifiers: [.command, .shift])
iconButton("arrow.up.left.and.arrow.down.right", "Plein écran (⌃⌘F)") {
    windowController.window?.toggleFullScreen(nil)
}
.keyboardShortcut("f", modifiers: [.control, .command])
```
Pour le bento : déplacer `bentoMenu` dans la barre d'outils du FolderBrowserView/LibraryView ou dans la barre latérale (ou le menu contextuel de la scène). Supprimer TopBar + GalleryStrip (dead code ~250 l., M13).

### M2 — Le source watcher éjecte l'utilisateur de la lecture en cours
- **Fichier:ligne** : ContentView.swift:508-512 ; VideoLibrary.swift:332-341 (poll 5 s) et 345-368.
- **Scénario** : `.onChange(of: library.assets.count)` bascule `session.section = .library` à **chaque** ajout d'asset, y compris les ajouts d'arrière-plan du moniteur de sources. Un fichier vidéo déposé dans un dossier source pendant qu'on regarde un film → l'app quitte la section Lecture et renvoie à la vidéothèque (la lecture continue en mini-lecteur, mais l'utilisateur est expulsé de la scène).
- **Correction** :
```swift
.onChange(of: library.assets.count) { oldCount, newCount in
    if newCount > oldCount, !session.immersiveMode, !engine.isPlaying {
        session.section = .library
    }
}
```

### M3 — Mini-lecteur : offset de glissement NON BORNÉ → perte définitive hors écran
- **Fichier:ligne** : ContentView.swift:751-759 (`miniOffset = value.translation`, aucun clamp) ; :577-581 (le retour de section réinitialise `miniPlayerHidden` mais PAS `miniOffset`).
- **Scénario** : l'utilisateur traîne le mini-lecteur au-delà des bords de la fenêtre (possible : le DragGesture est libre) → il disparaît de l'écran et **y reste pour toute la session** : changer de section le réaffiche mais à la même position hors écran. Seul un redémarrage le récupère.
- **Correction** :
```swift
.onChange(of: session.section) { oldSection, newSection in
    if oldSection == .library, newSection != .library {
        miniPlayerHidden = false
        miniOffset = .zero
    }
}
```
Idéalement, borner dans `onChanged` à la taille de la fenêtre (capturée via WindowAccessor) : `miniOffset = CGSize(width: min(max(value.translation.width, -w/2), w/2), height: ...)`.

### M4 — LibraryCard : le bouton ✕ (au survol) recouvre exactement le badge d'emplacement A/B/C
- **Fichier:ligne** : ContentView.swift:2602-2624. Dans le `ZStack(alignment: .topTrailing)`, le badge lettre (`.padding(5)`) et le bouton ✕ (`.padding(5)`) sont tous deux alignés topTrailing → mêmes coordonnées, le ✕ (28×28, rendu en dernier) masque entièrement la lettre (~16×23) au survol d'une carte assignée. Le badge « clignote » au survol ; impossible de voir A/B/C sur une carte survolée.
- **Correction** (décaler le ✕ sous le badge, ou ne l'afficher que si `slotLetter == nil`) :
```swift
if hovering {
    Button { library.removeAsset(asset) } label: { ... }
        .buttonStyle(.plain)
        .padding(.top, 30)   // sous le badge de lettre
        .padding(.trailing, 5)
}
```

---

## MINEURS

### m1 — TransportBar : picker de vitesse désynchronisé
ContentView.swift:3172-3178 : `rate` (@State) n'est resynchronisé qu'à `onAppear`. Un changement de vitesse par ⌥[/⌥] (PlayerLayerView.keyDown → `engine.nudgeRate`) ou par la section « Vitesse » des Réglages laisse l'affichage sur « 1× » alors que la lecture tourne à 1,25×.
```swift
.onChange(of: engine.currentRate) { _, newValue in rate = newValue }
```

### m2 — resumeBanner recouvre les contrôles du transport pendant 6 s
ContentView.swift:3167-3169 : l'`overlay(alignment: .top)` du bandeau (~46 px) est posé DANS les bounds de la barre → il intercepte les clics sur la moitié haute des boutons (Lecture, Arrêter, ±10 s) tant que `resumeOffer` existe. Fix : `allowsHitTesting(false)` sur le fond du bandeau (en gardant les boutons Reprendre/Recommencer actifs) ou `.offset(y: -8)` pour le sortir des bounds.

### m3 — Cartes : contenu ~2-3 px plus haut que le frame → étoile favori rognée
ContentView.swift:2389-2399 (BrowserVideoCard, frame 204) et 2647-2660 (LibraryCard, frame 206) : contenu intrinsèque ≈ 206-210 px (148 vignette + 2×6 spacing + titre 12-14 px + rangée étoile 18-20 px + padding 16) → `.clipped()` coupe 1-3 px en bas de l'étoile (visible sur LibraryCard). Fix : `.frame(height: 210)` sur LibraryCard, ou spacing 5.

### m4 — Entrée dans le champ de recherche peut déclencher « Lancer (N) »
ContentView.swift:1987, 2497, 2762 : `.keyboardShortcut(.return, modifiers: [])` sur « Lancer » + TextField « Rechercher… » dans la même hiérarchie. Les key equivalents sont dispatchés avant la gestion du champ → Retour après une recherche lance la sélection par accident. Fix : `.onSubmit { }` sur le TextField (consomme Retour) ou retirer le shortcut.

### m5 — ⌘⇧S ambigu avec plusieurs panneaux
ContentView.swift:3493-3499 : un bouton caché par StagePane → jusqu'à 5 boutons ⌘⇧S dans la hiérarchie ; SwiftUI en choisit un (typiquement le premier, slot A) → la capture ne suit jamais le panneau souhaité (le menu contextuel :3488 reste fiable). Fix : un seul bouton caché global ciblant `library.selectedSlot`, ou supprimer le bouton caché.

### m6 — Prefetch du dossier parent sans security scope
ContentView.swift:2163-2170 : `Task.detached` lit `parentURL` sans `startAccessingSecurityScopedResource` (contrairement à loadContents :2133-2134) → échec silencieux en sandbox (retour arrière moins fluide). Fix : start/stop équilibré dans la tâche.

### m7 — Positions de lecture potentiellement perdues au quit
ContentView.swift:27-33 : `applicationWillTerminate` lance `Task { @MainActor … }` — la terminaison peut précéder l'exécution. Appeler `saveNow()` / `persistPositionsNow()` de façon synchrone (on est déjà sur le main).

### m8 — Réassignations @Published sans garde (publications identiques, sans boucle)
- EngineAndSettings.swift:667 : `currentRate = rate` sans garde (déclenché par onChange(rate) → publication inutile à chaque sélection identique).
- VideoLibrary.swift:140/151/167/243/267 : `slots[i] = nil` / `slots[slot] = asset` réassignés sans garde d'identité (double clear publie quand même).
- AppSettings (EngineAndSettings.swift:86-91) : `didSet { save() }` sur valeur identique → écriture UserDefaults + re-render (clic sur l'option déjà active des Réglages).
Aucune de ces publications ne boucle (contrairement au bug leaderTime corrigé, gardes vérifiées : EngineAndSettings.swift:1180-1182, 1439-1445, 1456-1458, 1483-1485, 872-874, 1330-1332, 1575-1577 ; ContentView.swift:519-524, 3525-3527) — à nettoyer par cohérence.

### m9 — Accessibilité
- SettingsSheet : `sidebarRow` (:2882-2907) et `optionRow` (:3051-3076) sont des HStack en `onTapGesture` → non activables au clavier/VoiceOver. Remplacer par `Button(.plain)`.
- Sliders sans `.accessibilityLabel` : scrubber (TransportBar :3217-3230), volume (StagePane :3651-3656).
- Contraste : « TIMELINE » (blanc sur `Color.orange`, :3632) et « Repris » (blanc sur orange 0.9, :2368, :2630) ≈ 2,3:1 pour du 9 pt — sous WCAG AA. Texte en noir ou fond assombri.
- Tailles 9-13 pt : petites mais cohérentes (info vs action).

### m10 — Pas de restauration de fenêtre
TriSyncApp (ContentView.swift:72-73) : `defaultSize` 1280×800, aucun `frameAutosaveName` → position/taille perdues à chaque lancement. Fix : `window.setFrameAutosaveName("TriSync.Main")` dans WindowAccessor (à côté de la garde :519-524).

### m11 — Mode immersif : désync plein écran / état + Espace mort quand contrôles masqués
ContentView.swift:837-855 : sortie du plein écran par ⌃⌘F/feux verts pendant le mode immersif → `session.immersiveMode` reste true en fenêtré (Échap corrige). Quand les contrôles sont masqués (>3 s sans souris), TransportBar est démontée → Espace ne fonctionne plus. Fix : observer `NSWindow.didExitFullScreenNotification` pour réinitialiser immersiveMode ; garder la barre de transport dans la hiérarchie avec `.opacity` au lieu de l'`if`.

### m12 — Double-clic « lance » mais ne démarre pas si les items ne sont pas prêts
ContentView.swift:592-594, 2412-2414 ; EngineAndSettings.swift:571-574 : `engine.play()` est no-op tant que tous les items ne sont pas `.readyToPlay` (le `handleStatusChange` ne rejoue que si `isPlaying`). Après un double-clic, l'utilisateur atterrit en section Lecture, bouton actif, vidéo à l'arrêt. Fix UX : mécanisme « play when ready » (ex. `playRequestedWhileRewinding` étendu) ou désactiver le bouton avec le texte « Chargement… ».

### m13 — Dead code
TopBar (ContentView.swift:1105-1335) et GalleryStrip (:1341-1358) ne sont plus instanciées (~250 lignes, incluant le menu bento — cf. M1). `resumeText` de LibraryCard (:2567) n'est jamais lu (le badge vient de `resumePosition` :2576-2579 → `showsResumeBadge` de SmartGridView n'a aucun effet ; le badge « Repris » s'affiche dans toutes les grilles — comportement à documenter ou nettoyer).

### m14 — folderTile : contenu centré verticalement dans 204 px
ContentView.swift:2074-2100 : l'icône + texte (~142 px) sont centrés dans la tuile de 204 px → grand vide en haut à côté des vignettes des cartes vidéo (alignement visuel incohérent dans la grille mixte). Cosmétique : `.frame(maxHeight: .infinity, alignment: .top)` sur le VStack.

### m15 — Mini-lecteur : flèches ←/→ = déplacement du cadrage
ContentView.swift:692-693 : `immersiveMode: false, seekOnArrows: false` sur le mini-lecteur → après un clic sur sa vidéo, les flèches font du pan (panX/panY) au lieu de chercher. Quirk acceptable (documenté), à noter.

---

## VÉRIFICATIONS POSITIVES (concis)

1. **EnvironmentObject** : injection racine complète et unique (TriSyncApp :59-70) ; sheets/popovers/overlays/contextMenu tous sous la portée ; ré-injections redondantes (ContentView :504, :538, :789) inoffensives. **Aucun risque de crash « No ObservableObject found ».**
2. **Boucles de re-render** : toutes les gardes demandées sont en place — `leaderTime` (≠, EngineAndSettings:1180), `driftText` (1439), `slotError` (1080/1456/1483), `resumeOffer` (925/952), `audioSlot` (872), `independentSlot` (1330), `readyCount` (1575), `windowController.window` (ContentView:519), `paneView` (3525). Le bug 100 % CPU du 11/08 est correctement corrigé ; plus aucune boucle détectable.
3. **Mini-lecteur en pause** : `timelineTime` = `leaderTime` publié (ou gelé à la bonne valeur en pause — le time observer AVPlayer ne publie pas de valeur identique, garde :1180) ; après un scrub en pause, `seekAll` publie `leaderTime` (:1259/:1264) → l'affichage reste correct. Acceptable.
4. **AVPlayer partagé mini-lecteur/StagePane** : les deux ne sont JAMAIS simultanément dans la hiérarchie (sections exclusives) + `viewDidMoveToWindow` détache proprement le player (ContentView:240-248) → aucun conflit de layer.
5. **Grille** : hauteurs fixes 148/204/206 + `.clipped()` sur toutes les cartes → aucun chevauchement inter-cartes ; badges (B/C/Repris/✓/étoile) tous dans la zone vignette 148 px (sauf étoile, cf. m3) ; colonnes adaptives 128-152 cohérentes entre FolderBrowser/Library/SmartGrid ; folderTile 204 px aligné sur les cartes.
6. **Interactions** : onTapGesture + onTapGesture(count:2) coexistent (le single tap attend le timeout du double — délai ~0,25 s standard) ; boutons internes des cartes (✕, ★) prioritaire sur le tap parent ; drag&drop : `startAccessingSecurityScopedResource` équilibré partout (5 paires + exception documentée openVideosPanel, EngineAndSettings:234-238) ; complétions `loadItem` rapatriées sur le main (ContentView:3773) ; capture PNG ⌘⇧S sur le thread principal ✓.
7. **Dépréciations macOS 14** : tous les `.onChange(of:)` utilisent la forme 2 paramètres (nouvelle API) — aucune dépréciation ; `preferredColorScheme` OK ; pas de `Color.accentColor` (accent = `Color(nsColor: .controlAccentColor)`) ; `.sheet` + environmentObject ✓.
8. **Fuites** : timer de dérive invalidé à la pause (EngineAndSettings:1392-1395) ; KVO/notifications retirés dans teardown (:1220-1238) ; captures faibles systématiques (timeObserver, driftTimer, watcher, replaceTasks) ; `hideControlsWork` annulé à la sortie d'immersif (ContentView:849).
9. **Accessibilité** : `.help` + `.accessibilityLabel` sur la quasi-totalité des boutons icônes ; labels français cohérents ; bouton masqué ⌘⇧S en `accessibilityHidden` (ContentView:3498).
10. **État** : `miniPlayerHidden` correctement réinitialisé au changement de section (:577-581) ; reconfiguration moteur par diff sans churn (EngineAndSettings:485-558) ; badges « en trop » et « vignettes désactivées » présents sur les trois grilles.

---

## Synthèse

- **0 BLOCKER** (injection EnvironmentObject complète, aucun index non borné, aucune boucle de re-render).
- **4 MAJEURS** : M1 raccourcis ⌘O/⌃⌘F/⇧⌘F morts + menu bento inaccessible (TopBar jamais rendue) ; M2 source watcher éjectant de la lecture ; M3 mini-lecteur perdu hors écran ; M4 badge A/B/C masqué par le bouton ✕ au survol.
- **15 MINEURS** (désync vitesse, bandeau de reprise bloquant, étoile rognée, Entrée-lance, ⌘⇧S ambigu, security scope prefetch, quit async, publications sans garde, accessibilité, restauration fenêtre, immersif, dead code…).
