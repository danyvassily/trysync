import Foundation
import AppKit
import CoreMedia

/// Représentation d'une vidéo dans la bibliothèque TriSync.
@MainActor
public final class VideoAsset: Identifiable, ObservableObject {
    public let id: UUID
    public let url: URL
    public let title: String
    public let dateAdded: Date

    @Published public var duration: CMTime = .zero
    @Published public var frameRate: Double = 0
    @Published public var size: CGSize = .zero
    @Published public var thumbnail: NSImage? = nil

    /// Favori persisté par chemin standardisé dans UserDefaults.
    public var isFavorite: Bool {
        get { Self.favoritePaths.contains(canonicalPath(for: url)) }
        set {
            var paths = Self.favoritePaths
            let key = canonicalPath(for: url)
            if newValue { paths.insert(key) } else { paths.remove(key) }
            UserDefaults.standard.set(Array(paths), forKey: "library.favorites")
            Self.favoritePaths = paths
            objectWillChange.send()
        }
    }

    private static var favoritePaths: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "library.favorites") ?? [])
    }()

    public init(id: UUID = UUID(), url: URL, title: String? = nil, dateAdded: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.dateAdded = dateAdded
    }
}
