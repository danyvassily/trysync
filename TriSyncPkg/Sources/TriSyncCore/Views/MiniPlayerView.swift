import SwiftUI
import CoreMedia

/// Mini-lecteur flottant draggable type Picture-in-Picture au-dessus de la bibliothèque.
public struct MiniPlayerView: View {
    @EnvironmentObject private var engine: SyncEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: VideoLibrary
    public var onClose: () -> Void = {}

    public init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    private var referenceVideoSize: CGSize {
        guard let slot = engine.currentReferenceSlot,
              library.slots.indices.contains(slot),
              let asset = library.slots[slot] else { return .zero }
        return asset.size
    }

    public var body: some View {
        VStack(spacing: 0) {
            VideoPaneView(
                player: engine.referencePlayer(),
                displayMode: settings.displayMode.videoMode,
                videoSize: referenceVideoSize,
                cropOffset: settings.verticalOffset.value,
                zoom: settings.advancedScale.value,
                immersiveMode: false,
                seekOnArrows: false
            )
            .frame(width: 280, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button {
                    engine.togglePlay()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(triAccent))
                }
                .buttonStyle(.plain)

                Text(timeString(engine.timelineTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let drift = engine.maxDriftMilliseconds, drift >= 5 {
                    Text("Δ \(drift) ms")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.yellow)
                }

                Spacer(minLength: 4)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .frame(width: 280)
    }
}
