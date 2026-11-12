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

    /// zod's `.max()` and sdk-js count UTF-16 code units; Swift's `count` counts characters, so a
    /// value of emoji passed the old check and the server rejected the request.
    func testLengthLimitsCountUTF16CodeUnitsLikeTheServer() throws {
        let emoji = String(repeating: "😀", count: 33) // 33 characters, 66 UTF-16 units
        XCTAssertNil(ProoflineInput.normalizeCode(emoji))
        XCTAssertEqual(ProoflineInput.normalizeCode(String(repeating: "😀", count: 32)), String(repeating: "😀", count: 32))
        XCTAssertThrowsError(try ProoflineInput.optionalID(String(repeating: "é", count: 200) + String(repeating: "😀", count: 40),
                                                           limit: ProoflineInput.maxUserIDLength, field: "userID"))
        XCTAssertEqual(try ProoflineInput.optionalID(String(repeating: "😀", count: 128),
                                                     limit: ProoflineInput.maxUserIDLength, field: "userID")?.utf16.count, 256)
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

    func testRevenueCatUpdateClearsCreatorKeysAndNeverTheEndUserKey() {
        // Identical to sdk-js `revenueCatAttributeUpdate`: "" clears (RevenueCat deletes an attribute
        // set to an empty string on every platform); the end-user key is written only when known.
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
        XCTAssertEqual(Set(cleared.keys), Set(RevenueCatAttributes.creatorScopedKeys))
        XCTAssertNil(cleared[RevenueCatAttributes.endUserId], "an unknown end user is not cleared")
        XCTAssertTrue(cleared.values.allSatisfy { $0 == RevenueCatAttributes.clearValue })
        XCTAssertEqual(RevenueCatAttributes.clearValue, "")
        XCTAssertEqual(RevenueCatAttributes.update(for: nil, endUserID: "eu_1")[RevenueCatAttributes.endUserId], "eu_1")
        XCTAssertEqual(RevenueCatAttributes.allKeys.count, 6)
        XCTAssertEqual(Set(RevenueCatAttributes.creatorScopedKeys + [RevenueCatAttributes.endUserId]),
                       Set(RevenueCatAttributes.allKeys))
    }

    func testRevenueCatClearValueIsIdenticalToSdkJs() throws {
        let source = try ModelsContractTests.sdkJsSource("revenuecat.ts")
        XCTAssertTrue(source.contains("export const REVENUECAT_CLEAR_VALUE = '';"))
    }

    func testOfflineQueueCapIsIdenticalToSdkJs() throws {
        let source = try ModelsContractTests.sdkJsSource("queue.ts")
        XCTAssertTrue(source.contains("export const DEFAULT_MAX_QUEUE_SIZE = \(OfflineQueue.capacity);"))
        XCTAssertEqual(OfflineQueue.capacity, 200)
    }

    func testServerUUIDRuleIsTheServersAndSdkJsRule() {
        // RFC 9562: version 1-8, variant 8/9/a/b, 8-4-4-4-12 hex. `UUID(uuidString:)` is looser.
        let valid = [
            Fixture.creatorID,
            "5c4b3a29-1807-4f6e-9d5c-4b3a29180700",
            "9B8A7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D",
            "00000000-0000-1000-8000-000000000000",
            "ffffffff-ffff-8fff-bfff-ffffffffffff",
        ]
        let invalid = [
            "", "cr_not_a_uuid",
            "9b8a7c6d-5e4f-0a3b-8c2d-1e0f9a8b7c6d",   // version 0
            "9b8a7c6d-5e4f-9a3b-8c2d-1e0f9a8b7c6d",   // version 9
            "9b8a7c6d-5e4f-4a3b-0c2d-1e0f9a8b7c6d",   // variant 0
            "9b8a7c6d-5e4f-4a3b-cc2d-1e0f9a8b7c6d",   // variant c
            "00000000-0000-0000-0000-000000000000",   // nil UUID
            "9b8a7c6d5e4f4a3b8c2d1e0f9a8b7c6d",       // no hyphens
            "{9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d}",
            "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6",    // short
            "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6dd",  // long
            "9b8a7c6g-5e4f-4a3b-8c2d-1e0f9a8b7c6d",   // not hex
            "9b8a7c6d_5e4f-4a3b-8c2d-1e0f9a8b7c6d",
            " 9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d",  // the caller trims
            "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6\u{e9}",
        ]
        for id in valid { XCTAssertTrue(ProoflineInput.isServerUUID(id), id) }
        for id in invalid { XCTAssertFalse(ProoflineInput.isServerUUID(id), id) }
        // The looser Foundation parser would have let the server reject these with a 400.
        XCTAssertNotNil(UUID(uuidString: "9b8a7c6d-5e4f-0a3b-8c2d-1e0f9a8b7c6d"))
    }

    func testParseLinkReturnsTheClickAndTheInAppPath() {
        let base = "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9"
        func link(_ suffix: String) -> ProoflineLink? { URL(string: base + suffix).flatMap(ProoflineLinks.parse) }
        XCTAssertEqual(link(""), ProoflineLink(clickID: "Ab3dE5gH7jK9", deepLinkPath: nil))
        XCTAssertEqual(link("?dl=%2Fworkouts%2F42")?.deepLinkPath, "/workouts/42")
        XCTAssertEqual(link("/?dl=%2Fworkouts%2F42")?.deepLinkPath, "/workouts/42", "trailing slash")
        XCTAssertEqual(link("?utm_source=ig&dl=%2Fplans%3Ftab%3Dpro%26x%3D1&z=2")?.deepLinkPath, "/plans?tab=pro&x=1")
        XCTAssertEqual(link("?dl=/workouts/42#top")?.deepLinkPath, "/workouts/42", "unencoded, with a fragment")
        XCTAssertEqual(link("?dl=%2Fa+b")?.deepLinkPath, "/a+b", "+ is not a space")
        XCTAssertEqual(link("?dl=%2Fcaf%C3%A9%2F%F0%9F%8F%83")?.deepLinkPath, "/caf\u{e9}/\u{1F3C3}")
        XCTAssertEqual(link("?dl=%2Ffirst&dl=%2Fsecond")?.deepLinkPath, "/first", "the first wins")
        XCTAssertEqual(link("?d%6C=%2Fencoded-name")?.deepLinkPath, "/encoded-name")

        // Invalid paths: the click still counts, the path is dropped.
        let dropped = [
            "?dl=", "?dl", "?dl=workouts", "?dl=%2F%2Fevil.example%2Fx", "?dl=https%3A%2F%2Fevil.example",
            "?dl=%2Fa%5Cb", "?dl=%2Fa%0Ab", "?dl=%2Fa%00b", "?dl=%2Fa%7Fb", "?dl=%2Fa%C2%85b",
            "?dl=%2Fa%E2%80%A8b", "?dl=%2Fa%E2%80%A9b", "?dl=%2Fbad%FF", "?dl=%2Fbad%C3",
            "?dl=javascript%3Aalert(1)", "?dl=%2F%2F", "?dl=bad&dl=%2Fsecond", "?DL=%2Fupper",
            "?dl=%2F" + String(repeating: "a", count: 512),
        ]
        for suffix in dropped {
            XCTAssertEqual(link(suffix), ProoflineLink(clickID: "Ab3dE5gH7jK9", deepLinkPath: nil), suffix)
        }
        XCTAssertEqual(link("?dl=%2F" + String(repeating: "a", count: 511))?.deepLinkPath?.utf16.count, 512)
        XCTAssertEqual(link("?dl=%2F")?.deepLinkPath, "/")

        // Not a click link: nothing, whatever the query says.
        XCTAssertNil(ProoflineLinks.parse(URL(string: "https://go.example.com/l/fit/sarah?dl=%2Fx")!))
        XCTAssertNil(ProoflineLinks.parse(URL(string: "myapp://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9?dl=%2Fx")!))
        XCTAssertEqual(ProoflineLinks.deepLinkParameter, "dl")
        XCTAssertEqual(ProoflineLinks.maxDeepLinkPathLength, 512)
    }

    func testDeepLinkPathLengthIsCountedInUTF16LikeTheServer() {
        // 255 emoji = 510 UTF-16 units + "/" = 511: allowed. 256 emoji = 513: rejected.
        XCTAssertTrue(ProoflineLinks.isDeepLinkPath("/" + String(repeating: "\u{1F3C3}", count: 255)))
        XCTAssertFalse(ProoflineLinks.isDeepLinkPath("/" + String(repeating: "\u{1F3C3}", count: 256)))
        // A combining mark after the slash is still a path that starts with "/" (scalars, not graphemes).
        XCTAssertTrue(ProoflineLinks.isDeepLinkPath("/\u{301}x"))
        XCTAssertFalse(ProoflineLinks.isDeepLinkPath(""))
    }

    func testDeepLinkRulesAreIdenticalToSdkJs() throws {
        let source = try ModelsContractTests.sdkJsSource("links.ts")
        XCTAssertTrue(source.contains("export const DEEP_LINK_PARAM = '\(ProoflineLinks.deepLinkParameter)';"))
        XCTAssertTrue(source.contains("export const MAX_DEEP_LINK_PATH_LENGTH = \(ProoflineLinks.maxDeepLinkPathLength);"))
    }

    func testRevenueCatKeysAreIdenticalToSdkJs() throws {
        let source = try ModelsContractTests.sdkJsSource("revenuecat.ts")
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
