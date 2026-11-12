import Foundation

/// A Proofline click link the app was opened with (sdk-js `ProoflineLink`).
public struct ProoflineLink: Sendable, Equatable, Hashable {
    /// The click id from the link path (12 base62 characters).
    public let clickID: String
    /// The in-app path the link's owner configured for it (for example `/workouts/42`), for the host
    /// app to route on; nil when the link has none. Always starts with a single `/`.
    ///
    /// It comes from the URL's `dl` query parameter, so treat it as untrusted input: anyone can craft
    /// a link. Match it against the routes your app knows; never load it as a web URL.
    public let deepLinkPath: String?

    public init(clickID: String, deepLinkPath: String? = nil) {
        self.clickID = clickID
        self.deepLinkPath = deepLinkPath
    }
}

/// Pure helpers shared with sdk-js (same behaviour, same names).
public enum ProoflineLinks {
    /// The query parameter of a click link that carries the link's in-app path (server `?dl=`).
    public static let deepLinkParameter = "dl"
    /// Longest in-app path the server stores for a link (`destination.appPath`, `max(512)`), in
    /// UTF-16 code units as the server counts them.
    public static let maxDeepLinkPathLength = 512

    /// Parse a URL the app was opened with (sdk-js `parseLink`). Returns the click id and the link's
    /// in-app path when it is a Proofline click link
    /// (`https://<host>/l/<appSlug>/<linkSlug>/c/<clickId>[?dl=<path>]`), nil for anything else. The
    /// first `dl` parameter wins; an invalid one gives `deepLinkPath: nil` (the click still counts).
    /// Pure: nothing is recorded or sent.
    public static func parse(_ url: URL) -> ProoflineLink? {
        guard let clickID = clickID(from: url) else { return nil }
        return ProoflineLink(clickID: clickID, deepLinkPath: deepLinkPath(from: url))
    }

    /// The validated value of the first `dl` query parameter, or nil. See `isDeepLinkPath(_:)`.
    static func deepLinkPath(from url: URL) -> String? {
        // Percent-encoded items, decoded here: an item that does not decode (broken escapes or
        // invalid UTF-8) is rejected, as `decodeURIComponent` rejects it in sdk-js. `+` stays `+`
        // (the server writes the parameter with `encodeURIComponent`).
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems,
              let item = items.first(where: { $0.name.removingPercentEncoding == deepLinkParameter }),
              let path = item.value?.removingPercentEncoding, isDeepLinkPath(path)
        else { return nil }
        return path
    }

    /// The rule for an in-app path, identical to sdk-js: at most 512 UTF-16 code units, starting
    /// with exactly one `/` (so it can never be read as a protocol-relative `//host` URL), and
    /// without control characters, line separators or backslashes.
    static func isDeepLinkPath(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard scalars.first == "/", scalars.dropFirst().first != "/",
              value.utf16.count <= maxDeepLinkPathLength
        else { return false }
        return !scalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
                || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar == "\\"
        }
    }

    /// Click id from `https://<host>/l/<appSlug>/<linkSlug>/c/<clickId>` (12 chars base62), else nil.
    /// Click ids live in URL paths (invariant 7); a trailing slash is accepted, like sdk-js. Only
    /// absolute `http`/`https` URLs with a host qualify (sdk-js `clickIdFromUrl`), so a custom-scheme
    /// URL such as `myapp:///l/a/b/c/<id>` is not a Proofline link.
    public static func clickID(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0] == "l", parts[3] == "c" else { return nil }
        let id = String(parts[4])
        guard isClickID(id) else { return nil }
        return id
    }

    /// True for a 12-character base62 click id (the server's `clickId` schema).
    public static func isClickID(_ value: String) -> Bool {
        value.utf8.count == 12 && value.utf8.allSatisfy(isBase62)
    }

    /// True for Apple's offer-code redemption link
    /// `https://apps.apple.com/redeem?ctx=offercodes&id=<appStoreId>&code=<code>`
    /// (the shape `buildRedemptionUrl` in `packages/core` produces).
    public static func isAppleOfferCodeRedemption(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "itms-apps",
              comps.host?.lowercased() == "apps.apple.com",
              comps.path == "/redeem" || comps.path == "/redeem/"
        else { return false }
        let items = comps.queryItems ?? []
        let ctx = items.first { $0.name == "ctx" }?.value
        let code = items.first { $0.name == "code" }?.value
        return ctx == "offercodes" && !(code ?? "").isEmpty
    }

    private static func isBase62(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// Client-side input rules. Limits match the server's zod schemas so the SDK never sends a request
/// that is certain to be rejected. Lengths are UTF-16 code units, as zod's `.max()` (and sdk-js
/// `.length`) count them, not Swift `Character`s.
enum ProoflineInput {
    static let maxCodeLength = 64
    static let maxUserIDLength = 256
    static let maxAppTransactionIDLength = 128
    static let maxLinkURLLength = 2048
    /// The server's `suggestQuerySchema.q` limit.
    static let maxSuggestQueryLength = 50

    /// True for an RFC 9562 UUID (versions 1–8, variant 10xx) in the 8-4-4-4-12 form: the format the
    /// server's `z.uuid()` accepts and sdk-js `isUuid` checks. Stricter than `UUID(uuidString:)`,
    /// which takes any 32 hex digits.
    static func isServerUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            case 14:
                guard byte >= UInt8(ascii: "1"), byte <= UInt8(ascii: "8") else { return false }
            case 19:
                guard [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b"),
                       UInt8(ascii: "A"), UInt8(ascii: "B")].contains(byte) else { return false }
            default:
                guard isHexDigit(byte) else { return false }
            }
        }
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    /// Trimmed code; for pasted text only the first non-empty line is used. Nil when empty or longer
    /// than 64 characters. The server upper-cases; the SDK keeps the user's casing.
    static func normalizeCode(_ raw: String) -> String? {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let code = firstLine, !code.isEmpty, code.utf16.count <= maxCodeLength else { return nil }
        return code
    }

    /// The `q` for `/creators/suggest`: trimmed, without leading `@` (the server ignores it). Nil when
    /// longer than the server accepts or holding a NUL, which the server cannot match.
    static func suggestQuery(_ raw: String) -> String? {
        var query = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while query.hasPrefix("@") { query = query.dropFirst() }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count <= maxSuggestQueryLength, !trimmed.unicodeScalars.contains("\u{0}") else { return nil }
        return trimmed
    }

    /// Empty → nil; over `limit` → throws.
    static func optionalID(_ value: String?, limit: Int, field: String) throws(ProoflineError) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        guard v.utf16.count <= limit else { throw .invalidInput("\(field) is longer than \(limit) characters") }
        return v
    }
}

/// ISO 8601 with milliseconds in UTC (`2026-10-14T09:13:00.000Z`), the format sdk-js emits.
enum ISOTime {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func string(_ date: Date) -> String { style.format(date) }

    static func date(_ string: String) -> Date? {
        if let d = try? style.parse(string) { return d }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}

/// RevenueCat subscriber attribute names (identical to sdk-js `REVENUECAT_ATTRIBUTE_KEYS`).
/// RevenueCat reserves the `$` prefix, so Proofline uses `proofline_`.
public enum RevenueCatAttributes {
    public static let endUserId = "proofline_end_user_id"
    public static let creatorId = "proofline_creator_id"
    public static let creatorHandle = "proofline_creator_handle"
    public static let programId = "proofline_program_id"
    public static let tier = "proofline_tier"
    public static let code = "proofline_code"

    /// Every key, in a stable order.
    public static let allKeys = [endUserId, creatorId, creatorHandle, programId, tier, code]

    /// Pure mapping; omits unknown values.
    public static func attributes(for attribution: Attribution?, endUserID: String?) -> [String: String] {
        var out: [String: String] = [:]
        if let endUserID, !endUserID.isEmpty { out[endUserId] = endUserID }
        guard let a = attribution else { return out }
        out[creatorId] = a.creator.id
        if let h = a.creator.handle { out[creatorHandle] = h }
        out[programId] = a.programId
        out[tier] = a.tier.rawValue
        if let c = a.code { out[code] = c }
        return out
    }

    /// The creator-scoped keys: cleared whenever the current attribution does not set them.
    public static let creatorScopedKeys = [creatorId, creatorHandle, programId, tier, code]

    /// The value that clears a RevenueCat subscriber attribute (sdk-js `REVENUECAT_CLEAR_VALUE`).
    /// RevenueCat deletes an attribute that is set to an empty string, and its iOS SDK takes a
    /// `[String: String]`, so `""` is the one spelling that works on every platform.
    public static let clearValue = ""

    /// The full update `syncToRevenueCat` writes, identical to sdk-js `revenueCatAttributeUpdate`:
    /// every creator-scoped key, with `""` (`clearValue`) for values the current attribution does not
    /// set. RevenueCat keeps an attribute until it is overwritten or deleted, so this drops a previous
    /// creator's code or handle (or a previous attribution entirely) instead of leaving it next to
    /// the new values. `proofline_end_user_id` is included only when the end user is known and is
    /// never cleared: an unknown end user (for example storage unreadable this launch) does not mean
    /// there is none, and clearing it would cut the link ingest uses to tie purchases to the end
    /// user. Pure.
    public static func update(for attribution: Attribution?, endUserID: String?) -> [String: String] {
        let present = attributes(for: attribution, endUserID: endUserID)
        var out: [String: String] = [:]
        if let known = present[endUserId] { out[endUserId] = known }
        for key in creatorScopedKeys { out[key] = present[key] ?? clearValue }
        return out
    }
}
