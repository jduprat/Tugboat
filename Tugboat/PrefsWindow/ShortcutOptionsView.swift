import Cocoa

/// A contextual editor for existing, shared engine preferences. These are not
/// properties of a shortcut binding: changes are saved independently of Save.
final class ShortcutOptionsView: NSView {
    private let stack = NSStackView()
    private var selectedAction: WindowAction?
    private var selectedDefaultsKey = ""
    private var expandedSections = Set<String>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(action: WindowAction?, defaultsKey: String) {
        selectedAction = action
        selectedDefaultsKey = defaultsKey
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if TodoManager.defaultsKeys.contains(defaultsKey) || action == .leftTodo || action == .rightTodo {
            heading("Shared sidebar settings")
            sidebarOptions()
            return
        }
        guard let action = action else {
            note("This command has no additional behavior settings.")
            return
        }

        switch action {
        case .tileRows, .tileColumns, .tileActiveAppRows, .tileActiveAppColumns:
            heading("Shared tiling settings")
            check("Keep row and column layouts when displays change", preference: Defaults.maintainTiledLayouts, defaultEnabled: true)
            note("Keeps the same window order and proportions. A single-window placement command releases that window from the group. Moving a member to another display moves its group.")
            if action == .tileActiveAppRows || action == .tileActiveAppColumns { applicationScope(action) }
            return
        case .tileAll, .tileActiveApp:
            note("Tiles eligible windows on the current Space and display in a grid. Grid layouts are applied once.")
            return
        case .reverseAll:
            note("Mirrors window positions from left to right on the current display, keeping their sizes. Run again to reverse them back.")
            return
        case .cascadeAll, .cascadeActiveApp:
            heading("Shared cascade settings")
            number("Window offset", preference: Defaults.cascadeAllDeltaSize, unit: "px", minimum: 1)
            return
        default: break
        }

        heading("Shared window settings")
        let isSide = [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(action)
        let isCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(action)
        let isMove = [.moveLeft, .moveRight, .moveUp, .moveDown].contains(action)

        if action.positionCycles || isMove {
            repeatedCommandOptions(cycleSizes: isSide || isCorner || action == .centerHalf || isMove)
        }
        if isSide {
            check("Keep the other dimension’s size", preference: Defaults.halvesPreserveOtherAxisSize)
            disclosure("Side layout options", key: "side") { content in
                let horizontal = action == .leftHalf || action == .rightHalf
                self.number(horizontal ? "Left-side width" : "Top-side height",
                            preference: horizontal ? Defaults.horizontalSplitRatio : Defaults.verticalSplitRatio,
                            unit: "%", minimum: 1, maximum: 99, in: content) {
                    ActiveSideSplitRatios.shared.resetAll()
                }
                self.cooperativeOptions(in: content)
            }
        }
        if isCorner {
            disclosure("Corner layout options", key: "corner") { content in
                self.popup("Expand", items: [("Horizontally", 0), ("Vertically", 1)],
                           selected: Defaults.cornerCycleExpansionAxis.value.rawValue, in: content) { value in
                    if let axis = CornerCycleExpansionAxis(rawValue: value) {
                        Defaults.cornerCycleExpansionAxis.value = axis
                    }
                }
                self.cooperativeOptions(in: content)
            }
        }

        switch action {
        case .maximize, .almostMaximize, .maximizeHeight:
            if action != .maximizeHeight {
                check("Repeat to restore the previous size", preference: Defaults.repeatedMaximizeRestoresPrevious)
            }
            if action == .almostMaximize {
                fraction("Width", preference: Defaults.almostMaximizeWidth, fallback: 0.9)
                fraction("Height", preference: Defaults.almostMaximizeHeight, fallback: 0.9)
            } else {
                check("Apply window gaps", preference: action == .maximize ? Defaults.applyGapsToMaximize : Defaults.applyGapsToMaximizeHeight,
                      defaultEnabled: true)
            }
        case .specified:
            number("Width", preference: Defaults.specifiedWidth, unit: "px / fraction", minimum: 0.01)
            number("Height", preference: Defaults.specifiedHeight, unit: "px / fraction", minimum: 0.01)
            note("Values from 0 to 1 are fractions of the display; larger values are pixels.")
        case .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight:
            let widthOnly = action == .largerWidth || action == .smallerWidth
            number("Resize step", preference: widthOnly ? Defaults.widthStepSize : Defaults.sizeOffset,
                   unit: "px", minimum: 1, effectiveValue: widthOnly ? nil : max(1, Defaults.sizeOffset.value > 0 ? Defaults.sizeOffset.value : 30))
            check("Keep edges against the display", preference: Defaults.curtainChangeSize, defaultEnabled: true)
            if action == .smaller {
                check("Also shrink a full-height window", preference: Defaults.smallerShrinksMaximizedHeight)
            }
            disclosure("Minimum window size", key: "minimum") { content in
                self.minimumFraction("Width", preference: Defaults.minimumWindowWidth, in: content)
                self.minimumFraction("Height", preference: Defaults.minimumWindowHeight, in: content)
            }
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            check("Resize when moving to an edge", preference: Defaults.resizeOnDirectionalMove)
            check("Center on the other axis", preference: Defaults.centeredDirectionalMove, defaultEnabled: true)
        case .nextDisplay, .previousDisplay, .displayOne, .displayTwo, .displayThree, .displayFour,
             .displayFive, .displaySix, .displaySeven, .displayEight, .displayNine:
            check("Preserve relative placement", preference: Defaults.attemptMatchOnNextPrevDisplay)
            if action == .nextDisplay || action == .previousDisplay {
                check("Keep maximized windows maximized", preference: Defaults.autoMaximize, defaultEnabled: true)
            }
            check("Move the pointer to the new display", preference: Defaults.moveCursorAcrossDisplays)
        default: break
        }

        // Gap and overlap controls are only offered for actions which use them.
        if action.gapsApplicable != .none || action.overlapOffsetApplies || action == .maximize || action == .maximizeHeight {
            disclosure("Spacing and overlaps", key: "spacing") { content in
                if action.gapsApplicable != .none || action == .maximize || action == .maximizeHeight {
                    self.number("Window gap", preference: Defaults.gapSize, unit: "px", minimum: 0, in: content)
                    self.check("Skip the top-edge gap", preference: Defaults.skipGapTopEdge, in: content)
                }
                if action.overlapOffsetApplies {
                    self.check("Offset overlapping windows", preference: Defaults.cyclingOverlapOffset, in: content)
                    self.number("Overlap offset", preference: Defaults.cyclingOverlapOffsetSize, unit: "px", minimum: 0, in: content)
                }
            }
        }
        disclosure("Pointer options", key: "pointer") { content in
            self.check("Move pointer to the window after a shortcut", preference: Defaults.moveCursor, in: content)
        }
    }

    private func heading(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        add(label)
        note("Changes apply immediately to every command using these settings, independently of saving this shortcut.")
    }

    private func repeatedCommandOptions(cycleSizes: Bool) {
        popup("On repeat", items: [
            ("Do nothing", SubsequentExecutionMode.none.rawValue),
            ("Cycle displays", SubsequentExecutionMode.cycleMonitor.rawValue),
            ("Cycle side and corner sizes", SubsequentExecutionMode.resize.rawValue),
            ("Adjacent display on left / right", SubsequentExecutionMode.acrossMonitor.rawValue),
            ("Adjacent display + cycle other sizes", SubsequentExecutionMode.acrossAndResize.rawValue),
            ("Cycle corner positions + side sizes", SubsequentExecutionMode.resizeAndCycleQuadrants.rawValue)
        ], selected: Defaults.subsequentExecutionMode.value.rawValue) { [weak self] value in
            guard let mode = SubsequentExecutionMode(rawValue: value) else { return }
            Defaults.subsequentExecutionMode.value = mode
            self?.refresh()
        }
        guard cycleSizes && Defaults.subsequentExecutionMode.resizes else { return }
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.addArrangedSubview(NSTextField(labelWithString: "Cycle sizes"))
        let selected = Defaults.cycleSizesIsChanged.enabled ? Defaults.selectedCycleSizes.value : CycleSize.defaultSizes
        for size in CycleSize.sortedSizes {
            let button = ShortcutOptionCheckbox(title: size.title, enabled: selected.contains(size)) { enabled in
                if !Defaults.cycleSizesIsChanged.enabled {
                    Defaults.selectedCycleSizes.value = CycleSize.defaultSizes
                }
                Defaults.cycleSizesIsChanged.enabled = true
                if enabled {
                    Defaults.selectedCycleSizes.value.insert(size)
                } else {
                    Defaults.selectedCycleSizes.value.remove(size)
                }
            }
            row.addArrangedSubview(button)
        }
        add(row)
    }

    private func cooperativeOptions(in content: NSStackView) {
        check("Resize adjacent windows together", preference: Defaults.cooperativeCornerResize, in: content)
        note("Applies when cycling side and corner commands.", in: content)
    }

    private func sidebarOptions() {
        check("Enable sidebar commands", preference: Defaults.todo) {
            Notification.Name.todoMenuToggled.post()
        }
        number("Sidebar width", preference: Defaults.todoSidebarWidth,
               unit: Defaults.todoSidebarWidthUnit.value.description, minimum: 1,
               maximum: Defaults.todoSidebarWidthUnit.value == .pct ? 100 : nil) {
            TodoManager.moveAllIfNeeded(false)
        }
        popup("Width unit", items: [("Pixels", TodoSidebarWidthUnit.pixels.rawValue), ("Percent", TodoSidebarWidthUnit.pct.rawValue)],
              selected: Defaults.todoSidebarWidthUnit.value.rawValue) { [weak self] value in
            guard let unit = TodoSidebarWidthUnit(rawValue: value), unit != Defaults.todoSidebarWidthUnit.value else { return }
            Defaults.todoSidebarWidthUnit.value = unit
            TodoManager.refreshTodoScreen()
            TodoManager.changeSidebarWidthUnit(to: unit)
            TodoManager.moveAllIfNeeded(false)
            self?.refresh()
        }
        popup("Sidebar side", items: [("Left", TodoSidebarSide.left.rawValue), ("Right", TodoSidebarSide.right.rawValue)],
              selected: Defaults.todoSidebarSide.value.rawValue) { value in
            guard let side = TodoSidebarSide(rawValue: value) else { return }
            Defaults.todoSidebarSide.value = side
            TodoManager.moveAllIfNeeded(false)
        }
    }

    private func refresh() {
        configure(action: selectedAction, defaultsKey: selectedDefaultsKey)
    }

    private func add(_ view: NSView, to destination: NSStackView? = nil) {
        let destination = destination ?? stack
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        destination.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: destination.widthAnchor).isActive = true
    }

    private func applicationScope(_ action: WindowAction) {
        let selected = Defaults.tilingApplications.typedValue?[action.name]
        var identifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        identifiers.remove(Bundle.main.bundleIdentifier ?? "")
        identifiers.insert("com.apple.Terminal")
        if let selected { identifiers.insert(selected) }
        let apps = identifiers.compactMap { id -> (String, String)? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                return id == selected ? (id, id + " (unavailable)") : nil
            }
            return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        let ids = [String?](arrayLiteral: nil) + apps.map { Optional($0.0) }
        popup("Application", items: [("Current app", 0)] + apps.enumerated().map { ($0.element.1, $0.offset + 1) },
              selected: ids.firstIndex(of: selected) ?? 0) { index in
            var scopes = Defaults.tilingApplications.typedValue ?? [:]
            scopes[action.name] = ids[index]
            Defaults.tilingApplications.typedValue = scopes
        }
        note("A named app's visible windows are brought to the active display, even when another app has focus. This setting applies immediately to this command.")
    }

    private func note(_ text: String, in destination: NSStackView? = nil) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 350
        add(label, to: destination)
    }

    private func check(_ title: String, preference: BoolDefault, in destination: NSStackView? = nil,
                       changed: (() -> Void)? = nil) {
        add(ShortcutOptionCheckbox(title: title, enabled: preference.enabled) { value in
            preference.enabled = value
            changed?()
        }, to: destination)
    }

    private func check(_ title: String, preference: OptionalBoolDefault, defaultEnabled: Bool = false,
                       in destination: NSStackView? = nil, changed: (() -> Void)? = nil) {
        add(ShortcutOptionCheckbox(title: title, enabled: preference.enabled ?? defaultEnabled) { value in
            preference.enabled = value
            changed?()
        }, to: destination)
    }

    private func popup(_ title: String, items: [(String, Int)], selected: Int, in destination: NSStackView? = nil,
                       changed: @escaping (Int) -> Void) {
        let popup = ShortcutOptionPopup(items: items, selected: selected, changed: changed)
        add(row(title, control: popup), to: destination)
    }

    private func number(_ title: String, preference: FloatDefault, unit: String, minimum: Float, maximum: Float? = nil,
                        effectiveValue: Float? = nil, in destination: NSStackView? = nil, changed: (() -> Void)? = nil) {
        let field = ShortcutOptionNumberField(value: effectiveValue ?? preference.value, minimum: minimum, maximum: maximum) { value in
            preference.value = value
            changed?()
        }
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let controls = NSStackView(views: [field, NSTextField(labelWithString: unit)])
        controls.spacing = 5
        add(row(title, control: controls), to: destination)
    }

    private func fraction(_ title: String, preference: FloatDefault, fallback: Float) {
        let value = preference.value > 0 && preference.value <= 1 ? preference.value : fallback
        let field = ShortcutOptionNumberField(value: value * 100, minimum: 1, maximum: 100) {
            preference.value = $0 / 100
        }
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        add(row(title, control: NSStackView(views: [field, NSTextField(labelWithString: "%")])))
    }

    private func minimumFraction(_ title: String, preference: DoubleDefault, in destination: NSStackView) {
        let value = preference.value.isFinite && (0...1).contains(preference.value) ? preference.value : 0.25
        let field = ShortcutOptionNumberField(value: Float(value * 100), minimum: 0, maximum: 100) {
            preference.value = Double($0) / 100
        }
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        add(row(title, control: NSStackView(views: [field, NSTextField(labelWithString: "% of display") ])), to: destination)
    }

    private func row(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func disclosure(_ title: String, key: String, build: (NSStackView) -> Void) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        let button = ShortcutOptionCheckbox(title: title, enabled: expandedSections.contains(key)) { [weak self, weak content] enabled in
            if enabled { self?.expandedSections.insert(key) } else { self?.expandedSections.remove(key) }
            content?.isHidden = !enabled
        }
        button.setButtonType(.onOff)
        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")
        button.alternateImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        build(content)
        content.isHidden = !expandedSections.contains(key)
        add(button)
        add(content)
    }
}

private final class ShortcutOptionCheckbox: NSButton {
    private let changed: (Bool) -> Void

    init(title: String, enabled: Bool, changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        font = .systemFont(ofSize: 12)
        state = enabled ? .on : .off
        target = self
        action = #selector(updateValue)
        alignment = .left
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func updateValue() { changed(state == .on) }
}

private final class ShortcutOptionPopup: NSPopUpButton {
    private let changed: (Int) -> Void

    init(items: [(String, Int)], selected: Int, changed: @escaping (Int) -> Void) {
        self.changed = changed
        super.init(frame: .zero, pullsDown: false)
        font = .systemFont(ofSize: 12)
        for (title, tag) in items {
            addItem(withTitle: title)
            lastItem?.tag = tag
        }
        selectItem(withTag: selected)
        target = self
        action = #selector(updateValue)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func updateValue() { changed(selectedTag()) }
}

private final class ShortcutOptionNumberField: NSTextField, NSTextFieldDelegate {
    private let changed: (Float) -> Void
    private let minimum: Float
    private let maximum: Float?
    private var savedValue: Float

    init(value: Float, minimum: Float, maximum: Float?, changed: @escaping (Float) -> Void) {
        self.changed = changed
        self.minimum = minimum
        self.maximum = maximum
        savedValue = value
        super.init(frame: .zero)
        font = .systemFont(ofSize: 12)
        alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 3
        formatter.minimum = NSNumber(value: minimum)
        if let maximum = maximum { formatter.maximum = NSNumber(value: maximum) }
        self.formatter = formatter
        floatValue = value
        delegate = self
        target = self
        action = #selector(commit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ notification: Notification) { saveIfValid() }

    func controlTextDidEndEditing(_ notification: Notification) {
        saveIfValid()
        floatValue = savedValue
    }

    @objc private func commit() {
        saveIfValid()
        floatValue = savedValue
    }

    private func saveIfValid() {
        guard let formatter = formatter as? NumberFormatter,
              let value = formatter.number(from: stringValue)?.floatValue,
              value.isFinite, value >= minimum, maximum.map({ value <= $0 }) ?? true,
              value != savedValue else { return }
        savedValue = value
        changed(value)
    }
}
