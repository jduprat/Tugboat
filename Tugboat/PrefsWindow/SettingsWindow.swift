import AppKit

final class SettingsWindow: NSWindow {
    fileprivate var animatesTabResize = false
    fileprivate private(set) var isAnimatingTabResize = false
    private var activeTabResizeTarget: NSRect?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if shouldDeferTabResizeTarget(frameRect) {
            return
        }
        if isAnimatingTabResize {
            applyAnimationFrame(frameRect, display: flag)
        } else if shouldAnimateTabResize(to: frameRect) {
            setAnimatedTabFrame(frameRect, display: flag)
        } else {
            super.setFrame(frameRect, display: flag)
        }
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        if shouldDeferTabResizeTarget(frameRect) {
            return
        }
        if isAnimatingTabResize {
            applyAnimationFrame(frameRect, display: displayFlag)
        } else if shouldAnimateTabResize(to: frameRect) {
            setAnimatedTabFrame(frameRect, display: displayFlag)
        } else {
            super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
        }
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        isAnimatingTabResize ? 0.2 : super.animationResizeTime(newFrame)
    }

    private func shouldAnimateTabResize(to frameRect: NSRect) -> Bool {
        animatesTabResize && isVisible && !inLiveResize && !isAnimatingTabResize
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && frameRect.size != frame.size
    }

    private func shouldDeferTabResizeTarget(_ frameRect: NSRect) -> Bool {
        isAnimatingTabResize && frameRect == activeTabResizeTarget
    }

    private func applyAnimationFrame(_ frameRect: NSRect, display: Bool) {
        // Native interpolation callbacks must not start another animation.
        super.setFrame(frameRect, display: display)
    }

    private func setAnimatedTabFrame(_ frameRect: NSRect, display: Bool) {
        isAnimatingTabResize = true
        activeTabResizeTarget = frameRect
        defer {
            activeTabResizeTarget = nil
            isAnimatingTabResize = false
        }
        // Keep the frame AppKit resolved from the selected pane's layout.
        super.setFrame(frameRect, display: display, animate: true)
        // Layout repeatedly requests this endpoint during interpolation. Apply
        // it once after the native animation has finished its intermediate frames.
        activeTabResizeTarget = nil
        if frame != frameRect {
            super.setFrame(frameRect, display: display)
        }
    }
}

final class SettingsTabViewController: NSTabViewController {
    private var selectionRequest: UInt = 0
    private var queuedSelection: (item: NSTabViewItem, request: UInt)?

    private var settingsWindow: SettingsWindow? {
        isViewLoaded ? view.window as? SettingsWindow : nil
    }

    override func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        guard super.tabView(tabView, shouldSelect: tabViewItem) else { return false }
        selectionRequest &+= 1
        guard let tabViewItem, settingsWindow?.isAnimatingTabResize == true else {
            queuedSelection = nil
            return true
        }
        // Keep another pane from supplying a competing frame during the resize.
        queuedSelection = (tabViewItem, selectionRequest)
        return false
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if tabView.selectedTabViewItem !== tabViewItem {
            settingsWindow?.animatesTabResize = true
        }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let window = settingsWindow
        defer {
            window?.animatesTabResize = false
            replayQueuedSelection()
        }
        super.tabView(tabView, didSelect: tabViewItem)
        // Resolve the pane's frame before leaving the animation scope.
        window?.layoutIfNeeded()
    }

    private func replayQueuedSelection() {
        guard let queuedSelection else { return }
        self.queuedSelection = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectionRequest == queuedSelection.request,
                  let index = self.tabViewItems.firstIndex(where: { $0 === queuedSelection.item }),
                  index != self.selectedTabViewItemIndex else { return }
            self.selectedTabViewItemIndex = index
        }
    }
}
