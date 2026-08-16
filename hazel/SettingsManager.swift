import Foundation
import ServiceManagement

@Observable
class SettingsManager {
    static let shared = SettingsManager()

    var openOnStartup: Bool {
        get {
            UserDefaults.standard.bool(forKey: "openOnStartup")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "openOnStartup")
            updateLoginItem(enabled: newValue)
        }
    }
    
    private init() {
        _ = openOnStartup
    }
    
    private func updateLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update login item: \(error)")
            }
        }
    }
}
