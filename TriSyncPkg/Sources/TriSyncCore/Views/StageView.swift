import SwiftUI

/// Scène multi-vidéos intégrant tous les presets bento et le redimensionnement libre.
public struct StageView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var settings: AppSettings

    public init() {}

    private var loadedSlots: [Int] {
        library.slots.enumerated().compactMap { $0.element != nil ? $0.offset : nil }
    }

    public var body: some View {
        GeometryReader { geo in
            slotGrid(in: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: loadedSlots.count)
        }
    }

    @ViewBuilder
    private func slotGrid(in size: CGSize) -> some View {
        let slots = loadedSlots
        let aspects = slots.compactMap { library.slots[$0].map { settings.targetAspect(for: $0) } }
        let spacing: CGFloat = 10
        let preset = settings.isValidPreset(settings.layoutPreset, forCount: slots.count)
            ? settings.layoutPreset : .auto

        if slots.isEmpty {
            HStack(spacing: spacing) {
                ForEach(0..<VideoLibrary.maxSlots, id: \.self) { slot in
                    StagePane(slot: slot)
                }
            }
        } else {
            switch preset {
            case .custom:
                customGrid(slots: slots, size: size, spacing: spacing)
            case .auto:
                autoGrid(slots: slots, aspects: aspects, size: size, spacing: spacing)
            case .sideBySide:
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
            case .stacked:
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
            case .masterH:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    pane(slots[1]).frame(width: max(1, size.width * 0.38))
                }
            case .masterV:
                VStack(spacing: spacing) {
                    pane(slots[0]).frame(maxHeight: .infinity)
                    pane(slots[1]).frame(height: max(1, size.height * 0.38))
                }
            case .threeColumns:
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
            case .masterTwo:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) { pane(slots[1]); pane(slots[2]) }
                        .frame(maxWidth: .infinity)
                }
            case .threeRows:
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
            case .grid2x2:
                HStack(spacing: spacing) {
                    VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
                    VStack(spacing: spacing) { pane(slots[2]); pane(slots[3]) }
                }
            case .fourColumns:
                HStack(spacing: spacing) {
                    pane(slots[0]); pane(slots[1]); pane(slots[2]); pane(slots[3])
                }
            case .masterThree:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) { pane(slots[1]); pane(slots[2]); pane(slots[3]) }
                        .frame(maxWidth: .infinity)
                }
            case .wall32:
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
                    HStack(spacing: spacing) { pane(slots[3]); pane(slots[4]) }
                }
            case .wall23:
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
                    HStack(spacing: spacing) { pane(slots[2]); pane(slots[3]); pane(slots[4]) }
                }
            case .fiveColumns:
                HStack(spacing: spacing) {
                    pane(slots[0]); pane(slots[1]); pane(slots[2]); pane(slots[3]); pane(slots[4])
                }
            case .masterFour:
                HStack(spacing: spacing) {
                    pane(slots[0]).frame(maxWidth: .infinity)
                    VStack(spacing: spacing) {
                        HStack(spacing: spacing) { pane(slots[1]); pane(slots[2]) }
                        HStack(spacing: spacing) { pane(slots[3]); pane(slots[4]) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func pane(_ slot: Int) -> some View {
        StagePane(slot: slot)
    }

    // MARK: - Layout Libre (Custom Weights)

    @ViewBuilder
    private func customGrid(slots: [Int], size: CGSize, spacing: CGFloat) -> some View {
        let totalSpacing = spacing * CGFloat(max(0, slots.count - 1))
        let availableWidth = max(0, size.width - totalSpacing)
        let weights = slots.map { settings.weight(for: $0) }
        let totalWeight = weights.reduce(0, +)
        let safeTotal = totalWeight > 0 ? totalWeight : 1.0

        HStack(spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                let w = CGFloat(weights[index] / safeTotal) * availableWidth
                pane(slot)
                    .frame(width: max(80, w))

                if index < slots.count - 1 {
                    CustomResizeDivider(
                        leftSlot: slot,
                        rightSlot: slots[index + 1],
                        availableWidth: availableWidth
                    )
                    .frame(width: spacing)
                }
            }
        }
    }

    // MARK: - Layout Auto Responsive

    @ViewBuilder
    private func autoGrid(slots: [Int], aspects: [CGFloat], size: CGSize, spacing: CGFloat) -> some View {
        switch slots.count {
        case 1:
            pane(slots[0])
        case 2:
            if size.width > size.height {
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
            } else {
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
            }
        case 3:
            HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
        case 4:
            HStack(spacing: spacing) {
                VStack(spacing: spacing) { pane(slots[0]); pane(slots[1]) }
                VStack(spacing: spacing) { pane(slots[2]); pane(slots[3]) }
            }
        case 5:
            VStack(spacing: spacing) {
                HStack(spacing: spacing) { pane(slots[0]); pane(slots[1]); pane(slots[2]) }
                HStack(spacing: spacing) { pane(slots[3]); pane(slots[4]) }
            }
        default:
            HStack(spacing: spacing) {
                ForEach(slots, id: \.self) { pane($0) }
            }
        }
    }
}

/// Séparateur interactif de redimensionnement de blocs (layout Libre).
private struct CustomResizeDivider: View {
    @EnvironmentObject private var settings: AppSettings
    let leftSlot: Int
    let rightSlot: Int
    let availableWidth: CGFloat

    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(isHovered ? triAccent : Color.white.opacity(0.18))
                .frame(width: isHovered ? 4 : 2, height: 40)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let delta = Double(value.translation.width / max(1, availableWidth))
                    settings.adjustWeight(delta, left: leftSlot, right: rightSlot)
                }
        )
    }
}
