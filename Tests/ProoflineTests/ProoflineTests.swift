import Foundation
import XCTest
@testable import Proofline

/// The static facade: never throws (except `identify`), never crashes, routes to the client.
/// Uses the process-wide registry, so every test resets it first and last.
final class ProoflineFacadeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Proofline.install(nil)
        Proofline.registry.clearPending()
    }

    override func tearDown() {
        Proofline.install(nil)
        Proofline.registry.clearPending()
        super.tearDown()
    }

    func testPublicCallsDoNotCrashBeforeConfigure() async {
        XCTAssertFalse(Proofline.isConfigured)
        let attr = await Proofline.currentAttribution()
        XCTAssertNil(attr)
        let ok = await Proofline.confirmCreator("cr_1")
        XCTAssertFalse(ok)
        let suggestions = await Proofline.suggestCreators("sa")
        XCTAssertEqual(suggestions, [])
        if case .error = await Proofline.submitCode("SARAH20") {} else { XCTFail("expected .error") }
        let synced = await Proofline.syncToRevenueCat { _ in XCTFail("nothing to write") }
        XCTAssertEqual(synced, [:])
        let viaSink = await Proofline.syncToRevenueCat(RecordingSink())
        XCTAssertEqual(viaSink, [:])
        let viaOptions = await Proofline.syncToRevenueCat()
        XCTAssertEqual(viaOptions, [:])
        let flushed = await Proofline.flush()
        XCTAssertEqual(flushed, 0)
        let token = await Proofline.appAccountToken(userID: "u_1")
        XCTAssertNil(token)
        do {
            _ = try await Proofline.identify(userID: "u_1")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    func testInvalidKeysAreIgnored() {
        for key in ["", "sk_test_secret", "pk_test_", "pk_prod_1", "rk_live_1"] {
            Proofline.configure(appKey: key)
            XCTAssertFalse(Proofline.isConfigured, key)
        }
        XCTAssertTrue(Proofline.isPublishableKey("pk_live_abc"))
        XCTAssertTrue(Proofline.isPublishableKey("pk_test_abc"))
    }

    func testConfigureWithTheSameKeyTwiceKeepsTheClient() throws {
        let options = ProoflineOptions(baseURL: URL(string: "https://platform.test")!, transport: MockTransport(),
                                       urlOpener: RecordingOpener(), storageDirectory: temporaryDirectory(),
                                       automaticFlush: false)
        defer { options.storageDirectory.map { try? FileManager.default.removeItem(at: $0) } }
        Proofline.configure(appKey: Fixture.appKey, options: options)
        let first = try XCTUnwrap(Proofline.registry.client)
        Proofline.configure(appKey: Fixture.appKey, options: options)
        XCTAssertTrue(Proofline.registry.client === first)
        Proofline.configure(appKey: "pk_test_other", options: options)
        XCTAssertFalse(Proofline.registry.client === first)
    }

    func testHandleRecognisesOnlyProoflineLinks() {
        XCTAssertFalse(Proofline.handle(URL(string: "https://example.com/promo")!))
        XCTAssertFalse(Proofline.handle(URL(string: "myapp://settings")!))
        XCTAssertTrue(Proofline.handle(Fixture.linkURL))
    }

    func testHandleLinkReturnsTheLinkWithItsInAppPath() {
        XCTAssertNil(Proofline.handleLink(URL(string: "https://example.com/promo?dl=%2Fx")!))
        XCTAssertNil(Proofline.handleLink(URL(string: "myapp://settings")!))
        XCTAssertEqual(Proofline.registry.pendingCount, 0)

        let url = URL(string: Fixture.linkURL.absoluteString + "?dl=%2Fworkouts%2F42")!
        XCTAssertEqual(Proofline.handleLink(url), ProoflineLink(clickID: Fixture.clickID, deepLinkPath: "/workouts/42"))
        XCTAssertEqual(Proofline.registry.pendingCount, 1, "recorded exactly as handle(_:) records it")
        XCTAssertEqual(Proofline.handleLink(Fixture.linkURL), ProoflineLink(clickID: Fixture.clickID, deepLinkPath: nil))
        XCTAssertTrue(Proofline.handle(url))
        XCTAssertEqual(Proofline.registry.pendingCount, 1, "one click id is buffered once")
    }

    func testHandleLinkForAUniversalLinkUserActivity() {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: Fixture.linkURL.absoluteString + "?dl=%2Fplans")!
        XCTAssertEqual(Proofline.handleLink(activity)?.deepLinkPath, "/plans")
        let other = NSUserActivity(activityType: "com.example.handoff")
        other.webpageURL = activity.webpageURL
        XCTAssertNil(Proofline.handleLink(other))
        XCTAssertNil(Proofline.handleLink(NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)))
    }

    func testHandleLinkStillRoutesWhileTheKillSwitchIsOff() async throws {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()
        Proofline.install(h.client)
        let before = await h.transport.requests(to: "session").count
        let url = URL(string: Fixture.linkURL.absoluteString + "?dl=%2Fworkouts%2F42")!
        XCTAssertEqual(Proofline.handleLink(url)?.deepLinkPath, "/workouts/42",
                       "routing keeps working when attribution is off")
        XCTAssertFalse(Proofline.handle(url))
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await h.transport.requests(to: "session").count
        XCTAssertEqual(after, before, "a disabled SDK records nothing")
    }

    func testLinksHandledBeforeConfigureAreReplayed() async throws {
        XCTAssertTrue(Proofline.handle(Fixture.linkURL))
        XCTAssertTrue(Proofline.handle(Fixture.linkURL))
        XCTAssertEqual(Proofline.registry.pendingCount, 1, "duplicates are buffered once")

        let h = Harness()
        Proofline.install(h.client)
        XCTAssertEqual(Proofline.registry.pendingCount, 0)
        let deadline = Date().addingTimeInterval(5)
        var linkSessions: [SessionRequest] = []
        while Date() < deadline {
            linkSessions = try await h.transport.requests(to: "session")
                .map { try $0.decode(SessionRequest.self) }
                .filter { $0.linkClickId == Fixture.clickID }
            if !linkSessions.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(linkSessions.count, 1)
    }

    func testPendingLinksAreBounded() {
        for i in 0 ..< ClientRegistry.maxPendingLinks + 3 {
            Proofline.handle(URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7j\(String(format: "%02d", i))")!)
        }
        XCTAssertEqual(Proofline.registry.pendingCount, ClientRegistry.maxPendingLinks)
    }

    func testUniversalLinkUserActivity() {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = Fixture.linkURL
        XCTAssertTrue(Proofline.handle(activity))
        let other = NSUserActivity(activityType: "com.example.handoff")
        other.webpageURL = Fixture.linkURL
        XCTAssertFalse(Proofline.handle(other))
        let empty = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        XCTAssertFalse(Proofline.handle(empty))
    }

    func testFacadeRoutesToTheInstalledClient() async throws {
        let sink = RecordingSink(appUserID: "rc_1")
        let h = Harness(sink: sink)
        Proofline.install(h.client)
        XCTAssertTrue(Proofline.isConfigured)

        let token = try await Proofline.identify(userID: "u_1")
        XCTAssertEqual(token, UUID(uuidString: Fixture.endUserID))
        let nonThrowing = await Proofline.appAccountToken(userID: "u_1")
        XCTAssertEqual(nonThrowing, token)

        let result = await Proofline.submitCode("SARAH20", pasted: true, openRedemption: false)
        XCTAssertTrue(result.isAccepted)
        XCTAssertTrue(h.opener.opened.isEmpty)
        let code = try await h.transport.firstRequest(to: "code").decode(CodeRequest.self)
        XCTAssertEqual(code.entry, .pasted)

        let suggested = await Proofline.suggestCreators("sa")
        XCTAssertEqual(suggested, Fixture.suggestions)
        let confirmed = await Proofline.confirmCreator(Fixture.creatorID)
        XCTAssertTrue(confirmed)
        let attribution = await Proofline.currentAttribution()
        XCTAssertEqual(attribution, Fixture.attribution)

        let viaOptions = await Proofline.syncToRevenueCat()
        XCTAssertEqual(viaOptions[RevenueCatAttributes.creatorId], Fixture.creatorID)
        let other = RecordingSink()
        let viaSink = await Proofline.syncToRevenueCat(other)
        XCTAssertEqual(other.written, [viaSink])
        let box = RecordingSink()
        let viaClosure = await Proofline.syncToRevenueCat { attrs in
            Task { await box.setAttributes(attrs) }
        }
        XCTAssertEqual(viaClosure, viaSink)
        _ = await Proofline.flush()
    }

    func testParityAPIsBeforeConfigure() async {
        XCTAssertFalse(Proofline.setAppClipClickID(Fixture.clickID))
        let config = await Proofline.remoteConfig()
        XCTAssertNil(config)
    }

    func testParityAPIsWhenConfigured() async throws {
        let h = Harness()
        Proofline.install(h.client)
        XCTAssertFalse(Proofline.setAppClipClickID("not-a-click"))
        XCTAssertTrue(Proofline.setAppClipClickID(Fixture.clickID))
        let config = await Proofline.remoteConfig()
        XCTAssertNotNil(config)
    }

    func testHandleReturnsFalseWhileTheKillSwitchIsOff() async {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()
        Proofline.install(h.client)
        XCTAssertFalse(Proofline.handle(Fixture.linkURL))
        XCTAssertFalse(Proofline.setAppClipClickID(Fixture.clickID))
    }

    func testDefaultOptions() {
        let options = ProoflineOptions()
        XCTAssertEqual(options.baseURL, Proofline.defaultBaseURL)
        XCTAssertTrue(options.automaticFlush)
        XCTAssertFalse(options.debug)
        XCTAssertNil(options.appTransactionIDProvider, "StoreKit AppTransaction is opt-in")
        #if os(macOS)
        XCTAssertEqual(options.platform, .unknown)
        #else
        XCTAssertEqual(options.platform, .ios)
        #endif
    }
}
