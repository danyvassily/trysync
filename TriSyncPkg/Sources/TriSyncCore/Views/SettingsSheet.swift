import SwiftUI

/// Modal de réglages complet (affichage, ratio, cadrage, vitesse, sources).
public struct SettingsSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var library: VideoLibrary
    @Environment(\.dismiss) private var dismiss

    private enum Section: String, CaseIterable, Identifiable {
        case library = "Bibliothèque"
        case playback = "Lecture"
        case display = "Affichage"
        case ratio = "Ratio"
        case offset = "Décalage vertical"
        case scale = "Mise à l'échelle avancée"
        case speed = "Vitesse de lecture"
        var id: String { rawValue }
    }

    @State private var selection: Section = .display

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.35)
                detail
            }
        }
        .frame(width: 580, height: 460)
        .background(Color(red: 0.08, green: 0.08, blue: 0.095))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private var header: some View {
        ZStack {
            Text("Réglages")
                .font(.system(size: 14, weight: .bold))
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Options")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(triAccent)
                .padding(.bottom, 4)

            ForEach(Section.allCases) { section in
                sidebarRow(section)
            }
            Spacer()
        }
        .frame(width: 200, alignment: .leading)
        .padding(14)
    }

    private func sidebarRow(_ section: Section) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(section.rawValue)
                    .font(.system(size: 12, weight: selection == section ? .semibold : .regular))
                    .foregroundStyle(.white)
                Text(subtitle(for: section))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selection == section {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selection == section ? Color.white.opacity(0.09) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = section }
    }

    private func subtitle(for section: Section) -> String {
        switch section {
        case .library: return "\(library.sources.count) source\(library.sources.count > 1 ? "s" : "")"
        case .playback: return engine.autoReplace ? "Auto-remplacement" : "Statique"
        case .display: return settings.displayMode.rawValue
        case .ratio: return settings.ratioMode.rawValue
        case .offset: return settings.verticalOffset.rawValue
        case .scale: return settings.advancedScale.rawValue
        case .speed: return speedLabel(settings.playbackSpeed)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selection == .library {
                libraryDetail
            } else {
                Text(selection.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, 4)
                ForEach(options(for: selection), id: \.self) { option in
                    optionRow(option)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var libraryDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dossiers sources")
                .font(.system(size: 13, weight: .semibold))
            if library.sources.isEmpty {
                Text("Aucun dossier source configuré.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(library.sources) { source in
                HStack(spacing: 8) {
                    Button {
                        library.toggleSource(id: source.id)
                    } label: {
                        Image(systemName: source.enabled ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(source.enabled ? triAccent : .secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.url.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                        Text(source.url.path)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        library.removeSource(id: source.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            }

            HStack {
                Button {
                    if let url = openFolderPanel() { library.addSource(url: url) }
                } label: {
                    Label("Ajouter un dossier…", systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button {
                    library.scanSources()
                } label: {
                    Label("Analyser", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func options(for section: Section) -> [String] {
        switch section {
        case .library: return []
        case .playback: return ["Activé", "Désactivé"]
        case .display: return AppSettings.DisplayMode.allCases.map(\.rawValue)
        case .ratio: return AppSettings.RatioMode.allCases.map(\.rawValue)
        case .offset: return AppSettings.VerticalOffset.allCases.map(\.rawValue)
        case .scale: return AppSettings.AdvancedScale.allCases.map(\.rawValue)
        case .speed: return [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map(speedLabel)
        }
    }

    private func optionRow(_ option: String) -> some View {
        let isSelected = isSelected(option)
        return HStack {
            Text(option).font(.system(size: 12)).foregroundStyle(.white)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(triAccent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isSelected ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture { select(option) }
    }

    private func isSelected(_ option: String) -> Bool {
        switch selection {
        case .library: return false
        case .playback: return engine.autoReplace ? option == "Activé" : option == "Désactivé"
        case .display: return settings.displayMode.rawValue == option
        case .ratio: return settings.ratioMode.rawValue == option
        case .offset: return settings.verticalOffset.rawValue == option
        case .scale: return settings.advancedScale.rawValue == option
        case .speed: return speedLabel(settings.playbackSpeed) == option
        }
    }

    private func select(_ option: String) {
        switch selection {
        case .library: break
        case .playback: engine.autoReplace = (option == "Activé")
        case .display: if let mode = AppSettings.DisplayMode(rawValue: option) { settings.displayMode = mode }
        case .ratio: if let ratio = AppSettings.RatioMode(rawValue: option) { settings.ratioMode = ratio }
        case .offset: if let offset = AppSettings.VerticalOffset(rawValue: option) { settings.verticalOffset = offset }
        case .scale: if let scale = AppSettings.AdvancedScale(rawValue: option) { settings.advancedScale = scale }
        case .speed:
            let values = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
            if let val = values.first(where: { speedLabel($0) == option }) {
                settings.playbackSpeed = val
                engine.setRate(Float(val))
            }
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%.2f×", value)
    }
}
