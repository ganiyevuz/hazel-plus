import Foundation

/// What macOS currently has selected as the screen saver, as far as Hazel can tell.
enum ScreenSaverSelection: Equatable {
    /// An aerial asset whose ID matches a video in Hazel's library.
    case hazelWallpaper(UUID)
    /// An aerial asset that belongs to something else (Apple's own, or another app).
    case otherApp
    /// A non-aerial choice, e.g. a plain image, or nothing set.
    case notAnAerial
    /// The store could not be read or understood.
    ///
    /// Deliberately distinct from `notAnAerial`: "we couldn't read it" and
    /// "nothing is set" are different facts and must not show the same message.
    case unknown
}
