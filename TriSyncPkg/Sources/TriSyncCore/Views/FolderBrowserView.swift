import SwiftUI

/// Navigateur arborescent de dossiers sources (Mac, disques externes).
public struct FolderBrowserView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    public let source: LibrarySource

    private enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Nom"
        case date = "Date"
        case duration = "Durée"
        var id: String { rawValue }
    }

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case grid = "Grille"
        case list = "Liste"
        var id: String { rawValue }
    }

    @State private var folders: [URL] = []
    @State private var videos: [URL] = []
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    @State private var displayMode: DisplayMode = .grid

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 152), spacing: 12)]
    private var currentURL: URL { session.folderPath.last ?? source.url }
    private var showThumbnails: Bool { videos.count <= 200 }

    public init(source: LibrarySource) {
        self.source = source
    }

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
            result.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .date:
            result.sort { modificationDate($0) > modificationDate($1) }
        case .duration:
            result.sort { cachedDuration($0) > cachedDuration($1) }
        }
        return result
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func cachedDuration(_ url: URL) -> Double {
        MetadataCache.shared.get(for: url)?.duration ?? 0
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if displayMode == .grid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(folders, id: \.self) { folderTile($0) }
                        ForEach(filteredVideos, id: \.self) { BrowserVideoCard(url: $0, showThumbnail: showThumbnails) }
                    }
                    .padding(14)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders, id: \.self) { folderListRow($0) }
                        ForEach(filteredVideos, id: \.self) { video in
                            VideoListRow(url: video, onSelect: { selectVideo(video) }, onLaunch: { launchVideo(video) })
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color.black.opacity(0.25))
        .onAppear { scanCurrentFolder() }
        .onChange(of: session.folderPath) { _, _ in scanCurrentFolder() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if session.folderPath.count > 1 {
                Button {
                    session.folderPath.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.folderPath.count > 1 ? session.folderPath.last?.lastPathComponent ?? source.url.lastPathComponent : source.url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                Text(currentURL.path)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !library.selectedOrder.isEmpty {
                Button {
                    launchSelection()
                } label: {
                    Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(triAccent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Rechercher…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit {}
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            .frame(width: 180)

            Picker("Trier", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 96)

            Picker("Affichage", selection: $displayMode) {
                Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                Image(systemName: "list.bullet").tag(DisplayMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 92)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func folderTile(_ folder: URL) -> some View {
        Button {
            session.folderPath.append(folder)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(triAccent.opacity(0.85))
                Text(folder.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        }
        .buttonStyle(.plain)
    }

    private func folderListRow(_ folder: URL) -> some View {
        Button {
            session.folderPath.append(folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(triAccent)
                Text(folder.lastPathComponent)
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
        }
        .buttonStyle(.plain)
    }

    private func selectVideo(_ url: URL) {
        guard let asset = library.ensureInLibrary(url) else { return }
        if NSEvent.modifierFlags.contains(.command) {
            library.toggleSelection(asset)
        } else {
            library.selectOnly(asset)
        }
    }

    private func launchVideo(_ url: URL) {
        guard let asset = library.ensureInLibrary(url) else { return }
        library.selectOnly(asset)
        library.launchSelected()
        withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
    }

    private func launchSelection() {
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        library.launchSelected()
        withAnimation(.easeInOut(duration: 0.25)) { session.section = .play }
    }

    private func scanCurrentFolder() {
        let url = currentURL
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { return }

            var foundFolders: [URL] = []
            var foundVideos: [URL] = []
            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true { foundFolders.append(item) }
                else if values?.isRegularFile == true && !VideoLibrary.videoFiles(from: [item]).isEmpty {
                    foundVideos.append(item)
                }
            }
            let f = foundFolders.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let v = foundVideos.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            await MainActor.run {
                self.folders = f
                self.videos = v
            }
        }
    }
}

/// Carte de vidéo dans le navigateur de dossiers.
public struct BrowserVideoCard: View {
    @EnvironmentObject private var library: VideoLibrary
    public let url: URL
    public var showThumbnail: Bool = true

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    public init(url: URL, showThumbnail: Bool = true) {
        self.url = url
        self.showThumbnail = showThumbnail
    }

    private var asset: VideoAsset? {
        library.assets.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })
    }

    private var selected: Bool {
        guard let asset else { return false }
        return library.selectedOrder.contains(asset.id)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if showThumbnail, let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 148)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 148)
                        .overlay(Image(systemName: "film").font(.system(size: 24)).foregroundStyle(.secondary))
                }

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(triAccent)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .padding(8)
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(isHovered ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? triAccent : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let asset = library.ensureInLibrary(url) else { return }
            if NSEvent.modifierFlags.contains(.command) {
                library.toggleSelection(asset)
            } else {
                library.selectOnly(asset)
            }
        }
        .onHover { isHovered = $0 }
        .task {
            guard showThumbnail else { return }
            thumbnail = await ThumbnailCache.shared.thumbnail(for: url, variant: .portrait)
        }
    }
}

/// Ligne d'affichage compacte d'une vidéo en mode liste.
public struct VideoListRow: View {
    public let url: URL
    public var onSelect: () -> Void = {}
    public var onLaunch: () -> Void = {}

    public init(url: URL, onSelect: @escaping () -> Void = {}, onLaunch: @escaping () -> Void = {}) {
        self.url = url
        self.onSelect = onSelect
        self.onLaunch = onLaunch
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(triAccent)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onLaunch() }
    }
}
