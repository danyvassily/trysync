import SwiftUI
import AppKit

/// Couleur d'accent système macOS.
public let triAccent = Color(nsColor: .controlAccentColor)

/// Lettres des emplacements de scène (A à E pour jusqu'à 5 vidéos).
public let slotLetters = ["A", "B", "C", "D", "E"]

/// Mode de remplissage d'un panneau vidéo.
public enum VideoDisplayMode: Int, Codable, Sendable {
    case fit     // Plein : vidéo intégrale, barres noires si ratios différents
    case crop    // Rogner : la vidéo remplit le panneau, recadrage centré
    case stretch // Remplir : étirement sans bordures
}

/// Action de raccourci clavier émise par un panneau vidéo.
public enum ShortcutAction: Sendable {
    case seek(seconds: Double)
    case rate(factor: Float)
}

/// Section affichée dans la fenêtre principale.
public enum AppSection: Equatable, Sendable {
    case library  // Vidéothèque : navigation dossiers + grilles
    case play     // Lecture : scène synchronisée
}

/// Mode de désignation du maître de synchronisation.
public enum ReferenceMode: String, CaseIterable, Codable, Sendable {
    case auto = "Auto"
    case manual = "Manuel"
    case none = "Aucun"
}

/// Dossier intelligent de la bibliothèque (calculé à la volée).
public enum SmartFolder: String, CaseIterable, Identifiable, Sendable {
    case recent    // Récemment ajoutés (top 50, date décroissante)
    case favorites // À regarder (favoris ★)
    case resume    // Reprendre (position sauvegardée > 15 s)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recent: return "Récemment ajoutés"
        case .favorites: return "À regarder"
        case .resume: return "Reprendre"
        }
    }

    public var icon: String {
        switch self {
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "star.fill"
        case .resume: return "play.circle.fill"
        }
    }
}
