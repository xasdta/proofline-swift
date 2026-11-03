import Foundation
import XCTest
@testable import Proofline

/// `suggestCreators` ("Who sent you?" candidates): a read that never queues, as in sdk-js.
final class SuggestCreatorsTests: XCTestCase {
    func testReturnsTheSuggestionsAndSendsTheQueryAndInstallID() async throws {
        let h = Harness()
        let creators = await h.client.suggestCreators("sa")
        XCTAssertEqual(creators, Fixture.suggestions)
        let request = try await h.transport.firstRequest(to: "suggest")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.path, "/api/sdk/v1/creators/suggest")
        XCTAssertEqual(request.headers["X-Proofline-Key"], Fixture.appKey)
        XCTAssertNil(request.body)
        let installID = await h.client.installID
        XCTAssertEqual(request.query, ["q": "sa", "installId": installID])

        // Trimmed and without the leading @ (the server ignores it); no query lists the top creators.
        _ = await h.client.suggestCreators("  @@SARAH ")
        _ = await h.client.suggestCreators("")
        _ = await h.client.suggestCreators("@")
        let sent = await h.transport.requests(to: "suggest").map(\.query)
        XCTAssertEqual(sent.dropFirst().map { $0["q"] }, ["SARAH", nil, nil])
        XCTAssertEqual(Set(sent.map { $0["installId"] }), [installID])

        // The pick goes to confirmCreator.
        let confirmed = await h.client.confirmCreator(try XCTUnwrap(creators.first).id)
        XCTAssertTrue(confirmed)
        let body = try await h.transport.firstRequest(to: "confirm").decode(ConfirmRequest.self)
        XCTAssertEqual(body.creatorId, Fixture.creatorID)
    }

    func testNoMatchAndQueriesTheServerWouldRejectReturnEmpty() async throws {
        let h = Harness()
        await h.transport.set(suggestResponse: SuggestCreatorsResponse(creators: []))
        let none = await h.client.suggestCreators("zz")
        XCTAssertEqual(none, [])
        for query in [String(repeating: "x", count: 51), "a\u{0}b", String(repeating: "😀", count: 26)] {
            let result = await h.client.suggestCreators(query)
            XCTAssertEqual(result, [], "query of \(query.utf16.count) UTF-16 units")
        }
        var count = await h.transport.requests(to: "suggest").count
        XCTAssertEqual(count, 1, "queries the server would reject are not sent")
        // 50 UTF-16 units is the server's limit (zod counts UTF-16), after the @ is dropped.
        _ = await h.client.suggestCreators("@" + String(repeating: "s", count: 50))
        _ = await h.client.suggestCreators(String(repeating: "😀", count: 25))
        count = await h.transport.requests(to: "suggest").count
        XCTAssertEqual(count, 3)
    }

    func testPromptTurnedOffRemotelySendsNothing() async {
        let h = Harness()
        await h.transport.set(sessionResponse: SessionResponse(endUserId: Fixture.endUserID, attribution: nil,
                                                                config: Fixture.config(confirm: false)))
        await h.client.start()
        let creators = await h.client.suggestCreators("sa")
        XCTAssertEqual(creators, [])
        let count = await h.transport.requests(to: "suggest").count
        XCTAssertEqual(count, 0)
    }

    func testFailuresReturnEmptyAndAreNeverQueued() async throws {
        let h = Harness()
        let failures: [MockReply] = [
            .failure(.notConnectedToInternet),
            .status(429, Data(#"{"error":{"code":"rate_limited","message":"slow down"}}"#.utf8)),
            .status(500, Data()),
            .status(422, Data(#"{"error":{"code":"invalid_request","message":"q"}}"#.utf8)),
            .ok(Data(#"{"creators":[{"id":"c"}]}"#.utf8)),
            .ok(Data("<html>".utf8)),
        ]
        for reply in failures {
            await h.transport.set("suggest", reply)
            let creators = await h.client.suggestCreators("sa")
            XCTAssertEqual(creators, [])
        }
        let queued = await h.client.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(try persistedQueue(h.store).isEmpty)
        h.clock.advance(3600)
        let delivered = await h.client.flush()
        XCTAssertEqual(delivered, 0)
        let count = await h.transport.requests(to: "suggest").count
        XCTAssertEqual(count, failures.count, "a failed read is not retried")
        XCTAssertFalse(try persistedState(h.store).disabled)

        // Null optional fields decode as absent.
        let sam = #"{"creators":[{"id":"\#(Fixture.secondCreatorID)","name":"Sam Ortiz","handle":null}]}"#
        await h.transport.set("suggest", .ok(Data(sam.utf8)))
        let creators = await h.client.suggestCreators("sa")
        XCTAssertEqual(creators, [CreatorSummary(id: Fixture.secondCreatorID, name: "Sam Ortiz")])
    }

    func testHTTP403TripsTheKillSwitchAndHTTP401StopsTheSDK() async throws {
        let h = Harness()
        let off = #"{"error":{"code":"forbidden","message":"The SDK is disabled for this app"}}"#
        await h.transport.set("suggest", .status(403, Data(off.utf8)))
        var creators = await h.client.suggestCreators("sa")
        XCTAssertEqual(creators, [])
        XCTAssertTrue(try persistedState(h.store).disabled)
        await h.transport.set("suggest", nil)
        creators = await h.client.suggestCreators("sa")
        XCTAssertEqual(creators, [])
        var count = await h.transport.requests(to: "suggest").count
        XCTAssertEqual(count, 1, "a disabled SDK sends nothing")

        let other = Harness()
        let unknown = #"{"error":{"code":"unauthorized","message":"Unknown publishable key"}}"#
        await other.transport.set("suggest", .status(401, Data(unknown.utf8)))
        creators = await other.client.suggestCreators("sa")
        XCTAssertEqual(creators, [])
        await other.transport.set("suggest", nil)
        creators = await other.client.suggestCreators("sa")
        XCTAssertEqual(creators, [])
        let confirmed = await other.client.confirmCreator(Fixture.creatorID)
        XCTAssertFalse(confirmed)
        count = await other.transport.requests.count
        XCTAssertEqual(count, 1, "after a 401 nothing is sent")
    }

    /// SwiftUI's `.task(id:)` cancels the previous search when the text changes.
    func testACancelledSearchReturnsEmptyAndQueuesNothing() async throws {
        let h = Harness()
        await h.transport.set(delayNanoseconds: 30_000_000_000)
        let search = Task { await h.client.suggestCreators("sa") }
        search.cancel()
        let creators = await search.value
        XCTAssertEqual(creators, [])
        let queued = await h.client.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertFalse(try persistedState(h.store).disabled)
    }

    func testSuggestQueryNormalization() {
        XCTAssertEqual(ProoflineInput.suggestQuery("  @@Sarah Lee \n"), "Sarah Lee")
        XCTAssertEqual(ProoflineInput.suggestQuery("@ sam"), "sam")
        XCTAssertEqual(ProoflineInput.suggestQuery(""), "")
        XCTAssertEqual(ProoflineInput.suggestQuery("@"), "")
        XCTAssertEqual(ProoflineInput.suggestQuery("a@b"), "a@b")
        XCTAssertNil(ProoflineInput.suggestQuery(String(repeating: "é", count: 51)))
        XCTAssertNil(ProoflineInput.suggestQuery("nul\u{0}"))
    }
}
