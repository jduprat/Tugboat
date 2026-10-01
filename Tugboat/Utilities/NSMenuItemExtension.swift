/// NSMenuItemExtension.swift

import Cocoa

extension NSMenuItem {

    /// From macOS 27 AppKit decides whether a menu item's image is shown, and it usually hides it.
    /// Tugboat's menu is a list of window layouts, where the small picture of the layout is the point,
    /// so the items that carry one ask to keep it.
    func keepImageVisible() {
        if #available(macOS 27, *) {
            preferredImageVisibility = .visible
        }
    }
}
