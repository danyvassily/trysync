import AppKit

// NSImage instances in TriSync are created or loaded by the thumbnail cache,
// then consumed by SwiftUI on the main actor. AppKit does not declare NSImage
// Sendable in the macOS 14 SDK, so Swift 5.10's complete concurrency checking
// cannot prove this transfer is safe. We keep the boundary explicit and
// centralized instead of weakening concurrency checking for the whole target.
extension NSImage: @unchecked Sendable {}
