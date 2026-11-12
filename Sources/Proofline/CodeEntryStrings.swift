import Foundation

/// What a code-entry view is showing. A `CodeResult` reduced to the states a screen draws
/// differently; use `ProoflineCodeEntryView`'s `onResult` when you need the full result (for
/// example the redemption URL).
public enum ProoflineCodeEntryState: Sendable, Equatable {
    /// Nothing submitted yet, or the user edited the code after the last result.
    case idle
    /// A submission is in flight.
    case submitting
    /// The code was accepted for this creator; `offerLabel` is the offer it unlocks, when any.
    case success(creator: CreatorSummary, offerLabel: String?)
    /// No creator code matches ("code not found").
    case notFound
    case expired
    case exhausted
    case revoked
    /// The device is offline. The entry is queued and sent when the connection is back; the user
    /// does not need to retry.
    case offline
    /// The code could not be checked (server error, code entry turned off, SDK not configured).
    case failed

    public init(_ result: CodeResult) {
        switch result {
        case let .accepted(creator, _, offerLabel): self = .success(creator: creator, offerLabel: offerLabel)
        case .unknownCode: self = .notFound
        case .expired: self = .expired
        case .exhausted: self = .exhausted
        case .revoked: self = .revoked
        case .queued: self = .offline
        case .error: self = .failed
        }
    }
}

/// Every user-facing string of the code-entry views (`ProoflineCodeEntryView`, `CodeEntryField`,
/// `PasteCodeButton`).
///
/// `init()` reads the localised defaults: first a `Proofline.strings` table in the host app's main
/// bundle (add one to translate the SDK into more languages or reword it), then the table shipped
/// in the package's resources (English), then the same English text compiled into the SDK. Any
/// property can also be set in code.
///
/// `success` and `successWithOffer` are templates: `{creator}` is replaced with the creator's
/// display name and `{offer}` with the offer text.
public struct ProoflineCodeEntryStrings: Sendable, Equatable {
    /// Placeholder of the code text field.
    public var placeholder: String
    /// Accessibility label of the code text field.
    public var fieldLabel: String
    /// Title of the submit button.
    public var submit: String
    /// Accessibility label of the progress indicator, and the message while submitting.
    public var submitting: String
    /// Template for an accepted code without an offer. Tokens: `{creator}`.
    public var success: String
    /// Template for an accepted code with an offer. Tokens: `{offer}`, `{creator}`.
    public var successWithOffer: String
    public var notFound: String
    public var expired: String
    public var exhausted: String
    public var revoked: String
    /// Shown when the entry was queued offline. It is sent automatically, so do not ask for a retry.
    public var offline: String
    public var failed: String
    /// Accessibility hint of `PasteCodeButton`'s system paste control.
    public var pasteHint: String

    /// The localised defaults (see the type's documentation for the lookup order).
    public init() {
        self.init { ProoflineLocalization.string($0) }
    }

    /// The English text compiled into the SDK, without any bundle lookup.
    public static var english: ProoflineCodeEntryStrings {
        ProoflineCodeEntryStrings { $0.english }
    }

    init(lookup: (ProoflineLocalization.Key) -> String) {
        placeholder = lookup(.placeholder)
        fieldLabel = lookup(.fieldLabel)
        submit = lookup(.submit)
        submitting = lookup(.submitting)
        success = lookup(.success)
        successWithOffer = lookup(.successWithOffer)
        notFound = lookup(.notFound)
        expired = lookup(.expired)
        exhausted = lookup(.exhausted)
        revoked = lookup(.revoked)
        offline = lookup(.offline)
        failed = lookup(.failed)
        pasteHint = lookup(.pasteHint)
    }

    /// The text to show for a state: nil while idle, `submitting` while a submission is in flight,
    /// otherwise the result message with its tokens filled in.
    public func message(for state: ProoflineCodeEntryState) -> String? {
        switch state {
        case .idle: return nil
        case .submitting: return submitting
        case let .success(creator, offerLabel):
            if let offerLabel, !offerLabel.isEmpty {
                return Self.fill(successWithOffer, ["offer": offerLabel, "creator": creator.name])
            }
            return Self.fill(success, ["creator": creator.name])
        case .notFound: return notFound
        case .expired: return expired
        case .exhausted: return exhausted
        case .revoked: return revoked
        case .offline: return offline
        case .failed: return failed
        }
    }

    /// Replaces `{name}` tokens in one pass, so a value that itself contains a token (a creator
    /// named "{offer}") is never substituted again. Unknown tokens and stray braces stay as written.
    /// Not a format string: a translation cannot crash the app with a bad specifier.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest[rest.index(after: open)...]
            if let close = afterOpen.firstIndex(of: "}"), let value = values[String(afterOpen[..<close])] {
                out += value
                rest = afterOpen[afterOpen.index(after: close)...]
            } else {
                out.append("{")
                rest = afterOpen
            }
        }
        out += rest
        return out
    }
}

/// Looks up the SDK's localised strings without ever trapping: SwiftPM's generated resource-bundle
/// accessor stops the process when the bundle is missing, and the SDK must not crash a host app
/// over a status line.
enum ProoflineLocalization {
    /// The strings table: `Proofline.strings`.
    static let table = "Proofline"
    /// The resource bundle SwiftPM builds for this target (`<package>_<target>.bundle`).
    static let packageBundleName = "Proofline_Proofline.bundle"
    private static let missing = "\u{1}proofline.missing"

    enum Key: String, CaseIterable, Sendable {
        case placeholder = "code_entry.placeholder"
        case fieldLabel = "code_entry.field_label"
        case submit = "code_entry.submit"
        case submitting = "code_entry.submitting"
        case success = "code_entry.success"
        case successWithOffer = "code_entry.success_with_offer"
        case notFound = "code_entry.not_found"
        case expired = "code_entry.expired"
        case exhausted = "code_entry.exhausted"
        case revoked = "code_entry.revoked"
        case offline = "code_entry.offline"
        case failed = "code_entry.failed"
        case pasteHint = "code_entry.paste_hint"

        /// The English text, identical to `Resources/en.lproj/Proofline.strings` (a test keeps the
        /// two in step). Used when no bundle has the key.
        var english: String {
            switch self {
            case .placeholder: return "Creator code"
            case .fieldLabel: return "Creator code"
            case .submit: return "Apply"
            case .submitting: return "Applying code"
            case .success: return "Code applied: {creator}"
            case .successWithOffer: return "{offer} from {creator}"
            case .notFound: return "That code wasn't recognised"
            case .expired: return "That code has expired"
            case .exhausted: return "That code has reached its limit"
            case .revoked: return "That code is no longer valid"
            case .offline: return "You're offline. The code will be applied when you're back online."
            case .failed: return "Couldn't apply the code. Try again."
            case .pasteHint: return "Pastes a creator code from the clipboard"
            }
        }
    }

    /// The package's resource bundle, or nil when it is not where SwiftPM puts it (the English text
    /// compiled into the SDK is used then).
    static let packageBundle: Bundle? = findPackageBundle()

    static func findPackageBundle() -> Bundle? {
        let code = Bundle(for: BundleAnchor.self)
        // An app or framework holds the bundle in its resources; command-line builds and test
        // bundles have it next to the binary's bundle.
        let bases: [URL?] = [
            Bundle.main.resourceURL, code.resourceURL, Bundle.main.bundleURL, code.bundleURL,
            code.bundleURL.deletingLastPathComponent(),
        ]
        for case let base? in bases {
            if let bundle = Bundle(url: base.appendingPathComponent(packageBundleName)) { return bundle }
        }
        return nil
    }

    /// Host app's table first (so an app can translate or reword), then the package's, then English.
    static func string(_ key: Key) -> String {
        let bundles = [Bundle.main, packageBundle].compactMap { $0 }
        return string(key, in: bundles)
    }

    static func string(_ key: Key, in bundles: [Bundle]) -> String {
        for bundle in bundles {
            let value = bundle.localizedString(forKey: key.rawValue, value: missing, table: table)
            if value != missing, !value.isEmpty { return value }
        }
        return key.english
    }
}

/// Only locates the binary this code is linked into.
private final class BundleAnchor {}
