import Foundation
import ServiceManagement

/// Wraps SMAppService (macOS 13+) for registering the app as a login item.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success. Throws-free: errors are swallowed and reflected by `isEnabled`.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            print("[LaunchAtLogin] failed to set \(enabled): \(error)")
            return false
        }
    }
}
