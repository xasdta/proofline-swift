import Foundation
import XCTest
@testable import Proofline

// MARK: - Fixtures

enum Fixture {
    static let appKey = "pk_test_abc123"
    static let endUserID = "6f1c2a4e-8b3d-4f5a-9c7e-1d2b3a4c5e6f"
    static let otherEndUserID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    static let thirdEndUserID = "1e2d3c4b-5a69-4788-9a0b-c1d2e3f4a5b6"
    static let creatorID = "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    static let secondCreatorID = "2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f"
    static let clickID = "Ab3dE5gH7jK9"
    static let linkURL = URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!
    static let appleRedemption = "https://apps.apple.com/redeem?ctx=offercodes&id=1234567890&code=SARAH20"

    static let creator = CreatorSummary(id: creatorID, name: "Sarah Lee", handle: "sarahmoves",
                                        avatarUrl: "https://cdn.example.com/sarah.png")
    /// What the mock `/creators/suggest` answers by default, in ranking order.
    static let suggestions = [creator, CreatorSummary(id: secondCreatorID, name: "Sam Ortiz")]
    static let attribution = Attribution(creator: creator, programId: "pr_1", tier: .V, status: .attributed,
                                         offerLabel: "20% off your first 3 months", code: "SARAH20",
                                         redemptionUrl: appleRedemption, decidedAt: "2026-10-14T09:13:00.000Z")

    static func config(enabled: Bool = true, codeEntry: Bool = true, confirm: Bool = true,
                       batchSize: Int = 20, flushInterval: Int = 30) -> SdkConfig {
        SdkConfig(enabled: enabled, linkHosts: ["go.example.com"], appSlug: "fit", codeEntryEnabled: codeEntry,
                  confirmCreatorEnabled: confirm, batchSize: batchSize, flushIntervalSeconds: flushInterval)
    }

    static func json<T: Encodable>(_ value: T) -> Data {
        // Test fixtures are always encodable.
        try! JSONEncoder().encode(value)
    }
}

// MARK: - Mock transport

struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var endpoint: String { url.lastPathComponent }

    var query: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func decode<T: Decodable>(_: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: XCTUnwrap(body))
    }

    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
    }
}

enum MockReply: Sendable {
    case ok(Data)
    case status(Int, Data)
    case failure(URLError.Code)
}

/// In-memory fake of the SDK API. Routes by endpoint; every reply is configurable.
actor MockTransport: ProoflineTransport {
    private(set) var requests: [RecordedRequest] = []
    var sessionResponse = SessionResponse(endUserId: Fixture.endUserID, attribution: Fixture.attribution,
                                          config: Fixture.config())
    var identifyEndUserID = Fixture.endUserID
    var codeResponse = CodeResponse.accepted(creator: Fixture.creator, redemptionUrl: Fixture.appleRedemption,
                                             offerLabel: "20% off your first 3 months")
    var confirmResponse = ConfirmResponse(status: .accepted, attribution: Fixture.attribution)
    var attributionResponse = AttributionResponse(attribution: Fixture.attribution)
    var configResponse = Fixture.config()
    var suggestResponse = SuggestCreatorsResponse(creators: Fixture.suggestions)
    /// Overrides every endpoint when set.
    var override: MockReply?
    /// Per-endpoint override.
    var overrides: [String: MockReply] = [:]
    /// Artificial latency per request.
    var delayNanoseconds: UInt64 = 0
    /// Identify answers by `externalUserId`, each with its own latency (to reorder concurrent calls).
    var identifyByUser: [String: (endUserID: String, delayNanoseconds: UInt64)] = [:]

    func set(override: MockReply?) { self.override = override }
    func set(_ endpoint: String, _ reply: MockReply?) { overrides[endpoint] = reply }
    func set(sessionResponse: SessionResponse) { self.sessionResponse = sessionResponse }
    func set(identifyEndUserID: String) { self.identifyEndUserID = identifyEndUserID }
    func set(codeResponse: CodeResponse) { self.codeResponse = codeResponse }
    func set(confirmResponse: ConfirmResponse) { self.confirmResponse = confirmResponse }
    func set(attributionResponse: AttributionResponse) { self.attributionResponse = attributionResponse }
    func set(configResponse: SdkConfig) { self.configResponse = configResponse }
    func set(suggestResponse: SuggestCreatorsResponse) { self.suggestResponse = suggestResponse }
    func set(delayNanoseconds: UInt64) { self.delayNanoseconds = delayNanoseconds }
    func set(identifyFor userID: String, endUserID: String, delayNanoseconds: UInt64 = 0) {
        identifyByUser[userID] = (endUserID, delayNanoseconds)
    }
    func reset() { requests = [] }

    func requests(to endpoint: String) -> [RecordedRequest] { requests.filter { $0.endpoint == endpoint } }

    struct NoRequest: Error {}

    /// The first request (to `endpoint`, when given); throws when there is none.
    func firstRequest(to endpoint: String? = nil) throws -> RecordedRequest {
        guard let first = requests.first(where: { endpoint == nil || $0.endpoint == endpoint }) else {
            throw NoRequest()
        }
        return first
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let recorded = RecordedRequest(method: request.httpMethod ?? "GET", url: url,
                                       headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
        requests.append(recorded)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if override == nil, overrides[recorded.endpoint] == nil, recorded.endpoint == "identify",
           let user = try? recorded.decode(IdentifyRequest.self).externalUserId, let scripted = identifyByUser[user] {
            if scripted.delayNanoseconds > 0 { try await Task.sleep(nanoseconds: scripted.delayNanoseconds) }
            return (Fixture.json(IdentifyResponse(endUserId: scripted.endUserID)), Self.response(url, 200))
        }
        let reply = override ?? overrides[recorded.endpoint] ?? defaultReply(recorded.endpoint)
        switch reply {
        case let .ok(data):
            return (data, Self.response(url, 200))
        case let .status(code, data):
            return (data, Self.response(url, code))
        case let .failure(code):
            throw URLError(code)
        }
    }

    private func defaultReply(_ endpoint: String) -> MockReply {
        switch endpoint {
        case "session": .ok(Fixture.json(sessionResponse))
        case "identify": .ok(Fixture.json(IdentifyResponse(endUserId: identifyEndUserID)))
        case "code": .ok(Fixture.json(codeResponse))
        case "confirm": .ok(Fixture.json(confirmResponse))
        case "attribution": .ok(Fixture.json(attributionResponse))
        case "config": .ok(Fixture.json(configResponse))
        case "suggest": .ok(Fixture.json(suggestResponse))
        default: .status(404, Data(#"{"error":{"code":"not_found","message":"no route"}}"#.utf8))
        }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        // Valid arguments always produce a response.
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }
}

// MARK: - Clock, ids, opener, RevenueCat sink

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_792_000_000)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

final class SequentialUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1

    func make() -> UUID {
        lock.lock(); defer { lock.unlock() }
        defer { next += 1 }
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
    }
}

final class RecordingOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var opened: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    @MainActor
    func open(_ url: URL) async -> Bool {
        record(url)
        return true
    }

    private func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
    }
}

final class RecordingSink: RevenueCatAttributeSink, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [[String: String]] = []
    let rcAppUserID: String?

    init(appUserID: String? = nil) { rcAppUserID = appUserID }

    var written: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    func setAttributes(_ attributes: [String: String]) async {
        record(attributes)
    }

    private func record(_ attributes: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        writes.append(attributes)
    }

    func appUserID() async -> String? { rcAppUserID }
}

struct FixedAppTransactionID: AppTransactionIDProviding {
    let value: String?
    func appTransactionID() async -> String? { value }
}

// MARK: - Harness

/// One SDK client wired to fakes. Reuse `store` across harnesses to simulate a relaunch.
struct Harness {
    let transport: MockTransport
    let store: any PersistentStore
    let clock: TestClock
    let opener: RecordingOpener
    let sink: RecordingSink?
    let client: ProoflineClient

    init(transport: MockTransport = MockTransport(), store: any PersistentStore = MemoryStore(),
         clock: TestClock = TestClock(), sink: RecordingSink? = nil,
         appTransactionID: String? = nil, appGroupDirectory: URL? = nil, platform: Platform = .ios) {
        self.transport = transport
        self.store = store
        self.clock = clock
        let opener = RecordingOpener()
        self.opener = opener
        self.sink = sink
        let ids = SequentialUUIDs()
        let env = ClientEnvironment(
            api: APIClient(appKey: Fixture.appKey, baseURL: URL(string: "https://platform.test")!,
                           transport: transport, timeout: 5),
            store: store,
            opener: opener,
            now: { clock.now },
            makeUUID: { ids.make() },
            appGroupDirectory: { appGroupDirectory },
            appTransactionIDProvider: appTransactionID.map { FixedAppTransactionID(value: $0) },
            revenueCat: sink,
            platform: platform,
            appVersion: "2.3.1",
            sdkVersion: Proofline.sdkVersion,
            automaticFlush: false,
            log: ProoflineLog(enabled: false)
        )
        client = ProoflineClient(appKey: Fixture.appKey, environment: env)
    }

    /// A new client over the same store, transport and clock (an app relaunch).
    func relaunch(sink: RecordingSink? = nil) -> Harness {
        Harness(transport: transport, store: store, clock: clock, sink: sink ?? self.sink)
    }
}

func temporaryDirectory(_ name: String = #function) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("proofline-tests", isDirectory: true)
        .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
}

func persistedState(_ store: any PersistentStore) throws -> PersistedState {
    try JSONDecoder().decode(PersistedState.self, from: XCTUnwrap(store.read(PersistedState.fileName)))
}

func persistedQueue(_ store: any PersistentStore) throws -> [QueuedEvent] {
    guard let data = try store.read(OfflineQueue.fileName) else { return [] }
    return try JSONDecoder().decode([QueuedEvent].self, from: data)
}

/// A store whose reads can fail like a data-protected file before the first unlock. Records writes.
final class FlakyStore: PersistentStore, @unchecked Sendable {
    struct ReadError: Error {}

    private let lock = NSLock()
    private let backing = MemoryStore()
    private var failingReads = 0
    private var failForever = false
    private var failingNames: Set<String> = []
    private var writeLog: [String] = []
    private var readLog: [String] = []

    /// Every read throws until `heal()`.
    func failAllReads() {
        lock.lock(); defer { lock.unlock() }
        failForever = true
    }

    /// The next `count` reads throw.
    func failNextReads(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        failingReads = count
    }

    /// Every read of `name` throws until `heal()`.
    func failReads(of name: String) {
        lock.lock(); defer { lock.unlock() }
        failingNames.insert(name)
    }

    func heal() {
        lock.lock(); defer { lock.unlock() }
        failForever = false
        failingReads = 0
        failingNames = []
    }

    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return writeLog
    }

    var reads: [String] {
        lock.lock(); defer { lock.unlock() }
        return readLog
    }

    /// Seeds a blob without counting it as an SDK write.
    func seed(_ data: Data, as name: String) throws { try backing.write(data, to: name) }

    func read(_ name: String) throws -> Data? {
        lock.lock()
        readLog.append(name)
        let fail = failForever || failingReads > 0 || failingNames.contains(name)
        if failingReads > 0 { failingReads -= 1 }
        lock.unlock()
        if fail { throw ReadError() }
        return backing.read(name)
    }

    func write(_ data: Data, to name: String) throws {
        lock.lock()
        writeLog.append(name)
        lock.unlock()
        try backing.write(data, to: name)
    }

    func remove(_ name: String) { backing.remove(name) }
}
