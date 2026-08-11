import Foundation

/// Standardise et résout les alias de chemins macOS (/private/tmp, /private/var…).
public func canonicalPath(for url: URL) -> String {
    var path = url.resolvingSymlinksInPath().standardizedFileURL.path
    if path.hasPrefix("/private/tmp") {
        path = "/tmp" + path.dropFirst("/private/tmp".count)
    } else if path.hasPrefix("/private/var") {
        path = "/var" + path.dropFirst("/private/var".count)
    }
    return path
}
