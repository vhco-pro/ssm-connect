import Foundation
import ServiceManagement

/// Controls "Launch at Login" via `SMAppService.mainApp` (G8, F-02, ADR-3).
protocol LoginItemControlling: Sendable {
    /// Whether the app is currently registered as a login item (reflects System Settings).
    var isEnabled: Bool { get }
    /// Register or unregister the app as a login item.
    func setEnabled(_ enabled: Bool) throws
}

/// Real implementation backed by `SMAppService.mainApp` (macOS 13+, ADR-3).
struct SMAppServiceLoginItem: LoginItemControlling {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
