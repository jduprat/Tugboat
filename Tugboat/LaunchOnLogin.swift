/// LaunchOnLogin.swift

import Foundation
import ServiceManagement
import os.log

public enum LaunchOnLogin {
    public static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
            return Defaults.launchOnLogin.enabled
        }
        set {
            guard #available(macOS 13.0, *) else {
                let success = SMLoginItemSetEnabled("io.github.jduprat.TugboatLauncher" as CFString, newValue)
                if success { Defaults.launchOnLogin.enabled = newValue }
                else { os_log("Failed to change the legacy login item") }
                return
            }
            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled {
                        try? SMAppService.mainApp.unregister()
                    }
                    
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                os_log("Failed to \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            }
        }
    }
}
