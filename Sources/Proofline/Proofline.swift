import Foundation

/// Proofline SDK. Never crashes the host app: every call except `identify` returns a documented
/// fallback instead of throwing, and all work runs off the caller's thread inside an actor
/// (Swift 6 strict concurrency).
///
/// ```swift
/// Proofline.configure(appKey: "pk_live_…")
/// Proofline.handle(url)                                      // onOpenURL / universal links
/// let token = try await Proofline.identify(userID: "u_123")  // StoreKit appAccountToken
/// _ = try await product.purchase(options: [.appAccountToken(token)])
/// await Proofline.submitCode("SARAH20")                      // opens Apple's redemption for offer codes
/// PasteCodeButton()                                          // SwiftUI, UIPasteControl on iOS 16+
/// let creator = await Proofline.currentAttribution()
/// await Proofline.syncToRevenueCat { attrs in Purchases.shared.attribution.setAttributes(attrs) }
/// ```
public enum Proofline {
    public static let sdkVersion = "0.1.0"
    // A literal URL; it cannot fail to parse.
    public static let defaultBaseURL = URL(string: "https://app.proofline.link")!

    static let registry = ClientRegistry()

    /// True after a successful `configure`.
    public static var isConfigured: Bool { registry.client != nil }

    /// Configure once at launch with the publishable key (`pk_test_…` / `pk_live_…`).
    public static func configure(appKey: String, baseURL: URL = defaultBaseURL) {
        configure(appKey: appKey, options: ProoflineOptions(baseURL: baseURL))
    }

    /// Configure once at launch. An invalid key is ignored (logged when `options.debug`). Calling it
    /// again with the same key is a no-op; a different key replaces the client.
    public static func configure(appKey: String, options: ProoflineOptions) {
        let log = ProoflineLog(enabled: options.debug)
        guard isPublishableKey(appKey) else {
            log.debug("configure: appKey must be a publishable key (pk_test_… / pk_live_…)")
            return
        }
        if registry.client?.appKey == appKey {
            log.debug("configure: already configured")
            return
        }
        install(ProoflineClient(appKey: appKey, environment: .live(appKey: appKey, options: options)))
    }

    /// Handle a URL that opened the app. Returns true when it is a Proofline link with a click id.
    /// Links handled before `configure` are kept in memory and sent once it is called.
    /// Returns false while the remote kill switch is off.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard let clickID = ProoflineLinks.clickID(from: url) else { return false }
        if registry.client?.haltFlag.isDisabled == true { return false }
        if let client = registry.clientOrBuffer(clickID: clickID, url: url) {
            Task.detached(priority: .utility) { await client.recordLinkOpen(clickID: clickID, url: url) }
        }
        return true
    }

    /// Handle a universal-link `NSUserActivity` (`NSUserActivityTypeBrowsingWeb`).
    @discardableResult
    public static func handle(_ userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return false }
        return handle(url)
    }

    /// Pass a click id your App Clip handed off through your own shared storage (alternative to
    /// `ProoflineOptions.appGroupIdentifier`). Sent once per click id. Returns true when `clickID` is
    /// a well-formed Proofline click id and the SDK is configured and enabled.
    // UNVERIFIED(S8): App Clip → full app hand-off through a shared App Group is not validated.
    @discardableResult
    public static func setAppClipClickID(_ clickID: String) -> Bool {
        guard ProoflineLinks.isClickID(clickID), let client = registry.client,
              !client.haltFlag.isDisabled else { return false }
        Task.detached(priority: .utility) { await client.recordAppClipClick(clickID: clickID) }
        return true
    }

    /// Proofline end-user id to pass as StoreKit `appAccountToken`. Offline, it returns the last
    /// known id (the identify call is queued); it throws only when no id is known, the SDK is not
    /// configured or is disabled, or an argument is too long. This is the one throwing call, matching
    /// the plan's `try await Proofline.identify(userID:)`; `appAccountToken(userID:)` never throws.
    public static func identify(userID: String? = nil, revenueCatAppUserID: String? = nil,
                                appTransactionID: String? = nil) async throws(ProoflineError) -> UUID {
        guard let client = registry.client else { throw .notConfigured }
        return try await client.identify(userID: userID, revenueCatAppUserID: revenueCatAppUserID,
                                         appTransactionID: appTransactionID)
    }

    /// Non-throwing `identify`: nil when no end-user id is available.
    public static func appAccountToken(userID: String? = nil, revenueCatAppUserID: String? = nil,
                                       appTransactionID: String? = nil) async -> UUID? {
        try? await identify(userID: userID, revenueCatAppUserID: revenueCatAppUserID,
                            appTransactionID: appTransactionID)
    }

    /// Submit a code the user typed or pasted (call only from a user action). For an Apple offer code
    /// the result carries the redemption URL, and Apple's redemption sheet is opened unless
    /// `openRedemption` is false.
    @discardableResult
    public static func submitCode(_ code: String, pasted: Bool = false, openRedemption: Bool = true) async -> CodeResult {
        guard let client = registry.client else { return .error(message: "Proofline is not configured") }
        return await client.submitCode(code, entry: pasted ? .pasted : .typed, openRedemption: openRedemption)
    }

    /// The user confirmed a creator (id from the attribution or a creator list) in a prompt.
    /// Returns false on failure.
    @discardableResult
    public static func confirmCreator(_ creatorID: String) async -> Bool {
        guard let client = registry.client else { return false }
        return await client.confirmCreator(creatorID)
    }

    /// Current attribution for paywall copy; the last known one when offline; nil if none or unknown.
    public static func currentAttribution() async -> Attribution? {
        guard let client = registry.client else { return nil }
        return await client.currentAttribution()
    }

    /// Write the attribution into RevenueCat subscriber attributes. `setAttributes` receives all six
    /// `proofline_*` keys; a key without a current value is `""`, which RevenueCat treats as "delete
    /// this attribute", so a previous creator's code or handle does not linger. Pass the dictionary
    /// to RevenueCat unchanged. Nothing is written while neither the end user nor an attribution is
    /// known. Returns the non-empty values written.
    @discardableResult
    public static func syncToRevenueCat(setAttributes: @Sendable ([String: String]) -> Void) async -> [String: String] {
        guard let client = registry.client else { return [:] }
        return await client.syncToRevenueCat { setAttributes($0) }
    }

    /// Write the attribution into RevenueCat through a bridge (same update as the closure overload:
    /// all six keys, `""` meaning "delete"). Returns the non-empty values written.
    @discardableResult
    public static func syncToRevenueCat(_ sink: any RevenueCatAttributeSink) async -> [String: String] {
        guard let client = registry.client else { return [:] }
        return await client.syncToRevenueCat { await sink.setAttributes($0) }
    }

    /// Write the attribution through `ProoflineOptions.revenueCat`. Returns what was written
    /// (`[:]` when no bridge was configured).
    @discardableResult
    public static func syncToRevenueCat() async -> [String: String] {
        guard let client = registry.client else { return [:] }
        return await client.syncToConfiguredRevenueCat()
    }

    /// Remote settings in effect (`enabled` is the kill switch; `codeEntryEnabled` and
    /// `confirmCreatorEnabled` gate your paywall UI). Defaults until the server has answered; nil
    /// when not configured.
    public static func remoteConfig() async -> SdkConfig? {
        guard let client = registry.client else { return nil }
        return await client.remoteConfig()
    }

    /// Send queued events now (for example when the app moves to the background). Returns how many
    /// were delivered.
    @discardableResult
    public static func flush() async -> Int {
        guard let client = registry.client else { return 0 }
        return await client.flush()
    }

    // MARK: - Internals

    static func isPublishableKey(_ key: String) -> Bool {
        (key.hasPrefix("pk_test_") || key.hasPrefix("pk_live_")) && key.count > "pk_test_".count
    }

    /// Installs a client (or clears it with nil), replays buffered links and starts it.
    static func install(_ client: ProoflineClient?) {
        let (previous, pending) = registry.replace(with: client)
        if let previous { Task.detached { await previous.shutdown() } }
        guard let client else { return }
        Task.detached(priority: .utility) {
            await client.start()
            for link in pending { await client.recordLinkOpen(clickID: link.clickID, url: link.url) }
        }
    }
}

/// Lock-protected holder for the configured client (iOS 15 has no `Mutex`).
final class ClientRegistry: @unchecked Sendable {
    struct PendingLink: Sendable {
        let clickID: String
        let url: URL
    }

    static let maxPendingLinks = 5

    private let lock = NSLock()
    private var current: ProoflineClient?
    private var pending: [PendingLink] = []

    var client: ProoflineClient? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// The client, or nil after buffering the link for the next `configure`.
    func clientOrBuffer(clickID: String, url: URL) -> ProoflineClient? {
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        if !pending.contains(where: { $0.clickID == clickID }) {
            pending.append(PendingLink(clickID: clickID, url: url))
            if pending.count > Self.maxPendingLinks { pending.removeFirst() }
        }
        return nil
    }

    func replace(with client: ProoflineClient?) -> (previous: ProoflineClient?, pending: [PendingLink]) {
        lock.lock(); defer { lock.unlock() }
        let previous = current
        current = client
        let links = client == nil ? [] : pending
        if client != nil { pending = [] }
        return (previous, links)
    }

    func clearPending() {
        lock.lock(); defer { lock.unlock() }
        pending = []
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}
