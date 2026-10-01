/// AboutCredits.swift

import Cocoa

/// The About panel's build provenance and acknowledgements for the projects Tugboat builds on.
enum AboutCredits {

    private static let lineage = (
        text: NSLocalizedString("about.lineage", tableName: "Main",
                                value: "Tugboat is a fork of Rectangle by Ryan Hanson, itself based on Spectacle by Eric Czarny, both MIT licensed.",
                                comment: "About panel: the projects Tugboat is descended from"),
        links: [("Rectangle", "https://github.com/rxhanson/Rectangle"),
                ("Spectacle", "https://github.com/eczarny/spectacle")]
    )

    private static let arrangements = (
        text: NSLocalizedString("about.arrangements", tableName: "Main",
                                value: "Remembering where your windows go, down to a separate set of windows per display configuration, comes from Stay by Cordless Dog. Stay is closed source, so none of its code is here, only the debt.",
                                comment: "About panel: the app whose idea the window arrangements follow"),
        links: [("Stay", "https://cordlessdog.com/stay/")]
    )

    static var attributedString: NSAttributedString {
        attributedString(infoDictionary: Bundle.main.infoDictionary)
    }

    static func attributedString(infoDictionary: [String: Any]?) -> NSAttributedString {
        let details = buildDetails(infoDictionary: infoDictionary)
        let credits = NSMutableAttributedString(string: details)
        let detailsRange = NSRange(location: 0, length: credits.length)
        for paragraph in [lineage, arrangements] {
            credits.append(NSAttributedString(string: "\n\n"))
            credits.append(linked(paragraph.text, paragraph.links))
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttributes([.paragraphStyle: style,
                               .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
                              range: NSRange(location: 0, length: credits.length))
        credits.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                             range: detailsRange)
        return credits
    }

    private static func buildDetails(infoDictionary: [String: Any]?) -> String {
        let unknown = NSLocalizedString("about.build.unknown", tableName: "Main", value: "Unknown",
                                        comment: "About panel: build metadata was unavailable")
        let commitFormat = NSLocalizedString("about.build.commit", tableName: "Main", value: "Commit: %@",
                                             comment: "About panel: the full Git commit ID used for this build")
        let treeFormat = NSLocalizedString("about.build.workingTree", tableName: "Main", value: "Working tree: %@",
                                           comment: "About panel: whether the source tree had uncommitted changes")
        let branchFormat = NSLocalizedString("about.build.branch", tableName: "Main", value: "Branch: %@",
                                             comment: "About panel: the Git branch used for this build")

        let rawCommit = metadataString("TugboatGitCommit", in: infoDictionary)
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let commit = rawCommit.flatMap { value in
            [40, 64].contains(value.count) && value.unicodeScalars.allSatisfy(hexadecimal.contains) ? value : nil
        } ?? unknown

        let treeState: String
        switch metadataString("TugboatGitTreeState", in: infoDictionary) {
        case "clean":
            treeState = NSLocalizedString("about.build.clean", tableName: "Main", value: "Clean",
                                          comment: "About panel: the source tree had no uncommitted changes")
        case "dirty":
            treeState = NSLocalizedString("about.build.dirty", tableName: "Main", value: "Dirty",
                                          comment: "About panel: the source tree had uncommitted changes")
        default:
            treeState = unknown
        }

        var lines = [String(format: commitFormat, commit), String(format: treeFormat, treeState)]
        switch metadataString("TugboatGitBranch", in: infoDictionary) {
        case "main":
            break
        case "HEAD":
            lines.append(NSLocalizedString("about.build.detachedHead", tableName: "Main", value: "Detached HEAD",
                                           comment: "About panel: the build used a detached Git commit, not a branch"))
        case let branch?:
            lines.append(String(format: branchFormat, branch))
        case nil:
            lines.append(String(format: branchFormat, unknown))
        }
        return lines.joined(separator: "\n")
    }

    private static func metadataString(_ key: String, in infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Turns each name that appears in the sentence into a link, leaving a translation that drops or
    /// renames one of them as plain text rather than mislinking it.
    private static func linked(_ text: String, _ links: [(name: String, url: String)]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        for (name, url) in links {
            guard let range = text.range(of: name), let url = URL(string: url) else { continue }
            attributed.addAttribute(.link, value: url, range: NSRange(range, in: text))
        }
        return attributed
    }
}
