import Foundation

// SDK wire contract. Field names are identical to `packages/sdk-js/src/types.ts` (camelCase JSON).

public enum Tier: String, Codable, Sendable { case V, D, U }

public enum Platform: String, Codable, Sendable { case ios, android, web, unknown }

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
public struct Attribution: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case provisional, attributed, locked }
    public let creator: CreatorSummary
    public let programId: String
    public let tier: Tier
    public let status: Status
    public let offerLabel: String?
    public let code: String?
    /// ISO 8601.
    public let decidedAt: String

    public init(creator: CreatorSummary, programId: String, tier: Tier, status: Status,
                offerLabel: String? = nil, code: String? = nil, decidedAt: String) {
        self.creator = creator
        self.programId = programId
        self.tier = tier
        self.status = status
        self.offerLabel = offerLabel
        self.code = code
        self.decidedAt = decidedAt
    }
}

public struct SdkConfig: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let linkHosts: [String]
    public let appSlug: String
    public let codeEntryEnabled: Bool
    public let confirmCreatorEnabled: Bool
    public let batchSize: Int
    public let flushIntervalSeconds: Int
}

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

/// Response of `POST /api/sdk/v1/code` (and result of `submitCode`; `.error` is client-side only).
public enum CodeResult: Sendable, Equatable {
    case accepted(creator: CreatorSummary, redemptionURL: URL?, offerLabel: String?)
    case unknownCode, expired, exhausted, revoked
    case error(message: String)
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

public enum ProoflineError: Error, Sendable, Equatable {
    case notConfigured
    case invalidAppKey
    case api(status: Int, code: String, message: String)
    case network(String)
    case notImplemented(String)
}
