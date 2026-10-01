import Cocoa

// macOS 12 login items require an embedded app; newer systems use SMAppService.
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 13.0, *) { NSApp.terminate(nil); return }
        let identifier = "io.github.jduprat.Tugboat"
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == identifier }) else {
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(terminate),
            name: Notification.Name("killLauncher"), object: identifier)
        let url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    @objc private func terminate() { NSApp.terminate(nil) }
}
let app = NSApplication.shared
let delegate = LauncherDelegate()
app.delegate = delegate
app.run()
