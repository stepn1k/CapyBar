import ServiceManagement

/// "Open at Login" through `SMAppService.mainApp`: macOS lists CapyBar under
/// System Settings → General → Login Items and tells the user when it is added.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Returns an error description, or nil on success.
    @discardableResult
    static func set(_ isOn: Bool) -> String? {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
