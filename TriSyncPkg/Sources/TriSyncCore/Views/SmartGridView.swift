import SwiftUI
import CoreMedia

/// Grille réutilisable pour les dossiers intelligents (« Récemment ajoutés », « À regarder », « Reprendre »).
public struct SmartGridView: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var session: SessionState
    public let title: String
    public let assets: [VideoAsset]
    public var showsResumeBadge = false
    public var onLaunch: ([VideoAsset]) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 152), spacing: 12)]

    public init(
        title: String,
        assets: [VideoAsset],
        showsResumeBadge: Bool = false,
        onLaunch: @escaping ([VideoAsset]) -> Void = { _ in }
    ) {
        self.title = title
        self.assets = assets
        self.showsResumeBadge = showsResumeBadge
        self.onLaunch = onLaunch
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(assets.count) vidéo\(assets.count > 1 ? "s" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if library.selectedOrder.count > VideoLibrary.maxSlots {
                    Text("\(library.selectedOrder.count - VideoLibrary.maxSlots) en trop — max \(VideoLibrary.maxSlots)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !library.selectedOrder.isEmpty {
                    Button {
                        launchSelection()
                    } label: {
                        Label("Lancer (\(min(library.selectedOrder.count, VideoLibrary.maxSlots)))", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(triAccent))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(assets) { asset in
                        LibraryCard(
                            asset: asset,
                            resumeText: showsResumeBadge ? resumeText(for: asset) : nil,
                            onDoubleClick: {
                                library.selectOnly(asset)
                                launchSelection()
                            }
                        )
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.25))
    }

    private func resumeText(for asset: VideoAsset) -> String? {
        let pos = library.playbackPosition(for: asset.url)
        guard pos > 15 else { return nil }
        return "Repris " + timeString(CMTime(seconds: pos, preferredTimescale: 600))
    }

    private func launchSelection() {
        let selected = library.selectedAssets
        guard !selected.isEmpty else { return }
        library.launchSelected()
        onLaunch(selected)
    }
}
