import SwiftUI

/// Écran d'accueil accueillant avec animation douce et CTA d'importation.
public struct EmptyStateView: View {
    @State private var pulsing = false
    @State private var buttonHover = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .opacity(pulsing ? 0.45 : 0.85)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulsing)

            Text("Jusqu'à 5 vidéos, parfaitement synchronisées")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 16)

            Text("Glissez des fichiers vidéo dans la fenêtre ou choisissez un dossier.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Button {
                let urls = openVideosPanel()
                if !urls.isEmpty {
                    NotificationCenter.default.post(name: .triSyncIngestVideos, object: urls)
                }
            } label: {
                Label("Choisir des vidéos…", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(triAccent))
                    .scaleEffect(buttonHover ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .onHover { buttonHover = $0 }

            Spacer()
            Spacer().frame(height: 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulsing = true }
    }
}

public extension Notification.Name {
    static let triSyncIngestVideos = Notification.Name("TriSync.IngestVideos")
}
