import CryptoKit
import Foundation
import os

/// Diagnostics through `os.Logger`, only when `debug` is on. Messages never contain the app key,
/// user ids, codes or URLs.
struct ProoflineLog: Sendable {
    let enabled: Bool
    private let logger = Logger(subsystem: "dev.proofline.sdk", category: "Proofline")

    init(enabled: Bool) { self.enabled = enabled }

    func debug(_ message: String) {
        guard enabled else { return }
        logger.debug("\(message, privacy: .public)")
    }
}

/// Everything the client depends on, injectable for tests.
struct ClientEnvironment: Sendable {
    var api: APIClient
    var store: any PersistentStore
    var opener: any URLOpening
    var now: @Sendable () -> Date
    var makeUUID: @Sendable () -> UUID
    /// App Group directory holding the App Clip handoff (resolved lazily, off the caller's thread).
    var appGroupDirectory: @Sendable () -> URL?
    var appTransactionIDProvider: (any AppTransactionIDProviding)?
    var revenueCat: (any RevenueCatAttributeSink)?
    var platform: Platform
    var appVersion: String?
    var sdkVersion: String
    var automaticFlush: Bool
    var log: ProoflineLog

    static func live(appKey: String, options: ProoflineOptions) -> ClientEnvironment {
        let directory = options.storageDirectory ?? FileStore.defaultDirectory(appKey: appKey)
        let store: any PersistentStore = directory.map { FileStore(directory: $0) } ?? MemoryStore()
        let group = options.appGroupIdentifier
        return ClientEnvironment(
            api: APIClient(appKey: appKey, baseURL: options.baseURL,
                           transport: options.transport ?? URLSessionTransport(),
                           timeout: options.requestTimeout),
            store: store,
            opener: options.urlOpener ?? SystemURLOpener(),
            now: { Date() },
            makeUUID: { UUID() },
            appGroupDirectory: { group.flatMap(ProoflineAppClip.containerDirectory) },
            appTransactionIDProvider: options.appTransactionIDProvider,
            revenueCat: options.revenueCat,
            platform: options.platform,
            appVersion: options.appVersion,
            sdkVersion: Proofline.sdkVersion,
            automaticFlush: options.automaticFlush,
            log: ProoflineLog(enabled: options.debug)
        )
    }
}

/// The SDK's serialized state and logic. Every method is non-throwing except `identify`, which
/// throws only `ProoflineError`. State is loaded lazily on first use, so construction does no I/O.
actor ProoflineClient {
    /// Remote config is re-fetched (and a disabled SDK re-checks the kill switch) this often.
    static let configTTL: TimeInterval = 5 * 60
    /// `currentAttribution()` reuses a fetched value this long (paywalls call it often).
    static let attributionTTL: TimeInterval = 60

    nonisolated let appKey: String
    /// Kill-switch state readable without awaiting the actor (`Proofline.handle` is synchronous).
    nonisolated let haltFlag = HaltFlag()
    private let env: ClientEnvironment

    private var loaded = false
    private var state = PersistedState(installId: "")
    private var queue = OfflineQueue()
    /// Set on a 401: the key is wrong, so nothing is sent for the rest of this process.
    private var invalidKey = false
    private var started = false
    private var flushTask: Task<Int, Never>?
    private var loopTask: Task<Void, Never>?
    private var configFetchedAt: Date?
    private var attributionFetchedAt: Date?
    /// The stored state or queue could not be read (an I/O error, or iOS data protection before the
    /// first unlock after a reboot), as opposed to missing. The process then runs on in-memory state
    /// with a temporary install id, reports no first launch and writes nothing, so the identity on
    /// disk is not overwritten. Every later call retries the read and adopts the stored state once it
    /// succeeds. Mirrors sdk-js `ephemeralInstall`.
    private var storageUnavailable = false
    /// True once a session event was delivered in this process (sdk-js `sessionDelivered`).
    private var sessionDelivered = false
    /// Identify ordering (sdk-js `identifySeq` / `identifyApplied` / `identifyIssued`): every
    /// identify sent or queued in this process gets the next sequence number, and an answer is applied
    /// only when no newer identify was applied before it. Identifies queued by an earlier process are
    /// not in `identifyIssued` and count as 0, older than any issued in this one.
    private var identifySeq = 0
    private var identifyApplied = 0
    private var identifyIssued: [String: Int] = [:]

    init(appKey: String, environment: ClientEnvironment) {
        self.appKey = appKey
        self.env = environment
    }

    // MARK: - Lifecycle

    /// At launch: re-check the kill switch if it was off, read the App Clip handoff, queue a session
    /// event and flush. Idempotent.
    func start() async {
        loadIfNeeded()
        guard !started else { return }
        started = true

        if state.disabled {
            // The kill switch was off last time: ask again before sending anything.
            _ = await refreshConfig()
            guard !state.disabled else {
                env.log.debug("start: SDK still disabled; re-checking every 5 minutes")
                startLoopIfNeeded()
                return
            }
        }

        await queueLaunchSession()
        _ = await flush()
        startLoopIfNeeded()
    }

    /// Queues the session event for this open, with the App Clip handoff and the app transaction id.
    private func queueLaunchSession() async {
        let groupDir = env.appGroupDirectory()
        var appClipClickID = groupDir.flatMap(ProoflineAppClip.readHandoff(in:))
        if let id = appClipClickID {
            if state.handledClickIds.contains(id) { appClipClickID = nil } else { state.rememberClickID(id) }
        }
        let appTransactionID = await providedAppTransactionID()
        enqueueSession(linkClickID: nil, linkURL: nil, appClipClickID: appClipClickID,
                       appTransactionID: appTransactionID)
        // The click id is now in the durable queue; the handoff file has served its purpose. With
        // unreadable storage the queue is in memory only, so the handoff is kept for the next launch.
        if !storageUnavailable, let groupDir, ProoflineAppClip.readHandoff(in: groupDir) != nil {
            ProoflineAppClip.clearHandoff(in: groupDir)
        }
    }

    /// The kill switch was switched back on while this process runs. If `start()` skipped the launch
    /// session (cached kill switch) or the switch dropped it with the queue, report this open once.
    private func resumeAfterReenable() async {
        env.log.debug("kill switch off: SDK resumed")
        guard started, !sessionDelivered, !queue.events.contains(where: { $0.kind == .session }) else { return }
        await queueLaunchSession()
    }

    /// Stops the periodic flush (used when the client is replaced).
    func shutdown() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Public operations

    /// A Proofline link opened the app: queue a session event carrying its click id (D-tier signal).
    /// Sent once per click id.
    func recordLinkOpen(clickID: String, url: URL) async {
        let link = url.absoluteString
        await recordClick(clickID, linkURL: link.utf8.count <= ProoflineInput.maxLinkURLLength ? link : nil,
                          fromAppClip: false)
    }

    /// A click id handed off from an App Clip by the host app. Sent once per click id.
    func recordAppClipClick(clickID: String) async {
        await recordClick(clickID, linkURL: nil, fromAppClip: true)
    }

    private func recordClick(_ clickID: String, linkURL: String?, fromAppClip: Bool) async {
        loadIfNeeded()
        guard isActive, ProoflineLinks.isClickID(clickID) else { return }
        guard !state.handledClickIds.contains(clickID) else {
            env.log.debug("click already recorded")
            return
        }
        state.rememberClickID(clickID)
        enqueueSession(linkClickID: fromAppClip ? nil : clickID, linkURL: linkURL,
                       appClipClickID: fromAppClip ? clickID : nil,
                       appTransactionID: await providedAppTransactionID())
        _ = await flush()
    }

    /// Resolves the Proofline end-user id (StoreKit `appAccountToken`). A repeat call with the same
    /// arguments returns the cached id without a request. When the server cannot be reached the
    /// identify event is queued and the last known id is returned; with no known id it throws.
    func identify(userID: String?, revenueCatAppUserID: String?,
                  appTransactionID: String?) async throws(ProoflineError) -> UUID {
        loadIfNeeded()
        if state.disabled { throw .disabled }
        if invalidKey { throw .invalidAppKey }

        let external = try ProoflineInput.optionalID(userID, limit: ProoflineInput.maxUserIDLength, field: "userID")
        var rcID = try ProoflineInput.optionalID(revenueCatAppUserID, limit: ProoflineInput.maxUserIDLength,
                                                 field: "revenueCatAppUserID")
        if rcID == nil, let sink = env.revenueCat {
            rcID = try? ProoflineInput.optionalID(await sink.appUserID(), limit: ProoflineInput.maxUserIDLength,
                                                  field: "revenueCatAppUserID")
        }
        var appTx = try ProoflineInput.optionalID(appTransactionID, limit: ProoflineInput.maxAppTransactionIDLength,
                                                  field: "appTransactionID")
        if appTx == nil { appTx = await providedAppTransactionID() }

        let key = Self.identifyKey(external: external, revenueCat: rcID, appTransactionID: appTx)
        if key == state.lastIdentifyKey, let cached = cachedEndUserUUID { return cached }

        let request = IdentifyRequest(eventId: newID(), installId: state.installId, externalUserId: external,
                                      revenueCatAppUserId: rcID, appTransactionId: appTx, platform: env.platform)
        identifySeq += 1
        let seq = identifySeq
        identifyIssued[request.eventId] = seq
        do throws(ProoflineError) {
            let response = try await env.api.identify(request)
            identifyIssued[request.eventId] = nil
            guard let uuid = UUID(uuidString: response.endUserId) else {
                throw .invalidResponse("endUserId is not a UUID")
            }
            applyIdentify(endUserID: response.endUserId, seq: seq, key: key)
            // The caller gets the end user for the ids it passed, even when a newer identify won.
            return uuid
        } catch {
            switch DeliveryFailure(error) {
            case .retry:
                // Keeps its sequence number in `identifyIssued` for when the queue delivers it.
                queue.enqueue(.identify(request), now: env.now())
                saveQueue()
                env.log.debug("identify: offline; queued")
                if let cached = cachedEndUserUUID { return cached }
            case .disabled:
                identifyIssued[request.eventId] = nil
                applyDisabled()
            case .invalidKey:
                identifyIssued[request.eventId] = nil
                invalidKey = true
            case .drop:
                identifyIssued[request.eventId] = nil
            }
            throw error
        }
    }

    /// Applies an identify answer unless a newer identify was applied first. A stale answer that
    /// names another end user also drops the identify cache: the server may now link the install to
    /// that user, so the next identify must ask again rather than trust the cached id.
    private func applyIdentify(endUserID: String, seq: Int, key: String) {
        guard seq >= identifyApplied else {
            env.log.debug("identify: ignoring the answer to an older identify")
            if endUserID != state.endUserId, state.lastIdentifyKey != nil {
                state.lastIdentifyKey = nil
                saveState()
            }
            return
        }
        identifyApplied = seq
        setEndUserID(endUserID)
        state.lastIdentifyKey = key
        saveState()
    }

    /// Every end-user id assignment goes through here. When the id changes, the cached attribution
    /// is invalidated; when it changes from one end user to another, the attribution is dropped too,
    /// because it belonged to the previous end user (sdk-js `setEndUserId`).
    private func setEndUserID(_ id: String) {
        guard id != state.endUserId else { return }
        let previous = state.endUserId
        state.endUserId = id
        invalidateAttribution(endUserChanged: previous != nil)
    }

    /// The next `currentAttribution()` asks the server again. With `endUserChanged`, the stored
    /// attribution is also cleared so it is never served (or synced to RevenueCat) for the new end
    /// user. The caller persists the state.
    private func invalidateAttribution(endUserChanged: Bool) {
        attributionFetchedAt = nil
        if endUserChanged { state.attribution = nil }
    }

    /// Sends a typed or pasted code. Apple offer codes open Apple's redemption sheet via the opener.
    func submitCode(_ raw: String, entry: CodeRequest.Entry, openRedemption: Bool) async -> CodeResult {
        loadIfNeeded()
        if state.disabled { return .error(message: "Proofline is disabled for this app") }
        if invalidKey { return .error(message: "Invalid Proofline app key") }
        if let config = state.config, !config.codeEntryEnabled {
            return .error(message: "Code entry is turned off for this app")
        }
        guard let code = ProoflineInput.normalizeCode(raw) else {
            return .error(message: "Enter a code of 1 to \(ProoflineInput.maxCodeLength) characters")
        }
        let request = CodeRequest(eventId: newID(), installId: state.installId, endUserId: state.endUserId,
                                  code: code, entry: entry, platform: env.platform)
        do throws(ProoflineError) {
            let result = CodeResult(try await env.api.code(request))
            if result.isAccepted {
                // The code may have changed the attribution: do not serve the pre-code value.
                invalidateAttribution(endUserChanged: false)
            }
            if openRedemption, case let .accepted(_, url?, _) = result, ProoflineLinks.isAppleOfferCodeRedemption(url) {
                // UNVERIFIED(S2): opening the redemption URL from inside the app is assumed to present
                // Apple's sheet with the code pre-filled; not validated on devices.
                let opened = await env.opener.open(url)
                env.log.debug("submitCode: redemption sheet \(opened ? "opened" : "could not be opened")")
            }
            return result
        } catch {
            switch DeliveryFailure(error) {
            case .retry:
                // Keep the U-tier signal: deliver it when the connection is back.
                queue.enqueue(.code(request), now: env.now())
                saveQueue()
                return .queued(message: "Offline: the code will be sent when the connection is back")
            case .disabled:
                applyDisabled()
                return .error(message: "Proofline is disabled for this app")
            case .invalidKey:
                invalidKey = true
                return .error(message: "Invalid Proofline app key")
            case .drop:
                return .error(message: Self.describe(error))
            }
        }
    }

    /// The user picked a creator in a prompt. True only when the server accepted it now; when offline
    /// the event is queued and false is returned.
    func confirmCreator(_ creatorID: String) async -> Bool {
        loadIfNeeded()
        guard isActive else { return false }
        if let config = state.config, !config.confirmCreatorEnabled { return false }
        let id = creatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { return false }
        let request = ConfirmRequest(eventId: newID(), installId: state.installId, endUserId: state.endUserId,
                                     creatorId: id, platform: env.platform)
        do throws(ProoflineError) {
            let response = try await env.api.confirm(request)
            apply(confirm: response)
            return response.status == .accepted
        } catch {
            handleInteractiveFailure(error, queueing: .confirm(request))
            return false
        }
    }

    /// Current attribution from the server; the last known one when offline; nil when disabled.
    func currentAttribution() async -> Attribution? {
        loadIfNeeded()
        guard isActive else { return nil }
        if let fetched = attributionFetchedAt, env.now().timeIntervalSince(fetched) < Self.attributionTTL {
            return state.attribution
        }
        if state.endUserId == nil { _ = await flush() } // a queued session may resolve the end user
        guard let endUserID = state.endUserId else { return state.attribution }
        do throws(ProoflineError) {
            let response = try await env.api.attribution(endUserID: endUserID)
            // The end user changed while the request was in flight: this answer is about the old one.
            guard state.endUserId == endUserID else { return state.attribution }
            state.attribution = response.attribution
            attributionFetchedAt = env.now()
            saveState()
            return response.attribution
        } catch {
            handleInteractiveFailure(error, queueing: nil)
            return isActive ? state.attribution : nil
        }
    }

    /// Writes the attribution into RevenueCat subscriber attributes: all six `proofline_*` keys, with
    /// `""` (RevenueCat: delete) for values that are not known, so values left over from an earlier
    /// attribution or end user are cleared. Nothing is written while neither the end user nor an
    /// attribution is known. Returns the non-empty values written (sdk-js `syncToRevenueCat`).
    func syncToRevenueCat(_ write: @Sendable ([String: String]) async -> Void) async -> [String: String] {
        let attribution = await currentAttribution()
        guard isActive else { return [:] }
        let endUserID = state.endUserId
        let attrs = RevenueCatAttributes.attributes(for: attribution, endUserID: endUserID)
        if !attrs.isEmpty { await write(RevenueCatAttributes.update(for: attribution, endUserID: endUserID)) }
        return attrs
    }

    func syncToConfiguredRevenueCat() async -> [String: String] {
        guard let sink = env.revenueCat else {
            env.log.debug("syncToRevenueCat: no RevenueCatAttributeSink in ProoflineOptions")
            return [:]
        }
        return await syncToRevenueCat { await sink.setAttributes($0) }
    }

    /// Remote settings in effect: the server's last config, or the defaults until it has answered.
    func remoteConfig() -> SdkConfig {
        loadIfNeeded()
        return state.config ?? .fallback
    }

    // MARK: - Periodic work

    /// One tick of the background loop: refresh a stale config (which is also how a disabled SDK
    /// notices it was switched back on), then flush. Returns the delay until the next tick.
    func tick() async -> TimeInterval {
        loadIfNeeded()
        if invalidKey { return Self.configTTL }
        if configFetchedAt.map({ env.now().timeIntervalSince($0) >= Self.configTTL }) ?? true {
            if await refreshConfig() { await resumeAfterReenable() }
        }
        guard isActive else { return Self.configTTL }
        _ = await flush()
        return flushInterval
    }

    /// Fetches `/config`. Returns true when it switched a disabled SDK back on.
    @discardableResult
    private func refreshConfig() async -> Bool {
        do throws(ProoflineError) {
            let config = try await env.api.config()
            configFetchedAt = env.now()
            let wasDisabled = state.disabled
            apply(config: config)
            return wasDisabled && !state.disabled
        } catch {
            // Do not hammer the server: wait a full TTL before asking again.
            configFetchedAt = env.now()
            switch DeliveryFailure(error) {
            case .disabled: applyDisabled()
            case .invalidKey: invalidKey = true
            case .retry, .drop: env.log.debug("config refresh failed")
            }
            return false
        }
    }

    // MARK: - Offline queue

    /// Sends due events (at most `batchSize`), oldest first. Concurrent callers share one pass; a
    /// caller that arrives during a pass waits for it and then runs a fresh one, so events it just
    /// queued are included. Returns how many events were delivered.
    func flush() async -> Int {
        loadIfNeeded()
        var awaited: Task<Int, Never>?
        if let running = flushTask {
            awaited = running
            _ = await running.value
        }
        if let running = flushTask, running != awaited { return await running.value }
        let task = Task { await self.flushPass() }
        flushTask = task
        let delivered = await task.value
        if flushTask == task { flushTask = nil }
        return delivered
    }

    private func flushPass() async -> Int {
        guard isActive else { return 0 }
        let now = env.now()
        queue.pruneExpired(now: now)
        let batch = queue.due(now: now, limit: (state.config ?? .fallback).effectiveBatchSize)
        var delivered = 0
        for event in batch {
            guard isActive else { break }
            guard queue.events.contains(where: { $0.id == event.id }) else { continue }
            do throws(ProoflineError) {
                try await deliver(event)
                queue.remove(id: event.id)
                saveQueue()
                delivered += 1
            } catch {
                switch DeliveryFailure(error) {
                case .retry:
                    // Network or server trouble: back off and stop this pass.
                    queue.recordFailure(id: event.id, now: env.now())
                    saveQueue()
                    return delivered
                case .invalidKey:
                    invalidKey = true
                    env.log.debug("flush: app key rejected (401); sending stopped")
                    return delivered
                case .disabled:
                    applyDisabled()
                    return delivered
                case .drop:
                    env.log.debug("flush: \(event.kind.rawValue) event rejected; dropped")
                    queue.remove(id: event.id)
                    saveQueue()
                }
            }
        }
        return delivered
    }

    private func deliver(_ event: QueuedEvent) async throws(ProoflineError) {
        switch event.body {
        case let .session(body):
            let response = try await env.api.session(body)
            sessionDelivered = true
            try apply(session: response)
        case let .identify(body):
            let response: IdentifyResponse
            do throws(ProoflineError) {
                response = try await env.api.identify(body)
            } catch {
                // Kept for the retry only when the event stays queued.
                if DeliveryFailure(error) != .retry { identifyIssued[body.eventId] = nil }
                throw error
            }
            let seq = identifyIssued.removeValue(forKey: body.eventId) ?? 0
            guard UUID(uuidString: response.endUserId) != nil else { throw .invalidResponse("endUserId is not a UUID") }
            applyIdentify(endUserID: response.endUserId, seq: seq,
                          key: Self.identifyKey(external: body.externalUserId, revenueCat: body.revenueCatAppUserId,
                                                appTransactionID: body.appTransactionId))
        case let .code(body):
            _ = try await env.api.code(body)
            invalidateAttribution(endUserChanged: false)
        case let .confirm(body):
            apply(confirm: try await env.api.confirm(body))
        }
    }

    private func startLoopIfNeeded() {
        guard env.automaticFlush, loopTask == nil else { return }
        let first = isActive ? flushInterval : Self.configTTL
        loopTask = Task { [weak self] in
            var delay = first
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let client = self else { return }
                delay = await client.tick()
            }
        }
    }

    private var flushInterval: TimeInterval { (state.config ?? .fallback).effectiveFlushInterval }

    // MARK: - State

    var endUserID: String? {
        loadIfNeeded()
        return state.endUserId
    }

    /// False when the kill switch is off or the key was rejected.
    var isActive: Bool { !state.disabled && !invalidKey }

    var queuedEventCount: Int {
        loadIfNeeded()
        return queue.count
    }

    var installID: String {
        loadIfNeeded()
        return state.installId
    }

    private var cachedEndUserUUID: UUID? { state.endUserId.flatMap(UUID.init(uuidString:)) }

    private func loadIfNeeded() {
        if loaded {
            if storageUnavailable { recoverStorageIfReadable() }
            return
        }
        loaded = true
        do {
            adopt(try readStored())
        } catch {
            // Not a fresh install: the files may exist but cannot be read right now. Use a temporary
            // install id for this process, report no first launch, and write nothing.
            env.log.debug("state could not be read; using a temporary install id until it can be")
            storageUnavailable = true
            var temporary = PersistedState(installId: newID())
            temporary.sessionRecorded = true
            state = temporary
            queue = OfflineQueue()
        }
        haltFlag.set(state.disabled)
    }

    private struct StoredData {
        /// Nil when missing, undecodable or holding a non-UUID install id.
        var state: PersistedState?
        var events: [QueuedEvent]
    }

    /// Reads the state and queue files, each retried once on a read error. Throws when either still
    /// cannot be read; a missing or undecodable file is not an error.
    private func readStored() throws -> StoredData {
        let stateData = try readRetrying(PersistedState.fileName)
        let queueData = try readRetrying(OfflineQueue.fileName)
        let decoder = JSONDecoder()
        var saved: PersistedState?
        if let stateData, let decoded = try? decoder.decode(PersistedState.self, from: stateData),
           UUID(uuidString: decoded.installId) != nil {
            saved = decoded
        }
        let events = queueData.flatMap { try? decoder.decode([QueuedEvent].self, from: $0) } ?? []
        return StoredData(state: saved, events: events)
    }

    private func readRetrying(_ name: String) throws -> Data? {
        do {
            return try env.store.read(name)
        } catch {
            return try env.store.read(name)
        }
    }

    private func adopt(_ stored: StoredData) {
        if let saved = stored.state {
            state = saved
        } else {
            // First launch, or a corrupt file: start over with a fresh random install id.
            state = PersistedState(installId: newID())
            saveState()
        }
        queue = OfflineQueue(events: stored.events)
        queue.pruneExpired(now: env.now())
    }

    /// Storage became readable (e.g. the device was unlocked): switch to the stored identity. Events
    /// still pending from the temporary install move to the real install id and end user, and what
    /// this process learned from the server about the config and the kill switch is kept.
    private func recoverStorageIfReadable() {
        guard let stored = try? readStored() else { return }
        env.log.debug("state readable again; switching to the stored install id")
        let temporary = state
        let pending = queue.events
        storageUnavailable = false
        adopt(stored)
        for id in temporary.handledClickIds { state.rememberClickID(id) }
        if configFetchedAt != nil {
            state.config = temporary.config
            state.disabled = temporary.disabled
        }
        attributionFetchedAt = nil
        if state.disabled {
            queue.removeAll()
        } else {
            queue.append(pending.map { $0.rebased(installId: state.installId, endUserId: state.endUserId) })
        }
        haltFlag.set(state.disabled)
        saveState()
        saveQueue()
    }

    private func enqueueSession(linkClickID: String?, linkURL: String?, appClipClickID: String?,
                                appTransactionID: String?) {
        let appVersion = env.appVersion.flatMap { $0.isEmpty || $0.count > 64 ? nil : $0 }
        let request = SessionRequest(
            eventId: newID(), installId: state.installId, endUserId: state.endUserId, platform: env.platform,
            sdkVersion: env.sdkVersion, appVersion: appVersion, openedAt: ISOTime.string(env.now()),
            firstLaunch: !state.sessionRecorded, installReferrer: nil, appClipClickId: appClipClickID,
            linkClickId: linkClickID, linkUrl: linkURL, appTransactionId: appTransactionID
        )
        queue.enqueue(.session(request), now: env.now())
        saveQueue()
        state.sessionRecorded = true
        saveState()
    }

    private func apply(session response: SessionResponse) throws(ProoflineError) {
        guard UUID(uuidString: response.endUserId) != nil else { throw .invalidResponse("endUserId is not a UUID") }
        if let previous = state.endUserId, previous != response.endUserId {
            // The server moved this install to another end user: the identify cache no longer holds.
            state.lastIdentifyKey = nil
        }
        setEndUserID(response.endUserId)
        state.attribution = response.attribution
        configFetchedAt = env.now()
        apply(config: response.config)
    }

    /// An accepted confirm with an attribution is the new attribution; anything else (rejected, or
    /// no attribution) leaves the cached one stale.
    private func apply(confirm response: ConfirmResponse) {
        if response.status == .accepted, let attribution = response.attribution {
            state.attribution = attribution
            attributionFetchedAt = env.now()
        } else {
            invalidateAttribution(endUserChanged: false)
        }
        saveState()
    }

    private func apply(config: SdkConfig) {
        state.config = config
        if config.enabled {
            state.disabled = false
            haltFlag.set(false)
            saveState()
        } else {
            applyDisabled()
        }
    }

    /// Remote kill switch: stop sending, drop queued events, remember it across launches.
    private func applyDisabled() {
        env.log.debug("kill switch: SDK disabled for this app")
        state.disabled = true
        haltFlag.set(true)
        queue.removeAll()
        saveQueue()
        saveState()
        // The loop keeps running at the config TTL so the SDK notices when it is switched back on.
    }

    private func handleInteractiveFailure(_ error: ProoflineError, queueing body: QueuedEvent.Body?) {
        switch DeliveryFailure(error) {
        case .retry:
            if let body {
                queue.enqueue(body, now: env.now())
                saveQueue()
            }
        case .disabled: applyDisabled()
        case .invalidKey: invalidKey = true
        case .drop: env.log.debug("request rejected: \(Self.describe(error))")
        }
    }

    private func providedAppTransactionID() async -> String? {
        guard let provider = env.appTransactionIDProvider else { return nil }
        return try? ProoflineInput.optionalID(await provider.appTransactionID(),
                                              limit: ProoflineInput.maxAppTransactionIDLength,
                                              field: "appTransactionID")
    }

    private func saveState() {
        guard !storageUnavailable else { return }
        do {
            try env.store.write(try JSONEncoder().encode(state), to: PersistedState.fileName)
        } catch {
            env.log.debug("could not persist state")
        }
    }

    private func saveQueue() {
        guard !storageUnavailable else { return }
        do {
            try env.store.write(try JSONEncoder().encode(queue.events), to: OfflineQueue.fileName)
        } catch {
            env.log.debug("could not persist queue")
        }
    }

    private func newID() -> String { env.makeUUID().uuidString.lowercased() }

    /// Hash of the identify arguments, so the raw user ids are not kept on disk for the cache check.
    static func identifyKey(external: String?, revenueCat: String?, appTransactionID: String?) -> String {
        let joined = [external ?? "", revenueCat ?? "", appTransactionID ?? ""].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ error: ProoflineError) -> String {
        switch error {
        case .notConfigured: "Proofline is not configured"
        case .invalidAppKey: "Invalid Proofline app key"
        case let .api(status, code, message): "\(code) (\(status)): \(message)"
        case let .network(detail): "Network error: \(detail)"
        case .disabled: "Proofline is disabled for this app"
        case let .invalidResponse(detail): "Invalid response: \(detail)"
        case let .invalidInput(detail): "Invalid input: \(detail)"
        }
    }
}

/// Lock-protected kill-switch bit shared with the synchronous facade.
final class HaltFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isDisabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ disabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = disabled
    }
}

extension QueuedEvent {
    /// The same event (same id, attempts and schedule) for another install and end user.
    func rebased(installId: String, endUserId: String?) -> QueuedEvent {
        let newBody: Body
        switch body {
        case var .session(b):
            b.installId = installId
            b.endUserId = endUserId
            b.firstLaunch = false
            newBody = .session(b)
        case var .identify(b):
            b.installId = installId
            newBody = .identify(b)
        case var .code(b):
            b.installId = installId
            b.endUserId = endUserId
            newBody = .code(b)
        case var .confirm(b):
            b.installId = installId
            b.endUserId = endUserId
            newBody = .confirm(b)
        }
        return QueuedEvent(body: newBody, attempts: attempts, enqueuedAt: enqueuedAt, nextAttemptAt: nextAttemptAt)
    }
}
