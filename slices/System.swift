//  System.swift — TriSync
//  Couche système macOS : point d'entrée de l'application, bibliothèque vidéo
//  et accès aux fichiers (NSOpenPanel, sandbox, métadonnées AVFoundation).
//  Commentaires en français, identifiants en anglais.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Point d'entrée

@main
struct TriSyncApp: App {
    @StateObject private var library: VideoLibrary

    init() {
        // Création explicite de la bibliothèque pour pouvoir l'exposer à la
        // fonction globale ingestVideos(_:) (découplage avec UI.swift).
        let lib = VideoLibrary()
        _library = StateObject(wrappedValue: lib)
        sharedLibrary = lib
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                // macOS ne propose pas preferredColorScheme sur une Scene :
                // on l'applique donc à la vue racine.
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

// MARK: - Référence partagée de la bibliothèque

/// Instance courante de la bibliothèque, utilisée par ingestVideos(_:).
/// Référence faible : la propriété forte est portée par le StateObject de TriSyncApp.
@MainActor
fileprivate weak var sharedLibrary: VideoLibrary?

// MARK: - Asset vidéo

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

// MARK: - Bibliothèque vidéo

@MainActor
final class VideoLibrary: ObservableObject {
    static let maxSlots = 3

    @Published var slots: [VideoAsset?] = Array(repeating: nil, count: VideoLibrary.maxSlots)
    @Published var assets: [VideoAsset] = []
    @Published var selectedSlot = 0

    let engine = SyncEngine()

    // MARK: Sélection et gestion des slots

    func select(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        selectedSlot = slot
    }

    func clear(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
        syncEngine()
    }

    func clearAll() {
        slots = [nil, nil, nil]
        assets = []
        engine.clear()
    }

    func assign(_ asset: VideoAsset, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = asset
        syncEngine()
    }

    func removeAsset(_ asset: VideoAsset) {
        assets.removeAll { $0.id == asset.id }
        for index in slots.indices where slots[index]?.id == asset.id {
            slots[index] = nil
        }
        syncEngine()
    }

    // MARK: Ajout et ingestion de fichiers

    func add(urls: [URL]) {
        for url in Self.videoFiles(from: urls) {
            guard !assets.contains(where: { $0.url == url }) else { continue }
            let asset = VideoAsset(url: url)
            assets.append(asset)
            assignAutomatically(asset)
            Task { @MainActor in
                await loadMetadata(for: asset)
                objectWillChange.send()
            }
        }
        syncEngine()
    }

    func ingest(_ urls: [URL]) {
        add(urls: urls)
    }

    // MARK: Synchronisation du moteur

    private func syncEngine() {
        var configuration: [Int: VideoAsset] = [:]
        for (index, asset) in slots.enumerated() {
            guard let asset = asset else { continue }
            configuration[index] = asset
        }
        engine.reconfigure(slots: configuration)
    }

    // MARK: Filtrage des fichiers vidéo

    /// Extensions de secours quand UTType ne reconnaît pas le fichier
    /// (mkv, webm, ts, m2ts… ne sont pas toujours déclarés dans la base UTType).
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "ts", "m2ts"]

    /// Type du fichier : d'abord le type réel sur disque (NSURLContentTypeKey),
    /// puis déduction depuis l'extension (UTType n'a pas d'init(url:)).
    private static func fileType(of url: URL) -> UTType? {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Ne conserve que les URLs correspondant à des fichiers vidéo :
    /// conformité UTType (.movie / .video) ou extension de la liste de secours.
    static func videoFiles(from urls: [URL]) -> [URL] {
        urls.filter { url in
            if let type = Self.fileType(of: url) {
                return type.conforms(to: .movie) || type.conforms(to: .video)
            }
            return videoExtensions.contains(url.pathExtension.lowercased())
        }
    }

    // MARK: Attribution automatique d'un slot

    private func assignAutomatically(_ asset: VideoAsset) {
        if slots[selectedSlot] == nil {
            slots[selectedSlot] = asset
        } else if let firstEmpty = slots.firstIndex(where: { $0 == nil }) {
            slots[firstEmpty] = asset
        }
        // Aucun slot libre : l'asset reste dans la galerie, sans slot.
    }

    // MARK: Chargement des métadonnées (durée, résolution, fréquence, miniature)

    private func loadMetadata(for asset: VideoAsset) async {
        let url = asset.url
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let avAsset = AVURLAsset(url: url)

            asset.duration = try await avAsset.load(.duration)

            if let track = try await avAsset.loadTracks(withMediaType: .video).first {
                asset.size = try await track.load(.naturalSize)
                asset.frameRate = Double(try await track.load(.nominalFrameRate))
            }

            if asset.duration.isNumeric, asset.duration.seconds > 0 {
                let generator = AVAssetImageGenerator(asset: avAsset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                let requestTime = CMTime(seconds: min(1.0, asset.duration.seconds / 2.0),
                                         preferredTimescale: 600)
                let (cgImage, _) = try await generator.image(at: requestTime)
                asset.thumbnail = NSImage(cgImage: cgImage, size: .zero)
            }
        } catch {
            // Échec silencieux : l'asset reste utilisable avec des métadonnées à zéro.
        }
    }
}

// MARK: - Panneau d'ouverture de fichiers

/// Ouvre le panneau de sélection et retourne les URLs choisies (ou [] si annulé).
/// Dans la sandbox, NSOpenPanel accorde l'accès aux fichiers sélectionnés pour
/// la durée de la session ; aucun bookmark n'est persisté.
@MainActor
func openVideosPanel() -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.prompt = "Ajouter"

    guard panel.runModal() == .OK else { return [] }

    for url in panel.urls {
        // Accès sandbox accordé pour la session (équilibré par le stop
        // dans loadMetadata(for:)).
        _ = url.startAccessingSecurityScopedResource()
    }
    return panel.urls
}

/// Reçoit les URLs (bouton Ouvrir… ou glisser-déposer), filtre les vidéos et
/// les transmet à la bibliothèque courante. Ne fait rien si l'application
/// n'est pas encore initialisée (sharedLibrary nil).
@MainActor
func ingestVideos(_ urls: [URL]) {
    guard let library = sharedLibrary else { return }
    library.ingest(VideoLibrary.videoFiles(from: urls))
}

// MARK: - Accès à la fenêtre hôte

/// Vue utilitaire : expose la NSWindow hôte à la hiérarchie SwiftUI.
/// Permet à ContentView de rendre la fenêtre déplaçable par son fond
/// (window.isMovableByWindowBackground = true) malgré la barre de titre masquée.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}
