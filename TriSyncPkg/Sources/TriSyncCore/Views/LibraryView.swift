import SwiftUI
import CoreMedia

/// Grille principale de la vidéothèque type Infuse (recherche, tri, multi-sélection).
public struct LibraryView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    public var onLaunch: ([VideoAsset]) -> Void = { _ in }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Nom"
        case date = "Date"
        case duration = "Durée"
        var id: String { rawValue }
    }

    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .name
    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 152), spacing: 12)]

    public init(onLaunch: @escaping ([VideoAsset]) -> Void = { _ in }) {
        self.onLaunch = onLaunch
    }

    private var filteredAssets: [VideoAsset] {
        var result = library.assets
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !query.isEmpty {
            result = result.filter {
                $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(query)
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

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            searchBar
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

    private var topBar: some View {
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
                        .background(Capsule().fill(triAccent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var searchBar: some View {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .frame(width: 180)

            Picker("Trier", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 96)

            Spacer()
            Text("⌘+clic : multi-sélection · Double-clic : lancer")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func launchSelection() {
        let assets = library.selectedAssets
        guard !assets.isEmpty else { return }
        library.launchSelected()
        onLaunch(assets)
    }
}

/// Carte de vidéo dans la bibliothèque.
public struct LibraryCard: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    public let asset: VideoAsset
    public var resumeText: String? = nil
    public var onDoubleClick: () -> Void = {}

    @State private var hovering = false

    public init(
        asset: VideoAsset,
        resumeText: String? = nil,
        onDoubleClick: @escaping () -> Void = {}
    ) {
        self.asset = asset
        self.resumeText = resumeText
        self.onDoubleClick = onDoubleClick
    }

    private var selected: Bool {
        library.selectedOrder.contains(asset.id)
    }

    private var resumePosition: Double? {
        let position = engine.position(for: asset.url)
        return position > 15 ? position : nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumb
                    .frame(height: 148)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(triAccent)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let letter = slotLetter {
                    Text(letter)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(triAccent))
                        .padding(5)
                }

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
                    .padding(.top, 28)
                }

                if let position = resumePosition {
                    Text("Repris \(timeString(CMTime(seconds: position, preferredTimescale: 600)))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.9)))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }

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
        }
        .padding(8)
        .frame(height: 210)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? triAccent : Color.white.opacity(0.07), lineWidth: selected ? 2 : 1)
        )
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                library.toggleSelection(asset)
            } else {
                library.selectOnly(asset)
            }
        }
        .onTapGesture(count: 2) { onDoubleClick() }
        .onHover { hovering = $0 }
    }

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
    }

    private var slotLetter: String? {
        guard let index = library.slots.firstIndex(where: { $0?.id == asset.id }) else { return nil }
        return slotLetters[index]
    }
}
