import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Panneau individuel d'un slot de la scène multi-vidéos.
public struct StagePane: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var windowController: WindowController

    public let slot: Int

    @State private var speakerHover = false
    @State private var clearHover = false
    @State private var paneZoom: CGFloat = 1
    @State private var paneView: PlayerLayerView?
    @State private var isDropTargeted = false

    public init(slot: Int) {
        self.slot = slot
    }

    public var body: some View {
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
                .strokeBorder(library.selectedSlot == slot ? triAccent : Color.clear, lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    engine.isIndependentSlot(slot) ? Color.orange.opacity(0.9) : Color.clear,
                    lineWidth: engine.isIndependentSlot(slot) ? 2.5 : 0
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? triAccent.opacity(0.9) : Color.clear, lineWidth: 2.5)
        )
        .animation(.easeInOut(duration: 0.15), value: library.selectedSlot)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            library.select(slot: slot)
            if engine.referenceMode != .none, engine.isReferenceSlot(slot) {
                engine.setAudioSlot(nil)
                engine.setIndependentSlot(nil)
            } else {
                engine.setAudioSlot(slot)
                engine.setIndependentSlot(slot)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers, into: slot)
            return true
        }
        .contextMenu {
            Slider(
                value: Binding(
                    get: { Double(engine.volume(forSlot: slot) * 100) },
                    set: { engine.setVolume(Float($0 / 100), forSlot: slot) }
                ),
                in: 0...100
            ) {
                Text("Volume")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("100")
            }
            .frame(width: 180)
            .padding(.horizontal, 10)

            Divider()

            Button {
                engine.setManualMaster(slot)
            } label: {
                Label("Définir comme maître", systemImage: "crown.fill")
            }
            .disabled(engine.referenceMode == .manual && engine.manualReferenceSlot == slot)

            Button {
                engine.setReferenceMode(.auto)
            } label: {
                Label("Maître automatique (premier bloc)", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                engine.setAudioSlot(engine.isAudioSlot(slot) ? nil : slot)
            } label: {
                if engine.isAudioSlot(slot) {
                    Label("Rétablir l'audio automatique (maître)", systemImage: "speaker.slash")
                } else {
                    Label("Utiliser comme source audio", systemImage: "speaker.wave.2.fill")
                }
            }

            Button {
                capturePane()
            } label: {
                Label("Capture du bloc…", systemImage: "camera")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    private func videoPane(asset: VideoAsset) -> some View {
        ZStack(alignment: .bottom) {
            VideoPaneView(
                player: engine.player(forSlot: slot),
                displayMode: settings.displayMode.videoMode,
                videoSize: asset.size,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: false,
                seekOnArrows: engine.isPlaying,
                onStateChange: { zoom in paneZoom = zoom },
                onShortcut: { action in
                    switch action {
                    case .seek(let seconds): engine.skip(by: seconds)
                    case .rate(let factor): engine.nudgeRate(factor)
                    }
                },
                onViewCreated: { view in
                    if paneView !== view { paneView = view }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            infoBar(asset: asset)
                .padding(10)
        }
    }

    private func infoBar(asset: VideoAsset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(asset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if engine.referenceMode != .none, isLeader {
                        leaderBadge
                    }
                    if engine.isIndependentSlot(slot) {
                        timelineBadge
                    }
                    if engine.isAudioSlot(slot) {
                        Text("🔊")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                            .help("Source audio courante")
                    }
                    if paneZoom != 1 {
                        Text(String(format: "×%.1f", paneZoom))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                    if let drift = engine.driftText[slot], !drift.isEmpty {
                        Text(drift)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 10) {
                    Text(timeString(asset.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let error = engine.slotError[slot], !error.isEmpty {
                        Text(error)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            speakerButton
            volumeSlider
            clearButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.65))
        )
    }

    private var isLeader: Bool { engine.isReferenceSlot(slot) }

    private var leaderBadge: some View {
        Text("MAÎTRE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(triAccent))
    }

    private var timelineBadge: some View {
        Text("TIMELINE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange))
    }

    private var speakerButton: some View {
        Button {
            engine.setMuted(!engine.isMuted(slot: slot), forSlot: slot)
        } label: {
            Image(systemName: engine.isMuted(slot: slot) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(speakerHover ? Color.white.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engine.isMuted(slot: slot) ? "Activer le son" : "Couper le son")
        .onHover { speakerHover = $0 }
    }

    private var volumeSlider: some View {
        Slider(
            value: Binding(
                get: { engine.volume(forSlot: slot) },
                set: { engine.setVolume($0, forSlot: slot) }
            ),
            in: 0...1
        )
        .frame(width: 80)
        .controlSize(.small)
    }

    private var clearButton: some View {
        Button {
            library.clear(slot: slot)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(clearHover ? Color.white.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Retirer de la scène")
        .onHover { clearHover = $0 }
    }

    private var emptyPane: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.45))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Glisser une vidéo ici")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Emplacement \(slotLetters[slot])")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            )
    }

    private func capturePane() {
        guard let view = paneView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "TriSync-Capture-\(formatter.string(from: Date())).png"

        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let url = desktop.appendingPathComponent(name)
            if (try? data.write(to: url, options: .atomic)) != nil {
                NSSound.beep()
                return
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
            NSSound.beep()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], into targetSlot: Int) {
        let lib = self.library
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let str = item as? String { url = URL(fileURLWithPath: str) }
                else if let found = item as? URL { url = found }
                else { url = nil }

                guard let url else { return }
                DispatchQueue.main.async {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    guard !VideoLibrary.videoFiles(from: [url]).isEmpty,
                          let asset = lib.ensureInLibrary(url) else { return }
                    lib.assign(asset, to: targetSlot)
                }
            }
        }
    }
}
