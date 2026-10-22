import Foundation
import XCTest
@testable import Proofline

final class ClientSessionTests: XCTestCase {
    func testFirstLaunchSessionThenRelaunchReusesInstallID() async throws {
        let h = Harness()
        await h.client.start()

        let first = try await h.transport.firstRequest(to: "session")
        XCTAssertEqual(first.method, "POST")
        XCTAssertEqual(first.headers["X-Proofline-Key"], Fixture.appKey)
        let body = try first.decode(SessionRequest.self)
        XCTAssertTrue(body.firstLaunch)
        XCTAssertNil(body.endUserId)
        XCTAssertEqual(body.platform, .ios)
        XCTAssertEqual(body.sdkVersion, Proofline.sdkVersion)
        XCTAssertEqual(body.appVersion, "2.3.1")
        XCTAssertNotNil(UUID(uuidString: body.installId))
        XCTAssertEqual(body.installId, body.installId.lowercased())
        XCTAssertEqual(body.eventId, body.eventId.lowercased())
        XCTAssertNotNil(ISOTime.date(body.openedAt))
        let endUser = await h.client.endUserID
        XCTAssertEqual(endUser, Fixture.endUserID)
        let queued = await h.client.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(try persistedState(h.store).attribution, Fixture.attribution)

        // Relaunch over the same storage.
        await h.transport.reset()
        let relaunched = h.relaunch()
        await relaunched.client.start()
        let second = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertFalse(second.firstLaunch)
        XCTAssertEqual(second.installId, body.installId)
        XCTAssertEqual(second.endUserId, Fixture.endUserID)
    }

    func testStartIsIdempotent() async {
        let h = Harness()
        await h.client.start()
        await h.client.start()
        let sessions = await h.transport.requests(to: "session")
        XCTAssertEqual(sessions.count, 1)
    }

    func testOfflineSessionIsQueuedAndRetriedWithTheSameEventIDAfterBackoff() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        await h.client.start()
        let queued = try persistedQueue(h.store)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.attempts, 1)
        let eventID = try XCTUnwrap(queued.first?.id)

        // Not due yet: nothing is sent.
        await h.transport.set(override: nil)
        await h.transport.reset()
        h.clock.advance(4)
        let early = await h.client.flush()
        XCTAssertEqual(early, 0)
        let none = await h.transport.requests
        XCTAssertTrue(none.isEmpty)

        // After the 5 s first backoff (sdk-js schedule) the same event (same idempotency key) is delivered.
        h.clock.advance(1)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 1)
        let retried = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertEqual(retried.eventId, eventID)
        XCTAssertTrue(try persistedQueue(h.store).isEmpty)
    }

    func testQueuedEventsSurviveARelaunchOnDisk() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness(store: FileStore(directory: dir))
        await h.transport.set(override: .failure(.timedOut))
        await h.client.start()
        let offlineID = try XCTUnwrap(try persistedQueue(h.store).first?.id)

        await h.transport.set(override: nil)
        h.clock.advance(60)
        let relaunched = Harness(transport: h.transport, store: FileStore(directory: dir), clock: h.clock)
        await relaunched.client.start()
        let ids = try await h.transport.requests(to: "session").map { try $0.decode(SessionRequest.self).eventId }
        XCTAssertTrue(ids.contains(offlineID))
        XCTAssertEqual(Set(ids).count, 2, "the queued session and the new one")
        let remaining = await relaunched.client.queuedEventCount
        XCTAssertEqual(remaining, 0)
    }

    func testLinkOpenSendsClickIDOnceForTheSameLink() async throws {
        let h = Harness()
        await h.client.recordLinkOpen(clickID: Fixture.clickID, url: Fixture.linkURL)
        await h.client.recordLinkOpen(clickID: Fixture.clickID, url: Fixture.linkURL)
        let sessions = await h.transport.requests(to: "session")
        XCTAssertEqual(sessions.count, 1)
        let body = try XCTUnwrap(sessions.first).decode(SessionRequest.self)
        XCTAssertEqual(body.linkClickId, Fixture.clickID)
        XCTAssertEqual(body.linkUrl, Fixture.linkURL.absoluteString)
        XCTAssertTrue(body.firstLaunch, "the first session event carries firstLaunch, whichever sends it")
    }

    func testSessionWithoutOptionalFieldsOmitsThemFromJSON() async throws {
        let h = Harness()
        await h.client.start()
        let json = try await h.transport.firstRequest(to: "session").jsonObject()
        for key in ["endUserId", "installReferrer", "appClipClickId", "linkClickId", "linkUrl", "appTransactionId"] {
            XCTAssertNil(json[key], "\(key) must be omitted, not null")
        }
    }

    func testAppTransactionIDIsSentWithSessionAndIdentify() async throws {
        let h = Harness(appTransactionID: "atx_123")
        await h.client.start()
        _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        let session = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        let identify = try await h.transport.firstRequest(to: "identify").decode(IdentifyRequest.self)
        XCTAssertEqual(session.appTransactionId, "atx_123")
        XCTAssertEqual(identify.appTransactionId, "atx_123")
    }

    func testAppClipHandoffIsSentWithTheFirstSessionAndCleared() async throws {
        let group = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: group) }
        XCTAssertTrue(ProoflineAppClip.storeHandoff(from: Fixture.linkURL, in: group, now: Date()))
        let h = Harness(appGroupDirectory: group)
        await h.client.start()
        let body = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertEqual(body.appClipClickId, Fixture.clickID)
        XCTAssertNil(ProoflineAppClip.readHandoff(in: group), "handoff is consumed once")
    }

    func testCorruptStateFileStartsFresh() async throws {
        let store = MemoryStore()
        try store.write(Data("{not json".utf8), to: PersistedState.fileName)
        try store.write(Data("[{\"broken\":true}]".utf8), to: OfflineQueue.fileName)
        let h = Harness(store: store)
        await h.client.start()
        let body = try await h.transport.firstRequest(to: "session").decode(SessionRequest.self)
        XCTAssertNotNil(UUID(uuidString: body.installId))
        XCTAssertTrue(body.firstLaunch)
        XCTAssertEqual(try persistedState(store).installId, body.installId)
    }

    func testStateWithANonUUIDInstallIDIsReplaced() async throws {
        let store = MemoryStore()
        try store.write(Data(#"{"installId":"device-serial-123"}"#.utf8), to: PersistedState.fileName)
        let h = Harness(store: store)
        let installID = await h.client.installID
        XCTAssertNotNil(UUID(uuidString: installID))
    }
}

final class ClientIdentifyTests: XCTestCase {
    func testIdentifyReturnsTheEndUserUUIDAndSendsAliases() async throws {
        let h = Harness(sink: RecordingSink(appUserID: "rc_user_1"))
        let token = try await h.client.identify(userID: " u_123 ", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(token, UUID(uuidString: Fixture.endUserID))
        let body = try await h.transport.firstRequest(to: "identify").decode(IdentifyRequest.self)
        XCTAssertEqual(body.externalUserId, "u_123")
        XCTAssertEqual(body.revenueCatAppUserId, "rc_user_1")
        XCTAssertEqual(body.platform, .ios)
        XCTAssertNotNil(UUID(uuidString: body.installId))
        XCTAssertEqual(try persistedState(h.store).endUserId, Fixture.endUserID)
        XCTAssertFalse(try persistedState(h.store).lastIdentifyKey?.contains("u_123") ?? true,
                       "raw user ids are not stored for the cache check")
    }

    func testRepeatIdentifyWithSameArgumentsIsServedFromCache() async throws {
        let h = Harness()
        _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
        var count = await h.transport.requests(to: "identify").count
        XCTAssertEqual(count, 1)
        _ = try await h.client.identify(userID: "u_2", revenueCatAppUserID: nil, appTransactionID: nil)
        count = await h.transport.requests(to: "identify").count
        XCTAssertEqual(count, 2)
    }

    func testIdentifyOfflineReturnsTheKnownIDAndQueuesTheCall() async throws {
        let h = Harness()
        await h.client.start()
        await h.transport.set(override: .failure(.networkConnectionLost))
        let token = try await h.client.identify(userID: "u_2", revenueCatAppUserID: nil, appTransactionID: nil)
        XCTAssertEqual(token, UUID(uuidString: Fixture.endUserID))
        let queued = try persistedQueue(h.store)
        XCTAssertEqual(queued.map(\.kind), [.identify])

        // Back online: the queued identify is delivered and its end user id adopted.
        await h.transport.set(override: nil)
        await h.transport.set(identifyEndUserID: Fixture.otherEndUserID)
        h.clock.advance(3600)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 1)
        let endUser = await h.client.endUserID
        XCTAssertEqual(endUser, Fixture.otherEndUserID)
    }

    func testIdentifyOfflineWithNoKnownIDThrowsNetworkAndQueues() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        do {
            _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
            XCTFail("expected a throw")
        } catch {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        }
        let queued = await h.client.queuedEventCount
        XCTAssertEqual(queued, 1)
    }

    func testIdentifyRejectsANonUUIDEndUserID() async throws {
        let h = Harness()
        await h.transport.set(identifyEndUserID: "eu_not_a_uuid")
        do {
            _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
            XCTFail("expected a throw")
        } catch {
            guard case .invalidResponse = error else { return XCTFail("expected .invalidResponse, got \(error)") }
        }
        let endUser = await h.client.endUserID
        XCTAssertNil(endUser)
    }

    func testIdentifyValidatesArgumentLengthsWithoutARequest() async throws {
        let h = Harness()
        do {
            _ = try await h.client.identify(userID: String(repeating: "x", count: 257), revenueCatAppUserID: nil,
                                            appTransactionID: nil)
            XCTFail("expected a throw")
        } catch {
            guard case .invalidInput = error else { return XCTFail("expected .invalidInput, got \(error)") }
        }
        do {
            _ = try await h.client.identify(userID: nil, revenueCatAppUserID: nil,
                                            appTransactionID: String(repeating: "1", count: 129))
            XCTFail("expected a throw")
        } catch {
            guard case .invalidInput = error else { return XCTFail("expected .invalidInput, got \(error)") }
        }
        let count = await h.transport.requests.count
        XCTAssertEqual(count, 0)

        // Empty strings mean "not provided".
        _ = try await h.client.identify(userID: "", revenueCatAppUserID: "  ", appTransactionID: nil)
        let json = try await h.transport.firstRequest(to: "identify").jsonObject()
        XCTAssertNil(json["externalUserId"])
        XCTAssertNil(json["revenueCatAppUserId"])
    }

    func testIdentifyAPIErrorIsSurfacedAndNotQueued() async throws {
        let h = Harness()
        await h.transport.set("identify", .status(422, Data(#"{"error":{"code":"invalid_input","message":"bad"}}"#.utf8)))
        do {
            _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error, .api(status: 422, code: "invalid_input", message: "bad"))
        }
        let queued = await h.client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }
}

final class ClientCodeTests: XCTestCase {
    func testAppleOfferCodeIsAcceptedAndTheRedemptionSheetOpened() async throws {
        let h = Harness()
        await h.client.start()
        let result = await h.client.submitCode("  SARAH20 \n", entry: .typed, openRedemption: true)
        let url = try XCTUnwrap(URL(string: Fixture.appleRedemption))
        XCTAssertEqual(result, .accepted(creator: Fixture.creator, redemptionURL: url,
                                         offerLabel: "20% off your first 3 months"))
        XCTAssertEqual(h.opener.opened, [url])
        let body = try await h.transport.firstRequest(to: "code").decode(CodeRequest.self)
        XCTAssertEqual(body.code, "SARAH20")
        XCTAssertEqual(body.entry, .typed)
        XCTAssertEqual(body.endUserId, Fixture.endUserID)
    }

    func testPastedEntryIsReported() async throws {
        let h = Harness()
        _ = await h.client.submitCode("SARAH20", entry: .pasted, openRedemption: false)
        let body = try await h.transport.firstRequest(to: "code").decode(CodeRequest.self)
        XCTAssertEqual(body.entry, .pasted)
        XCTAssertTrue(h.opener.opened.isEmpty, "openRedemption: false never opens")
    }

    func testNonAppleRedemptionURLIsReturnedButNotOpened() async {
        let h = Harness()
        let play = "https://play.google.com/redeem?code=SARAH20"
        await h.transport.set(codeResponse: .accepted(creator: Fixture.creator, redemptionUrl: play, offerLabel: nil))
        let result = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        XCTAssertEqual(result, .accepted(creator: Fixture.creator, redemptionURL: URL(string: play), offerLabel: nil))
        XCTAssertTrue(h.opener.opened.isEmpty)
    }

    func testAcceptedCodeWithoutRedemptionURL() async {
        let h = Harness()
        await h.transport.set(codeResponse: .accepted(creator: Fixture.creator, redemptionUrl: nil, offerLabel: nil))
        let result = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        XCTAssertEqual(result, .accepted(creator: Fixture.creator, redemptionURL: nil, offerLabel: nil))
        XCTAssertTrue(h.opener.opened.isEmpty)
    }

    func testRejectedStatusesMapToResults() async {
        let cases: [(CodeResponse.Rejection, CodeResult)] = [
            (.unknownCode, .unknownCode), (.expired, .expired), (.exhausted, .exhausted), (.revoked, .revoked),
        ]
        for (rejection, expected) in cases {
            let h = Harness()
            await h.transport.set(codeResponse: .rejected(rejection))
            let result = await h.client.submitCode("NOPE", entry: .typed, openRedemption: true)
            XCTAssertEqual(result, expected)
        }
    }

    func testInvalidCodesNeverReachTheServer() async {
        let h = Harness()
        for raw in ["", "   \n  ", String(repeating: "A", count: 65)] {
            let result = await h.client.submitCode(raw, entry: .typed, openRedemption: true)
            guard case .error = result else { return XCTFail("expected .error for \(raw.debugDescription)") }
        }
        let count = await h.transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testOfflineCodeIsQueuedAndReportedAsQueued() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        let result = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        guard case .queued = result else { return XCTFail("expected .queued, got \(result)") }
        XCTAssertEqual(try persistedQueue(h.store).map(\.kind), [.code])
    }

    func testServerErrorWithEnvelopeIsReportedAndNotQueued() async {
        let h = Harness()
        await h.transport.set("code", .status(400, Data(#"{"error":{"code":"invalid_input","message":"code too long"}}"#.utf8)))
        let result = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        guard case let .error(message) = result else { return XCTFail("expected .error") }
        XCTAssertTrue(message.contains("invalid_input"))
        let queued = await h.client.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testUnknownStatusInResponseIsAnError() async {
        let h = Harness()
        await h.transport.set("code", .ok(Data(#"{"status":"maybe"}"#.utf8)))
        let result = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        guard case .error = result else { return XCTFail("expected .error") }
    }

    func testCodeEntryTurnedOffRemotely() async {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(codeEntry: false)))
        await h.client.start()
        let result = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        XCTAssertEqual(result, .error(message: "Code entry is turned off for this app"))
        let count = await h.transport.requests(to: "code").count
        XCTAssertEqual(count, 0)
    }
}

final class ClientConfirmAndAttributionTests: XCTestCase {
    func testConfirmCreatorAcceptedRejectedAndInvalid() async throws {
        let h = Harness()
        var ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertTrue(ok)
        let body = try await h.transport.firstRequest(to: "confirm").decode(ConfirmRequest.self)
        XCTAssertEqual(body.creatorId, Fixture.creatorID)

        await h.transport.set(confirmResponse: ConfirmResponse(status: .rejected, attribution: nil))
        ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertFalse(ok)

        ok = await h.client.confirmCreator("cr_not_a_uuid")
        XCTAssertFalse(ok)
        let count = await h.transport.requests(to: "confirm").count
        XCTAssertEqual(count, 2, "invalid ids are not sent")
    }

    func testConfirmOfflineQueuesAndReturnsFalse() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.cannotFindHost))
        let ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertFalse(ok)
        XCTAssertEqual(try persistedQueue(h.store).map(\.kind), [.confirm])
    }

    func testConfirmTurnedOffRemotely() async {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(confirm: false)))
        await h.client.start()
        let ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertFalse(ok)
        let count = await h.transport.requests(to: "confirm").count
        XCTAssertEqual(count, 0)
    }

    func testCurrentAttributionFetchesThenFallsBackToCacheOffline() async throws {
        let h = Harness()
        await h.client.start()
        let online = await h.client.currentAttribution()
        XCTAssertEqual(online, Fixture.attribution)
        let request = try await h.transport.firstRequest(to: "attribution")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.query["endUserId"], Fixture.endUserID)

        await h.transport.set(override: .failure(.notConnectedToInternet))
        let offline = await h.client.currentAttribution()
        XCTAssertEqual(offline, Fixture.attribution)
    }

    func testCurrentAttributionNullFromServerClearsCache() async {
        let h = Harness()
        await h.client.start()
        await h.transport.set(attributionResponse: AttributionResponse(attribution: nil))
        let value = await h.client.currentAttribution()
        XCTAssertNil(value)
        await h.transport.set(override: .failure(.notConnectedToInternet))
        let cached = await h.client.currentAttribution()
        XCTAssertNil(cached)
    }

    func testCurrentAttributionWithoutAnEndUserMakesNoAttributionRequest() async {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        let value = await h.client.currentAttribution()
        XCTAssertNil(value)
        let count = await h.transport.requests(to: "attribution").count
        XCTAssertEqual(count, 0)
    }

    func testSyncToRevenueCatWritesMappedAttributes() async {
        let sink = RecordingSink()
        let h = Harness(sink: sink)
        await h.client.start()
        let attrs = await h.client.syncToConfiguredRevenueCat()
        let expected = [
            "proofline_end_user_id": Fixture.endUserID,
            "proofline_creator_id": Fixture.creatorID,
            "proofline_creator_handle": "sarahmoves",
            "proofline_program_id": "pr_1",
            "proofline_tier": "V",
            "proofline_code": "SARAH20",
        ]
        XCTAssertEqual(attrs, expected)
        XCTAssertEqual(sink.written, [expected])
    }

    func testSyncToRevenueCatWithoutASinkOrDataWritesNothing() async {
        let h = Harness()
        let none = await h.client.syncToConfiguredRevenueCat()
        XCTAssertEqual(none, [:])

        let sink = RecordingSink()
        let offline = Harness(sink: sink)
        await offline.transport.set(override: .failure(.notConnectedToInternet))
        let attrs = await offline.client.syncToConfiguredRevenueCat()
        XCTAssertEqual(attrs, [:])
        XCTAssertTrue(sink.written.isEmpty)
    }
}

final class ClientKillSwitchTests: XCTestCase {
    private func assertQuiet(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        await h.transport.reset()
        do {
            _ = try await h.client.identify(userID: "u_1", revenueCatAppUserID: nil, appTransactionID: nil)
            XCTFail("expected .disabled", file: file, line: line)
        } catch {
            XCTAssertEqual(error, .disabled, file: file, line: line)
        }
        let code = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        XCTAssertEqual(code, .error(message: "Proofline is disabled for this app"), file: file, line: line)
        let confirmed = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertFalse(confirmed, file: file, line: line)
        let attribution = await h.client.currentAttribution()
        XCTAssertNil(attribution, file: file, line: line)
        await h.client.recordLinkOpen(clickID: "Zz9yX8wV7uT6", url: Fixture.linkURL)
        let flushed = await h.client.flush()
        XCTAssertEqual(flushed, 0, file: file, line: line)
        let sent = await h.transport.requests
        XCTAssertTrue(sent.isEmpty, "a disabled SDK sends nothing", file: file, line: line)
    }

    func testConfigEnabledFalseStopsTheSDKAndPurgesTheQueue() async throws {
        let h = Harness()
        // Queue an event while offline, then let the session report the kill switch.
        await h.transport.set(override: .failure(.notConnectedToInternet))
        _ = await h.client.submitCode("SARAH20", entry: .typed, openRedemption: true)
        await h.transport.set(override: nil)
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()
        XCTAssertTrue(try persistedState(h.store).disabled)
        XCTAssertTrue(try persistedQueue(h.store).isEmpty)
        await assertQuiet(h)
    }

    func testHTTP403IsTreatedAsTheKillSwitch() async throws {
        let h = Harness()
        await h.transport.set(override: .status(403, Data(#"{"error":{"code":"sdk_disabled","message":"off"}}"#.utf8)))
        await h.client.start()
        XCTAssertTrue(try persistedState(h.store).disabled)
        await h.transport.set(override: nil)
        await assertQuiet(h)
    }

    func testDisabledSDKRechecksConfigOnTheNextLaunch() async throws {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()

        // Still disabled at the next launch: only the config is fetched.
        await h.transport.reset()
        await h.transport.set(configResponse: Fixture.config(enabled: false))
        let stillOff = h.relaunch()
        await stillOff.client.start()
        var sent = await h.transport.requests.map(\.endpoint)
        XCTAssertEqual(sent, ["config"])

        // Re-enabled: the SDK resumes and sends a session.
        await h.transport.reset()
        await h.transport.set(configResponse: Fixture.config(enabled: true))
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config()))
        let back = h.relaunch()
        await back.client.start()
        sent = await h.transport.requests.map(\.endpoint)
        XCTAssertEqual(sent, ["config", "session"])
        XCTAssertFalse(try persistedState(h.store).disabled)
    }

    func testDisabledSDKStaysQuietWhenTheConfigCheckFails() async throws {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()
        await h.transport.reset()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        let next = h.relaunch()
        await next.client.start()
        let sent = await h.transport.requests.map(\.endpoint)
        XCTAssertEqual(sent, ["config"])
        XCTAssertTrue(try persistedState(h.store).disabled)
    }
}

final class ClientQueueDeliveryTests: XCTestCase {
    func testHTTP401StopsSendingButKeepsTheQueue() async throws {
        let h = Harness()
        await h.transport.set(override: .status(401, Data(#"{"error":{"code":"invalid_key","message":"no"}}"#.utf8)))
        await h.client.start()
        XCTAssertEqual(try persistedQueue(h.store).count, 1)
        await h.transport.reset()
        await h.transport.set(override: nil)
        h.clock.advance(3600)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 0)
        let sent = await h.transport.requests
        XCTAssertTrue(sent.isEmpty)
        do {
            _ = try await h.client.identify(userID: "u", revenueCatAppUserID: nil, appTransactionID: nil)
            XCTFail("expected .invalidAppKey")
        } catch {
            XCTAssertEqual(error, .invalidAppKey)
        }
    }

    func testPermanentClientErrorsDropTheEvent() async throws {
        let h = Harness()
        await h.transport.set("session", .status(400, Data(#"{"error":{"code":"invalid_input","message":"x"}}"#.utf8)))
        await h.client.start()
        XCTAssertTrue(try persistedQueue(h.store).isEmpty)
    }

    func testServerErrorsAndRateLimitsAreRetried() async throws {
        for status in [500, 503, 429, 408] {
            let h = Harness()
            await h.transport.set("session", .status(status, Data()))
            await h.client.start()
            let queued = try persistedQueue(h.store)
            XCTAssertEqual(queued.count, 1, "status \(status)")
            XCTAssertEqual(queued.first?.attempts, 1, "status \(status)")
        }
    }

    func testMalformedSuccessBodyDropsTheEvent() async throws {
        let h = Harness()
        await h.transport.set("session", .ok(Data(#"{"endUserId":"not-a-uuid","attribution":null,"config":{}}"#.utf8)))
        await h.client.start()
        XCTAssertTrue(try persistedQueue(h.store).isEmpty)
        let endUser = await h.client.endUserID
        XCTAssertNil(endUser)
    }

    func testAFailingEventStopsThePassSoTheNetworkIsNotHammered() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        await h.client.start()
        for i in 0 ..< 3 {
            await h.client.recordLinkOpen(clickID: "Ab3dE5gH7jK\(i)", url: Fixture.linkURL)
        }
        await h.transport.reset()
        h.clock.advance(3600)
        _ = await h.client.flush()
        let attempts = await h.transport.requests.count
        XCTAssertEqual(attempts, 1)
    }

    func testBatchSizeLimitsOnePass() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        for i in 0 ..< 5 {
            await h.client.recordLinkOpen(clickID: "Ab3dE5gH7jK\(i)", url: Fixture.linkURL)
        }
        XCTAssertEqual(try persistedQueue(h.store).count, 5)
        try h.store.write(Fixture.json(PersistedState.withConfig(Fixture.config(batchSize: 2), from: h.store)),
                          to: PersistedState.fileName)
        let reloaded = h.relaunch()
        await h.transport.set(override: nil)
        h.clock.advance(3600)
        let delivered = await reloaded.client.flush()
        XCTAssertEqual(delivered, 2)
        let remaining = await reloaded.client.queuedEventCount
        XCTAssertEqual(remaining, 3)
    }

    func testConcurrentFlushesSendEachEventOnce() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        for i in 0 ..< 4 {
            await h.client.recordLinkOpen(clickID: "Ab3dE5gH7jK\(i)", url: Fixture.linkURL)
        }
        await h.transport.reset()
        await h.transport.set(override: nil)
        await h.transport.set(delayNanoseconds: 20_000_000)
        h.clock.advance(3600)
        let client = h.client
        let total = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 6 { group.addTask { await client.flush() } }
            return await group.reduce(0, +)
        }
        let ids = try await h.transport.requests(to: "session").map { try $0.decode(SessionRequest.self).eventId }
        XCTAssertEqual(ids.count, Set(ids).count, "no event is sent twice")
        XCTAssertEqual(Set(ids).count, 4)
        XCTAssertGreaterThanOrEqual(total, 4)
        let remaining = await client.queuedEventCount
        XCTAssertEqual(remaining, 0)
    }

    func testFlushDuringAPassIncludesEventsQueuedMeanwhile() async throws {
        let h = Harness()
        await h.transport.set(delayNanoseconds: 30_000_000)
        let client = h.client
        async let first: Void = client.start()
        try await Task.sleep(nanoseconds: 5_000_000)
        await client.recordLinkOpen(clickID: Fixture.clickID, url: Fixture.linkURL)
        await first
        let sessions = await h.transport.requests(to: "session").count
        XCTAssertEqual(sessions, 2)
        let remaining = await client.queuedEventCount
        XCTAssertEqual(remaining, 0)
    }
}

extension PersistedState {
    static func withConfig(_ config: SdkConfig, from store: any PersistentStore) throws -> PersistedState {
        var state = try persistedState(store)
        state.config = config
        return state
    }
}

final class ClientPeriodicTests: XCTestCase {
    func testTickRefreshesAStaleConfigAndFlushes() async throws {
        let h = Harness()
        await h.client.start()
        // Fresh config from the session: no config request, nothing due.
        await h.transport.reset()
        var delay = await h.client.tick()
        XCTAssertEqual(delay, 30)
        var sent = await h.transport.requests.map(\.endpoint)
        XCTAssertEqual(sent, [])

        // After the TTL the config is re-fetched and its flush interval adopted.
        await h.transport.set(configResponse: Fixture.config(flushInterval: 120))
        h.clock.advance(ProoflineClient.configTTL)
        delay = await h.client.tick()
        XCTAssertEqual(delay, 120)
        sent = await h.transport.requests.map(\.endpoint)
        XCTAssertEqual(sent, ["config"])
        let config = await h.client.remoteConfig()
        XCTAssertEqual(config.flushIntervalSeconds, 120)
    }

    func testTickDeliversDueEvents() async throws {
        let h = Harness()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        await h.client.start()
        await h.transport.set(override: nil)
        h.clock.advance(60)
        _ = await h.client.tick()
        let remaining = await h.client.queuedEventCount
        XCTAssertEqual(remaining, 0)
    }

    func testDisabledSDKNoticesWhenItIsSwitchedBackOn() async throws {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(enabled: false)))
        await h.client.start()
        XCTAssertTrue(h.client.haltFlag.isDisabled)

        // Within the TTL nothing is asked.
        await h.transport.reset()
        var delay = await h.client.tick()
        XCTAssertEqual(delay, ProoflineClient.configTTL)
        var sent = await h.transport.requests
        XCTAssertTrue(sent.isEmpty)

        // Still off after the TTL.
        await h.transport.set(configResponse: Fixture.config(enabled: false))
        h.clock.advance(ProoflineClient.configTTL)
        delay = await h.client.tick()
        XCTAssertEqual(delay, ProoflineClient.configTTL)
        XCTAssertTrue(h.client.haltFlag.isDisabled)

        // Switched back on: the SDK resumes. This open's session was already delivered (its answer
        // carried the kill switch), so it is not reported a second time.
        await h.transport.reset()
        await h.transport.set(configResponse: Fixture.config(enabled: true))
        h.clock.advance(ProoflineClient.configTTL)
        delay = await h.client.tick()
        XCTAssertEqual(delay, 30)
        XCTAssertFalse(h.client.haltFlag.isDisabled)
        XCTAssertFalse(try persistedState(h.store).disabled)
        sent = await h.transport.requests
        XCTAssertEqual(sent.map(\.endpoint), ["config"])
        await h.transport.reset()
        let ok = await h.client.confirmCreator(Fixture.creatorID)
        XCTAssertTrue(ok)
        sent = await h.transport.requests
        XCTAssertEqual(sent.map(\.endpoint), ["confirm"])
    }

    func testConfigRefreshFailureWaitsAFullTTL() async throws {
        let h = Harness()
        await h.client.start()
        await h.transport.set(override: .failure(.notConnectedToInternet))
        h.clock.advance(ProoflineClient.configTTL)
        _ = await h.client.tick()
        await h.transport.reset()
        h.clock.advance(10)
        _ = await h.client.tick()
        let configRequests = await h.transport.requests(to: "config").count
        XCTAssertEqual(configRequests, 0)
    }

    func testCurrentAttributionIsCachedForAMinute() async throws {
        let h = Harness()
        await h.client.start()
        _ = await h.client.currentAttribution()
        _ = await h.client.currentAttribution()
        var count = await h.transport.requests(to: "attribution").count
        XCTAssertEqual(count, 1)
        h.clock.advance(ProoflineClient.attributionTTL + 1)
        _ = await h.client.currentAttribution()
        count = await h.transport.requests(to: "attribution").count
        XCTAssertEqual(count, 2)
    }

    func testAppClipClickIsSentOnceAndInvalidIDsAreIgnored() async throws {
        let h = Harness()
        await h.client.recordAppClipClick(clickID: Fixture.clickID)
        await h.client.recordAppClipClick(clickID: Fixture.clickID)
        await h.client.recordAppClipClick(clickID: "bad")
        let sessions = try await h.transport.requests(to: "session").map { try $0.decode(SessionRequest.self) }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.appClipClickId, Fixture.clickID)
        XCTAssertNil(sessions.first?.linkClickId)
    }

    func testRemoteConfigDefaultsUntilTheServerAnswers() async {
        let h = Harness()
        let before = await h.client.remoteConfig()
        XCTAssertEqual(before, SdkConfig.fallback)
        await h.client.start()
        let after = await h.client.remoteConfig()
        XCTAssertEqual(after, Fixture.config())
    }
}
