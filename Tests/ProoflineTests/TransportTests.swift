import Foundation
import XCTest
@testable import Proofline

final class APIClientTests: XCTestCase {
    private func client(_ transport: MockTransport, base: String = "https://platform.test") -> APIClient {
        APIClient(appKey: Fixture.appKey, baseURL: URL(string: base)!, transport: transport, timeout: 7)
    }

    private let session = SessionRequest(eventId: "e", installId: "i", endUserId: nil, platform: .ios, sdkVersion: "1",
                                         appVersion: nil, openedAt: "t", firstLaunch: true, installReferrer: nil,
                                         appClipClickId: nil, linkClickId: nil,
                                         linkUrl: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9",
                                         appTransactionId: nil)

    func testPostBuildsTheContractRequest() async throws {
        let transport = MockTransport()
        _ = try await client(transport).session(session)
        let req = try await transport.firstRequest()
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.absoluteString, "https://platform.test/api/sdk/v1/session")
        XCTAssertEqual(req.headers["X-Proofline-Key"], Fixture.appKey)
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertEqual(req.headers["Accept"], "application/json")
        XCTAssertEqual(try req.decode(SessionRequest.self), session)
        let raw = String(decoding: try XCTUnwrap(req.body), as: UTF8.self)
        XCTAssertTrue(raw.contains("https://go.example.com/l/"), "slashes are not escaped")
    }

    func testEveryEndpointPath() async throws {
        let transport = MockTransport()
        let api = client(transport, base: "https://example.com/proofline/")
        _ = try await api.session(session)
        _ = try await api.identify(IdentifyRequest(eventId: "e", installId: "i", externalUserId: nil,
                                                   revenueCatAppUserId: nil, appTransactionId: nil, platform: .ios))
        _ = try await api.code(CodeRequest(eventId: "e", installId: "i", endUserId: nil, code: "C", entry: .typed,
                                           platform: .ios))
        _ = try await api.confirm(ConfirmRequest(eventId: "e", installId: "i", endUserId: nil, creatorId: "c",
                                                 platform: .ios))
        _ = try await api.attribution(endUserID: "a b&c")
        _ = try await api.config()
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.path), [
            "/proofline/api/sdk/v1/session", "/proofline/api/sdk/v1/identify", "/proofline/api/sdk/v1/code",
            "/proofline/api/sdk/v1/confirm", "/proofline/api/sdk/v1/attribution", "/proofline/api/sdk/v1/config",
        ])
        XCTAssertEqual(requests.map(\.method), ["POST", "POST", "POST", "POST", "GET", "GET"])
        XCTAssertEqual(requests[4].query["endUserId"], "a b&c", "query values are percent-encoded")
        XCTAssertNil(requests[5].body)
        XCTAssertNil(requests[5].headers["Content-Type"])
    }

    func testTimeoutIsApplied() {
        let req = client(MockTransport()).request("config", method: "GET")
        XCTAssertEqual(req.timeoutInterval, 7)
        XCTAssertEqual(req.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testErrorMapping() async {
        let cases: [(MockReply, ProoflineError)] = [
            (.status(401, Data()), .invalidAppKey),
            (.status(403, Data(#"{"error":{"code":"sdk_disabled","message":"off"}}"#.utf8)), .disabled),
            // No Proofline error body: a CDN or firewall answered, not the kill switch.
            (.status(403, Data("<html>Forbidden</html>".utf8)), .api(status: 403, code: "http_403", message: "HTTP 403")),
            (.status(422, Data(#"{"error":{"code":"invalid_input","message":"bad code"}}"#.utf8)),
             .api(status: 422, code: "invalid_input", message: "bad code")),
            (.status(500, Data("<html>".utf8)), .api(status: 500, code: "http_500", message: "HTTP 500")),
            (.failure(.notConnectedToInternet), .network("URLError \(URLError.Code.notConnectedToInternet.rawValue)")),
            (.ok(Data("not json".utf8)), .invalidResponse("config response did not match the contract")),
        ]
        for (reply, expected) in cases {
            let transport = MockTransport()
            await transport.set(override: reply)
            do {
                _ = try await client(transport).config()
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testDeliveryFailureClassification() {
        XCTAssertEqual(DeliveryFailure(.network("x")), .retry)
        XCTAssertEqual(DeliveryFailure(.api(status: 500, code: "", message: "")), .retry)
        XCTAssertEqual(DeliveryFailure(.api(status: 502, code: "", message: "")), .retry)
        XCTAssertEqual(DeliveryFailure(.api(status: 429, code: "", message: "")), .retry)
        XCTAssertEqual(DeliveryFailure(.api(status: 408, code: "", message: "")), .retry)
        XCTAssertEqual(DeliveryFailure(.api(status: 425, code: "", message: "")), .retry)
        XCTAssertEqual(DeliveryFailure(.api(status: 403, code: "http_403", message: "HTTP 403")), .retry)
        XCTAssertEqual(DeliveryFailure(.disabled), .disabled)
        XCTAssertEqual(DeliveryFailure(.api(status: 400, code: "", message: "")), .drop)
        XCTAssertEqual(DeliveryFailure(.api(status: 404, code: "", message: "")), .drop)
        XCTAssertEqual(DeliveryFailure(.api(status: 409, code: "", message: "")), .drop)
        XCTAssertEqual(DeliveryFailure(.invalidAppKey), .invalidKey)
        XCTAssertEqual(DeliveryFailure(.disabled), .disabled)
        XCTAssertEqual(DeliveryFailure(.invalidResponse("x")), .drop)
        XCTAssertEqual(DeliveryFailure(.invalidInput("x")), .drop)
    }
}

/// Serves canned responses to a real `URLSession` (no network).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Captured] = []
    nonisolated(unsafe) private static var reply: (Int, Data) = (200, Data())

    static func setReply(_ status: Int, _ body: Data) {
        lock.lock(); defer { lock.unlock() }
        reply = (status, body)
        captured = []
    }

    static var requests: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(Captured(url: request.url, method: request.httpMethod,
                                      headers: request.allHTTPHeaderFields ?? [:]))
        let (status, body) = Self.reply
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
    func testRealURLSessionRoundTrip() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.setReply(200, Fixture.json(Fixture.config()))
        let api = APIClient(appKey: Fixture.appKey, baseURL: URL(string: "https://platform.test")!,
                            transport: URLSessionTransport(session: URLSession(configuration: config)), timeout: 5)
        let received = try await api.config()
        XCTAssertEqual(received, Fixture.config())
        let captured = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(captured.url?.absoluteString, "https://platform.test/api/sdk/v1/config")
        XCTAssertEqual(captured.headers["X-Proofline-Key"], Fixture.appKey)

        StubURLProtocol.setReply(503, Data())
        do {
            _ = try await api.config()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error, .api(status: 503, code: "http_503", message: "HTTP 503"))
        }
    }

    func testDefaultSessionIsEphemeralWithoutCookiesOrCache() {
        let session = URLSessionTransport.makeDefaultSession()
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertFalse(session.configuration.waitsForConnectivity)
    }
}
