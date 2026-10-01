/// Config.swift

import Foundation
import MASShortcut

extension Defaults {
    static func encoded() -> String? {
        guard let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        
        let snapshot = Config.shortcutSnapshot()
        
        var codableDefaults = [String: CodableDefault]()
        for exportableDefault in Defaults.array {
            codableDefaults[exportableDefault.key] = exportableDefault.toCodable()
        }
                
        let config = Config(bundleId: "io.github.jduprat.Tugboat",
                            version: version,
                            shortcuts: snapshot.shortcuts,
                            defaults: codableDefaults,
                            clearedShortcuts: snapshot.clearedShortcuts.isEmpty ? nil : snapshot.clearedShortcuts)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encodedJson = try? encoder.encode(config) {
            if let jsonString = String(data: encodedJson, encoding: .utf8) {
                return jsonString
            }
        }
        return nil
    }
    
    static func convert(jsonString: String) -> Config? {
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Config.self, from: jsonData)
    }
    
    static func load(fileUrl: URL, notificationCenter: NotificationCenter = .default) {
        guard ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)) != nil else { return }
        
        // Size cap: legitimate configs are ~tens of KB; refuse anything that
        // looks abusive (defense against OOM via a giant config file).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 1_048_576 {
            return
        }
        
        guard let jsonString = try? String(contentsOf: fileUrl, encoding: .utf8),
              let config = convert(jsonString: jsonString) else { return }

        for availableDefault in Defaults.array {
            if let codedDefault = config.defaults[availableDefault.key] {
                availableDefault.load(from: codedDefault)
            }
        }
        
        config.applyShortcutPreferences()
        
        Notification.Name.configImported.post(center: notificationCenter)
    }
    
    static func loadFromSupportDir() {
        if let rectangleSupportURL = getSupportDir()?
            .appendingPathComponent("Tugboat", isDirectory: true) {
            
            let configURL = rectangleSupportURL.appendingPathComponent("TugboatConfig.json")
                        
            let exists = try? configURL.checkResourceIsReachable()
            if exists == true {
                // Defense-in-depth: any process running as this user can drop
                // a TugboatConfig.json in Application Support and have it
                // silently applied on next launch, overwriting shortcuts and
                // defaults. Require the user to confirm before loading.
                //
                // We also refuse symlinks (could redirect reads elsewhere) and
                // any file with world-write permission (suggests tampering).
                let path = configURL.path
                let fm = FileManager.default
                var isSafe = true
                
                if let attrs = try? fm.attributesOfItem(atPath: path) {
                    if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                        isSafe = false
                    }
                    if let perms = attrs[.posixPermissions] as? NSNumber,
                       (perms.intValue & 0o002) != 0 {
                        isSafe = false
                    }
                }
                
                guard isSafe else {
                    AlertUtil.oneButtonAlert(
                        question: "Refused to load TugboatConfig.json",
                        text: "The configuration file at \(path) is a symlink or world-writable. Tugboat has refused to load it. Remove the file or fix its permissions and try again."
                    )
                    try? fm.removeItem(at: configURL)
                    return
                }
                
                let response = AlertUtil.twoButtonAlert(
                    question: "Apply Tugboat configuration?",
                    text: "A configuration file was found at \(path). Applying it will overwrite your current Tugboat shortcuts and preferences. Apply now?",
                    confirmText: "Apply",
                    cancelText: "Discard"
                )
                guard response == .alertFirstButtonReturn else {
                    try? fm.removeItem(at: configURL)
                    return
                }
                
                load(fileUrl: configURL)
                do {
                    let newFilename = "TugboatConfig\(timestamp()).json"
                    
                    try fm.moveItem(atPath: configURL.path, toPath: rectangleSupportURL.appendingPathComponent(newFilename).path)
                } catch {
                    do {
                        try fm.removeItem(at: configURL)
                    } catch {
                        AlertUtil.oneButtonAlert(question: "Error after loading from Support Dir", text: "Unable to rename/remove TugboatConfig.json from \(rectangleSupportURL) after loading.")
                    }
                }
            }
        }
    }
    
    private static func getSupportDir() -> URL? {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths.isEmpty ? nil : paths[0]
    }
    
    private static func timestamp() -> String {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd_H-mm-ss-SSSS"
        return formatter.string(from: date)
    }
}

struct Config: Codable {
    let bundleId: String
    let version: String
    let shortcuts: [String: Shortcut]
    let defaults: [String: CodableDefault]
    /// Optional for old exports. An explicit clear must mask a registered default after import.
    var clearedShortcuts: [String]? = nil

    static func shortcutSnapshot(userDefaults: UserDefaults = .standard)
        -> (shortcuts: [String: Shortcut], clearedShortcuts: [String]) {
        let keys = WindowAction.active.map(\.name)
            + TodoManager.defaultsKeys + StackBadgeManager.defaultsKeys + ArrangementManager.defaultsKeys
        var shortcuts = [String: Shortcut]()
        var cleared = [String]()
        for key in keys {
            if userDefaults.dictionary(forKey: key)?.isEmpty == true {
                cleared.append(key)
            } else if let shortcut = ShortcutCycle.shortcut(forDefaultsKey: key, userDefaults: userDefaults),
                      shortcut.keyCode >= 0 {
                shortcuts[key] = Shortcut(masShortcut: shortcut)
            }
        }
        return (shortcuts, cleared)
    }

    /// Missing entries retain the historical import behavior. Only an explicit clear in a new
    /// export suppresses registered defaults; bindings retain their existing dictionary format.
    func applyShortcutPreferences(userDefaults: UserDefaults = .standard) {
        guard let transformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)) else { return }
        let cleared = Set(clearedShortcuts ?? [])
        func apply(_ shortcut: Shortcut?, key: String, explicitlyCleared: Bool) {
            if explicitlyCleared {
                userDefaults.set([String: Any](), forKey: key)
            } else if let shortcut, shortcut.keyCode >= 0 {
                userDefaults.set(transformer.reverseTransformedValue(shortcut.toMASSHortcut()), forKey: key)
            } else {
                userDefaults.removeObject(forKey: key)
            }
        }
        for action in WindowAction.active {
            let shortcut = shortcuts[action.name] ?? action.aliasName.flatMap { shortcuts[$0] }
            let clearAlias = shortcuts[action.name] == nil && action.aliasName.map { cleared.contains($0) } == true
            // A stale renamed preference must not restore a cleared binding during the rebind.
            if let alias = action.aliasName { userDefaults.removeObject(forKey: alias) }
            apply(shortcut, key: action.name, explicitlyCleared: cleared.contains(action.name) || clearAlias)
        }
        for key in TodoManager.defaultsKeys + StackBadgeManager.defaultsKeys + ArrangementManager.defaultsKeys {
            apply(shortcuts[key], key: key, explicitlyCleared: cleared.contains(key))
        }
    }
}
