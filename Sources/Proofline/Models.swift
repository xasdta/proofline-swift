import Foundation

// SDK wire contract. Field names are identical to `packages/sdk-js/src/types.ts` (camelCase JSON)
// and to the zod schemas in `packages/server/src/http/sdk.ts`. `ModelsContractTests` parses
// `types.ts` and fails when the two drift apart.
//
// Optional properties are omitted from encoded JSON (synthesized `encodeIfPresent`), never sent as
// `null`, because the server's zod `.optional()` fields reject `null`.

/// Signal tiers: V = store-verified, D = deterministic carry, U = user-asserted.
public enum Tier: String, Codable, Sendable { case V, D, U }

public enum Platform: String, Codable, Sendable { case ios, android, web, unknown }

/// Error envelope returned with any non-2xx status.
public struct ApiErrorBody: Codable, Sendable, Equatable {
    public struct Detail: Codable, Sendable, Equatable {
        public let code: String
        public let message: String
    }
    public let error: Detail
}

public struct CreatorSummary: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let handle: String?
    public let avatarUrl: String?

    public init(id: String, name: String, handle: String? = nil, avatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.handle = handle
        self.avatarUrl = avatarUrl
    }
}

/// The current attribution, for paywall copy (creator name, avatar, offer).
/// Mirrors `CurrentAttribution` in sdk-js.
public struct Attribution: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case provisional, attributed, locked }
    public let creator: CreatorSummary
    public let programId: String
    public let tier: Tier
    public let status: Status
    /// e.g. "20% off your first 3 months".
    public let offerLabel: String?
    /// Code the user can see/redeem, if any.
    public let code: String?
    /// Where this device redeems `code` (its own store only), as in the `/code` answer; absent for
    /// in-app codes and other stores' codes. See `redemptionURL`.
    public let redemptionUrl: String?
    /// ISO 8601.
    public let decidedAt: String

    public init(creator: CreatorSummary, programId: String, tier: Tier, status: Status,
                offerLabel: String? = nil, code: String? = nil, redemptionUrl: String? = nil,
                decidedAt: String) {
        self.creator = creator
        self.programId = programId
        self.tier = tier
        self.status = status
        self.offerLabel = offerLabel
        self.code = code
        self.redemptionUrl = redemptionUrl
        self.decidedAt = decidedAt
    }

    /// `redemptionUrl` as a URL: open it (for example with `UIApplication.open`) to show the store's
    /// redemption flow for `code` from the paywall.
    public var redemptionURL: URL? { redemptionUrl.flatMap(URL.init(string:)) }
}

/// Remote settings and kill switch (`GET /api/sdk/v1/config`, also embedded in the session response).
public struct SdkConfig: Codable, Sendable, Equatable {
    /// Remote kill switch: when false the SDK stops sending events (`apps.sdk_enabled`).
    public let enabled: Bool
    public let linkHosts: [String]
    public let appSlug: String
    public let codeEntryEnabled: Bool
    public let confirmCreatorEnabled: Bool
    /// Max events per flush pass.
    public let batchSize: Int
    /// Seconds between flushes of the offline queue.
    public let flushIntervalSeconds: Int

    public init(enabled: Bool, linkHosts: [String], appSlug: String, codeEntryEnabled: Bool,
                confirmCreatorEnabled: Bool, batchSize: Int, flushIntervalSeconds: Int) {
        self.enabled = enabled
        self.linkHosts = linkHosts
        self.appSlug = appSlug
        self.codeEntryEnabled = codeEntryEnabled
        self.confirmCreatorEnabled = confirmCreatorEnabled
        self.batchSize = batchSize
        self.flushIntervalSeconds = flushIntervalSeconds
    }

    /// Used until the server has sent a config.
    static let fallback = SdkConfig(enabled: true, linkHosts: [], appSlug: "", codeEntryEnabled: true,
                                    confirmCreatorEnabled: true, batchSize: 20, flushIntervalSeconds: 30)

    /// Server values clamped to sane bounds (the server is trusted, but a bad value must never
    /// make the SDK spin or stall).
    var effectiveBatchSize: Int { min(max(batchSize, 1), 100) }
    var effectiveFlushInterval: TimeInterval { TimeInterval(min(max(flushIntervalSeconds, 5), 3600)) }
}

/// `GET /api/sdk/v1/config`
public typealias ConfigResponse = SdkConfig

/// `POST /api/sdk/v1/session`
public struct SessionRequest: Codable, Sendable, Equatable {
    public var eventId: String
    public var installId: String
    public var endUserId: String?
    public var platform: Platform
    public var sdkVersion: String
    public var appVersion: String?
    public var openedAt: String
    public var firstLaunch: Bool
    public var installReferrer: String?
    public var appClipClickId: String?
    public var linkClickId: String?
    public var linkUrl: String?
    public var appTransactionId: String?
}

public struct SessionResponse: Codable, Sendable, Equatable {
    public let endUserId: String
    public let attribution: Attribution?
    public let config: SdkConfig
}

/// `POST /api/sdk/v1/identify`
public struct IdentifyRequest: Codable, Sendable, Equatable {
    public var eventId: String
    public var installId: String
    public var externalUserId: String?
    public var revenueCatAppUserId: String?
    public var appTransactionId: String?
    public var platform: Platform
}

public struct IdentifyResponse: Codable, Sendable, Equatable {
    /// Pass as StoreKit `appAccountToken`.
    public let endUserId: String
}

/// `POST /api/sdk/v1/code`
public struct CodeRequest: Codable, Sendable, Equatable {
    public enum Entry: String, Codable, Sendable { case typed, pasted }
    public var eventId: String
    public var installId: String
    public var endUserId: String?
    public var code: String
    public var entry: Entry
    public var platform: Platform
}

/// Wire shape of the `POST /api/sdk/v1/code` response (a union discriminated by `status`).
enum CodeResponse: Codable, Sendable, Equatable {
    enum Rejection: String, Codable, Sendable { case unknownCode = "unknown_code", expired, exhausted, revoked }

    case accepted(creator: CreatorSummary, redemptionUrl: String?, offerLabel: String?)
    case rejected(Rejection)

    private enum CodingKeys: String, CodingKey { case status, creator, redemptionUrl, offerLabel }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        if status == "accepted" {
            self = .accepted(
                creator: try c.decode(CreatorSummary.self, forKey: .creator),
                redemptionUrl: try c.decodeIfPresent(String.self, forKey: .redemptionUrl),
                offerLabel: try c.decodeIfPresent(String.self, forKey: .offerLabel)
            )
        } else if let rejection = Rejection(rawValue: status) {
            self = .rejected(rejection)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "unknown code status \(status)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .accepted(creator, redemptionUrl, offerLabel):
            try c.encode("accepted", forKey: .status)
            try c.encode(creator, forKey: .creator)
            try c.encodeIfPresent(redemptionUrl, forKey: .redemptionUrl)
            try c.encodeIfPresent(offerLabel, forKey: .offerLabel)
        case let .rejected(rejection):
            try c.encode(rejection, forKey: .status)
        }
    }
}

/// Result of `Proofline.submitCode` (`.error` is client-side only: the request could not be made
/// or the SDK is disabled). Mirrors `SubmitCodeResult` in sdk-js.
public enum CodeResult: Sendable, Equatable {
    /// `redemptionURL` is set for store offer codes; Apple offer-code URLs are opened automatically
    /// unless `submitCode(_:pasted:openRedemption:)` was called with `openRedemption: false`.
    case accepted(creator: CreatorSummary, redemptionURL: URL?, offerLabel: String?)
    case unknownCode, expired, exhausted, revoked
    /// Offline: the entry is queued and reaches the server when the connection is back (the
    /// U-tier signal is kept), but no redemption URL is available now. sdk-js: `{status:'error', queued:true}`.
    case queued(message: String)
    case error(message: String)

    init(_ response: CodeResponse) {
        switch response {
        case let .accepted(creator, redemptionUrl, offerLabel):
            self = .accepted(creator: creator, redemptionURL: redemptionUrl.flatMap(URL.init(string:)),
                             offerLabel: offerLabel)
        case .rejected(.unknownCode): self = .unknownCode
        case .rejected(.expired): self = .expired
        case .rejected(.exhausted): self = .exhausted
        case .rejected(.revoked): self = .revoked
        }
    }

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// `POST /api/sdk/v1/confirm`
public struct ConfirmRequest: Codable, Sendable, Equatable {
    public var eventId: String
    public var installId: String
    public var endUserId: String?
    public var creatorId: String
    public var platform: Platform
}

public struct ConfirmResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case accepted, rejected }
    public let status: Status
    public let attribution: Attribution?
}

/// `GET /api/sdk/v1/attribution`
public struct AttributionResponse: Codable, Sendable, Equatable {
    public let attribution: Attribution?
}

/// `GET /api/sdk/v1/creators/suggest?q=<prefix>&installId=<uuid>`: candidates for the "Who sent
/// you?" prompt, at most 5, ranked by aggregate data only. Mirrors `SuggestCreatorsResponse` in sdk-js.
public struct SuggestCreatorsResponse: Codable, Sendable, Equatable {
    public let creators: [CreatorSummary]
}

/// Errors surfaced by `Proofline.identify` (the only throwing public call). Every other public call
/// maps failures to a documented fallback value.
public enum ProoflineError: Error, Sendable, Equatable {
    case notConfigured
    case invalidAppKey
    case api(status: Int, code: String, message: String)
    case network(String)
    /// The remote kill switch is off for this app (`apps.sdk_enabled = false`).
    case disabled
    /// The server answered 2xx with a body that does not match the contract.
    case invalidResponse(String)
    /// An argument failed client-side validation (same limits as the server's zod schemas).
    case invalidInput(String)
}

// MARK: - Offline queue (mirrors `QueuedEvent` in sdk-js)

enum QueuedEventKind: String, Codable, Sendable { case session, identify, code, confirm }

/// A durable event awaiting delivery. `id` is the idempotency key sent as `eventId`; retries reuse it.
struct QueuedEvent: Codable, Sendable, Equatable {
    enum Body: Sendable, Equatable {
        case session(SessionRequest)
        case identify(IdentifyRequest)
        case code(CodeRequest)
        case confirm(ConfirmRequest)

        var kind: QueuedEventKind {
            switch self {
            case .session: .session
            case .identify: .identify
            case .code: .code
            case .confirm: .confirm
            }
        }

        var eventId: String {
            switch self {
            case let .session(b): b.eventId
            case let .identify(b): b.eventId
            case let .code(b): b.eventId
            case let .confirm(b): b.eventId
            }
        }
    }

    var id: String
    var body: Body
    var attempts: Int
    /// ISO 8601.
    var enqueuedAt: String
    /// ISO 8601; retry with exponential backoff.
    var nextAttemptAt: String

    var kind: QueuedEventKind { body.kind }

    init(body: Body, attempts: Int = 0, enqueuedAt: String, nextAttemptAt: String) {
        self.id = body.eventId
        self.body = body
        self.attempts = attempts
        self.enqueuedAt = enqueuedAt
        self.nextAttemptAt = nextAttemptAt
    }

    private enum CodingKeys: String, CodingKey { case id, kind, body, attempts, enqueuedAt, nextAttemptAt }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        switch try c.decode(QueuedEventKind.self, forKey: .kind) {
        case .session: body = .session(try c.decode(SessionRequest.self, forKey: .body))
        case .identify: body = .identify(try c.decode(IdentifyRequest.self, forKey: .body))
        case .code: body = .code(try c.decode(CodeRequest.self, forKey: .body))
        case .confirm: body = .confirm(try c.decode(ConfirmRequest.self, forKey: .body))
        }
        attempts = try c.decode(Int.self, forKey: .attempts)
        enqueuedAt = try c.decode(String.self, forKey: .enqueuedAt)
        nextAttemptAt = try c.decode(String.self, forKey: .nextAttemptAt)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        switch body {
        case let .session(b): try c.encode(b, forKey: .body)
        case let .identify(b): try c.encode(b, forKey: .body)
        case let .code(b): try c.encode(b, forKey: .body)
        case let .confirm(b): try c.encode(b, forKey: .body)
        }
        try c.encode(attempts, forKey: .attempts)
        try c.encode(enqueuedAt, forKey: .enqueuedAt)
        try c.encode(nextAttemptAt, forKey: .nextAttemptAt)
    }
}
