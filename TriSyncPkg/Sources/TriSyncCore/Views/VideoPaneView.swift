import SwiftUI
import AppKit
import AVFoundation

/// Pont SwiftUI vers `PlayerLayerView`.
public struct VideoPaneView: NSViewRepresentable {
    public let player: AVPlayer?
    public var displayMode: VideoDisplayMode = .crop
    public var videoSize: CGSize = .zero
    public var cropOffset: CGFloat = 0.5
    public var zoom: CGFloat = 1.0
    public var immersiveMode = false
    public var seekOnArrows = false
    public var onStateChange: ((CGFloat) -> Void)?
    public var onShortcut: ((ShortcutAction) -> Void)?
    public var onViewCreated: ((PlayerLayerView) -> Void)?

    public init(
        player: AVPlayer?,
        displayMode: VideoDisplayMode = .crop,
        videoSize: CGSize = .zero,
        cropOffset: CGFloat = 0.5,
        zoom: CGFloat = 1.0,
        immersiveMode: Bool = false,
        seekOnArrows: Bool = false,
        onStateChange: ((CGFloat) -> Void)? = nil,
        onShortcut: ((ShortcutAction) -> Void)? = nil,
        onViewCreated: ((PlayerLayerView) -> Void)? = nil
    ) {
        self.player = player
        self.displayMode = displayMode
        self.videoSize = videoSize
        self.cropOffset = cropOffset
        self.zoom = zoom
        self.immersiveMode = immersiveMode
        self.seekOnArrows = seekOnArrows
        self.onStateChange = onStateChange
        self.onShortcut = onShortcut
        self.onViewCreated = onViewCreated
    }

    public func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.displayMode = displayMode
        view.videoSize = videoSize
        view.cropOffset = cropOffset
        view.zoom = zoom
        view.immersiveMode = immersiveMode
        view.seekOnArrows = seekOnArrows
        view.onStateChange = onStateChange
        view.onShortcut = onShortcut
        return view
    }

    public func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
        nsView.displayMode = displayMode
        nsView.videoSize = videoSize
        nsView.cropOffset = cropOffset
        nsView.zoom = zoom
        nsView.immersiveMode = immersiveMode
        nsView.seekOnArrows = seekOnArrows
        nsView.onStateChange = onStateChange
        nsView.onShortcut = onShortcut
        if let onViewCreated {
            onViewCreated(nsView)
        }
    }
}
