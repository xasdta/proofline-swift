import Foundation

/// Pure helpers shared with sdk-js (same behaviour, same names).
public enum ProoflineLinks {
    /// Click id from `https://<host>/l/<appSlug>/<linkSlug>/c/<clickId>` (12 chars base62), else nil.
    public static func clickID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0] == "l", parts[3] == "c" else { return nil }
        let id = String(parts[4])
        let base62 = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard id.count == 12, id.unicodeScalars.allSatisfy(base62.contains) else { return nil }
        return id
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
}
