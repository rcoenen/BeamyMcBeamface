@preconcurrency import Foundation

// UI controller is confined to the main thread; mark unchecked to silence
// Sendable warnings from GCD closures used for background discovery.
extension TermKitTranscoderUI: @unchecked Sendable {}
