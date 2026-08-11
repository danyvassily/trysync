import Foundation
import CoreMedia

/// Formate un CMTime en « m:ss » (ou « h:mm:ss » au-delà d'une heure).
/// Les durées nulles, négatives, indéfinies ou non numériques renvoient « 0:00 ».
public func timeString(_ t: CMTime) -> String {
    guard t.isNumeric, t.seconds.isFinite else { return "0:00" }
    let total = max(0, Int(t.seconds.rounded()))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}
