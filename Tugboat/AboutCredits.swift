/// AboutCredits.swift

import Cocoa

/// What the About panel says about where Tugboat comes from: the project it is forked from, the one
/// that project came from, and the app whose idea the arrangements half follows.
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
        let credits = NSMutableAttributedString()
        for paragraph in [lineage, arrangements] {
            if credits.length > 0 {
                credits.append(NSAttributedString(string: "\n\n"))
            }
            credits.append(linked(paragraph.text, paragraph.links))
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttributes([.paragraphStyle: style,
                               .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
                              range: NSRange(location: 0, length: credits.length))
        return credits
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
