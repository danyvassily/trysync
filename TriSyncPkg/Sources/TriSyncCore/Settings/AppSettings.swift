import SwiftUI
import AppKit
import Combine

/// Réglages utilisateur de l'affichage et de la lecture, persistés dans UserDefaults et miroités iCloud.
@MainActor
public final class AppSettings: ObservableObject {

    public enum DisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
        case fit = "Plein"
        case crop = "Rogner"
        case stretch = "Remplir"
        public var id: String { rawValue }
        public var videoMode: VideoDisplayMode {
            switch self {
            case .fit: return .fit
            case .crop: return .crop
            case .stretch: return .stretch
            }
        }
    }

    public enum RatioMode: String, CaseIterable, Identifiable, Codable, Sendable {
        case auto = "Auto"
        case r43 = "4:3"
        case r169 = "16:9"
        case r11 = "1:1"
        public var id: String { rawValue }
    }

    public enum VerticalOffset: String, CaseIterable, Identifiable, Codable, Sendable {
        case none = "Aucun"
        case top = "Haut"
        case center = "Centre"
        case bottom = "Bas"
        public var id: String { rawValue }
        public var value: CGFloat {
            switch self {
            case .top: return 0
            case .none, .center: return 0.5
            case .bottom: return 1
            }
        }
    }

    public enum AdvancedScale: String, CaseIterable, Identifiable, Codable, Sendable {
        case auto = "Auto"
        case p110 = "110 %"
        case p125 = "125 %"
        case p150 = "150 %"
        public var id: String { rawValue }
        public var value: CGFloat {
            switch self {
            case .auto: return 1.0
            case .p110: return 1.1
            case .p125: return 1.25
            case .p150: return 1.5
            }
        }
    }

    /// Presets de composition bento pour la scène multi-vidéos.
    public enum LayoutPreset: String, CaseIterable, Identifiable, Codable, Sendable {
        case custom = "Libre"
        case auto = "Auto"
        case sideBySide = "Côte à côte"
        case stacked = "Empilées"
        case masterH = "Maître + détail"
        case masterV = "Maître haut + détail"
        case threeColumns = "3 colonnes"
        case masterTwo = "Maître + 2"
        case threeRows = "3 rangées"
        case grid2x2 = "Grille 2×2"
        case fourColumns = "4 colonnes"
        case masterThree = "Maître + 3"
        case wall32 = "Mur 3+2"
        case wall23 = "Mur 2+3"
        case fiveColumns = "5 colonnes"
        case masterFour = "Maître + 4"
        public var id: String { rawValue }
    }

    @Published public var displayMode: DisplayMode { didSet { save() } }
    @Published public var ratioMode: RatioMode { didSet { save() } }
    @Published public var verticalOffset: VerticalOffset { didSet { save() } }
    @Published public var advancedScale: AdvancedScale { didSet { save() } }
    @Published public var playbackSpeed: Double { didSet { save() } }
    @Published public var layoutPreset: LayoutPreset { didSet { save() } }
    @Published private var customWeights: [Int: Double] = [:]

    private static let keys = (
        display: "settings.displayMode",
        ratio: "settings.ratioMode",
        offset: "settings.verticalOffset",
        scale: "settings.advancedScale",
        speed: "settings.playbackSpeed",
        layout: "settings.layoutPreset",
        customWeights: "settings.customWeights"
    )

    private static let cloudKeys = (
        display: "cloud.displayMode",
        ratio: "cloud.ratioMode",
        offset: "cloud.verticalOffset",
        scale: "cloud.advancedScale",
        speed: "cloud.playbackSpeed",
        layout: "cloud.layoutPreset"
    )

    private static let cloud = NSUbiquitousKeyValueStore.default

    public init() {
        let d = UserDefaults.standard
        let fromCloud = Self.cloud.dictionaryRepresentation

        func localString(_ key: String, _ cloudKey: String) -> String? {
            if d.object(forKey: key) != nil { return d.string(forKey: key) }
            return fromCloud[cloudKey] as? String
        }
        func localDouble(_ key: String, _ cloudKey: String) -> Double? {
            if d.object(forKey: key) != nil { return d.object(forKey: key) as? Double }
            return fromCloud[cloudKey] as? Double
        }

        self.displayMode = DisplayMode(rawValue: localString(Self.keys.display, Self.cloudKeys.display) ?? "") ?? .crop
        self.ratioMode = RatioMode(rawValue: localString(Self.keys.ratio, Self.cloudKeys.ratio) ?? "") ?? .auto
        self.verticalOffset = VerticalOffset(rawValue: localString(Self.keys.offset, Self.cloudKeys.offset) ?? "") ?? .center
        self.advancedScale = AdvancedScale(rawValue: localString(Self.keys.scale, Self.cloudKeys.scale) ?? "") ?? .auto
        self.playbackSpeed = localDouble(Self.keys.speed, Self.cloudKeys.speed) ?? 1.0
        self.layoutPreset = LayoutPreset(rawValue: localString(Self.keys.layout, Self.cloudKeys.layout) ?? "") ?? .auto

        if let raw = d.dictionary(forKey: Self.keys.customWeights) as? [String: Double] {
            self.customWeights = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: Self.cloud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadFromCloud()
            }
        }
    }

    private func loadFromCloud() {
        let fromCloud = Self.cloud.dictionaryRepresentation
        if let raw = fromCloud[Self.cloudKeys.display] as? String, let value = DisplayMode(rawValue: raw) {
            displayMode = value
        }
        if let raw = fromCloud[Self.cloudKeys.ratio] as? String, let value = RatioMode(rawValue: raw) {
            ratioMode = value
        }
        if let raw = fromCloud[Self.cloudKeys.offset] as? String, let value = VerticalOffset(rawValue: raw) {
            verticalOffset = value
        }
        if let raw = fromCloud[Self.cloudKeys.scale] as? String, let value = AdvancedScale(rawValue: raw) {
            advancedScale = value
        }
        if let value = fromCloud[Self.cloudKeys.speed] as? Double {
            playbackSpeed = value
        }
        if let raw = fromCloud[Self.cloudKeys.layout] as? String, let value = LayoutPreset(rawValue: raw) {
            layoutPreset = value
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(displayMode.rawValue, forKey: Self.keys.display)
        d.set(ratioMode.rawValue, forKey: Self.keys.ratio)
        d.set(verticalOffset.rawValue, forKey: Self.keys.offset)
        d.set(advancedScale.rawValue, forKey: Self.keys.scale)
        d.set(playbackSpeed, forKey: Self.keys.speed)
        d.set(layoutPreset.rawValue, forKey: Self.keys.layout)
        d.set(
            Dictionary(uniqueKeysWithValues: customWeights.map { (String($0.key), $0.value) }),
            forKey: Self.keys.customWeights
        )

        let cloud = Self.cloud
        cloud.set(displayMode.rawValue, forKey: Self.cloudKeys.display)
        cloud.set(ratioMode.rawValue, forKey: Self.cloudKeys.ratio)
        cloud.set(verticalOffset.rawValue, forKey: Self.cloudKeys.offset)
        cloud.set(advancedScale.rawValue, forKey: Self.cloudKeys.scale)
        cloud.set(playbackSpeed, forKey: Self.cloudKeys.speed)
        cloud.set(layoutPreset.rawValue, forKey: Self.cloudKeys.layout)
        cloud.synchronize()
    }

    public func validPresets(forCount count: Int) -> [LayoutPreset] {
        switch count {
        case 2: return [.custom, .auto, .sideBySide, .stacked, .masterH, .masterV]
        case 3: return [.custom, .auto, .threeColumns, .masterTwo, .threeRows]
        case 4: return [.custom, .auto, .grid2x2, .fourColumns, .masterThree]
        case 5: return [.custom, .auto, .wall32, .wall23, .fiveColumns, .masterFour]
        default: return [.auto]
        }
    }

    public func isValidPreset(_ preset: LayoutPreset, forCount count: Int) -> Bool {
        validPresets(forCount: count).contains(preset)
    }

    // MARK: - Layout Libre (Custom Weights)

    public func weight(for slot: Int) -> Double {
        customWeights[slot] ?? 1.0
    }

    public func setWeight(_ value: Double, for slot: Int) {
        let clamped = min(max(value, 0.1), 10.0)
        let old = customWeights[slot] ?? 1.0
        if abs(old - clamped) > 0.001 {
            customWeights[slot] = clamped
            save()
        }
    }

    public func resetCustomWeights() {
        guard !customWeights.isEmpty else { return }
        customWeights.removeAll()
        save()
    }

    public func adjustWeight(_ delta: Double, left: Int, right: Int) {
        let wl = weight(for: left)
        let wr = weight(for: right)
        let total = wl + wr
        let newL = min(max(wl + delta * total, total * 0.15), total * 0.85)
        if abs(newL - wl) > 0.001 {
            customWeights[left] = newL
            customWeights[right] = total - newL
            save()
        }
    }

    public func targetAspect(for asset: VideoAsset) -> CGFloat {
        switch ratioMode {
        case .auto:
            return (asset.size.width > 1 && asset.size.height > 1)
                ? asset.size.width / asset.size.height : 0.75
        case .r43: return 4.0 / 3.0
        case .r169: return 16.0 / 9.0
        case .r11: return 1.0
        }
    }
}
