import Foundation
import XCTest
@testable import Proofline

final class HelpersTests: XCTestCase {
    func testClickIDExtraction() {
        XCTAssertEqual(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!), "Ab3dE5gH7jK9")
        XCTAssertEqual(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9/")!), "Ab3dE5gH7jK9")
        XCTAssertEqual(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9?utm=x")!), "Ab3dE5gH7jK9")
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/short")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK!")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/go/Ab3dE5gH7jK9")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/x/fit/sarah/c/Ab3dE5gH7jK9")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9/extra")!))
        XCTAssertFalse(ProoflineLinks.isClickID("Ab3dE5gH7jKé"))
    }

    func testClickIDRequiresAnAbsoluteHTTPURLWithAHost() {
        // Same as sdk-js `clickIdFromUrl`: only absolute http(s) URLs are Proofline links.
        XCTAssertEqual(ProoflineLinks.clickID(from: URL(string: "http://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!), "Ab3dE5gH7jK9")
        XCTAssertEqual(ProoflineLinks.clickID(from: URL(string: "HTTPS://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!), "Ab3dE5gH7jK9")
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "myapp:///l/fit/sarah/c/Ab3dE5gH7jK9")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "myapp://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "ftp://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(fileURLWithPath: "/l/fit/sarah/c/Ab3dE5gH7jK9")))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https:///l/fit/sarah/c/Ab3dE5gH7jK9")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "/l/fit/sarah/c/Ab3dE5gH7jK9")!), "relative URL")
    }

    func testAppleOfferCodeRedemptionDetection() {
        let yes = [
            "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SARAH20",
            "https://apps.apple.com/redeem/?ctx=offercodes&id=1&code=A",
            "itms-apps://apps.apple.com/redeem?ctx=offercodes&id=1&code=A",
            "HTTPS://APPS.APPLE.COM/redeem?ctx=offercodes&id=1&code=A",
        ]
        let no = [
            "https://apps.apple.com/redeem?ctx=offercodes&id=1",
            "https://apps.apple.com/redeem?ctx=other&id=1&code=A",
            "https://apps.apple.com/app/id123",
            "https://play.google.com/redeem?code=A",
            "http://apps.apple.com/redeem?ctx=offercodes&id=1&code=A",
            "https://apps.apple.com.evil.example/redeem?ctx=offercodes&id=1&code=A",
        ]
        for s in yes { XCTAssertTrue(ProoflineLinks.isAppleOfferCodeRedemption(URL(string: s)!), s) }
        for s in no { XCTAssertFalse(ProoflineLinks.isAppleOfferCodeRedemption(URL(string: s)!), s) }
    }

    func testCodeNormalization() {
        XCTAssertEqual(ProoflineInput.normalizeCode("  SARAH20  "), "SARAH20")
        XCTAssertEqual(ProoflineInput.normalizeCode("sarah20"), "sarah20", "the server upper-cases")
        XCTAssertEqual(ProoflineInput.normalizeCode("\n\n  SARAH20\nUse it today"), "SARAH20")
        XCTAssertEqual(ProoflineInput.normalizeCode(String(repeating: "A", count: 64))?.count, 64)
        XCTAssertNil(ProoflineInput.normalizeCode(String(repeating: "A", count: 65)))
        XCTAssertNil(ProoflineInput.normalizeCode(""))
        XCTAssertNil(ProoflineInput.normalizeCode(" \t\n "))
    }

    func testISOTimeMatchesTheJSFormat() {
        let date = Date(timeIntervalSince1970: 1_792_000_000.123)
        let s = ISOTime.string(date)
        XCTAssertTrue(s.hasSuffix("Z"))
        XCTAssertTrue(s.contains("."), "milliseconds, like Date.toISOString()")
        XCTAssertEqual(ISOTime.date(s)?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(ISOTime.date("2026-10-14T09:13:00Z"), "accepts timestamps without fractions")
        XCTAssertNil(ISOTime.date("yesterday"))
    }

    func testRevenueCatAttributesMatchSdkJs() {
        let attribution = Attribution(creator: CreatorSummary(id: "cr_1", name: "Sarah Lee", handle: "sarahmoves"),
                                      programId: "pr_1", tier: .V, status: .attributed, code: "SARAH20",
                                      decidedAt: "2026-10-14T09:13:00.000Z")
        XCTAssertEqual(RevenueCatAttributes.attributes(for: attribution, endUserID: "eu_1"), [
            "proofline_end_user_id": "eu_1",
            "proofline_creator_id": "cr_1",
            "proofline_creator_handle": "sarahmoves",
            "proofline_program_id": "pr_1",
            "proofline_tier": "V",
            "proofline_code": "SARAH20",
        ])
        XCTAssertEqual(RevenueCatAttributes.attributes(for: nil, endUserID: nil), [:])
        XCTAssertEqual(RevenueCatAttributes.attributes(for: nil, endUserID: "eu_1"), ["proofline_end_user_id": "eu_1"])
        XCTAssertEqual(RevenueCatAttributes.attributes(for: nil, endUserID: ""), [:])
        let bare = Attribution(creator: CreatorSummary(id: "c", name: "n"), programId: "p", tier: .U,
                               status: .provisional, decidedAt: "t")
        XCTAssertEqual(RevenueCatAttributes.attributes(for: bare, endUserID: nil),
                       ["proofline_creator_id": "c", "proofline_program_id": "p", "proofline_tier": "U"])
    }

    func testRevenueCatUpdateWritesEveryKeyAndClearsUnknownOnes() {
        // sdk-js `revenueCatAttributeUpdate` uses null; RevenueCat iOS deletes an attribute set to "".
        let bare = Attribution(creator: CreatorSummary(id: "c", name: "n"), programId: "p", tier: .U,
                               status: .provisional, decidedAt: "t")
        XCTAssertEqual(RevenueCatAttributes.update(for: bare, endUserID: "eu_1"), [
            "proofline_end_user_id": "eu_1",
            "proofline_creator_id": "c",
            "proofline_creator_handle": "",
            "proofline_program_id": "p",
            "proofline_tier": "U",
            "proofline_code": "",
        ])
        let cleared = RevenueCatAttributes.update(for: nil, endUserID: nil)
        XCTAssertEqual(Set(cleared.keys), Set(RevenueCatAttributes.allKeys))
        XCTAssertTrue(cleared.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(RevenueCatAttributes.allKeys.count, 6)
    }

    func testRevenueCatKeysAreIdenticalToSdkJs() throws {
        let rcURL = ModelsContractTests.typesURL.deletingLastPathComponent().appendingPathComponent("revenuecat.ts")
        let source = try String(contentsOf: rcURL, encoding: .utf8)
        let keys = [RevenueCatAttributes.endUserId, RevenueCatAttributes.creatorId, RevenueCatAttributes.creatorHandle,
                    RevenueCatAttributes.programId, RevenueCatAttributes.tier, RevenueCatAttributes.code]
        for key in keys {
            XCTAssertTrue(source.contains("'\(key)'"), "\(key) missing from sdk-js revenuecat.ts")
            XCTAssertFalse(key.hasPrefix("$"), "RevenueCat reserves the $ prefix")
        }
    }
}

final class OfflineQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func session(_ id: String) -> QueuedEvent.Body {
        .session(SessionRequest(eventId: id, installId: "i", endUserId: nil, platform: .ios, sdkVersion: "1",
                                appVersion: nil, openedAt: "t", firstLaunch: false, installReferrer: nil,
                                appClipClickId: nil, linkClickId: nil, linkUrl: nil, appTransactionId: nil))
    }

    func testBackoffScheduleMatchesSdkJs() {
        // min(2^previousAttempts * 5 s, 1 h), drop after 25 attempts (sdk-js backoffMs, DEFAULT_MAX_ATTEMPTS)
        XCTAssertEqual(OfflineQueue.maxAttempts, 25)
        XCTAssertEqual(OfflineQueue.backoff(attempts: 0), 5)
        XCTAssertEqual(OfflineQueue.backoff(attempts: 1), 10)
        XCTAssertEqual(OfflineQueue.backoff(attempts: 2), 20)
        XCTAssertEqual(OfflineQueue.backoff(attempts: 9), 2560)
        XCTAssertEqual(OfflineQueue.backoff(attempts: 10), 3600)
        XCTAssertEqual(OfflineQueue.backoff(attempts: 1000), 3600)
        XCTAssertEqual(OfflineQueue.backoff(attempts: -3), 5)
    }

    func testEnqueueIsIdempotentOnEventID() {
        var q = OfflineQueue()
        q.enqueue(session("a"), now: now)
        q.enqueue(session("a"), now: now)
        XCTAssertEqual(q.count, 1)
    }

    func testCapacityDropsTheOldest() {
        var q = OfflineQueue()
        for i in 0 ..< OfflineQueue.capacity + 3 { q.enqueue(session("e\(i)"), now: now) }
        XCTAssertEqual(q.count, OfflineQueue.capacity)
        XCTAssertEqual(q.events.first?.id, "e3")
    }

    func testDueIsOldestFirstAndLimited() {
        var q = OfflineQueue()
        for i in 0 ..< 5 { q.enqueue(session("e\(i)"), now: now) }
        XCTAssertEqual(q.due(now: now, limit: 3).map(\.id), ["e0", "e1", "e2"])
        q.recordFailure(id: "e0", now: now)
        XCTAssertEqual(q.due(now: now, limit: 3).map(\.id), ["e1", "e2", "e3"])
        XCTAssertEqual(q.due(now: now.addingTimeInterval(10), limit: 10).map(\.id), ["e0", "e1", "e2", "e3", "e4"])
    }

    func testRecordFailureBacksOffAndDropsAfterMaxAttempts() throws {
        var q = OfflineQueue()
        q.enqueue(session("a"), now: now)
        q.recordFailure(id: "a", now: now)
        let e = try XCTUnwrap(q.events.first)
        XCTAssertEqual(e.attempts, 1)
        XCTAssertEqual(ISOTime.date(e.nextAttemptAt)?.timeIntervalSince(now) ?? 0, 5, accuracy: 0.001,
                       "the first retry waits 5 s, like sdk-js backoffMs(previous = 0)")
        q.recordFailure(id: "a", now: now)
        XCTAssertEqual(ISOTime.date(try XCTUnwrap(q.events.first).nextAttemptAt)?.timeIntervalSince(now) ?? 0, 10,
                       accuracy: 0.001)
        for _ in 2 ..< OfflineQueue.maxAttempts - 1 { q.recordFailure(id: "a", now: now) }
        XCTAssertEqual(q.events.first?.attempts, OfflineQueue.maxAttempts - 1)
        q.recordFailure(id: "a", now: now)
        XCTAssertTrue(q.isEmpty)
        q.recordFailure(id: "missing", now: now) // no-op
    }

    func testPruneExpiredDropsOldAndUnreadableEvents() {
        var q = OfflineQueue(events: [
            QueuedEvent(body: session("old"), enqueuedAt: ISOTime.string(now.addingTimeInterval(-OfflineQueue.maxAge - 1)),
                        nextAttemptAt: ISOTime.string(now)),
            QueuedEvent(body: session("bad"), enqueuedAt: "garbage", nextAttemptAt: ISOTime.string(now)),
            QueuedEvent(body: session("new"), enqueuedAt: ISOTime.string(now), nextAttemptAt: ISOTime.string(now)),
        ])
        q.pruneExpired(now: now)
        XCTAssertEqual(q.events.map(\.id), ["new"])
    }

    func testRemoveAndRemoveAll() {
        var q = OfflineQueue()
        q.enqueue(session("a"), now: now)
        q.enqueue(session("b"), now: now)
        q.remove(id: "a")
        XCTAssertEqual(q.events.map(\.id), ["b"])
        q.removeAll()
        XCTAssertTrue(q.isEmpty)
    }
}

final class StorageTests: XCTestCase {
    func testFileStoreCreatesItsDirectoryAndWritesAtomically() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        XCTAssertNil(try store.read("x.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "construction does no I/O")
        try store.write(Data("one".utf8), to: "x.json")
        try store.write(Data("two".utf8), to: "x.json")
        XCTAssertEqual(try store.read("x.json"), Data("two".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["x.json"], "atomic writes leave no temporary files")
        store.remove("x.json")
        XCTAssertNil(try store.read("x.json"))
        store.remove("never-existed.json")
    }

    func testDefaultDirectorySeparatesTestAndLiveKeys() throws {
        let test = try XCTUnwrap(FileStore.defaultDirectory(appKey: "pk_test_1"))
        let live = try XCTUnwrap(FileStore.defaultDirectory(appKey: "pk_live_1"))
        XCTAssertEqual(test.lastPathComponent, "test")
        XCTAssertEqual(live.lastPathComponent, "live")
        XCTAssertTrue(test.path.contains("Application Support"))
        XCTAssertTrue(test.path.contains("dev.proofline.sdk"))
    }

    func testMemoryStore() throws {
        let store = MemoryStore()
        try store.write(Data("a".utf8), to: "k")
        XCTAssertEqual(store.read("k"), Data("a".utf8))
        store.remove("k")
        XCTAssertNil(store.read("k"))
    }

    func testPersistedStateDecodesOlderFilesWithMissingFields() throws {
        let state = try JSONDecoder().decode(PersistedState.self,
                                             from: Data(#"{"installId":"6f1c2a4e-8b3d-4f5a-9c7e-1d2b3a4c5e6f"}"#.utf8))
        XCTAssertFalse(state.sessionRecorded)
        XCTAssertFalse(state.disabled)
        XCTAssertTrue(state.handledClickIds.isEmpty)
        let withBadAttribution = #"{"installId":"x","attribution":{"oops":1},"config":{"enabled":"yes"}}"#
        let tolerant = try JSONDecoder().decode(PersistedState.self, from: Data(withBadAttribution.utf8))
        XCTAssertNil(tolerant.attribution)
        XCTAssertNil(tolerant.config)
    }

    func testHandledClickIDsAreBounded() {
        var state = PersistedState(installId: "i")
        for i in 0 ..< PersistedState.maxHandledClickIds + 10 { state.rememberClickID("id\(i)") }
        XCTAssertEqual(state.handledClickIds.count, PersistedState.maxHandledClickIds)
        XCTAssertEqual(state.handledClickIds.first, "id10")
        state.rememberClickID("id10")
        XCTAssertEqual(state.handledClickIds.last, "id10")
        XCTAssertEqual(state.handledClickIds.count, PersistedState.maxHandledClickIds)
    }

    func testAppClipHandoffRoundTrip() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ProoflineAppClip.storeHandoff(from: URL(string: "https://go.example.com/l/fit/sarah")!, in: dir, now: Date()))
        XCTAssertNil(ProoflineAppClip.readHandoff(in: dir))
        XCTAssertTrue(ProoflineAppClip.storeHandoff(from: Fixture.linkURL, in: dir, now: Date()))
        XCTAssertEqual(ProoflineAppClip.readHandoff(in: dir), Fixture.clickID)
        ProoflineAppClip.clearHandoff(in: dir)
        XCTAssertNil(ProoflineAppClip.readHandoff(in: dir))
        // A tampered file is ignored.
        try FileStore(directory: dir).write(Data(#"{"clickId":"../../etc","storedAt":"t"}"#.utf8),
                                            to: ProoflineAppClip.fileName)
        XCTAssertNil(ProoflineAppClip.readHandoff(in: dir))
    }
}
