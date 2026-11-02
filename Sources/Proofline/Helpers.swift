import Foundation

/// Pure helpers shared with sdk-js (same behaviour, same names).
public enum ProoflineLinks {
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

    /// The full update `syncToRevenueCat` writes: all six `proofline_*` keys, with `""` for values
    /// that are not known. RevenueCat keeps an attribute until it is overwritten, and the iOS SDK
    /// deletes an attribute whose value is an empty string, so this drops a previous creator's code
    /// or handle (or a previous attribution entirely) instead of leaving it next to the new values.
    /// Mirrors sdk-js `revenueCatAttributeUpdate`, which uses `null` for the same purpose. Pure.
    public static func update(for attribution: Attribution?, endUserID: String?) -> [String: String] {
        let present = attributes(for: attribution, endUserID: endUserID)
        var out: [String: String] = [:]
        for key in allKeys { out[key] = present[key] ?? "" }
        return out
    }
}
