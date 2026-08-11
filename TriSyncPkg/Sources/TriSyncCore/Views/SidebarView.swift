import SwiftUI

/// Barre latérale principale de navigation macOS (Apple HIG).
public struct SidebarView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController

    public var onOpenImporter: () -> Void = {}
    public var onEnterImmersive: () -> Void = {}
    public var onOpenSettings: () -> Void = {}

    public init(
        onOpenImporter: @escaping () -> Void = {},
        onEnterImmersive: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.onOpenImporter = onOpenImporter
        self.onEnterImmersive = onEnterImmersive
        self.onOpenSettings = onOpenSettings
    }

    private var filledSlots: Int { library.slots.compactMap { $0 }.count }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            playSection
            bentoMenu
            masterMenu
            Divider().opacity(0.3).padding(.vertical, 4)
            librarySection
            smartFoldersSection
            sourcesSection
            Spacer()
            bottomActions
        }
        .padding(.horizontal, 10)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.35))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(triAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("TriSync")
                    .font(.system(size: 14, weight: .bold))
                Text("Lecture synchronisée")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private var playSection: some View {
        itemButton(
            title: "Lecture",
            icon: "play.rectangle.fill",
            badge: filledSlots > 0 ? "\(filledSlots)/\(VideoLibrary.maxSlots)" : nil,
            selected: session.section == .play
        ) {
            session.section = .play
        }
    }

    private var bentoMenu: some View {
        Menu {
            ForEach(settings.validPresets(forCount: filledSlots)) { preset in
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        settings.layoutPreset = preset
                    }
                } label: {
                    HStack {
                        Text(preset.rawValue)
                        if settings.layoutPreset == preset {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text("Composition")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var masterMenu: some View {
        Menu {
            Button {
                library.engine.setReferenceMode(.auto)
            } label: {
                HStack {
                    Text("Auto (premier bloc)")
                    if library.engine.referenceMode == .auto { Image(systemName: "checkmark") }
                }
            }
            Button {
                library.engine.setReferenceMode(.none)
            } label: {
                HStack {
                    Text("Aucun maître")
                    if library.engine.referenceMode == .none { Image(systemName: "checkmark") }
                }
            }

            Divider()

            ForEach(Array(library.slots.enumerated()), id: \.offset) { index, asset in
                if let asset {
                    Button {
                        library.engine.setManualMaster(index)
                    } label: {
                        HStack {
                            Text("Bloc \(slotLetters[index]) — \(asset.title)")
                            if library.engine.referenceMode == .manual && library.engine.manualReferenceSlot == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                    .frame(width: 16)
                Text("Maître : \(masterSummary)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var masterSummary: String {
        switch library.engine.referenceMode {
        case .auto: return "Auto"
        case .none: return "Aucun"
        case .manual:
            if let slot = library.engine.manualReferenceSlot { return "Bloc \(slotLetters[slot])" }
            return "Manuel"
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VIDÉOTHÈQUE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            itemButton(
                title: "Toutes les vidéos",
                icon: "square.grid.2x2.fill",
                badge: "\(library.assets.count)",
                selected: session.section == .library && session.browsingSource == nil && session.smartFolder == nil
            ) {
                session.section = .library
                session.browsingSource = nil
                session.smartFolder = nil
            }
        }
    }

    private var smartFoldersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SmartFolder.allCases) { folder in
                itemButton(
                    title: folder.title,
                    icon: folder.icon,
                    badge: smartCount(for: folder),
                    selected: session.section == .library && session.smartFolder == folder
                ) {
                    session.section = .library
                    session.browsingSource = nil
                    session.smartFolder = folder
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("SOURCES")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = openFolderPanel() { library.addSource(url: url) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Ajouter un dossier source")
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ForEach(library.sources) { source in
                HStack(spacing: 6) {
                    Button {
                        session.section = .library
                        session.browsingSource = source
                        session.smartFolder = nil
                        session.folderPath = [source.url]
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(source.enabled ? triAccent : .secondary)
                            Text(source.url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        library.toggleSource(id: source.id)
                    } label: {
                        Image(systemName: source.enabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(source.enabled ? triAccent : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(session.browsingSource?.id == source.id ? Color.white.opacity(0.1) : Color.clear)
                )
            }
        }
    }

    private var bottomActions: some View {
        VStack(spacing: 4) {
            Button {
                onOpenImporter()
            } label: {
                Label("Ajouter des vidéos…", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command])

            Button {
                onEnterImmersive()
            } label: {
                Label("Mode immersif", systemImage: "viewfinder")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button {
                onOpenSettings()
            } label: {
                Label("Réglages", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: [.command])
        }
        .padding(.horizontal, 8)
    }

    private func itemButton(title: String, icon: String, badge: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white : triAccent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.2 : 0.08)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? triAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func smartCount(for folder: SmartFolder) -> String? {
        switch folder {
        case .recent:
            let count = min(library.assets.count, 50)
            return count > 0 ? "\(count)" : nil
        case .favorites:
            _ = library.favoritesRevision
            let count = library.assets.filter { $0.isFavorite }.count
            return count > 0 ? "\(count)" : nil
        case .resume:
            let count = library.assets.filter { library.playbackPosition(for: $0.url) > 15 }.count
            return count > 0 ? "\(count)" : nil
        }
    }
}
