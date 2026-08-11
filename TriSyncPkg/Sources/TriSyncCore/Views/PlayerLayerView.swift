import AppKit
import AVFoundation
import CoreMedia

/// Vue AppKit hébergeant un AVPlayerLayer sans composition SwiftUI sur le flux vidéo.
/// Supporte le zoom interactif, le déplacement (pan) à la souris/clavier et les raccourcis Infuse.
public final class PlayerLayerView: NSView {

    private let playerLayer = AVPlayerLayer()
    public private(set) var interactiveZoom: CGFloat = 1
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0

    public var onStateChange: ((CGFloat) -> Void)?
    public var onShortcut: ((ShortcutAction) -> Void)?
    public var immersiveMode = false
    public var seekOnArrows = false

    public var player: AVPlayer? {
        didSet {
            guard player !== oldValue else { return }
            playerLayer.player = player
            interactiveZoom = 1
            panX = 0
            panY = 0
            onStateChange?(1)
            applyGeometry()
        }
    }

    public var displayMode: VideoDisplayMode = .crop {
        didSet { applyGeometry() }
    }

    public var videoSize: CGSize = .zero {
        didSet { applyGeometry() }
    }

    public var cropOffset: CGFloat = 0.5 {
        didSet { applyGeometry() }
    }

    public var zoom: CGFloat = 1.0 {
        didSet { applyGeometry() }
    }

    public override var acceptsFirstResponder: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 12
        playerLayer.masksToBounds = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas supporté")
    }

    public override func layout() {
        super.layout()
        playerLayer.frame = bounds
        applyGeometry()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            player = nil
        }
    }

    // MARK: - Interactions Souris & Clavier

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            resetInteractive()
        } else {
            super.mouseDown(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let scale = totalScale()
        panX -= event.deltaX / scale
        panY -= event.deltaY / scale
        applyGeometry()
    }

    public override func scrollWheel(with event: NSEvent) {
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.02 : 0.12
        let delta = event.scrollingDeltaY * sensitivity
        guard delta != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoom(around: point, to: interactiveZoom * (1 + delta))
    }

    public override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(around: point, to: interactiveZoom * (1 + event.magnification))
    }

    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift])
        if mods == .command {
            switch event.keyCode {
            case 124: onShortcut?(.seek(seconds: 60)); return   // ⌘→ : +60 s
            case 123: onShortcut?(.seek(seconds: -60)); return  // ⌘← : −60 s
            default: break
            }
        } else if mods == .option {
            switch event.keyCode {
            case 30: onShortcut?(.rate(factor: 1.25)); return   // ⌥] : accélérer
            case 33: onShortcut?(.rate(factor: 0.8)); return    // ⌥[ : ralentir
            default: break
            }
        } else if mods.isEmpty {
            switch event.keyCode {
            case 124, 123:
                if immersiveMode {
                    onShortcut?(.seek(seconds: event.keyCode == 124 ? 10 : -10))
                    return
                }
                if seekOnArrows {
                    onShortcut?(.seek(seconds: event.keyCode == 124 ? 5 : -3))
                    return
                }
            default:
                break
            }
        }

        let step: CGFloat = 28
        let scale = totalScale()
        switch event.keyCode {
        case 123: panX -= step / scale   // ←
        case 124: panX += step / scale   // →
        case 126: panY += step / scale   // ↑
        case 125: panY -= step / scale   // ↓
        case 24, 69: zoom(around: CGPoint(x: bounds.midX, y: bounds.midY), to: interactiveZoom * 1.25) // +
        case 27: zoom(around: CGPoint(x: bounds.midX, y: bounds.midY), to: interactiveZoom / 1.25)      // -
        case 29: resetInteractive()      // 0
        default:
            super.keyDown(with: event)
            return
        }
        applyGeometry()
    }

    private func zoom(around point: CGPoint, to newZoom: CGFloat) {
        let old = interactiveZoom
        let clamped = min(max(newZoom, 1), 10)
        guard clamped != old else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        panX += (point.x - center.x) * (1 / clamped - 1 / old)
        panY += (point.y - center.y) * (1 / clamped - 1 / old)
        interactiveZoom = clamped
        onStateChange?(clamped)
    }

    public func resetInteractive() {
        guard interactiveZoom != 1 || panX != 0 || panY != 0 else { return }
        interactiveZoom = 1
        panX = 0
        panY = 0
        onStateChange?(1)
        applyGeometry()
    }

    private func totalScale() -> CGFloat {
        displayMode == .crop ? max(zoom, 1) * interactiveZoom : interactiveZoom
    }

    // MARK: - Géométrie Calibrée

    private func applyGeometry() {
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }

        switch displayMode {
        case .stretch:
            playerLayer.videoGravity = .resize
            playerLayer.setAffineTransform(.identity)
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.setAffineTransform(.identity)
        case .crop:
            playerLayer.videoGravity = .resizeAspectFill
            guard videoSize.width > 1, videoSize.height > 1 else {
                playerLayer.setAffineTransform(.identity)
                return
            }
            let videoAspect = videoSize.width / videoSize.height
            let boundsAspect = b.width / b.height
            let fittedHeight = videoAspect <= boundsAspect ? b.height : b.width / videoAspect
            let fittedWidth = videoAspect <= boundsAspect ? b.height * videoAspect : b.width
            let basePanY = (cropOffset - 0.5) * max(fittedHeight * max(zoom, 1) - b.height, 0)
            let scale = totalScale()
            let maxPanX = max(fittedWidth / 2 - b.width / (2 * scale), 0)
            let maxPanY = max(fittedHeight / 2 - b.height / (2 * scale), 0)
            let totalPanX = min(max(panX, -maxPanX), maxPanX)
            let totalPanY = min(max(basePanY + panY, -maxPanY), maxPanY)
            let tf = CGAffineTransform(translationX: -totalPanX, y: -totalPanY).scaledBy(x: scale, y: scale)
            playerLayer.setAffineTransform(tf)
        }
    }
}
