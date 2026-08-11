import Foundation
import AVFoundation

/// Regroupe les ressources AVFoundation d'un slot de lecture multi-vidéos.
final class SlotState: @unchecked Sendable {
    let slot: Int
    let url: URL
    let asset: AVAsset
    let item: AVPlayerItem
    let player: AVPlayer

    var timeObserver: Any?
    var statusObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?

    var volume: Float = 1.0
    var muted = false
    var userAdjustedMute = false
    var ended = false

    init(slot: Int, url: URL, asset: AVAsset, item: AVPlayerItem, player: AVPlayer) {
        self.slot = slot
        self.url = url
        self.asset = asset
        self.item = item
        self.player = player
    }
}
