import AppKit
import UniformTypeIdentifiers

/// Ouvre le panneau de sélection de vidéos (NSOpenPanel) et retourne les URLs choisies.
@MainActor
public func openVideosPanel() -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.prompt = "Ajouter"
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}

/// Ouvre le panneau de sélection d'un dossier source.
@MainActor
public func openFolderPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.folder]
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.prompt = "Ajouter"
    panel.message = "Choisissez un dossier de vidéos (Mac, disque externe…)"
    guard panel.runModal() == .OK, let url = panel.urls.first else { return nil }
    return url
}
