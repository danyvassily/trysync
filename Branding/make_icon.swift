// Génère l'icône TriSync : 3 panneaux vidéo synchronisés sur une timeline.
// Usage : swiftc make_icon.swift -o make_icon && ./make_icon
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0, alpha: alpha)
}

// MARK: - Dessin du design (coordonnées 1024×1024, mis à l'échelle ensuite)

func drawIconDesign() {
    // --- Fond : dégradé sombre premium ---
    let bg = NSGradient(colors: [color(0x0B0D16), color(0x161A2C)])!
    bg.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -90)

    // --- Halo radial violet/bleu derrière la scène ---
    if let ctx = NSGraphicsContext.current?.cgContext {
        let haloColors = [color(0x4A6CF7, 0.38).cgColor, color(0x4A6CF7, 0.0).cgColor] as CFArray
        let haloGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: haloColors, locations: [0, 1])!
        ctx.drawRadialGradient(
            haloGrad,
            startCenter: CGPoint(x: 512, y: 650), startRadius: 0,
            endCenter: CGPoint(x: 512, y: 650), endRadius: 470,
            options: []
        )
    }

    // --- Vignettage léger ---
    color(0x000000, 0.18).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()

    // --- 3 panneaux vidéo synchronisés ---
    let paneW: CGFloat = 192, paneH: CGFloat = 336, spacing: CGFloat = 44
    let total = paneW * 3 + spacing * 2
    let startX = (1024 - total) / 2
    let paneY: CGFloat = 300

    for i in 0..<3 {
        let x = startX + CGFloat(i) * (paneW + spacing)
        let rect = NSRect(x: x, y: paneY, width: paneW, height: paneH)
        let path = NSBezierPath(roundedRect: rect, xRadius: 38, yRadius: 38)

        // Dégradé interne du panneau (reflet vidéo)
        let shades = [color(0x262B42), color(0x10131F)]
        let g = NSGradient(colors: shades)!
        g.draw(in: path, angle: -90)

        // Bordure fine
        color(0xFFFFFF, 0.10).setStroke()
        path.lineWidth = 2.5
        path.stroke()

        // Reflet haut-gauche (verre)
        let gloss = NSBezierPath(roundedRect: NSRect(x: x + 10, y: paneY + paneH - 150, width: paneW - 20, height: 140), xRadius: 30, yRadius: 30)
        color(0xFFFFFF, 0.05).setFill()
        gloss.fill()

        // Vignette du panneau CENTRAL : triangle play
        if i == 1 {
            let play = NSBezierPath()
            play.move(to: NSPoint(x: x + paneW / 2 - 34, y: paneY + paneH / 2 + 46))
            play.line(to: NSPoint(x: x + paneW / 2 - 34, y: paneY + paneH / 2 - 46))
            play.line(to: NSPoint(x: x + paneW / 2 + 52, y: paneY + paneH / 2))
            play.close()
            color(0xFFFFFF, 0.92).setFill()
            play.fill()
        }
    }

    // --- Timeline synchronisée sous les panneaux ---
    let tlY: CGFloat = 196
    let tlX0: CGFloat = 150, tlX1: CGFloat = 874
    let tlPath = NSBezierPath(roundedRect: NSRect(x: tlX0, y: tlY, width: tlX1 - tlX0, height: 14), xRadius: 7, yRadius: 7)
    let tlGrad = NSGradient(colors: [color(0x35D0FF), color(0x4A6CF7)])!
    tlGrad.draw(in: tlPath, angle: 0)

    // Pistes secondaires (marques de frames)
    color(0xFFFFFF, 0.22).setFill()
    for i in 1..<10 {
        let mx = tlX0 + CGFloat(i) * (tlX1 - tlX0) / 10
        NSBezierPath(rect: NSRect(x: mx, y: tlY + 2, width: 3, height: 10)).fill()
    }

    // Tête de lecture (pastille) au centre = synchronisation
    let head = NSBezierPath(ovalIn: NSRect(x: 512 - 22, y: tlY + 14 - 10, width: 44, height: 44))
    color(0xFFFFFF).setFill()
    head.fill()
    color(0x4A6CF7, 0.35).setFill()
    NSBezierPath(ovalIn: NSRect(x: 512 - 36, y: tlY + 14 - 24, width: 72, height: 72)).fill()

    // Connecteurs panneaux → timeline (fils de synchro)
    color(0x4A6CF7, 0.45).setStroke()
    let wire = NSBezierPath()
    wire.lineWidth = 5
    for i in 0..<3 {
        let x = startX + CGFloat(i) * (paneW + spacing) + paneW / 2
        wire.move(to: NSPoint(x: x, y: paneY))
        wire.line(to: NSPoint(x: x, y: tlY + 14))
    }
    wire.stroke()
}

// MARK: - Export

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024.0, y: size / 1024.0)
    drawIconDesign()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)")
}

// Dossier de sortie
let outDir = "/Users/danyvassily/dev/trisync-work/Branding"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// Toutes les tailles (icns + assets Xcode)
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for s in sizes {
    savePNG(render(size: CGFloat(s.px)), to: "\(iconset)/\(s.name)")
}
// Logo pleine taille pour la promo (site, blog…)
savePNG(render(size: 1024), to: "\(outDir)/logo-trisync-1024.png")

print("Terminé — icônes dans \(outDir)")
