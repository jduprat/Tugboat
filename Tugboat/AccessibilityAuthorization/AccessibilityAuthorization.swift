/// AccessibilityAuthorization.swift

import Foundation
import Cocoa

class AccessibilityAuthorization {
    
    private var accessibilityWindowController: NSWindowController?
    weak var windowActivationCoordinator: WindowActivationCoordinator?
    
    public func checkAccessibility(completion: @escaping () -> Void) -> Bool {
        if !AXIsProcessTrusted() {
            
            accessibilityWindowController = NSStoryboard(name: "Main", bundle: nil).instantiateController(withIdentifier: "AccessibilityWindowController") as? NSWindowController
            showAuthorizationWindow()
            pollAccessibility(completion: completion)
            return false
        } else {
            return true
        }
    }
    
    private func pollAccessibility(completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if AXIsProcessTrusted() {
                self.accessibilityWindowController?.close()
                self.accessibilityWindowController = nil
                completion()
            } else {
                self.pollAccessibility(completion: completion)
            }
        }
    }
    
    func showAuthorizationWindow() {
        if let window = accessibilityWindowController?.window {
            windowActivationCoordinator?.register(window)
            if window.isMiniaturized {
                window.deminiaturize(self)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        accessibilityWindowController?.showWindow(self)
    }
    
}
