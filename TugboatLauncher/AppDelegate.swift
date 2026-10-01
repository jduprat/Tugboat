/// AppDelegate.swift

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if #available(macOS 13, *) {
            terminate()
            return
        }
        let mainAppIdentifier = "io.github.jduprat.Tugboat"
        let running = NSWorkspace.shared.runningApplications
        let isRunning = !running.filter({$0.bundleIdentifier == mainAppIdentifier}).isEmpty
        
        if isRunning {
            self.terminate()
        } else {
            let killNotification = Notification.Name("killLauncher")
            DistributedNotificationCenter.default().addObserver(self,
                                                                selector: #selector(self.terminate),
                                                                name: killNotification,
                                                                object: mainAppIdentifier)
            // This launcher lives in Tugboat.app/Contents/Library/LoginItems, so four levels up is
            // the app itself. The modern API opens an app bundle, not the executable inside it.
            let mainAppURL = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            NSWorkspace.shared.openApplication(at: mainAppURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    
    @objc func terminate() {
        NSApp.terminate(nil)
    }

}

