import Foundation

/// The user's real home directory, bypassing any sandbox container redirection.
///
/// `NSHomeDirectory()` and `FileManager.urls(for:in:)` return a *container* path
/// inside a sandboxed process. Hazel itself is unsandboxed, but the screen saver
/// is loaded into Apple's sandboxed `legacyScreenSaver` extension, where those
/// APIs point somewhere useless. The passwd database reports the real home in
/// both cases.
enum RealHomeDirectory {
    static var url: URL {
        if let pw = getpwuid(getuid()) {
            let dir = String(cString: pw.pointee.pw_dir)
            if !dir.isEmpty {
                return URL(fileURLWithPath: dir, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
