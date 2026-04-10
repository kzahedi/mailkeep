import Foundation
import ServiceManagement

/// Service for managing app launch at login using SMAppService
@MainActor
class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()

    @Published var isEnabled: Bool {
        didSet {
            if isEnabled {
                enable()
            } else {
                disable()
            }
        }
    }

    private init() {
        // Check current status
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }

    private func enable() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("Failed to enable launch at login: \(error)")
            // Revert the change
            isEnabled = false
        }
    }

    private func disable() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            print("Failed to disable launch at login: \(error)")
            // Revert the change
            isEnabled = true
        }
    }

    /// Check if launch at login is currently enabled
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
