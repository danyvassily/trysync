//  UI.swift
//  TriSync — Couche d'interface SwiftUI : scène synchronisée jusqu'à 3 vidéos.
//  macOS 14+, optimisé Apple Silicon M3.
//
//  Règle de performance critique : aucun material/flou/ombre AU-DESSUS des
//  couches vidéo (composition hors-écran coûteuse). Les materials ne sont
//  utilisés que sur le « chrome » : barre supérieure, barre de transport et
//  panneaux d'infos superposés.

import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Constantes

/// Couleur d'accent système (évite l'API dépréciée Color.accentColor).
private let accent = Color(nsColor: .controlAccentColor)

// MARK: - Lecteur vidéo (couche d'hébergement)

/// Vue AppKit qui héberge un AVPlayerLayer : rendu vidéo direct, sans
/// composition SwiftUI sur le flux (économie de bande passante GPU).
final class PlayerLayerView: NSView {

    private let playerLayer = AVPlayerLayer()

    /// Lecteur attaché à la couche. La vérification d'identité évite de
    /// réassigner le même AVPlayer à chaque passe de rendu SwiftUI.
    var player: AVPlayer? {
        didSet {
            guard player !== oldValue else { return }
            playerLayer.player = player
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Mode « layer-hosting » : la vue ne fait que porter la couche.
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 12
        playerLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas supporté")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Libère le AVPlayer quand la vue quitte la fenêtre. On passe par la
        // propriété (et non la couche directement) pour que le didSet puisse
        // rattacher proprement le lecteur lors d'un éventuel retour en fenêtre.
        if window == nil {
            player = nil
        }
    }
}

/// Pont SwiftUI → PlayerLayerView. Aucun coordinator nécessaire : la mise à
/// jour se résume à (ré)assigner le lecteur (le didSet filtre les no-op).
struct VideoPaneView: NSViewRepresentable {

    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - Formatage du temps

/// Formate un CMTime en « m:ss » (ou « h:mm:ss » au-delà d'une heure).
/// Les temps invalides ou indéfinis renvoient « 0:00 ».
func timeString(_ t: CMTime) -> String {
    guard t.isNumeric, t.seconds.isFinite else { return "0:00" }
    let total = max(0, Int(t.seconds.rounded()))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Vue racine

/// Vue racine : barre supérieure, scène vidéo, bandeau de bibliothèque et
/// barre de transport. La scène accepte les dépôts de fichiers vidéo.
struct ContentView: View {

    @EnvironmentObject private var library: VideoLibrary

    // MARK: Corps

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            stage
            GalleryStrip()
            TransportBar()
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(background)
        // Le moteur est aussi exposé à l'environnement : les sous-vues qui
        // lisent ses @Published se ré-affichent correctement à chaque tick.
        .environmentObject(library.engine)
    }

    // MARK: Scène

    /// Scène vidéo : disposition réactive selon le nombre d'emplacements
    /// remplis, avec dépôt de fichiers sur toute la zone.
    private var stage: some View {
        GeometryReader { geo in
            Group {
                if library.assets.isEmpty {
                    EmptyStateView()
                        .transition(.opacity)
                } else {
                    slotGrid
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: loadedCount)
            .animation(.easeInOut(duration: 0.2), value: library.assets.isEmpty)
        }
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
            return true
        }
    }

    /// Disposition réactive :
    /// — 1 vidéo : plein cadre ;
    /// — 2 vidéos : HStack à largeurs égales ;
    /// — 3 vidéos : panneau maître à 50 % + colonne des deux autres.
    @ViewBuilder
    private var slotGrid: some View {
        let slots = loadedSlots
        if slots.isEmpty {
            HStack(spacing: 12) {
                ForEach(0..<VideoLibrary.maxSlots, id: \.self) { slot in
                    StagePane(slot: slot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if slots.count == 1 {
            StagePane(slot: slots[0])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if slots.count == 2 {
            HStack(spacing: 12) {
                StagePane(slot: slots[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StagePane(slot: slots[1])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 12) {
                StagePane(slot: slots[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    StagePane(slot: slots[1])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    StagePane(slot: slots[2])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Indices des emplacements remplis, dans l'ordre.
    private var loadedSlots: [Int] {
        library.slots.indices.filter { library.slots[$0] != nil }
    }

    private var loadedCount: Int { loadedSlots.count }

    /// Filtre les fichiers vidéo déposés : ignore les dossiers et les
    /// extensions non supportées, puis transmet le reste à l'ingestion.
    private func addDropped(_ urls: [URL]) {
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "ts", "m2ts"]
        let videos = urls.filter { url in
            guard !isDirectory(url) else { return false }
            return videoExtensions.contains(url.pathExtension.lowercased())
        }
        guard !videos.isEmpty else { return }
        ingestVideos(videos)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: Fond

    /// Fond sombre : dégradé subtil + voile de material très léger
    /// (derrière la scène, jamais au-dessus des vidéos).
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.11, blue: 0.14),
                    Color(red: 0.045, green: 0.045, blue: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.35)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Barre supérieure

/// Barre supérieure : identité de l'app + actions d'ouverture et de
/// nettoyage. Préparée pour un titre de fenêtre masqué (hiddenTitleBar) :
/// le bloc titre est décalé pour dégager les feux de signalisation.
struct TopBar: View {

    @EnvironmentObject private var library: VideoLibrary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TriSync")
                    .font(.system(size: 16, weight: .bold))
                Text("Lecture synchronisée · Apple Silicon")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 56)

            Spacer()

            BarButton(systemName: "folder", title: "Ouvrir…") {
                _ = openVideosPanel()
            }
            .help("Importer des vidéos")

            BarButton(systemName: "trash", title: "Tout effacer") {
                library.clearAll()
            }
            .help("Vider la bibliothèque")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

// MARK: - Bandeau de bibliothèque

/// Bandeau horizontal des vidéos de la bibliothèque (miniatures cliquables).
/// Masqué tant que la bibliothèque est vide.
struct GalleryStrip: View {

    @EnvironmentObject private var library: VideoLibrary

    var body: some View {
        if !library.assets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(library.assets) { asset in
                        AssetChip(asset: asset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }
}

/// Pastille de bibliothèque : miniature 160×90, titre, durée, emplacement
/// assigné (A/B/C) et bouton de retrait. Un clic assigne l'actif à
/// l'emplacement sélectionné.
private struct AssetChip: View {

    @EnvironmentObject private var library: VideoLibrary

    let asset: VideoAsset

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeString(asset.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let letter = slotLetter {
                    Text("Emplacement \(letter)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.85)))
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 4)

            Button {
                library.removeAsset(asset)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(hovering ? Color.white.opacity(0.15) : Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Retirer de la bibliothèque")
            .padding(.trailing, 6)
        }
        .frame(width: 300, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { library.assign(asset, to: library.selectedSlot) }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = asset.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 90)
                .clipped()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.22, blue: 0.27),
                        Color(red: 0.10, green: 0.10, blue: 0.13)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 160, height: 90)
        }
    }

    /// Lettre A/B/C si l'actif occupe un emplacement, sinon nil.
    private var slotLetter: String? {
        guard let index = library.slots.firstIndex(where: { $0?.id == asset.id }) else { return nil }
        return ["A", "B", "C"][index]
    }
}

// MARK: - Barre de transport

/// Barre de transport : lecture/pause, arrêt, resynchronisation, vitesse,
/// scrubber synchronisé sur le temps du maître et statut de lecture.
struct TransportBar: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine

    private static let rates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var rate: Float = 1.0
    @State private var playHover = false

    private var loadedCount: Int { library.slots.compactMap { $0 }.count }

    /// Lecture possible uniquement quand tous les emplacements remplis sont prêts.
    private var canPlay: Bool { loadedCount > 0 && engine.readyCount >= loadedCount }

    var body: some View {
        HStack(spacing: 12) {
            playButton
            BarIconButton(systemName: "stop.fill", help: "Arrêter") { engine.stop() }
            BarIconButton(systemName: "arrow.triangle.2.circlepath", help: "Resynchroniser") { engine.resync() }
            ratePicker
            scrubber
            timeLabel
            Spacer(minLength: 8)
            statusLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            if engine.currentRate > 0 {
                rate = engine.currentRate
            }
        }
        .onChange(of: engine.leaderTime.seconds) { _, _ in syncScrub() }
        .onChange(of: rate) { _, newValue in engine.setRate(newValue) }
    }

    // MARK: Contrôles

    private var playButton: some View {
        Button {
            engine.togglePlay()
        } label: {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(accent))
                .scaleEffect(playHover ? 1.06 : 1.0)
                .shadow(color: accent.opacity(playHover ? 0.45 : 0.2), radius: playHover ? 10 : 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1.0 : 0.35)
        .help(engine.isPlaying ? "Pause" : "Lecture")
        .onHover { playHover = $0 }
    }

    private var ratePicker: some View {
        Picker("Vitesse", selection: $rate) {
            ForEach(Self.rates, id: \.self) { value in
                Text(rateLabel(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 74)
        .help("Vitesse de lecture")
    }

    private var scrubber: some View {
        Slider(value: $scrub, in: 0...1) { editing in
            if editing {
                isScrubbing = true
                engine.beginScrub()
            } else {
                isScrubbing = false
                engine.endScrub(atFraction: scrub)
            }
        }
        .frame(minWidth: 120, maxWidth: 260)
        .disabled(loadedCount == 0)
        .help("Position de lecture")
    }

    private var timeLabel: some View {
        Text("\(timeString(engine.leaderTime)) / \(timeString(engine.leaderDuration))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 120, alignment: .leading)
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 96, alignment: .trailing)
    }

    private var statusText: String {
        if engine.isPlaying { return "Lecture synchronisée" }
        if loadedCount > 0 && engine.readyCount < loadedCount {
            return "Chargement \(engine.readyCount)/\(loadedCount)…"
        }
        return "Prêt"
    }

    // MARK: Aides

    /// Synchronise le scrubber local depuis le temps du maître, sauf pendant
    /// un glissement manuel (le flag isScrubbing évite les combats de valeur).
    private func syncScrub() {
        guard !isScrubbing else { return }
        let time = engine.leaderTime
        let duration = engine.leaderDuration.seconds
        guard time.isNumeric, duration.isFinite, duration > 0 else { return }
        scrub = min(max(time.seconds / duration, 0), 1)
    }

    private func rateLabel(_ value: Float) -> String {
        value == value.rounded()
            ? String(format: "%.0f×", value)
            : String(format: "%.2f×", value)
    }
}

// MARK: - État vide

/// Écran d'accueil : héros animé (pulsation douce) et bouton d'ouverture.
struct EmptyStateView: View {

    @State private var pulsing = false
    @State private var buttonHover = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.secondary)
                .opacity(pulsing ? 0.4 : 0.85)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulsing)
            Text("Jusqu'à 3 vidéos, parfaitement synchronisées")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 18)
            Text("Glissez vos fichiers vidéo dans la fenêtre ou cliquez sur Ouvrir…")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Button {
                _ = openVideosPanel()
            } label: {
                Label("Choisir des vidéos…", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accent)
                    )
                    .scaleEffect(buttonHover ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            .help("Importer des vidéos")
            .padding(.top, 22)
            .onHover { buttonHover = $0 }
            Spacer()
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulsing = true }
    }
}

// MARK: - Sous-vues privées

/// Panneau d'un emplacement de la scène : vidéo (ou placeholder) + barre
/// d'infos avec contrôles par panneau (son, volume, retrait).
private struct StagePane: View {

    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine

    let slot: Int

    @State private var speakerHover = false
    @State private var clearHover = false

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

    // MARK: Panneau vidéo

    private func videoPane(asset: VideoAsset) -> some View {
        ZStack(alignment: .bottom) {
            VideoPaneView(player: engine.player(forSlot: slot))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Dégradé léger en bas pour détacher la barre d'infos du contenu.
            // Simple dégradé (pas de flou) : aucun material au-dessus de la vidéo.
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            infoBar(asset: asset)
                .padding(10)
        }
    }

    /// Barre d'infos : titre, badges (maître, dérive, erreur), durée et
    /// contrôles du panneau. Material autorisé : c'est un overlay de panneau,
    /// pas une couche posée sur le flux vidéo.
    private func infoBar(asset: VideoAsset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(asset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isLeader {
                        leaderBadge
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
                            .truncationMode(.tail)
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
                .fill(.ultraThinMaterial)
        )
    }

    /// L'emplacement maître est le premier emplacement rempli dont le lecteur est prêt.
    private var isLeader: Bool {
        guard engine.player(forSlot: slot) != nil else { return false }
        return library.slots.firstIndex(where: { $0 != nil }) == slot
    }

    private var leaderBadge: some View {
        Text("MAÎTRE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(accent))
    }

    private var speakerButton: some View {
        Button {
            mutedBinding.wrappedValue.toggle()
        } label: {
            Image(systemName: engine.isMuted(slot: slot) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(speakerHover ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(engine.isMuted(slot: slot) ? "Activer le son" : "Couper le son")
        .onHover { speakerHover = $0 }
    }

    private var volumeSlider: some View {
        Slider(value: volumeBinding, in: 0...1)
            .frame(width: 90)
            .controlSize(.small)
            .help("Volume")
    }

    private var clearButton: some View {
        Button {
            library.clear(slot: slot)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(clearHover ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Retirer du panneau")
        .onHover { clearHover = $0 }
    }

    /// Liaison de mise en sourdine vers le moteur (lecture + écriture).
    private var mutedBinding: Binding<Bool> {
        Binding(
            get: { engine.isMuted(slot: slot) },
            set: { engine.setMuted($0, forSlot: slot) }
        )
    }

    /// Liaison de volume vers le moteur (lecture + écriture).
    private var volumeBinding: Binding<Float> {
        Binding(
            get: { engine.volume(forSlot: slot) },
            set: { engine.setVolume($0, forSlot: slot) }
        )
    }

    // MARK: Emplacement vide

    /// Panneau d'attente : invite au glisser-déposer vers cet emplacement.
    private var emptyPane: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Glisser une vidéo ici")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Emplacement \(["A", "B", "C"][slot])")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            )
    }
}

/// Bouton de barre avec libellé : fond discret et effet de survol.
private struct BarButton: View {

    let systemName: String
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Bouton icône de barre : fond discret et effet de survol.
private struct BarIconButton: View {

    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
