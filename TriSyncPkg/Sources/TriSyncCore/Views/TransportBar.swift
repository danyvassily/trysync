import SwiftUI

/// Barre de transport principale de TriSync (Apple HIG / Glassmorphism).
public struct TransportBar: View {
    @EnvironmentObject private var library: VideoLibrary
    @EnvironmentObject private var engine: SyncEngine

    private static let rates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var rate: Float = 1.0
    @State private var playHover = false

    public init() {}

    private var loadedCount: Int { library.slots.compactMap { $0 }.count }
    private var canPlay: Bool { loadedCount > 0 && engine.readyCount >= loadedCount }

    public var body: some View {
        HStack(spacing: 12) {
            playButton
            barIconButton(systemName: "stop.fill", help: "Arrêter") { engine.stop() }
            barIconButton(systemName: "gobackward.10", help: "Reculer de 10 s") { engine.skip(by: -10) }
            barIconButton(systemName: "goforward.10", help: "Avancer de 10 s") { engine.skip(by: 10) }
            barIconButton(systemName: "arrow.triangle.2.circlepath", help: "Resynchroniser") { engine.resync() }
            barIconButton(systemName: "shuffle", help: "Mélanger les files de lecture") { library.shuffleQueues() }

            ratePicker
            scrubber
            timeLabel
            Spacer(minLength: 8)
            statusLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            resumeBanner
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            if engine.currentRate > 0 { rate = engine.currentRate }
        }
        .onChange(of: engine.leaderTime.seconds) { _, _ in syncScrub() }
        .onChange(of: rate) { _, newValue in engine.setRate(newValue) }
        .onChange(of: engine.currentRate) { _, newValue in
            if newValue != rate { rate = newValue }
        }
    }

    // MARK: - Boutons & Contrôles

    private var playButton: some View {
        Button {
            engine.togglePlay()
        } label: {
            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(triAccent))
                .scaleEffect(playHover ? 1.05 : 1.0)
                .shadow(color: triAccent.opacity(playHover ? 0.45 : 0.2), radius: playHover ? 8 : 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1.0 : 0.35)
        .keyboardShortcut(.space, modifiers: [])
        .help(engine.isPlaying ? "Pause (Espace)" : "Lecture (Espace)")
        .onHover { playHover = $0 }
    }

    private func barIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var ratePicker: some View {
        Picker("Vitesse", selection: $rate) {
            ForEach(Self.rates, id: \.self) { value in
                Text(rateLabel(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 72)
        .help("Vitesse de lecture")
    }

    private var scrubber: some View {
        Slider(value: $scrub, in: 0...1) { editing in
            if editing {
                isScrubbing = true
                engine.beginScrub()
            } else {
                isScrubbing = false
                engine.endScrub(atFraction: scrub)
            }
        }
        .frame(minWidth: 140, maxWidth: 280)
        .disabled(loadedCount == 0)
    }

    private var timeLabel: some View {
        Text("\(independentPrefix)\(timeString(engine.timelineTime)) / \(timeString(engine.timelineDuration))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 120, alignment: .leading)
    }

    private var independentPrefix: String {
        guard let slot = engine.independentSlot, engine.timelineDuration.seconds > 0 else { return "" }
        return slotLetters[slot] + " · "
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 90, alignment: .trailing)
    }

    private var statusText: String {
        if engine.isPlaying { return "Lecture sync" }
        if loadedCount > 0 && engine.readyCount < loadedCount {
            return "Chargement \(engine.readyCount)/\(loadedCount)…"
        }
        return "Prêt"
    }

    // MARK: - Bandeau de Reprise

    @ViewBuilder
    private var resumeBanner: some View {
        if let offer = engine.resumeOffer {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(triAccent)
                Text("Reprendre à \(offer.label)")
                    .font(.system(size: 12, weight: .semibold))
                Button {
                    engine.acceptResumeOffer()
                } label: {
                    Text("Reprendre")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(triAccent))
                }
                .buttonStyle(.plain)

                Button {
                    engine.declineResumeOffer()
                } label: {
                    Text("Recommencer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func syncScrub() {
        guard !isScrubbing else { return }
        let time = engine.timelineTime
        let duration = engine.timelineDuration.seconds
        guard time.isNumeric, duration.isFinite, duration > 0 else { return }
        scrub = min(max(time.seconds / duration, 0), 1)
    }

    private func rateLabel(_ value: Float) -> String {
        value == value.rounded()
            ? String(format: "%.0f×", value)
            : String(format: "%.2f×", value)
    }
}
