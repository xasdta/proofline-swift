import Foundation
import XCTest
@testable import Proofline

/// Identify ordering (sdk-js SDK-9(c)): an older identify answered later never replaces a newer one.
final class ClientIdentifyOrderingTests: XCTestCase {
    func testQueuedOlderIdentifyDeliveredLaterDoesNotOverrideANewerOne() async throws {
        let h = Harness()
        await h.client.start()

        // A is queued offline...
        await h.transport.set(override: .failure(.notConnectedToInternet))
        _ = try await h.client.identify(userID: "A", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(try persistedQueue(h.store).map(\.kind), [.identify])

        // ...then B succeeds online.
        await h.transport.set(override: nil)
        await h.transport.set(identifyFor: "A", endUserID: Fixture.thirdEndUserID)
        await h.transport.set(identifyFor: "B", endUserID: Fixture.otherEndUserID)
        let b = try await h.client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(b, UUID(uuidString: Fixture.otherEndUserID))

        // The flush delivers A's stale identify: B's end user stays.
        h.clock.advance(3600)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 1)
        let endUser = await h.client.endUserID
        XCTAssertEqual(endUser, Fixture.otherEndUserID)
        XCTAssertEqual(try persistedState(h.store).endUserId, Fixture.otherEndUserID)

        // identify(B) returns B's end user (asking again, since the server saw A last).
        await h.transport.reset()
        let again = try await h.client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(again, UUID(uuidString: Fixture.otherEndUserID))
        let token = await h.client.endUserID
        XCTAssertEqual(token, Fixture.otherEndUserID)
    }

    func testConcurrentIdentifiesApplyInCallOrderNotArrivalOrder() async throws {
        let h = Harness()
        // A is called first but answered last.
        await h.transport.set(identifyFor: "A", endUserID: Fixture.thirdEndUserID, delayNanoseconds: 300_000_000)
        await h.transport.set(identifyFor: "B", endUserID: Fixture.otherEndUserID)
        let client = h.client
        let first = Task { try await client.identify(userID: "A", revenueCatAppUserID: nil, appTransactionID: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let issued = await h.transport.requests(to: "identify").count
        XCTAssertEqual(issued, 1, "A is in flight before B is called")
        let b = try await client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        let a = try await first.value

        XCTAssertEqual(b, UUID(uuidString: Fixture.otherEndUserID))
        XCTAssertEqual(a, UUID(uuidString: Fixture.thirdEndUserID), "each caller gets the answer for its own ids")
        let endUser = await client.endUserID
        XCTAssertEqual(endUser, Fixture.otherEndUserID, "the newer identify (B) wins")
        XCTAssertEqual(try persistedState(h.store).endUserId, Fixture.otherEndUserID)

        // The cache never hands out A's id for B.
        let again = try await client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(again, UUID(uuidString: Fixture.otherEndUserID))
    }

    func testIdentifyQueuedByAnEarlierProcessLosesToOneFromThisProcess() async throws {
        let h = Harness()
        await h.client.start()
        await h.transport.set(override: .failure(.timedOut))
        _ = try await h.client.identify(userID: "A", revenueCatAppUserID: nil, appTransactionID: nil)

        let next = h.relaunch()
        await h.transport.set(override: nil)
        await h.transport.set(identifyFor: "A", endUserID: Fixture.thirdEndUserID)
        await h.transport.set(identifyFor: "B", endUserID: Fixture.otherEndUserID)
        _ = try await next.client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        h.clock.advance(3600)
        _ = await next.client.flush()
        let requests = try await h.transport.requests(to: "identify").map { try $0.decode(IdentifyRequest.self) }
        XCTAssertTrue(requests.contains { $0.externalUserId == "A" }, "the old identify was still delivered")
        let endUser = await next.client.endUserID
        XCTAssertEqual(endUser, Fixture.otherEndUserID)
    }

    func testIdentifyQueuedByAnEarlierProcessAppliesWhenNothingNewerWasApplied() async throws {
        let h = Harness()
        await h.client.start()
        await h.transport.set(override: .failure(.timedOut))
        _ = try await h.client.identify(userID: "A", revenueCatAppUserID: nil, appTransactionID: nil)

        let next = h.relaunch()
        await h.transport.set(override: nil)
        await h.transport.set(identifyFor: "A", endUserID: Fixture.thirdEndUserID)
        h.clock.advance(3600)
        let delivered = await next.client.flush()
        XCTAssertEqual(delivered, 1)
        let endUser = await next.client.endUserID
        XCTAssertEqual(endUser, Fixture.thirdEndUserID)
    }

    func testDeliveredQueuedIdentifyUpdatesTheIdentifyCache() async throws {
        let h = Harness()
        await h.transport.set(identifyFor: "B", endUserID: Fixture.otherEndUserID)
        await h.transport.set(identifyFor: "A", endUserID: Fixture.thirdEndUserID)
        _ = try await h.client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)

        // A newer identify (A) is queued offline and delivered later: it wins over B.
        await h.transport.set(override: .failure(.notConnectedToInternet))
        _ = try await h.client.identify(userID: "A", revenueCatAppUserID: nil, appTransactionID: nil)
        await h.transport.set(override: nil)
        h.clock.advance(3600)
        _ = await h.client.flush()
        let endUser = await h.client.endUserID
        XCTAssertEqual(endUser, Fixture.thirdEndUserID)

        // identify(B) must not be served A's id from the cache.
        let b = try await h.client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(b, UUID(uuidString: Fixture.otherEndUserID))
        // ...and identify(B), just applied, is now the cached one: repeating it sends nothing.
        await h.transport.reset()
        _ = try await h.client.identify(userID: "B", revenueCatAppUserID: nil, appTransactionID: nil)
        let cached = await h.transport.requests(to: "identify").count
        XCTAssertEqual(cached, 0)
    }
}

/// The cached attribution follows the end user, the code and the confirmation (SDK-9(d)).
final class ClientAttributionInvalidationTests: XCTestCase {
    private func attributionRequests(_ h: Harness) async -> Int {
        await h.transport.requests(to: "attribution").count
    }

    private static let otherAttribution = Attribution(
        creator: CreatorSummary(id: "5c4b3a29-1807-4f6e-9d5c-4b3a29180700", name: "Max Kim"),
        programId: "pr_2", tier: .U, status: .provisional, decidedAt: "2026-10-20T10:00:00.000Z"
    )

    /// Started, with `Fixture.attribution` fetched and cached (fresh for 60 s).
    private func warmed(sink: RecordingSink? = nil) async -> Harness {
        let h = Harness(sink: sink)
        await h.client.start()
        _ = await h.client.currentAttribution()
        return h
    }

    func testIdentifyToAnotherEndUserDropsThePreviousUsersAttribution() async throws {
        let sink = RecordingSink()
        let h = await warmed(sink: sink)
        XCTAssertEqual(try persistedState(h.store).attribution, Fixture.attribution)

        await h.transport.set(identifyEndUserID: Fixture.otherEndUserID)
        _ = try await h.client.identify(userID: "u_2", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertNil(try persistedState(h.store).attribution, "the old user's attribution is not kept")

        // Within the 60 s window, offline: the old user's attribution is not served.
        await h.transport.set("attribution", .failure(.notConnectedToInternet))
        let value = await h.client.currentAttribution()
        XCTAssertNil(value)
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 2, "the cache was invalidated, so the server was asked")

        // RevenueCat gets the new end user and no creator from the previous one.
        let attrs = await h.client.syncToConfiguredRevenueCat()
        XCTAssertEqual(attrs, [RevenueCatAttributes.endUserId: Fixture.otherEndUserID])
        let written = try XCTUnwrap(sink.written.last)
        XCTAssertEqual(written[RevenueCatAttributes.endUserId], Fixture.otherEndUserID)
        XCTAssertEqual(written[RevenueCatAttributes.creatorId], "")
        XCTAssertEqual(written[RevenueCatAttributes.code], "")
    }

    func testIdentifyResolvingTheSameEndUserOnlyRefreshes() async throws {
        let h = await warmed()
        _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(try persistedState(h.store).attribution, Fixture.attribution)
        let value = await h.client.currentAttribution()
        XCTAssertEqual(value, Fixture.attribution)
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 1, "same end user: the cached attribution stays valid")
    }

    func testDeliveredQueuedIdentifyToAnotherEndUserDropsTheAttribution() async throws {
        let h = await warmed()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        _ = try await h.client.identify(userID: "u_2", revenueCatAppUserID: nil, appTransactionID: nil)
        await h.transport.set(override: nil)
        await h.transport.set(identifyEndUserID: Fixture.otherEndUserID)
        h.clock.advance(10)
        _ = await h.client.flush()
        XCTAssertNil(try persistedState(h.store).attribution)
        await h.transport.set(attributionResponse: AttributionResponse(attribution: Self.otherAttribution))
        let value = await h.client.currentAttribution()
        XCTAssertEqual(value, Self.otherAttribution)
        let attributionRequests = await h.transport.requests(to: "attribution")
        let request = try XCTUnwrap(attributionRequests.last)
        XCTAssertEqual(request.query["endUserId"], Fixture.otherEndUserID)
    }

    func testSessionMovingTheInstallToAnotherEndUserInvalidatesTheCaches() async throws {
        let h = await warmed()
        _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.otherEndUserID,
                                                                attribution: nil, config: Fixture.config()))
        await h.client.recordLinkOpen(clickID: Fixture.clickID, url: Fixture.linkURL)
        let endUser = await h.client.endUserID
        XCTAssertEqual(endUser, Fixture.otherEndUserID)

        _ = await h.client.currentAttribution()
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 2)
        // The identify cache belonged to the previous end user: identify asks again.
        await h.transport.reset()
        _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        let identifies = await h.transport.requests(to: "identify").count
        XCTAssertEqual(identifies, 1)
    }

    func testAcceptedCodeInvalidatesTheCachedAttribution() async throws {
        let h = await warmed()
        await h.transport.set(attributionResponse: AttributionResponse(attribution: Self.otherAttribution))
        let result = await h.client.submitCode("MAX10", entry: .typed, openRedemption: false)
        XCTAssertTrue(result.isAccepted)
        let value = await h.client.currentAttribution()
        XCTAssertEqual(value, Self.otherAttribution, "the paywall sees the post-code attribution at once")
    }

    func testRejectedCodeKeepsTheCachedAttribution() async throws {
        let h = await warmed()
        await h.transport.set(codeResponse: .rejected(.unknownCode))
        _ = await h.client.submitCode("NOPE", entry: .typed, openRedemption: false)
        _ = await h.client.currentAttribution()
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 1)
    }

    func testDeliveredQueuedCodeInvalidatesTheCachedAttribution() async throws {
        let h = await warmed()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        let queued = await h.client.submitCode("MAX10", entry: .typed, openRedemption: false)
        guard case .queued = queued else { return XCTFail("expected .queued, got \(queued)") }
        await h.transport.set(override: nil)
        h.clock.advance(10)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 1)
        _ = await h.client.currentAttribution()
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 2)
    }

    func testRejectedConfirmInvalidatesTheCachedAttribution() async throws {
        let h = await warmed()
        await h.transport.set(confirmResponse: ConfirmResponse(status: .rejected, attribution: Fixture.attribution))
        let ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertFalse(ok)
        _ = await h.client.currentAttribution()
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 2)
    }

    func testAcceptedConfirmWithoutAnAttributionInvalidatesTheCachedAttribution() async throws {
        let h = await warmed()
        await h.transport.set(confirmResponse: ConfirmResponse(status: .accepted, attribution: nil))
        let ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertTrue(ok)
        _ = await h.client.currentAttribution()
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 2)
    }

    func testAcceptedConfirmWithAnAttributionIsServedDirectly() async throws {
        let h = await warmed()
        await h.transport.set(confirmResponse: ConfirmResponse(status: .accepted, attribution: Self.otherAttribution))
        _ = await h.client.confirmCreator(Fixture.creatorID)
        let value = await h.client.currentAttribution()
        XCTAssertEqual(value, Self.otherAttribution)
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 1)
    }

    func testDeliveredQueuedRejectedConfirmInvalidatesTheCachedAttribution() async throws {
        let h = await warmed()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        _ = await h.client.confirmCreator(Fixture.creatorID)
        await h.transport.set(override: nil)
        await h.transport.set(confirmResponse: ConfirmResponse(status: .rejected, attribution: nil))
        h.clock.advance(10)
        _ = await h.client.flush()
        _ = await h.client.currentAttribution()
        let asked = await attributionRequests(h)
        XCTAssertEqual(asked, 2)
    }
}

/// RevenueCat attributes that no longer apply are cleared (SDK-9(a)).
final class ClientRevenueCatClearingTests: XCTestCase {
    func testAttributionWithoutACodeClearsThePreviousCodeAndHandle() async throws {
        let sink = RecordingSink()
        let h = Harness(sink: sink)
        await h.client.start()
        _ = await h.client.syncToConfiguredRevenueCat()
        XCTAssertEqual(sink.written.last?[RevenueCatAttributes.code], "SARAH20")

        let noCode = Attribution(creator: CreatorSummary(id: "5c4b3a29-1807-4f6e-9d5c-4b3a29180700", name: "Max Kim"),
                                 programId: "pr_2", tier: .D, status: .attributed, decidedAt: "2026-10-20T10:00:00.000Z")
        await h.transport.set(attributionResponse: AttributionResponse(attribution: noCode))
        h.clock.advance(ProoflineClient.attributionTTL + 1)
        let returned = await h.client.syncToConfiguredRevenueCat()

        let written = try XCTUnwrap(sink.written.last)
        XCTAssertEqual(written, [
            RevenueCatAttributes.endUserId: Fixture.endUserID,
            RevenueCatAttributes.creatorId: "5c4b3a29-1807-4f6e-9d5c-4b3a29180700",
            RevenueCatAttributes.creatorHandle: "",
            RevenueCatAttributes.programId: "pr_2",
            RevenueCatAttributes.tier: "D",
            RevenueCatAttributes.code: "",
        ])
        XCTAssertEqual(returned, [
            RevenueCatAttributes.endUserId: Fixture.endUserID,
            RevenueCatAttributes.creatorId: "5c4b3a29-1807-4f6e-9d5c-4b3a29180700",
            RevenueCatAttributes.programId: "pr_2",
            RevenueCatAttributes.tier: "D",
        ], "only the non-empty values are returned, like sdk-js")
    }

    func testLostAttributionClearsEveryCreatorKey() async throws {
        let sink = RecordingSink()
        let h = Harness(sink: sink)
        await h.client.start()
        await h.transport.set(attributionResponse: AttributionResponse(attribution: nil))
        let returned = await h.client.syncToRevenueCat { _ in }
        XCTAssertEqual(returned, [RevenueCatAttributes.endUserId: Fixture.endUserID])
        let viaClosure = LockedBox<[String: String]>()
        _ = await h.client.syncToRevenueCat { viaClosure.set($0) }
        let written = try XCTUnwrap(viaClosure.value)
        XCTAssertEqual(written.count, 6)
        XCTAssertEqual(written[RevenueCatAttributes.endUserId], Fixture.endUserID)
        for key in RevenueCatAttributes.allKeys where key != RevenueCatAttributes.endUserId {
            XCTAssertEqual(written[key], "", key)
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }
}

/// An unreadable state file is not a fresh install (SDK-9(b)).
final class ClientStorageReadFailureTests: XCTestCase {
    private func seededStore(installID: String = "11111111-2222-4333-8444-555555555555") throws -> FlakyStore {
        let store = FlakyStore()
        var state = PersistedState(installId: installID)
        state.endUserId = Fixture.endUserID
        state.sessionRecorded = true
        state.attribution = Fixture.attribution
        try store.seed(Fixture.json(state), as: PersistedState.fileName)
        return store
    }

    func testUnreadableStateIsNotAFirstLaunchAndNothingIsWritten() async throws {
        let store = try seededStore()
        store.failAllReads()
        let h = Harness(store: store)
        await h.client.start()

        let session = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertFalse(session.firstLaunch, "a read error must not look like a (re)install")
        XCTAssertNotNil(UUID(uuidString: session.installId))
        XCTAssertNotEqual(session.installId, "11111111-2222-4333-8444-555555555555")
        XCTAssertNil(session.endUserId)
        XCTAssertTrue(store.writes.isEmpty, "the stored identity is never overwritten")

        // Within the process the SDK still works with what the server answered.
        let token = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(token, UUID(uuidString: Fixture.endUserID))
        XCTAssertTrue(store.writes.isEmpty)

        // The original identity is intact for the next launch.
        store.heal()
        XCTAssertEqual(try persistedState(store).installId, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(try persistedState(store).attribution, Fixture.attribution)
    }

    func testAReadErrorIsRetriedOnceBeforeFallingBack() async throws {
        let store = try seededStore()
        store.failNextReads(1)
        let h = Harness(store: store)
        await h.client.start()
        let session = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertEqual(session.installId, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(session.endUserId, Fixture.endUserID)
        XCTAssertFalse(session.firstLaunch)
    }

    func testUnreadableQueueAlsoKeepsTheStoreUntouched() async throws {
        let store = try seededStore()
        // The state file reads fine; the queue file cannot be read.
        store.failReads(of: OfflineQueue.fileName)
        let h = Harness(store: store)
        await h.client.start()
        XCTAssertTrue(store.writes.isEmpty)
        let session = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertFalse(session.firstLaunch)
    }

    func testStorageThatBecomesReadableIsAdoptedAndPendingEventsMoveToTheRealInstall() async throws {
        let store = try seededStore()
        store.failAllReads()
        let h = Harness(store: store)
        await h.transport.set(override: .failure(.notConnectedToInternet))
        await h.client.start()
        let temporaryInstall = await h.client.installID
        XCTAssertNotEqual(temporaryInstall, "11111111-2222-4333-8444-555555555555")

        // The device is unlocked; the network is back.
        store.heal()
        await h.transport.set(override: nil)
        await h.transport.reset()
        h.clock.advance(60)
        let installID = await h.client.installID
        XCTAssertEqual(installID, "11111111-2222-4333-8444-555555555555")
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 1)
        let session = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertEqual(session.installId, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(session.endUserId, Fixture.endUserID)
        XCTAssertFalse(session.firstLaunch)
        XCTAssertEqual(try persistedState(store).installId, "11111111-2222-4333-8444-555555555555")
    }

    func testAKillSwitchLearnedWhileStorageWasUnreadableSurvivesTheRecovery() async throws {
        // Regression: a 403 while storage was unreadable did not set configFetchedAt, so the
        // recovery restored `disabled: false` from disk and flushed the stored queue again.
        let store = try seededStore()
        // A queued event on disk from an earlier, offline launch.
        let earlier = Harness(store: store)
        await earlier.transport.set(override: .failure(.notConnectedToInternet))
        _ = try? await earlier.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertFalse(try persistedQueue(store).isEmpty)

        store.failAllReads()
        let h = earlier.relaunch()
        await h.transport.set(override: .status(403, Data(#"{"error":{"code":"sdk_disabled","message":"off"}}"#.utf8)))
        await h.client.start()
        XCTAssertTrue(h.client.haltFlag.isDisabled)

        // The device is unlocked and the server answers again; nothing re-enabled the SDK.
        store.heal()
        await h.transport.set(override: nil)
        await h.transport.reset()
        h.clock.advance(60)
        let installID = await h.client.installID
        XCTAssertEqual(installID, "11111111-2222-4333-8444-555555555555", "storage was adopted")
        XCTAssertTrue(h.client.haltFlag.isDisabled)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 0)
        let requests = await h.transport.requests
        XCTAssertTrue(requests.isEmpty, "a disabled SDK sends nothing")
        XCTAssertTrue(try persistedState(store).disabled)
        XCTAssertTrue(try persistedQueue(store).isEmpty)
    }

    func testSyncToRevenueCatNeverClearsAnUnknownEndUser() async throws {
        // Storage unreadable this launch and the session cannot be sent, so the end user is
        // unknown; a confirmed creator still gives an attribution. The end-user key must be left
        // alone, not deleted ("").
        let store = try seededStore()
        store.failAllReads()
        let h = Harness(store: store)
        await h.transport.set("session", .failure(.notConnectedToInternet))
        await h.client.start()
        let confirmed = await h.client.confirmCreator(Fixture.attribution.creator.id)
        XCTAssertTrue(confirmed)
        let endUser = await h.client.endUserID
        XCTAssertNil(endUser)
        let written = LockedBox<[String: String]>()
        let returned = await h.client.syncToRevenueCat { written.set($0) }
        let update = try XCTUnwrap(written.value)
        XCTAssertNil(update[RevenueCatAttributes.endUserId], "never cleared")
        XCTAssertEqual(update[RevenueCatAttributes.creatorId], Fixture.attribution.creator.id)
        XCTAssertNil(returned[RevenueCatAttributes.endUserId])
    }

    func testFileStoreReportsMissingAsNilAndOtherFailuresAsErrors() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        XCTAssertNil(try store.read("missing.json"), "no directory yet")
        try store.write(Data("x".utf8), to: "present.json")
        XCTAssertNil(try store.read("missing.json"), "no file")
        // Unreadable (here: a directory where the file should be) is an error, not "missing".
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state.v1.json"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.read("state.v1.json"))
    }

    func testUnreadableStateFileOnDiskDoesNotStartOver() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(PersistedState.fileName),
                                                withIntermediateDirectories: true)
        let h = Harness(store: FileStore(directory: dir))
        await h.client.start()
        let session = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertFalse(session.firstLaunch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(OfflineQueue.fileName).path))
    }
}

/// Re-enabling the SDK mid-launch reports this open once (SDK-9(f)).
final class ClientReenableSessionTests: XCTestCase {
    func testReenabledWhileRunningSendsOneSessionWhenStartSkippedIt() async throws {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()

        // Next launch: still off, so start() sends no session.
        await h.transport.reset()
        await h.transport.set(configResponse: Fixture.config(enabled: false))
        let next = h.relaunch()
        await next.client.start()
        var sessions = await h.transport.requests(to: "session")
        XCTAssertTrue(sessions.isEmpty)

        // Switched back on during this launch: one session for this open.
        await h.transport.set(configResponse: Fixture.config(enabled: true))
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config()))
        h.clock.advance(ProoflineClient.configTTL)
        _ = await next.client.tick()
        sessions = await h.transport.requests(to: "session")
        XCTAssertEqual(sessions.count, 1)
        let body = try XCTUnwrap(sessions.first).decode(SessionRequest.self)
        XCTAssertFalse(body.firstLaunch)
        XCTAssertEqual(body.endUserId, Fixture.endUserID)

        // Only once.
        h.clock.advance(ProoflineClient.configTTL)
        _ = await next.client.tick()
        sessions = await h.transport.requests(to: "session")
        XCTAssertEqual(sessions.count, 1)
    }

    func testReenabledAfterTheLaunchSessionWasDroppedSendsItAgain() async throws {
        let h = Harness()
        // The launch session meets a 403: kill switch on, queue (with that session) dropped.
        await h.transport.set("session", .status(403, Data(#"{"error":{"code":"sdk_disabled","message":"off"}}"#.utf8)))
        await h.client.start()
        XCTAssertTrue(h.client.haltFlag.isDisabled)

        await h.transport.set("session", nil)
        await h.transport.reset()
        _ = await h.client.tick()
        let sessions = await h.transport.requests(to: "session")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(h.client.haltFlag.isDisabled)
    }

    func testReenableBeforeStartDoesNotSendASession() async throws {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()
        await h.transport.reset()
        let next = h.relaunch()
        _ = await next.client.tick() // config is enabled; start() has not run
        let sessions = await h.transport.requests(to: "session")
        XCTAssertTrue(sessions.isEmpty, "start() reports the launch")
        await next.client.start()
        let afterStart = await h.transport.requests(to: "session")
        XCTAssertEqual(afterStart.count, 1)
    }
}
