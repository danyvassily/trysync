import Foundation

/// Dossier source de la vidéothèque (Mac, disque externe…) avec bookmark
/// de sécurité persisté pour restaurer les accès au redémarrage (sandbox macOS).
public struct LibrarySource: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var enabled: Bool
    public let bookmark: Data

    public init(id: UUID = UUID(), url: URL, enabled: Bool = true, bookmark: Data) {
        self.id = id
        self.url = url
        self.enabled = enabled
        self.bookmark = bookmark
    }
}
