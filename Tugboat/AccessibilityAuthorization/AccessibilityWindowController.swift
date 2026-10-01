/// AccessibilityWindowController.swift

import Cocoa

class AccessibilityWindowController: NSWindowController {
    
    override func windowDidLoad() {
        super.windowDidLoad()
        let closeButton = self.window?.standardWindowButton(.closeButton)
        closeButton?.target = self
        closeButton?.action = #selector(quit)
    }
    
    @objc func quit() {
        exit(1)
    }
    
}

class AccessibilityViewController: NSViewController {
    
    @IBAction func requestAccess(_ sender: Any) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @IBAction func openSystemPrefs(_ sender: Any) {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
