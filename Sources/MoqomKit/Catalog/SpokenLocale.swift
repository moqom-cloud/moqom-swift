// A language tag, as a publisher claims it.
//
// BCP 47 rather than a Foundation `Locale`, because this value leaves the
// device: it is written into the catalog, read by every other client, and
// peeked by the relay so the control plane can store it. Those readers do not
// share our runtime, and a tag they can all parse is a string.

import Foundation

/// A BCP 47 language tag a participant publishes about themselves.
public enum SpokenLocale {
    /// Longest tag we will send or accept.
    ///
    /// Typical tags are `en`, `en-US`, `zh-Hans-CN`. Anything longer is almost
    /// certainly a paste or a bug, and a catalog is the one document a third
    /// party reads without our code, so a bound here is a bound on what the
    /// relay will store.
    public static let maxLength = 35

    /// What this device is set to, right now.
    ///
    /// Underscores become hyphens (`en_US` → `en-US`) so the wire form is BCP 47
    /// rather than Foundation's identifier. `und` only if the system has
    /// nothing we can normalise, which a real phone does not do.
    public static func current() -> String {
        normalize(Locale.current.identifier(.bcp47)) ?? "und"
    }

    /// A tag we will put on the wire, or `nil` if it is not one.
    ///
    /// Empty, oversized, or not shaped like a language tag is refused rather
    /// than passed through: a catalog is forwarded to every subscriber and
    /// stored by the control plane, and neither should have to sanitise what
    /// we sent.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty, tag.count <= maxLength else { return nil }
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...8).contains(language.count),
              language.allSatisfy(\.isLetter)
        else { return nil }
        guard parts.dropFirst().allSatisfy({ part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isLetter || $0.isNumber }
        }) else { return nil }
        return tag
    }
}
