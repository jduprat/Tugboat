import Cocoa
import MASShortcut

/// The recorder is unbound: key and action edits are committed together only on Save.
class PrefsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    typealias Command = ShortcutEditorModel.Command
    private struct Draft {
        var command: Command
        var shortcut: MASShortcut?
    }
    var model = ShortcutEditorModel()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let recorder = MASShortcutView(frame: NSRect(x: 0, y: 0, width: 175, height: 25))
    private let recordingObserver = ShortcutRecordingObserver()
    private let familyPicker = NSPopUpButton()
    private let categoryPicker = NSPopUpButton()
    private let actionPicker = NSPopUpButton()
    private let presetPicker = NSPopUpButton()
    private let heading = NSTextField(labelWithString: "Shortcut")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let conflictLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private let options = ShortcutOptionsView(frame: .zero)
    private let resolutionPicker = NSPopUpButton()
    private let replaceTarget = NSButton(checkboxWithTitle: "Replace this action’s existing shortcut", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Shortcut", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var rows = [(id: String, command: Command)]()
    private var selectedID: String?
    private var drafts = [String: Draft]()
    private var dirtyDrafts = Set<String>()
    private var hasNewDraft = false
    private var actionChoices = [Command]()
    private var observers = [NSObjectProtocol]()
    private var updating = false
    private let newID = "__new_shortcut__"

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 800, height: 560)
        buildInterface()
        recordingObserver.observe([recorder])
        recorder.shortcutValueChange = { [weak self] sender in
            guard let self, !self.updating, let id = self.selectedID, var draft = self.drafts[id] else { return }
            draft.shortcut = sender.shortcutValue
            self.drafts[id] = draft
            self.dirtyDrafts.insert(id)
            self.resolutionPicker.selectItem(at: 0)
            self.statusLabel.stringValue = ""
            self.refreshConflicts()
            self.table.reloadData()
        }
        for name in [UserDefaults.didChangeNotification, .configImported, .changeDefaults, .allowAnyShortcut] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isViewLoaded else { return }
                if let id = self.selectedID, !self.dirtyDrafts.contains(id),
                   let command = self.originalCommand, let draft = self.drafts[id],
                   !self.sameKey(draft.shortcut, self.model.shortcut(for: command)) {
                    self.drafts[id] = Draft(command: command, shortcut: self.model.shortcut(for: command))
                    if !self.recorder.isRecording { self.renderEditor() }
                }
                self.reloadList()
                self.recorder.shortcutValidator = Defaults.allowAnyShortcut.enabled ? PassthroughShortcutValidator() : EditorShortcutValidator()
                self.refreshConflicts()
            })
        }
        reloadList()
        if let first = rows.first { select(first.id) } else { addShortcut(nil) }
    }

    override func viewWillAppear() { super.viewWillAppear(); reloadList() }
    override func viewWillDisappear() { recorder.isRecording = false; super.viewWillDisappear() }
    deinit {
        recorder.isRecording = false
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func buildInterface() {
        let left = NSView(), right = NSView()
        let separator = NSBox()
        separator.boxType = .separator
        for child in [left, separator, right] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor), left.topAnchor.constraint(equalTo: view.topAnchor),
            left.bottomAnchor.constraint(equalTo: view.bottomAnchor), left.widthAnchor.constraint(equalToConstant: 276),
            separator.leadingAnchor.constraint(equalTo: left.trailingAnchor), separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor), separator.widthAnchor.constraint(equalToConstant: 1),
            right.leadingAnchor.constraint(equalTo: separator.trailingAnchor), right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            right.topAnchor.constraint(equalTo: view.topAnchor), right.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "Your Shortcuts")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let add = NSButton(title: "＋", target: self, action: #selector(addShortcut(_:)))
        add.bezelStyle = .rounded
        add.setAccessibilityLabel("Add shortcut")
        let header = horizontal([title, NSView(), add])
        search.placeholderString = "Find shortcut"
        search.delegate = self
        search.setAccessibilityLabel("Find assigned shortcut")
        search.controlSize = .small
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        nameColumn.width = 160
        nameColumn.minWidth = 90
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keys"))
        keyColumn.width = 89
        keyColumn.minWidth = 65
        keyColumn.maxWidth = 100
        table.addTableColumn(nameColumn); table.addTableColumn(keyColumn)
        table.headerView = nil
        table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 4, height: 1)
        table.style = .plain
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Assigned shortcuts")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        presetPicker.addItems(withTitles: ["Presets…", "Rectangle + Tugboat", "Compact", "App Tiling"])
        presetPicker.target = self
        presetPicker.action = #selector(applyPreset(_:))
        presetPicker.controlSize = .small
        presetPicker.setAccessibilityLabel("Shortcut presets")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let footer = horizontal([countLabel, NSView(), presetPicker])
        for child in [header, search, listScroll, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: header.leadingAnchor), search.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            listScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 5),
            listScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -5),
            listScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 7),
            listScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -10)
        ])

        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        recorder.style = .texturedRect
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 175).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 25).isActive = true
        recorder.setAccessibilityLabel("Record keyboard shortcut")
        let hint = NSTextField(wrappingLabelWithString: "Click to record. Esc cancels.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        familyPicker.addItems(withTitles: ShortcutEditorModel.Family.allCases.map(\.rawValue))
        familyPicker.target = self; familyPicker.action = #selector(familyChanged(_:))
        familyPicker.setAccessibilityLabel("Action family")
        categoryPicker.target = self; categoryPicker.action = #selector(categoryChanged(_:))
        categoryPicker.setAccessibilityLabel("Placement type")
        actionPicker.target = self; actionPicker.action = #selector(actionChanged(_:))
        actionPicker.setAccessibilityLabel("Action")
        for picker in [familyPicker, categoryPicker, actionPicker] { picker.controlSize = .small }
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 76).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 64).isActive = true
        summary.font = .systemFont(ofSize: 12)
        let explanation = horizontal([preview, summary])
        explanation.spacing = 12
        conflictLabel.font = .systemFont(ofSize: 12)
        conflictLabel.textColor = .secondaryLabelColor
        resolutionPicker.addItems(withTitles: ["Choose how to use this key…", "Replace conflicting shortcuts", "Cycle through these actions"])
        resolutionPicker.target = self; resolutionPicker.action = #selector(resolutionChanged(_:))
        resolutionPicker.controlSize = .small
        replaceTarget.target = self; replaceTarget.action = #selector(resolutionChanged(_:))
        replaceTarget.controlSize = .small
        let content = NSStackView(views: [heading, labeled("Keyboard", horizontal([recorder, hint])),
                                         labeled("Action", familyPicker), categoryPicker, actionPicker, explanation,
                                         conflictLabel, resolutionPicker, replaceTarget, options])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedShortcutView()
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(scroll)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        for button in [removeButton, cancelButton, saveButton] { button.bezelStyle = .rounded; button.target = self }
        removeButton.action = #selector(removeShortcut(_:))
        cancelButton.action = #selector(cancelEditing(_:))
        saveButton.action = #selector(saveShortcut(_:))
        saveButton.keyEquivalent = "\r"
        let buttons = horizontal([removeButton, NSView(), cancelButton, saveButton])
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [statusLabel, buttons])
        bottom.orientation = .vertical; bottom.alignment = .leading; bottom.spacing = 6
        bottom.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(bottom)
        buttons.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: right.topAnchor), scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -6),
            bottom.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -12)
        ])
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        return stack
    }

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 62).isActive = true
        return horizontal([label, control])
    }
    private var originalCommand: Command? { ShortcutEditorModel.catalog.first { $0.id == selectedID } }
    private var currentDraft: Draft? { selectedID.flatMap { drafts[$0] } }

    private func reloadList() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = model.assignedBindings.map(\.command).filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.family.rawValue.localizedCaseInsensitiveContains(query)
                || keyLabel(model.shortcut(for: $0)).localizedCaseInsensitiveContains(query)
        }.map { ($0.id, $0) }
        if query.isEmpty, let original = originalCommand, dirtyDrafts.contains(original.id), !rows.contains(where: { $0.id == original.id }) {
            rows.append((original.id, original))
        }
        if hasNewDraft, let draft = drafts[newID] { rows.append((newID, draft.command)) }
        updating = true
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            // Filtering must never highlight a different action while the inspector holds a draft.
            table.deselectAll(nil)
        }
        updating = false
        countLabel.stringValue = "\(model.assignedBindings.count) shortcuts"
    }

    private func select(_ id: String) {
        recorder.isRecording = false
        selectedID = id
        if !dirtyDrafts.contains(id) { drafts.removeValue(forKey: id) }
        if drafts[id] == nil, let command = ShortcutEditorModel.catalog.first(where: { $0.id == id }) {
            drafts[id] = Draft(command: command, shortcut: model.shortcut(for: command))
        }
        resolutionPicker.selectItem(at: 0); replaceTarget.state = .off
        statusLabel.stringValue = ""
        renderEditor(); reloadList()
    }

    private func renderEditor() {
        guard let draft = currentDraft else { return }
        updating = true
        recorder.shortcutValidator = Defaults.allowAnyShortcut.enabled ? PassthroughShortcutValidator() : EditorShortcutValidator()
        recorder.shortcutValue = draft.shortcut
        familyPicker.selectItem(withTitle: draft.command.family.rawValue)
        heading.stringValue = draft.command.title
        let commands = ShortcutEditorModel.catalog.filter { $0.family == draft.command.family }
        let categories = Array(Set(commands.map { section(for: $0) })).sorted()
        categoryPicker.removeAllItems(); categoryPicker.addItems(withTitles: categories)
        categoryPicker.selectItem(withTitle: section(for: draft.command))
        categoryPicker.isHidden = categories.count < 2
        actionChoices = commands.filter { section(for: $0) == section(for: draft.command) }
        actionPicker.removeAllItems(); actionPicker.addItems(withTitles: actionChoices.map(\.title))
        actionPicker.selectItem(at: actionChoices.firstIndex(where: { $0.id == draft.command.id }) ?? 0)
        preview.image = draft.command.windowAction?.image ?? NSImage(systemSymbolName: draft.command.family == .record ? "square.and.arrow.down" : "rectangle.on.rectangle", accessibilityDescription: draft.command.title)
        summary.stringValue = draft.command.summary
        options.configure(action: draft.command.windowAction, defaultsKey: draft.command.id)
        removeButton.isEnabled = selectedID != newID
        updating = false
        refreshConflicts()
    }

    private func section(for command: Command) -> String {
        guard command.family == .place, let action = command.windowAction else { return command.family.rawValue }
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf: return "Halves"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "Corners"
        case .maximize: return "Maximize"
        default: return action.category?.displayName ?? "Other Placements"
        }
    }

    private func changeCommand(_ command: Command) {
        guard let id = selectedID, var draft = drafts[id] else { return }
        draft.command = command; drafts[id] = draft
        dirtyDrafts.insert(id)
        resolutionPicker.selectItem(at: 0); replaceTarget.state = .off
        renderEditor(); reloadList()
    }
    @objc private func familyChanged(_ sender: NSPopUpButton) {
        let family = ShortcutEditorModel.Family.allCases[sender.indexOfSelectedItem]
        if let command = ShortcutEditorModel.catalog.first(where: { $0.family == family }) { changeCommand(command) }
    }
    @objc private func categoryChanged(_ sender: NSPopUpButton) {
        guard let draft = currentDraft, let name = sender.titleOfSelectedItem,
              let command = ShortcutEditorModel.catalog.first(where: { $0.family == draft.command.family && section(for: $0) == name }) else { return }
        changeCommand(command)
    }
    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard actionChoices.indices.contains(sender.indexOfSelectedItem) else { return }
        changeCommand(actionChoices[sender.indexOfSelectedItem])
    }

    private func refreshConflicts() {
        guard let draft = currentDraft else { return }
        let conflicts = draft.shortcut.map { model.conflicts(for: $0, assigning: draft.command, replacing: originalCommand) } ?? []
        let saved = model.shortcut(for: draft.command)
        let targetAlreadyAssigned = draft.command.id != originalCommand?.id && saved != nil
        replaceTarget.isHidden = !targetAlreadyAssigned
        if let saved { replaceTarget.title = "Replace \(draft.command.title)’s \(keyLabel(saved)) binding" }
        let unchanged = draft.command.id == originalCommand?.id && sameKey(draft.shortcut, saved)
        let canShare = model.canShareCycle(command: draft.command, conflicts: conflicts)
        resolutionPicker.item(at: 2)?.isEnabled = canShare
        resolutionPicker.isHidden = conflicts.isEmpty || unchanged
        let names = conflicts.map { $0.command.title }
        conflictLabel.stringValue = conflicts.isEmpty ? "" : (unchanged ? "Shared key: " : "Also assigned to ") + names.joined(separator: ", ") + "."
        conflictLabel.isHidden = conflicts.isEmpty
        saveButton.isEnabled = draft.shortcut != nil
            && (!targetAlreadyAssigned || replaceTarget.state == .on)
            && (conflicts.isEmpty || unchanged || resolutionPicker.indexOfSelectedItem == 1
                || (resolutionPicker.indexOfSelectedItem == 2 && canShare))
    }
    @objc private func resolutionChanged(_ sender: Any) { refreshConflicts() }

    @objc private func addShortcut(_ sender: Any?) {
        if hasNewDraft { select(newID); return }
        let command = ShortcutEditorModel.catalog.first { model.shortcut(for: $0) == nil } ?? ShortcutEditorModel.catalog[0]
        hasNewDraft = true
        drafts[newID] = Draft(command: command, shortcut: nil)
        dirtyDrafts.insert(newID)
        search.stringValue = ""
        select(newID)
    }

    @objc private func saveShortcut(_ sender: Any?) {
        guard saveButton.isEnabled, let id = selectedID, let draft = currentDraft, let shortcut = draft.shortcut else { return }
        recorder.isRecording = false
        let unchanged = originalCommand?.id == draft.command.id && sameKey(shortcut, model.shortcut(for: draft.command))
        // Existing intentional cycles remain valid, even for legacy actions no longer offered for new cycles.
        if unchanged {
            drafts.removeValue(forKey: id); dirtyDrafts.remove(id); select(draft.command.id)
            statusLabel.stringValue = "Shortcut unchanged. Shared settings save automatically."
            return
        }
        let resolution: ShortcutEditorModel.ConflictResolution = resolutionPicker.indexOfSelectedItem == 1 ? .replaceConflicts
            : resolutionPicker.indexOfSelectedItem == 2 ? .shareCycle : .reject
        do {
            try model.save(command: draft.command, shortcut: shortcut, replacing: originalCommand, resolution: resolution)
            drafts.removeValue(forKey: id)
            dirtyDrafts.remove(id)
            if id == newID { hasNewDraft = false }
            // A draft for the target action must not survive replacing its binding.
            drafts.removeValue(forKey: draft.command.id)
            dirtyDrafts.remove(draft.command.id)
            select(draft.command.id)
            statusLabel.stringValue = "Saved. The shortcut is ready to use."
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    @objc private func cancelEditing(_ sender: Any?) {
        recorder.isRecording = false
        guard let id = selectedID else { return }
        drafts.removeValue(forKey: id)
        dirtyDrafts.remove(id)
        if id == newID {
            hasNewDraft = false; selectedID = nil; reloadList()
            if let first = rows.first { select(first.id) } else { addShortcut(nil) }
        } else { select(id) }
    }

    @objc private func removeShortcut(_ sender: Any?) {
        guard let command = originalCommand else { return }
        recorder.isRecording = false
        drafts.removeValue(forKey: command.id); dirtyDrafts.remove(command.id); selectedID = nil
        model.clear(command); reloadList()
        if let first = rows.first { select(first.id) } else { addShortcut(nil) }
        statusLabel.stringValue = "Removed \(command.title). Add it again at any time."
    }

    @objc private func applyPreset(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index > 0 else { return }
        let name = sender.titleOfSelectedItem ?? "Preset"
        sender.selectItem(at: 0); recorder.isRecording = false
        let alert = NSAlert()
        alert.messageText = "Apply \(name) shortcuts?"
        alert.informativeText = "This replaces your shortcut bindings and discards shortcut drafts. Window behavior and snap areas stay as configured."
        alert.addButton(withTitle: "Apply Preset"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.applyPreset(index == 1 ? .tugboat : index == 2 ? .compact : .appTiling)
            drafts.removeAll(); dirtyDrafts.removeAll(); hasNewDraft = false; selectedID = nil; search.stringValue = ""
            reloadList()
            if let first = rows.first { select(first.id) }
            statusLabel.stringValue = "Applied \(name)."
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let draft = dirtyDrafts.contains(entry.id) ? drafts[entry.id] : nil
        let shortcut = draft == nil ? model.shortcut(for: entry.command) : draft?.shortcut
        let title = draft?.command.title ?? entry.command.title
        let value = tableColumn?.identifier.rawValue == "keys" ? keyLabel(shortcut) : title + (entry.id == newID ? " (new)" : "")
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
        label.toolTip = title + "  " + keyLabel(shortcut)
        label.alignment = tableColumn?.identifier.rawValue == "keys" ? .right : .left
        label.setAccessibilityLabel(label.toolTip)
        let cell = NSTableCellView()
        cell.textField = label; label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow) else { return }
        select(rows[table.selectedRow].id)
    }
    func controlTextDidChange(_ obj: Notification) { reloadList() }
    private func sameKey(_ a: MASShortcut?, _ b: MASShortcut?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return ShortcutCycle.ShortcutIdentity(a) == ShortcutCycle.ShortcutIdentity(b)
    }
    private func keyLabel(_ shortcut: MASShortcut?) -> String {
        guard let shortcut else { return "—" }
        return shortcut.modifierFlagsString + (shortcut.keyCodeString ?? "")
    }
}

private class FlippedShortcutView: NSView { override var isFlipped: Bool { true } }
/// App conflicts are resolved explicitly after recording; system validation is retained.
private class EditorShortcutValidator: MASShortcutValidator {
    override func isShortcut(_ shortcut: MASShortcut!, alreadyTakenIn menu: NSMenu!, explanation: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool { false }
}
class PassthroughShortcutValidator: MASShortcutValidator {
    override func isShortcutValid(_ shortcut: MASShortcut!) -> Bool { true }
    override func isShortcutAlreadyTaken(bySystem shortcut: MASShortcut!, explanation: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool { false }
    override func isShortcut(_ shortcut: MASShortcut!, alreadyTakenIn menu: NSMenu!, explanation: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Bool { false }
}
