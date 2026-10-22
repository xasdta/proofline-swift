import Foundation

/// Proofline SDK. Never crashes the host app: non-throwing calls swallow errors and return
/// documented fallbacks. State lives in an actor (Swift 6 strict concurrency).
///
/// ```swift
/// Proofline.configure(appKey: "pk_live_…")
/// Proofline.handle(url)                                      // onOpenURL / universal links
/// let token = try await Proofline.identify(userID: "u_123")  // StoreKit appAccountToken
/// await Proofline.submitCode("SARAH20")
/// let creator = await Proofline.currentAttribution()
/// await Proofline.syncToRevenueCat { attrs in Purchases.shared.attribution.setAttributes(attrs) }
/// ```
public enum Proofline {
    public static let sdkVersion = "0.0.0"
    public static let defaultBaseURL = URL(string: "https://app.proofline.dev")!

    static let state = ProoflineState()

    /// Configure once at launch with the publishable key (`pk_test_…` / `pk_live_…`).
    public static func configure(appKey: String, baseURL: URL = defaultBaseURL) {
        Task { await state.configure(appKey: appKey, baseURL: baseURL) }
    }

    /// Handle a URL that opened the app. Returns true when it is a Proofline link with a click id.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard let clickID = ProoflineLinks.clickID(from: url) else { return false }
        Task { await state.recordLinkOpen(clickID: clickID, url: url) }
        return true
    }

    /// Proofline end-user id to pass as StoreKit `appAccountToken`.
    public static func identify(userID: String? = nil) async throws -> UUID {
        try await state.identify(userID: userID)
    }

    /// Submit a code the user typed/pasted. For store offer codes, `.accepted` carries the redemption URL.
    @discardableResult
    public static func submitCode(_ code: String, pasted: Bool = false) async -> CodeResult {
        do { return try await state.submitCode(code, entry: pasted ? .pasted : .typed) } catch {
            return .error(message: String(describing: error))
        }
    }

    /// The user confirmed a creator in a prompt. Returns false on failure.
    @discardableResult
    public static func confirmCreator(_ creatorID: String) async -> Bool {
        (try? await state.confirmCreator(creatorID)) ?? false
    }

    /// Current attribution for paywall copy; nil if none or unknown.
    public static func currentAttribution() async -> Attribution? {
        (try? await state.currentAttribution()) ?? nil
    }

    /// Write the attribution into RevenueCat subscriber attributes. Returns what was written.
    @discardableResult
    public static func syncToRevenueCat(setAttributes: @Sendable ([String: String]) -> Void) async -> [String: String] {
        let attribution = await currentAttribution()
        let attrs = RevenueCatAttributes.attributes(for: attribution, endUserID: await state.endUserID)
        if !attrs.isEmpty { setAttributes(attrs) }
        return attrs
    }
}

/// Serialized SDK state. Internals are stubs for the sdk-swift workstream.
actor ProoflineState {
    private(set) var appKey: String?
    private(set) var baseURL: URL = Proofline.defaultBaseURL
    private(set) var endUserID: String?

    var isConfigured: Bool { appKey != nil }

    func configure(appKey: String, baseURL: URL) {
        guard appKey.hasPrefix("pk_test_") || appKey.hasPrefix("pk_live_") else { return }
        self.appKey = appKey
        self.baseURL = baseURL
    }

    func recordLinkOpen(clickID _: String, url _: URL) {
        // Stub: enqueue a session event with linkClickId (sdk-swift workstream).
    }

    func identify(userID _: String?) throws -> UUID {
        guard isConfigured else { throw ProoflineError.notConfigured }
        throw ProoflineError.notImplemented("identify")
    }

    func submitCode(_: String, entry _: CodeRequest.Entry) throws -> CodeResult {
        guard isConfigured else { throw ProoflineError.notConfigured }
        throw ProoflineError.notImplemented("submitCode")
    }

    func confirmCreator(_: String) throws -> Bool {
        guard isConfigured else { throw ProoflineError.notConfigured }
        throw ProoflineError.notImplemented("confirmCreator")
    }

    func currentAttribution() throws -> Attribution? {
        guard isConfigured else { throw ProoflineError.notConfigured }
        throw ProoflineError.notImplemented("currentAttribution")
    }
}
