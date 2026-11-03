import Foundation
import XCTest
@testable import Proofline

/// Proves the Codable models mirror `packages/sdk-js/src/types.ts` exactly: the same JSON keys and
/// the same optionality. Parses the TypeScript source, so a field added on either side fails here.
final class ModelsContractTests: XCTestCase {
    struct Field: Hashable {
        let name: String
        let optional: Bool
    }

    static let typesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ProoflineTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // swift
        .deletingLastPathComponent() // sdks
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("packages/sdk-js/src/types.ts")

    /// Top-level fields of `export interface <name> { … }` (two-space indented `name?: type;` lines).
    static func tsInterface(_ name: String) throws -> Set<Field> {
        let source = try String(contentsOf: typesURL, encoding: .utf8)
        guard let start = source.range(of: "export interface \(name) {") else {
            throw ParseFailure("interface \(name) not found in types.ts")
        }
        var fields = Set<Field>()
        for line in source[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("}") { break }
            guard line.hasPrefix("  "), !line.hasPrefix("   ") else { continue }
            let trimmed = line.dropFirst(2)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            var key = String(trimmed[..<colon])
            let optional = key.hasSuffix("?")
            if optional { key.removeLast() }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            fields.insert(Field(name: key, optional: optional))
        }
        return fields
    }

    struct ParseFailure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(obj.keys)
    }

    /// `full` sets every field; `minimal` only the required ones.
    func assertMirrors<T: Codable & Equatable>(_ interface: String, full: T, minimal: T,
                                               nullableRequired: Set<String> = [],
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let ts = try Self.tsInterface(interface)
        XCTAssertFalse(ts.isEmpty, "\(interface) parsed no fields", file: file, line: line)
        let all = Set(ts.map(\.name))
        let required = Set(ts.filter { !$0.optional }.map(\.name)).subtracting(nullableRequired)
        XCTAssertEqual(try Self.keys(full), all, "\(interface): keys differ from types.ts", file: file, line: line)
        XCTAssertEqual(try Self.keys(minimal), required, "\(interface): required keys differ", file: file, line: line)
        // Round trip.
        let decoded = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(decoded, full, file: file, line: line)
    }

    func testTypesFileIsPresent() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.typesURL.path), Self.typesURL.path)
    }

    func testCreatorSummaryAndAttribution() throws {
        try assertMirrors("CreatorSummary", full: Fixture.creator, minimal: CreatorSummary(id: "c", name: "n"))
        try assertMirrors("CurrentAttribution", full: Fixture.attribution,
                          minimal: Attribution(creator: CreatorSummary(id: "c", name: "n"), programId: "p",
                                               tier: .U, status: .provisional, decidedAt: "2026-01-01T00:00:00.000Z"))
    }

    func testSdkConfig() throws {
        try assertMirrors("SdkConfig", full: Fixture.config(), minimal: Fixture.config())
    }

    func testSessionRequestAndResponse() throws {
        let full = SessionRequest(eventId: "e", installId: "i", endUserId: "u", platform: .ios, sdkVersion: "1",
                                  appVersion: "2", openedAt: "t", firstLaunch: true, installReferrer: "r",
                                  appClipClickId: "a", linkClickId: "l", linkUrl: "https://x", appTransactionId: "x")
        let minimal = SessionRequest(eventId: "e", installId: "i", endUserId: nil, platform: .ios, sdkVersion: "1",
                                     appVersion: nil, openedAt: "t", firstLaunch: false, installReferrer: nil,
                                     appClipClickId: nil, linkClickId: nil, linkUrl: nil, appTransactionId: nil)
        try assertMirrors("SessionRequest", full: full, minimal: minimal)
        try assertMirrors("SessionResponse",
                          full: SessionResponse(endUserId: "u", attribution: Fixture.attribution, config: Fixture.config()),
                          minimal: SessionResponse(endUserId: "u", attribution: nil, config: Fixture.config()),
                          nullableRequired: ["attribution"])
    }

    func testIdentify() throws {
        try assertMirrors("IdentifyRequest",
                          full: IdentifyRequest(eventId: "e", installId: "i", externalUserId: "x",
                                                revenueCatAppUserId: "r", appTransactionId: "a", platform: .ios),
                          minimal: IdentifyRequest(eventId: "e", installId: "i", externalUserId: nil,
                                                   revenueCatAppUserId: nil, appTransactionId: nil, platform: .web))
        try assertMirrors("IdentifyResponse", full: IdentifyResponse(endUserId: "u"),
                          minimal: IdentifyResponse(endUserId: "u"))
    }

    func testCodeAndConfirm() throws {
        try assertMirrors("CodeRequest",
                          full: CodeRequest(eventId: "e", installId: "i", endUserId: "u", code: "C", entry: .pasted,
                                            platform: .ios),
                          minimal: CodeRequest(eventId: "e", installId: "i", endUserId: nil, code: "C", entry: .typed,
                                               platform: .ios))
        try assertMirrors("ConfirmRequest",
                          full: ConfirmRequest(eventId: "e", installId: "i", endUserId: "u", creatorId: "c", platform: .ios),
                          minimal: ConfirmRequest(eventId: "e", installId: "i", endUserId: nil, creatorId: "c",
                                                  platform: .ios))
        try assertMirrors("ConfirmResponse",
                          full: ConfirmResponse(status: .accepted, attribution: Fixture.attribution),
                          minimal: ConfirmResponse(status: .rejected, attribution: nil),
                          nullableRequired: ["attribution"])
        try assertMirrors("AttributionResponse",
                          full: AttributionResponse(attribution: Fixture.attribution),
                          minimal: AttributionResponse(attribution: nil),
                          nullableRequired: ["attribution"])
    }

    func testSuggestCreatorsResponse() throws {
        try assertMirrors("SuggestCreatorsResponse", full: SuggestCreatorsResponse(creators: Fixture.suggestions),
                          minimal: SuggestCreatorsResponse(creators: []))
    }

    func testQueuedEventMirrorsTheJSShape() throws {
        let body = SessionRequest(eventId: "e1", installId: "i", endUserId: nil, platform: .ios, sdkVersion: "1",
                                  appVersion: nil, openedAt: "t", firstLaunch: true, installReferrer: nil,
                                  appClipClickId: nil, linkClickId: nil, linkUrl: nil, appTransactionId: nil)
        let event = QueuedEvent(body: .session(body), enqueuedAt: "2026-10-21T00:00:00.000Z",
                                nextAttemptAt: "2026-10-21T00:00:00.000Z")
        try assertMirrors("QueuedEvent", full: event, minimal: event)
        XCTAssertEqual(event.id, "e1", "the queue id is the eventId (idempotency key)")
        let kinds: [QueuedEvent.Body] = [
            .session(body),
            .identify(IdentifyRequest(eventId: "e2", installId: "i", externalUserId: nil, revenueCatAppUserId: nil,
                                      appTransactionId: nil, platform: .ios)),
            .code(CodeRequest(eventId: "e3", installId: "i", endUserId: nil, code: "C", entry: .typed, platform: .ios)),
            .confirm(ConfirmRequest(eventId: "e4", installId: "i", endUserId: nil, creatorId: "c", platform: .ios)),
        ]
        for body in kinds {
            let e = QueuedEvent(body: body, enqueuedAt: "t", nextAttemptAt: "t")
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
            XCTAssertEqual(obj["kind"] as? String, body.kind.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(QueuedEvent.self, from: JSONEncoder().encode(e)), e)
        }
    }

    func testEnumsMatchTheTypeScriptUnions() throws {
        let source = try String(contentsOf: Self.typesURL, encoding: .utf8)
        XCTAssertTrue(source.contains("export type Tier = 'V' | 'D' | 'U';"))
        XCTAssertTrue(source.contains("export type Platform = 'ios' | 'android' | 'web' | 'unknown';"))
        XCTAssertTrue(source.contains("status: 'provisional' | 'attributed' | 'locked';"))
        XCTAssertTrue(source.contains("entry: 'typed' | 'pasted';"))
        XCTAssertTrue(source.contains("{ status: 'unknown_code' | 'expired' | 'exhausted' | 'revoked' }"))
        XCTAssertTrue(source.contains("export type QueuedEventKind = 'session' | 'identify' | 'code' | 'confirm';"))
        XCTAssertEqual(["V", "D", "U"].compactMap(Tier.init(rawValue:)).count, 3)
        XCTAssertEqual(["ios", "android", "web", "unknown"].compactMap(Platform.init(rawValue:)).count, 4)
        XCTAssertEqual(["unknown_code", "expired", "exhausted", "revoked"]
            .compactMap(CodeResponse.Rejection.init(rawValue:)).count, 4)
        XCTAssertEqual(["session", "identify", "code", "confirm"].compactMap(QueuedEventKind.init(rawValue:)).count, 4)
    }

    func testCodeResponseDecodesEveryVariant() throws {
        let accepted = #"{"status":"accepted","creator":{"id":"c","name":"Sarah"},"redemptionUrl":"https://apps.apple.com/redeem?ctx=offercodes&id=1&code=A","offerLabel":"20%"}"#
        XCTAssertEqual(try JSONDecoder().decode(CodeResponse.self, from: Data(accepted.utf8)),
                       .accepted(creator: CreatorSummary(id: "c", name: "Sarah"),
                                 redemptionUrl: "https://apps.apple.com/redeem?ctx=offercodes&id=1&code=A",
                                 offerLabel: "20%"))
        let bare = #"{"status":"accepted","creator":{"id":"c","name":"Sarah"}}"#
        XCTAssertEqual(try JSONDecoder().decode(CodeResponse.self, from: Data(bare.utf8)),
                       .accepted(creator: CreatorSummary(id: "c", name: "Sarah"), redemptionUrl: nil, offerLabel: nil))
        for status in ["unknown_code", "expired", "exhausted", "revoked"] {
            let decoded = try JSONDecoder().decode(CodeResponse.self, from: Data(#"{"status":"\#(status)"}"#.utf8))
            XCTAssertEqual(decoded, .rejected(try XCTUnwrap(CodeResponse.Rejection(rawValue: status))))
            // Encoding produces the same wire shape.
            XCTAssertEqual(try Self.keys(decoded), ["status"])
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CodeResponse.self, from: Data(#"{"status":"nope"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(CodeResponse.self, from: Data(#"{"status":"accepted"}"#.utf8)))
    }

    func testResponsesDecodeFromTheTypeScriptMinimalShapes() throws {
        let session = #"{"endUserId":"u","attribution":null,"config":{"enabled":true,"linkHosts":[],"appSlug":"a","codeEntryEnabled":true,"confirmCreatorEnabled":false,"batchSize":10,"flushIntervalSeconds":60}}"#
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: Data(session.utf8))
        XCTAssertNil(decoded.attribution)
        XCTAssertEqual(decoded.config.batchSize, 10)
        let error = #"{"error":{"code":"rate_limited","message":"slow down"}}"#
        XCTAssertEqual(try JSONDecoder().decode(ApiErrorBody.self, from: Data(error.utf8)).error.code, "rate_limited")
    }

    /// The server's `currentAttributionSchema` carries `redemptionUrl` (the code's store redemption
    /// link for this device); it was dropped on decode, so a paywall could not open it.
    func testAttributionKeepsTheServersRedemptionURL() throws {
        let body = #"{"attribution":{"creator":{"id":"c","name":"Sarah"},"programId":"p","tier":"D","status":"provisional","code":"SARAH20","redemptionUrl":"\#(Fixture.appleRedemption)","decidedAt":"2026-10-14T09:13:00.000Z"}}"#
        let attribution = try XCTUnwrap(try JSONDecoder().decode(AttributionResponse.self, from: Data(body.utf8)).attribution)
        XCTAssertEqual(attribution.redemptionUrl, Fixture.appleRedemption)
        XCTAssertEqual(attribution.redemptionURL, URL(string: Fixture.appleRedemption))
        XCTAssertTrue(ProoflineLinks.isAppleOfferCodeRedemption(try XCTUnwrap(attribution.redemptionURL)))
        let inApp = #"{"creator":{"id":"c","name":"Sarah"},"programId":"p","tier":"U","status":"provisional","code":"SARAH20","decidedAt":"2026-10-14T09:13:00.000Z"}"#
        XCTAssertNil(try JSONDecoder().decode(Attribution.self, from: Data(inApp.utf8)).redemptionURL)
    }

    func testCodeResultFromResponseParsesTheRedemptionURL() {
        XCTAssertEqual(CodeResult(.accepted(creator: Fixture.creator, redemptionUrl: Fixture.appleRedemption, offerLabel: nil)),
                       .accepted(creator: Fixture.creator, redemptionURL: URL(string: Fixture.appleRedemption), offerLabel: nil))
        XCTAssertTrue(CodeResult.accepted(creator: Fixture.creator, redemptionURL: nil, offerLabel: nil).isAccepted)
        XCTAssertFalse(CodeResult.expired.isAccepted)
    }

    func testConfigClampsServerValues() {
        XCTAssertEqual(Fixture.config(batchSize: 0).effectiveBatchSize, 1)
        XCTAssertEqual(Fixture.config(batchSize: 10_000).effectiveBatchSize, 100)
        XCTAssertEqual(Fixture.config(flushInterval: 0).effectiveFlushInterval, 5)
        XCTAssertEqual(Fixture.config(flushInterval: 999_999).effectiveFlushInterval, 3600)
        XCTAssertEqual(Fixture.config(flushInterval: 45).effectiveFlushInterval, 45)
    }
}
