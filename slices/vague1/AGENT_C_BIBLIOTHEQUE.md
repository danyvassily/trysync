# AGENT C — BIBLIOTHÈQUE (Vidéothèque)

**Fichier cible** : `TriSyncPkg/Sources/TriSync/ContentView.swift` (4281 lignes, inchangé — les patches sont à appliquer par l'orchestrateur, build interdit ici).
**Cible** : Swift 5.9 / macOS 14, UI dark, commentaires FRANÇAIS, `[weak self]`, main thread.
**Aucune dépendance ajoutée** : `UniformTypeIdentifiers` déjà importé (l.15), `AVFoundation` déjà importé.

## Vue d'ensemble — 4 features, 26 patches

| Feature | Patches | Contenu |
|---|---|---|
| **F1 — Recherche + tri + mode liste** | P15–P20 | TextField recherche (casse + diacritiques insensibles), Picker tri (Nom/Date/Durée), toggle Grille/Liste, lignes compactes sans vignettes (double-clic = lancer, ⌘+clic = sélectionner), filtres appliqués AVANT l'affichage |
| **F2 — Dossiers intelligents + favoris** | P1–P14, P25–P26 | `VideoAsset.dateAdded` + `isFavorite` (UserDefaults `library.favorites`, clés = chemins standardisés), `SmartFolder` (recent/favorites/resume), section « BIBLIOTHÈQUE » dans la barre latérale, `SmartGridView` générique réutilisée ×3, étoile ★ sur `LibraryCard` et `BrowserVideoCard`, badge « Repris m:ss », positions lues depuis `playback.positions` |
| **F3 — Détection auto des nouveaux fichiers** | P21–P23 | Polling léger 5 s (`Task.sleep` annulable, pas de Timer), empreinte mtime par source, rescan incrémental via `scanSource`, garde `isScanning` + compteur `activeScans` (anti double-scan) |
| **F4 — Drag & drop Finder → bloc** | P24 | `.onDrop(of: [UTType.fileURL])` sur chaque `StagePane` : URL vidéo → remplace le slot (`ensureInLibrary` + `assign` → `engine.reconfigure`), accès security-scoped avec `defer`. Le drop « scène (fond) » est déjà couvert par le `dropDestination` racine existant (l.1925) → `add(urls:)` : aucun patch nécessaire |

**Choix assumés** (écarts au libellé, justifiés) :
- Favoris persistés par **chemin standardisé** (`[String]`) plutôt que `Set<UUID>` : `VideoAsset.id` est un `UUID()` éphémère régénéré à chaque lancement (restauration = nouveaux objets), un stockage par id perdrait les favoris au redémarrage. La spec autorisait explicitement `[String]`.
- `favoritesRevision` (@Published, incrémenté à chaque bascule) : les cartes et la vue « À regarder » observent `VideoLibrary` ; sans cela, la bascule d'étoile (UserDefaults seul) ne rafraîchirait pas l'UI. Pas de réassignation de valeur identique en boucle : n'émet que sur clic utilisateur.
- Feature 3 : `Task` + `Task.sleep` en boucle (annulable, libère le main thread) plutôt qu'un `Timer` — conforme à la consigne.
- Le drop sur la scène (fond) ne reçoit **pas** de nouveau patch : le `dropDestination(for: URL.self)` racine (ContentView.swift l.1925–1932) ingère déjà les dépôts hors panneaux → `add(urls:)`. Avec le `onDrop` des panneaux, SwiftUI livre le drop au plus profond des vues acceptantes : panneau = remplacement de slot, ailleurs = ajout à la bibliothèque.

---

## FEATURE 2 — Dossiers intelligents & favoris

### Patch 1 — `VideoAsset` : dateAdded + isFavorite (persisté par chemin standardisé)
**Où** : `final class VideoAsset` (l.86–100)

**old_string**
```swift
final class VideoAsset: Identifiable {
    let id = UUID()
    let url: URL
    let title: String

    var duration: CMTime = .zero
    var frameRate: Double = 0
    var size: CGSize = .zero
    var thumbnail: NSImage? = nil

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }
}
```

**new_string**
```swift
final class VideoAsset: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    /// Date d'ajout à la bibliothèque (trie le dossier intelligent
    /// « Récemment ajoutés »).
    let dateAdded = Date()

    var duration: CMTime = .zero
    var frameRate: Double = 0
    var size: CGSize = .zero
    var thumbnail: NSImage? = nil

    /// Favori (dossier intelligent « À regarder »), persisté par chemin
    /// STANDARDISÉ dans UserDefaults (« library.favorites »). Les clés sont
    /// des chemins (et non des UUID) car VideoAsset.id est régénéré à chaque
    /// lancement : les favoris survivent ainsi au redémarrage.
    /// VideoLibrary.toggleFavorite(_:) publie la bascule pour rafraîchir l'UI.
    var isFavorite: Bool {
        get { Self.favoritePaths.contains(url.standardizedFileURL.path) }
        set {
            var paths = Self.favoritePaths
            let key = url.standardizedFileURL.path
            if newValue { paths.insert(key) } else { paths.remove(key) }
            UserDefaults.standard.set(Array(paths), forKey: "library.favorites")
            Self.favoritePaths = paths
        }
    }

    private static var favoritePaths: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "library.favorites") ?? [])
    }()

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }
}
```

### Patch 2 — `VideoLibrary` : publication des favoris
**Où** : propriétés @Published de `VideoLibrary` (l.108–110)

**old_string**
```swift
    @Published var slots: [VideoAsset?] = Array(repeating: nil, count: VideoLibrary.maxSlots)
    @Published var assets: [VideoAsset] = []
    @Published var selectedSlot = 0
```

**new_string**
```swift
    @Published var slots: [VideoAsset?] = Array(repeating: nil, count: VideoLibrary.maxSlots)
    @Published var assets: [VideoAsset] = []
    @Published var selectedSlot = 0
    /// Révision des favoris : incrémentée à chaque bascule d'étoile pour que
    /// les cartes et le dossier intelligent « À regarder » se rafraîchissent
    /// (la persistance elle-même vit dans VideoAsset.isFavorite).
    @Published private(set) var favoritesRevision = 0
```

### Patch 3 — `VideoLibrary.init` : démarre la surveillance des sources
**Où** : `init()` de `VideoLibrary` (l.128–134)

**old_string**
```swift
    init() {
        // Remplacement automatique : quand une vidéo se termine, la
        // bibliothèque choisit une autre vidéo pour que le bloc continue.
        engine.onItemEnded = { [weak self] slot in
            self?.autoReplace(slot: slot)
        }
    }
```

**new_string**
```swift
    init() {
        // Remplacement automatique : quand une vidéo se termine, la
        // bibliothèque choisit une autre vidéo pour que le bloc continue.
        engine.onItemEnded = { [weak self] slot in
            self?.autoReplace(slot: slot)
        }
        // Détection automatique des nouveaux fichiers dans les sources
        // (polling léger toutes les 5 s, voir checkSourcesForChanges).
        startSourceWatcher()
    }
```

### Patch 4 — `VideoLibrary` : toggleFavorite + playbackPosition
**Où** : après `ensureInLibrary(_:)` (l.443–447)

**old_string**
```swift
    /// Garantit qu'un fichier est présent dans la bibliothèque (sans occuper
    /// de slot) et retourne l'asset correspondant. Utilisé par le navigateur
    /// de dossiers au clic sur une vidéo.
    func ensureInLibrary(_ url: URL) -> VideoAsset? {
        if let existing = assets.first(where: { $0.url == url }) { return existing }
        add(urls: [url], source: nil)
        return assets.first(where: { $0.url == url })
    }
```

**new_string**
```swift
    /// Garantit qu'un fichier est présent dans la bibliothèque (sans occuper
    /// de slot) et retourne l'asset correspondant. Utilisé par le navigateur
    /// de dossiers au clic sur une vidéo.
    func ensureInLibrary(_ url: URL) -> VideoAsset? {
        if let existing = assets.first(where: { $0.url == url }) { return existing }
        add(urls: [url], source: nil)
        return assets.first(where: { $0.url == url })
    }

    // MARK: Favoris et reprise de lecture (dossiers intelligents)

    /// Bascule le favori d'un asset (étoile des cartes) et publie le
    /// changement pour rafraîchir les vues qui en dépendent (« À regarder »).
    func toggleFavorite(_ asset: VideoAsset) {
        asset.isFavorite.toggle()
        favoritesRevision += 1
    }

    /// Position de lecture sauvegardée pour une URL (dict « playback.positions »,
    /// clé = chemin standardisé), écrite par la feature « Reprendre ».
    /// Retourne 0 quand aucune position n'est enregistrée.
    func playbackPosition(for url: URL) -> Double {
        let key = url.standardizedFileURL.path
        return UserDefaults.standard.dictionary(forKey: "playback.positions")?[key] as? Double ?? 0
    }
```

### Patch 5 — `SmartFolder` (enum) + `SessionState.smartFolder`
**Où** : bloc `AppSection` / `SessionState` (l.1539–1553)

**old_string**
```swift
/// Section affichée dans la fenêtre principale.
enum AppSection: Equatable {
    case library  // Vidéothèque : navigation dossiers + grilles
    case play     // Lecture : scène synchronisée (sans bandeau de miniatures)
}

/// État de session partagé (section active, mode immersif, navigation).
final class SessionState: ObservableObject {
    @Published var immersiveMode = false
    @Published var section: AppSection = .library
    /// Source en cours de navigation dans la Vidéothèque (nil = toutes les vidéos).
    @Published var browsingSource: LibrarySource?
    /// Pile de dossiers du navigateur (dernier = dossier courant).
    @Published var folderPath: [URL] = []
}
```

**new_string**
```swift
/// Section affichée dans la fenêtre principale.
enum AppSection: Equatable {
    case library  // Vidéothèque : navigation dossiers + grilles
    case play     // Lecture : scène synchronisée (sans bandeau de miniatures)
}

/// Dossier intelligent de la bibliothèque : entrée virtuelle de la barre
/// latérale dont le contenu est calculé à la volée depuis les assets.
enum SmartFolder: String, CaseIterable, Identifiable {
    case recent    // Récemment ajoutés (top 50, date d'ajout décroissante)
    case favorites // À regarder (favoris ★)
    case resume    // Reprendre (position de lecture sauvegardée > 15 s)

    var id: String { rawValue }

    /// Libellé affiché dans la barre latérale et l'en-tête de la grille.
    var title: String {
        switch self {
        case .recent: return "Récemment ajoutés"
        case .favorites: return "À regarder"
        case .resume: return "Reprendre"
        }
    }

    /// Icône de la barre latérale.
    var icon: String {
        switch self {
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "star.fill"
        case .resume: return "play.circle"
        }
    }
}

/// État de session partagé (section active, mode immersif, navigation).
final class SessionState: ObservableObject {
    @Published var immersiveMode = false
    @Published var section: AppSection = .library
    /// Source en cours de navigation dans la Vidéothèque (nil = toutes les vidéos).
    @Published var browsingSource: LibrarySource?
    /// Pile de dossiers du navigateur (dernier = dossier courant).
    @Published var folderPath: [URL] = []
    /// Dossier intelligent affiché (nil = vue standard : grille ou navigateur).
    @Published var smartFolder: SmartFolder?
}
```

### Patch 6 — Barre latérale : section « BIBLIOTHÈQUE » + Vidéothèque remise à zéro
**Où** : `SidebarView.body`, items Vidéothèque → SOURCES (l.2901–2918)

**old_string**
```swift
            // Section Vidéothèque : toutes les vidéos.
            itemButton(title: "Vidéothèque", icon: "square.grid.2x2.fill",
                       selected: session.section == .library && session.browsingSource == nil) {
                session.section = .library
                session.browsingSource = nil
            }

            // Sources (dossiers Mac / disque externe).
            if !library.sources.isEmpty {
                Text("SOURCES")
```

**new_string**
```swift
            // Section Vidéothèque : toutes les vidéos.
            itemButton(title: "Vidéothèque", icon: "square.grid.2x2.fill",
                       selected: session.section == .library && session.browsingSource == nil && session.smartFolder == nil) {
                session.section = .library
                session.browsingSource = nil
                session.smartFolder = nil
            }

            // Dossiers intelligents : vues calculées à la volée depuis les
            // assets (récemment ajoutés, favoris ★, reprise de lecture).
            Text("BIBLIOTHÈQUE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.horizontal, 14)
            ForEach(SmartFolder.allCases) { smart in
                smartFolderRow(smart)
            }

            // Sources (dossiers Mac / disque externe).
            if !library.sources.isEmpty {
                Text("SOURCES")
```

### Patch 7 — Barre latérale : `sourceRow` remet `smartFolder` à zéro
**Où** : `SidebarView.sourceRow` (l.2982–2986)

**old_string**
```swift
        return Button {
            session.section = .library
            session.browsingSource = source
            session.folderPath = [source.url]
        } label: {
```

**new_string**
```swift
        return Button {
            session.section = .library
            session.browsingSource = source
            session.smartFolder = nil
            session.folderPath = [source.url]
        } label: {
```

### Patch 8 — Barre latérale : `smartFolderRow(_:)`
**Où** : après `sourceRow(_:)` (l.3009–3011)

**old_string**
```swift
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help(source.url.path)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
```

**new_string**
```swift
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help(source.url.path)
    }

    /// Entrée de dossier intelligent : affiche la grille calculée associée.
    private func smartFolderRow(_ smart: SmartFolder) -> some View {
        let selected = session.section == .library
            && session.browsingSource == nil
            && session.smartFolder == smart
        return Button {
            session.section = .library
            session.browsingSource = nil
            session.smartFolder = smart
        } label: {
            HStack(spacing: 8) {
                Image(systemName: smart.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? accent : Color.secondary)
                    .frame(width: 16)
                Text(smart.title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.11) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
```

### Patch 9 — `ContentView.librarySection` : aiguillage vers `SmartGridView` + calcul des assets
**Où** : `ContentView.librarySection` (l.1967–1981)

**old_string**
```swift
    @ViewBuilder
    private var librarySection: some View {
        if session.browsingSource == nil {
            if library.assets.isEmpty {
                EmptyStateView()
            } else {
                LibraryView { _ in
                    withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
                    library.engine.play()
                }
            }
        } else if let source = session.browsingSource {
            FolderBrowserView(source: source)
        }
    }
```

**new_string**
```swift
    @ViewBuilder
    private var librarySection: some View {
        if let smart = session.smartFolder {
            SmartGridView(title: smart.title,
                          assets: smartAssets(for: smart),
                          showsResumeBadge: smart == .resume) { _ in
                withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
                library.engine.play()
            }
        } else if session.browsingSource == nil {
            if library.assets.isEmpty {
                EmptyStateView()
            } else {
                LibraryView { _ in
                    withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
                    library.engine.play()
                }
            }
        } else if let source = session.browsingSource {
            FolderBrowserView(source: source)
        }
    }

    /// Assets du dossier intelligent demandé. Réévalué à chaque rendu : les
    /// favoris et les positions de lecture sont publiés par la bibliothèque.
    private func smartAssets(for smart: SmartFolder) -> [VideoAsset] {
        switch smart {
        case .recent:
            // Top 50 des vidéos ajoutées le plus récemment.
            return library.assets
                .sorted { $0.dateAdded > $1.dateAdded }
                .prefix(50)
                .map { $0 }
        case .favorites:
            return library.assets.filter { $0.isFavorite }
        case .resume:
            // Vidéos dont la position de lecture sauvegardée dépasse 15 s.
            return library.assets.filter { library.playbackPosition(for: $0.url) > 15 }
        }
    }
```

### Patch 10 — `LibraryCard` : paramètre `resumeText`
**Où** : déclaration de `LibraryCard` (l.3378–3382)

**old_string**
```swift
struct LibraryCard: View {

    @EnvironmentObject private var library: VideoLibrary
    let asset: VideoAsset
    var onDoubleClick: () -> Void = {}
```

**new_string**
```swift
struct LibraryCard: View {

    @EnvironmentObject private var library: VideoLibrary
    let asset: VideoAsset
    /// Badge de reprise (« Repris 3:24 ») affiché sur la vignette, si présent.
    var resumeText: String? = nil
    var onDoubleClick: () -> Void = {}
```

### Patch 11 — `LibraryCard` : badge « Repris m:ss » sur la vignette
**Où** : fin du ZStack vignette de `LibraryCard` (l.3414–3429)

**old_string**
```swift
                if hovering {
                    Button {
                        library.removeAsset(asset)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer de la bibliothèque")
                    .help("Retirer de la bibliothèque")
                }
            }
```

**new_string**
```swift
                if hovering {
                    Button {
                        library.removeAsset(asset)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer de la bibliothèque")
                    .help("Retirer de la bibliothèque")
                }
                // Badge « Repris m:ss » (dossier intelligent « Reprendre »).
                if let resumeText {
                    Text(resumeText)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
```

### Patch 12 — `LibraryCard` : étoile ★ dans la ligne durée
**Où** : colonne texte de `LibraryCard` (l.3430–3436)

**old_string**
```swift
            Text(asset.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(timeString(asset.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
```

**new_string**
```swift
            Text(asset.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(timeString(asset.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                favoriteButton
            }
```

### Patch 13 — `LibraryCard` : bouton étoile
**Où** : après `thumb` de `LibraryCard` (l.3465–3482)

**old_string**
```swift
    @ViewBuilder
    private var thumb: some View {
        if let image = asset.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.22, green: 0.22, blue: 0.27), Color(red: 0.10, green: 0.10, blue: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
```

**new_string**
```swift
    @ViewBuilder
    private var thumb: some View {
        if let image = asset.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.22, green: 0.22, blue: 0.27), Color(red: 0.10, green: 0.10, blue: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// Étoile de favori : bascule « À regarder » (persistée par chemin).
    private var favoriteButton: some View {
        Button {
            library.toggleFavorite(asset)
        } label: {
            Image(systemName: asset.isFavorite ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(asset.isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
        .help(asset.isFavorite ? "Retirer des favoris (À regarder)" : "Ajouter aux favoris (À regarder)")
    }
```

### Patch 14 — `SmartGridView` : grille générique des 3 dossiers intelligents
**Où** : avant `// MARK: - Réglages (panneau modal)` (l.3491–3495)

**old_string**
```swift
// MARK: - Réglages (panneau modal)

/// Panneau « Réglages » façon lecteur pro : colonne de navigation à gauche
/// (catégorie Vidéo), options à droite avec coche sur la valeur active.
struct SettingsSheet: View {
```

**new_string**
```swift
// MARK: - Dossiers intelligents

/// Grille générique des dossiers intelligents (« Récemment ajoutés »,
/// « À regarder », « Reprendre ») : réutilise les cartes de la bibliothèque
/// (vignettes, sélection ⌘+clic, double-clic, étoile ★) sur un sous-ensemble
/// d'assets — aucune logique dupliquée entre les trois vues.
struct SmartGridView: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    let title: String
    let assets: [VideoAsset]
    /// Affiche le badge « Repris m:ss » sur les cartes (vue « Reprendre »).
    var showsResumeBadge = false
    var onLaunch: ([VideoAsset]) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(assets.count) vidéo\(assets.count > 1 ? "s" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots) à l'écran")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Lancer la sélection (Entrée)")
                }
                Text("⌘+clic : multi-sélection · Double-clic : lancer directement")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in
                        LibraryCard(asset: asset,
                                    resumeText: showsResumeBadge ? resumeText(for: asset) : nil,
                                    onDoubleClick: {
                            library.selectOnly(asset)
                            launchSelection()
                        })
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
    }

    /// Badge « Repris m:ss » si une position de lecture est enregistrée.
    private func resumeText(for asset: VideoAsset) -> String? {
        let position = library.playbackPosition(for: asset.url)
        guard position > 15 else { return nil }
        return "Repris " + timeString(CMTime(seconds: position, preferredTimescale: 600))
    }

    /// Place la sélection (max 5, ordre des clics) dans les emplacements A→E,
    /// vide la sélection et lance la lecture synchronisée.
    private func launchSelection() {
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        library.launchSelected()
        onLaunch(assets)
    }
}

// MARK: - Réglages (panneau modal)

/// Panneau « Réglages » façon lecteur pro : colonne de navigation à gauche
/// (catégorie Vidéo), options à droite avec coche sur la valeur active.
struct SettingsSheet: View {
```

### Patch 25 — `BrowserVideoCard` : bouton étoile (helper)
**Où** : après `cachedDuration` de `BrowserVideoCard` (l.3219–3223)

**old_string**
```swift
    /// Durée affichée depuis le cache de métadonnées (sans ouvrir l'AVAsset).
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }
```

**new_string**
```swift
    /// Durée affichée depuis le cache de métadonnées (sans ouvrir l'AVAsset).
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }

    /// Étoile de favori : bascule « À regarder » (persistée par chemin).
    private func favoriteButton(_ asset: VideoAsset) -> some View {
        Button {
            library.toggleFavorite(asset)
        } label: {
            Image(systemName: asset.isFavorite ? "star.fill" : "star")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(asset.isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
        .help(asset.isFavorite ? "Retirer des favoris (À regarder)" : "Ajouter aux favoris (À regarder)")
    }
```

### Patch 26 — `BrowserVideoCard` : étoile ★ dans la ligne durée
**Où** : colonne texte de `BrowserVideoCard` (l.3265–3271)

**old_string**
```swift
            if let duration = cachedDuration, duration.isNumeric, duration.seconds > 0 {
                Text(timeString(duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
```

**new_string**
```swift
            HStack(spacing: 6) {
                if let duration = cachedDuration, duration.isNumeric, duration.seconds > 0 {
                    Text(timeString(duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                if let asset {
                    favoriteButton(asset)
                }
            }
        }
        .padding(8)
```

---

## FEATURE 1 — Recherche + tri + mode liste

### Patch 15 — `FolderBrowserView` : états, filtrage, tri et actions liste
**Où** : propriétés @State de `FolderBrowserView` (l.3040–3045)

**old_string**
```swift
    @State private var folders: [URL] = []
    @State private var videos: [URL] = []

    private var currentURL: URL { session.folderPath.last ?? source.url }
    private var showThumbnails: Bool { videos.count <= Self.thumbnailLimit }
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 14)]
```

**new_string**
```swift
    /// Ordre de tri des vidéos du navigateur.
    private enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Nom"
        case date = "Date"
        case duration = "Durée"
        var id: String { rawValue }
    }

    /// Mode d'affichage : grille (vignettes) ou liste (lignes compactes).
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case grid = "Grille"
        case list = "Liste"
        var id: String { rawValue }
    }

    @State private var folders: [URL] = []
    @State private var videos: [URL] = []
    /// Texte de recherche : filtre instantané par titre, insensible à la
    /// casse et aux diacritiques.
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var displayMode: DisplayMode = .grid

    private var currentURL: URL { session.folderPath.last ?? source.url }
    private var showThumbnails: Bool { videos.count <= Self.thumbnailLimit }
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 14)]

    /// Vidéos filtrées par la recherche puis triées selon le critère choisi.
    /// Appliqué AVANT l'affichage : les vignettes de la grille restent
    /// inchangées (cache par URL).
    private var filteredVideos: [URL] {
        var result = videos
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !query.isEmpty {
            result = result.filter {
                $0.deletingPathExtension().lastPathComponent
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query)
            }
        }
        switch sortOrder {
        case .name:
            result.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        case .date:
            result.sort { modificationDate($0) > modificationDate($1) }
        case .duration:
            result.sort { cachedDuration($0) > cachedDuration($1) }
        }
        return result
    }

    /// Date de modification d'une vidéo (tri « Date »).
    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Durée mémoïsée d'une vidéo (tri « Durée », sans ouvrir l'AVAsset).
    private func cachedDuration(_ url: URL) -> Double {
        MetadataCache.shared.get(for: url)?.duration ?? 0
    }

    /// Clic simple / ⌘+clic sur une vidéo (mêmes règles que la grille).
    private func selectVideo(_ url: URL) {
        guard let asset = library.ensureInLibrary(url) else { return }
        if NSEvent.modifierFlags.contains(.command) {
            library.toggleSelection(asset)
        } else {
            library.selectOnly(asset)
        }
    }

    /// Double-clic : lance immédiatement cette vidéo seule.
    private func launchVideo(_ url: URL) {
        guard let asset = library.ensureInLibrary(url) else { return }
        library.selectOnly(asset)
        library.launchSelected()
        withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
    }
```

### Patch 16 — `FolderBrowserView` : barre d'outils (recherche/tri/toggle) + grille/liste
**Où** : en-tête + contenu de `FolderBrowserView.body` (l.3100–3118)

**old_string**
```swift
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(folders, id: \.self) { folder in
                        folderTile(folder)
                    }
                    ForEach(videos, id: \.self) { video in
                        BrowserVideoCard(url: video, showThumbnail: showThumbnails)
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
        .task(id: currentURL) { await loadContents() }
    }
```

**new_string**
```swift
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Barre d'outils : recherche, tri et bascule Grille/Liste.
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Rechercher…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .frame(width: 170)

                if !searchText.isEmpty {
                    Text("\(filteredVideos.count) résultat\(filteredVideos.count > 1 ? "s" : "")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Picker("Trier", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 96)
                .help("Trier les vidéos")

                Picker("Affichage", selection: $displayMode) {
                    Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                    Image(systemName: "list.bullet").tag(DisplayMode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 92)
                .help("Grille / Liste")

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if displayMode == .grid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(folders, id: \.self) { folder in
                            folderTile(folder)
                        }
                        ForEach(filteredVideos, id: \.self) { video in
                            BrowserVideoCard(url: video, showThumbnail: showThumbnails)
                        }
                    }
                    .padding(14)
                }
            } else {
                // Mode liste : lignes compactes sans vignettes (économie pour
                // les gros dossiers) — mêmes interactions que la grille.
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders, id: \.self) { folder in
                            folderListRow(folder)
                        }
                        ForEach(filteredVideos, id: \.self) { video in
                            VideoListRow(url: video,
                                         onSelect: { selectVideo(video) },
                                         onLaunch: { launchVideo(video) })
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color.black.opacity(0.25))
        .task(id: currentURL) { await loadContents() }
    }
```

### Patch 17 — `FolderBrowserView` : ligne de dossier en mode liste
**Où** : après `folderTile(_:)` (l.3142–3146)

**old_string**
```swift
        .buttonStyle(.plain)
        .help(folder.path)
    }

    /// Liste à la demande du dossier courant (rapide : fichiers locaux).
    private func loadContents() async {
```

**new_string**
```swift
        .buttonStyle(.plain)
        .help(folder.path)
    }

    /// Ligne de dossier en mode Liste (icône + nom + chevron).
    private func folderListRow(_ folder: URL) -> some View {
        Button {
            session.folderPath.append(folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accent.opacity(0.85))
                    .frame(width: 16)
                Text(folder.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.03)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(folder.path)
    }

    /// Liste à la demande du dossier courant (rapide : fichiers locaux).
    private func loadContents() async {
```

### Patch 18 — `VideoListRow` : ligne vidéo compacte (sans vignette)
**Où** : avant `BrowserVideoCard` (l.3199–3201)

**old_string**
```swift
/// Carte vidéo du navigateur de dossiers : capture en cache, badge
/// d'emplacement si déjà chargée, coche de sélection multi.
struct BrowserVideoCard: View {
```

**new_string**
```swift
/// Ligne compacte du mode Liste du navigateur de dossiers : titre, durée,
/// date et taille SANS vignette (économie pour les gros dossiers). Mêmes
/// interactions que la grille : ⌘+clic = sélectionner, double-clic = lancer.
private struct VideoListRow: View {

    @EnvironmentObject private var library: VideoLibrary
    let url: URL
    var onSelect: () -> Void = {}
    var onLaunch: () -> Void = {}

    private var asset: VideoAsset? { library.assets.first { $0.url == url } }
    private var selected: Bool {
        guard let asset else { return false }
        return library.selectedOrder.contains(asset.id)
    }
    private var slotLetter: String? {
        guard let asset else { return nil }
        return library.slots.firstIndex { $0?.id == asset.id }.map { slotLetters[$0] }
    }
    private var cachedDuration: CMTime? {
        guard let meta = MetadataCache.shared.get(for: url) else { return nil }
        return CMTime(seconds: meta.duration, preferredTimescale: 600)
    }
    private var dateText: String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        return Self.dateFormatter.string(from: date)
    }
    private var sizeText: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let letter = slotLetter {
                Text(letter)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(accent))
            }
            Spacer(minLength: 8)
            if let duration = cachedDuration, duration.isNumeric, duration.seconds > 0 {
                Text(timeString(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            Text(dateText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            Text(sizeText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.white.opacity(0.09) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onLaunch() }
        .help("Clic : sélectionner · ⌘+clic : multi-sélection · Double-clic : lancer")
    }
}

/// Carte vidéo du navigateur de dossiers : capture en cache, badge
/// d'emplacement si déjà chargée, coche de sélection multi.
struct BrowserVideoCard: View {
```

### Patch 19 — `LibraryView` : états + `filteredAssets` (recherche + tri)
**Où** : déclaration de `LibraryView` (l.3313–3317)

**old_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    var onLaunch: ([VideoAsset]) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 14)]
```

**new_string**
```swift
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    var onLaunch: ([VideoAsset]) -> Void = { _ in }

    /// Ordre de tri de la bibliothèque.
    private enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Nom"
        case date = "Date"
        case duration = "Durée"
        var id: String { rawValue }
    }

    /// Texte de recherche : filtre instantané par titre (insensible à la
    /// casse et aux diacritiques).
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 14)]

    /// Assets filtrés par la recherche puis triés (nom, date d'ajout, durée).
    /// Appliqué AVANT l'affichage : les vignettes restent inchangées.
    private var filteredAssets: [VideoAsset] {
        var result = library.assets
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !query.isEmpty {
            result = result.filter {
                $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query)
            }
        }
        switch sortOrder {
        case .name:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date:
            result.sort { $0.dateAdded > $1.dateAdded }
        case .duration:
            result.sort { $0.duration.seconds > $1.duration.seconds }
        }
        return result
    }
```

### Patch 20 — `LibraryView` : en-tête sur deux rangées (compteur + Lancer / recherche + tri)
**Où** : corps de `LibraryView` (l.3319–3364)

**old_string**
```swift
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(library.assets.count) vidéo\(library.assets.count > 1 ? "s" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots) à l'écran")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Lancer la sélection (Entrée)")
                }
                Text("⌘+clic : multi-sélection · Double-clic : lancer directement")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(library.assets) { asset in
                        LibraryCard(asset: asset, onDoubleClick: {
                            library.selectOnly(asset)
                            launchSelection()
                        })
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
    }
```

**new_string**
```swift
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(filteredAssets.count) vidéo\(filteredAssets.count > 1 ? "s" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots) à l'écran")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Lancer la sélection (Entrée)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Rechercher…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .frame(width: 170)
                Picker("Trier", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 96)
                .help("Trier les vidéos")
                Spacer()
                Text("⌘+clic : multi-sélection · Double-clic : lancer directement")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredAssets) { asset in
                        LibraryCard(asset: asset, onDoubleClick: {
                            library.selectOnly(asset)
                            launchSelection()
                        })
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
    }
```

---

## FEATURE 3 — Détection automatique des nouveaux fichiers

### Patch 21 — `VideoLibrary` : scan par source + garde isScanning + watcher 5 s
**Où** : `scanSources()` (l.261–289) — remplacé par le bloc complet de surveillance

**old_string**
```swift
    /// Scanne tous les dossiers sources actifs (en arrière-plan, priorité
    /// utilitaire) et ingère les vidéos trouvées sans occuper les slots.
    func scanSources() {
        let active = sources.filter { $0.enabled }
        for source in active {
            let url = source.url
            let sourceID = source.id
            Task.detached(priority: .utility) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var found: [URL] = []
                let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
                if let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        guard found.count < 5000 else { break }
                        guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                              values.isRegularFile == true else { continue }
                        if !Self.videoFiles(from: [fileURL]).isEmpty { found.append(fileURL) }
                    }
                }
                let result = found
                await MainActor.run {
                    self.add(urls: result, source: sourceID)
                }
            }
        }
    }
```

**new_string**
```swift
    // MARK: Surveillance automatique des sources

    /// Empreinte du dossier source (date de modification) à la dernière
    /// vérification : un changement déclenche un rescan incrémental.
    private var sourceFingerprints: [UUID: Date] = [:]
    /// Vrai tant qu'au moins un scan de source est en cours (évite les
    /// double scans déclenchés par la surveillance ou l'interface).
    @Published private(set) var isScanning = false
    private var activeScans = 0
    /// Tâche de polling des sources : s'arrête d'elle-même quand la
    /// bibliothèque est libérée (capture faible).
    private var sourceWatcherTask: Task<Void, Never>?

    /// Scanne tous les dossiers sources actifs (en arrière-plan, priorité
    /// utilitaire) et ingère les vidéos trouvées sans occuper les slots.
    func scanSources() {
        guard !isScanning else { return }
        for source in sources where source.enabled {
            scanSource(source)
        }
    }

    /// Scanne UNE source en arrière-plan, puis met à jour son empreinte.
    private func scanSource(_ source: LibrarySource) {
        activeScans += 1
        isScanning = true
        let url = source.url
        let sourceID = source.id
        Task.detached(priority: .utility) { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var found: [URL] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
            if let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    guard found.count < 5000 else { break }
                    guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    if !Self.videoFiles(from: [fileURL]).isEmpty { found.append(fileURL) }
                }
            }
            let result = found
            await MainActor.run {
                guard let self else { return }
                self.add(urls: result, source: sourceID)
                self.sourceFingerprints[sourceID] = Self.modificationDate(of: url)
                self.activeScans -= 1
                if self.activeScans == 0 { self.isScanning = false }
            }
        }
    }

    /// Lance le moniteur : toutes les 5 s (si une source active existe et
    /// qu'aucun scan n'est en cours), compare les dates de modification des
    /// dossiers sources et rescanne ceux qui ont changé. Léger : une stat par
    /// source sur le main thread ; le scan reste en arrière-plan. La lecture
    /// n'est jamais interrompue (ajout sans occupation de slot).
    func startSourceWatcher() {
        guard sourceWatcherTask == nil else { return }
        sourceWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkSourcesForChanges()
            }
        }
    }

    /// Compare les sources actives à leurs empreintes et rescanne les
    /// dossiers modifiés (jamais pendant un scan en cours).
    private func checkSourcesForChanges() {
        guard !isScanning else { return }
        let active = sources.filter { $0.enabled }
        guard !active.isEmpty else {
            sourceFingerprints.removeAll()
            return
        }
        for source in active {
            let current = Self.modificationDate(of: source.url)
            guard let known = sourceFingerprints[source.id] else {
                // Source jamais échantillonnée (ex. réactivée pendant un
                // scan) : on enregistre l'empreinte ET on scanne.
                sourceFingerprints[source.id] = current
                scanSource(source)
                continue
            }
            // Tolérance de 1,5 s : évite les rescan en rafale quand le
            // système de fichiers arrondit les dates de modification.
            if abs(current.timeIntervalSince(known)) > 1.5 {
                sourceFingerprints[source.id] = current
                scanSource(source)
            }
        }
    }

    /// Date de modification d'un dossier (empreinte de surveillance).
    /// nonisolated : appelable depuis la fin d'un scan (Task détachée).
    nonisolated private static func modificationDate(of url: URL) -> Date {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
```

### Patch 22 — `toggleSource` : empreinte oubliée à la (dés)activation
**Où** : `VideoLibrary.toggleSource(id:)` (l.240–249)

**old_string**
```swift
    func toggleSource(id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled.toggle()
        persistSources()
        if sources[index].enabled {
            scanSources()
        } else {
            removeSourceVideos(id: id)
        }
    }
```

**new_string**
```swift
    func toggleSource(id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled.toggle()
        persistSources()
        // Empreinte oubliée : à la réactivation, le moniteur détectera le
        // moindre changement (et le scan ci-dessous la rafraîchit).
        sourceFingerprints.removeValue(forKey: id)
        if sources[index].enabled {
            scanSources()
        } else {
            removeSourceVideos(id: id)
        }
    }
```

### Patch 23 — `removeSource` : empreinte oubliée
**Où** : `VideoLibrary.removeSource(id:)` (l.223–227)

**old_string**
```swift
    func removeSource(id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        persistSources()
```

**new_string**
```swift
    func removeSource(id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        persistSources()
        sourceFingerprints.removeValue(forKey: id)
```

---

## FEATURE 4 — Drag & drop Finder → bloc

### Patch 24 — `StagePane` : onDrop UTType.fileURL, remplacement de slot, anneau visuel
**Où** : corps + états de `StagePane` (l.4017–4039)

**old_string**
```swift
    @State private var speakerHover = false
    @State private var clearHover = false
    @State private var paneZoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            if let asset = library.slots[slot] {
                videoPane(asset: asset)
            } else {
                emptyPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(library.selectedSlot == slot ? accent : .clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: library.selectedSlot)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { library.select(slot: slot) }
        .transition(.opacity.combined(with: .scale(0.96)))
    }
```

**new_string**
```swift
    @State private var speakerHover = false
    @State private var clearHover = false
    @State private var paneZoom: CGFloat = 1
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let asset = library.slots[slot] {
                videoPane(asset: asset)
            } else {
                emptyPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(library.selectedSlot == slot ? accent : .clear, lineWidth: 2)
        )
        .overlay(
            // Anneau de dépôt : retour visuel pendant un glisser-déposer Finder.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? accent.opacity(0.9) : .clear, lineWidth: 2.5)
        )
        .animation(.easeInOut(duration: 0.15), value: library.selectedSlot)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { library.select(slot: slot) }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers, into: slot)
            return true
        }
        .transition(.opacity.combined(with: .scale(0.96)))
    }

    // MARK: Dépôt de fichiers (Finder)

    /// Extrait les URLs des providers du dépôt et les applique au slot.
    /// Chargement asynchrone des providers : la suite s'exécute sur le
    /// thread principal. StagePane étant une struct, on capture la référence
    /// à la bibliothèque (classe, durée de vie = application) plutôt que self.
    private func handleDrop(_ providers: [NSItemProvider], into targetSlot: Int) {
        let library = self.library
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                } else if let found = item as? URL {
                    url = found
                } else {
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    // Accès sandbox : requis pour les URLs venues du Finder
                    // quand l'app est sandboxée ; sans effet (false) sinon.
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    guard !VideoLibrary.videoFiles(from: [url]).isEmpty,
                          let asset = library.ensureInLibrary(url) else { return }
                    // Remplace le slot ; engine.reconfigure est appelé par
                    // VideoLibrary.assign (via syncEngine()).
                    library.assign(asset, to: targetSlot)
                }
            }
        }
    }
```

---

## VÉRIFICATIONS

Chaque `old_string` a été relu **mot pour mot** dans le fichier (`read_file`, jamais modifié) :

| Patch | Ancrage unique (début du old_string) | Lignes confirmées |
|---|---|---|
| P1 | `final class VideoAsset: Identifiable {` | 86–100 |
| P2 | `@Published var slots: [VideoAsset?] = Array(...)` | 108–110 |
| P3 | `init() {` (VideoLibrary, bloc `engine.onItemEnded`) | 128–134 |
| P4 | `/// Garantit qu'un fichier est présent dans la bibliothèque` | 443–447 |
| P5 | `/// Section affichée dans la fenêtre principale.` | 1539–1553 |
| P6 | `// Section Vidéothèque : toutes les vidéos.` | 2901–2918 |
| P7 | `session.folderPath = [source.url]` (sourceRow) | 2982–2986 |
| P8 | `.help(source.url.path)` + `private func iconButton` | 3009–3011 |
| P9 | `@ViewBuilder private var librarySection` | 1967–1981 |
| P10 | `struct LibraryCard: View {` | 3378–3382 |
| P11 | `if hovering {` (bouton retrait, font size 8) | 3414–3429 |
| P12 | `Text(asset.title)` (font 11, truncationMode .middle) | 3430–3436 |
| P13 | `@ViewBuilder private var thumb` (font size 22) | 3465–3482 |
| P14 | `// MARK: - Réglages (panneau modal)` | 3491–3495 |
| P15 | `@State private var folders: [URL] = []` | 3040–3045 |
| P16 | `.padding(.horizontal, 14)` + `ScrollView { LazyVGrid` (folders) | 3100–3118 |
| P17 | `.help(folder.path)` + `private func loadContents` | 3142–3146 |
| P18 | `/// Carte vidéo du navigateur de dossiers` | 3199–3201 |
| P19 | `var onLaunch: ([VideoAsset]) -> Void = { _ in }` + columns 140 | 3313–3317 |
| P20 | `var body: some View { VStack(spacing: 0) { HStack(spacing: 10) { Text("\(library.assets.count)` | 3319–3364 |
| P21 | `/// Scanne tous les dossiers sources actifs` | 261–289 |
| P22 | `func toggleSource(id: UUID) {` | 240–249 |
| P23 | `func removeSource(id: UUID) {` | 223–227 |
| P24 | `@State private var speakerHover = false` (StagePane) | 4017–4039 |
| P25 | `/// Durée affichée depuis le cache de métadonnées` (BrowserVideoCard) | 3219–3223 |
| P26 | `if let duration = cachedDuration, duration.isNumeric` | 3265–3271 |

**Unicité vérifiée** (search_files) : pas de `isScanning`, `dateAdded`, `isFavorite`, `favorite`, `playback.positions` préexistants dans le fichier ; `scanSources()` appelé à 4 endroits (l.220, 245, 343, 3705 — signature conservée, compatibles) ; `private var slotLetter` de `AssetChip` (l.2682) et `LibraryCard` (l.3485) sont identiques → P13 utilise `thumb` (font 22, unique) comme ancre, jamais `slotLetter`.

## RISQUES

1. **Favoris par chemin standardisé** (écart assumé au libellé « par id ») : `VideoAsset.id` est éphémère (régénéré à la restauration), les UUID auraient perdu les favoris au redémarrage. La spec autorisait `[String]` ; cohérent avec la clé des positions (`playback.positions`).
2. **Concurrence du watcher** : `isScanning` + compteur `activeScans` (MainActor uniquement, pas de race). Premier tick à +5 s : si le scan de `restoreLibrary` est encore en cours, `checkSourcesForChanges` est court-circuité par `guard !isScanning`. Si l'utilisateur réactive une source pendant un scan, l'empreinte est absente → le tick suivant scanne (branche « jamais échantillonnée »).
3. **Lecture en cours** : un rescan incrémental n'occupe aucun slot et n'appelle jamais `engine.*` — la lecture n'est pas interrompue (conforme à l'existant `add(urls:source:)`).
4. **`Task.detached` + `MainActor.run` avec `[weak self]`** : `guard let self` (shorthand Swift 5.7+) ; si la bibliothèque est libérée pendant un scan, le résultat est simplement ignoré. `sourceWatcherTask` en capture faible : la boucle s'arrête seule au `guard let self`.
5. **Drop pane vs drop fenêtre** : SwiftUI livre le drop au plus profond des vues acceptantes → panneau = remplacement de slot ; ailleurs (fond de scène, transport) = `dropDestination` racine existant (l.1925) → `add(urls:)` (aucun patch, comportement demandé déjà en place). Pas de double ingestion : `add` déduplique par URL.
6. **StagePane est une struct** : pas de `[weak self]` possible dans les complétions de `loadItem` — capture de la référence `library` (classe, durée de vie application) à la place. `handleDrop` retourne `true` même si aucun fichier vidéo (le drop est consommé par le panneau) — comportement standard macOS.
7. **`favoritesRevision`** : écrit mais jamais lu directement (le @Published émet `objectWillChange` à chaque incrément — c'est le mécanisme de rafraîchissement voulu). Pas de boucle : émission uniquement sur clic utilisateur.
8. **Coût UI** : `filteredVideos`/`filteredAssets` recalculés à chaque rendu — tri + filtre en mémoire sur des listes ≤ quelques milliers d'éléments, `MetadataCache` en lookup dict ; acceptable. `VideoListRow` fait 2 `resourceValues` (stat) par ligne — coût négligeable, LazyVStack.
9. **Picker segmenté avec images** : supporté sur macOS 14 ; repli naturel si l'icône manque (SF Symbols standard).
