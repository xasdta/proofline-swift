import Foundation
import XCTest
@testable import Proofline

final class ProoflineTests: XCTestCase {
    private let attribution = Attribution(
        creator: CreatorSummary(id: "cr_1", name: "Sarah Lee", handle: "sarahmoves"),
        programId: "pr_1", tier: .V, status: .attributed, code: "SARAH20",
        decidedAt: "2026-10-14T09:13:00.000Z"
    )

    func testClickIDExtraction() {
        XCTAssertEqual(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9")!), "Ab3dE5gH7jK9")
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah")!))
        XCTAssertNil(ProoflineLinks.clickID(from: URL(string: "https://go.example.com/l/fit/sarah/c/short")!))
    }

    func testRevenueCatAttributesMatchSdkJs() {
        XCTAssertEqual(RevenueCatAttributes.attributes(for: attribution, endUserID: "eu_1"), [
            "proofline_end_user_id": "eu_1",
            "proofline_creator_id": "cr_1",
            "proofline_creator_handle": "sarahmoves",
            "proofline_program_id": "pr_1",
            "proofline_tier": "V",
            "proofline_code": "SARAH20",
        ])
        XCTAssertEqual(RevenueCatAttributes.attributes(for: nil, endUserID: nil), [:])
    }

    func testWireModelsUseCamelCaseJSON() throws {
        let json = try JSONEncoder().encode(attribution)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNotNil(obj["programId"])
        XCTAssertNotNil(obj["decidedAt"])
        let decoded = try JSONDecoder().decode(Attribution.self, from: json)
        XCTAssertEqual(decoded, attribution)
    }

    func testPublicCallsDoNotCrashBeforeConfigure() async {
        let attr = await Proofline.currentAttribution()
        XCTAssertNil(attr)
        let ok = await Proofline.confirmCreator("cr_1")
        XCTAssertFalse(ok)
        if case .error = await Proofline.submitCode("SARAH20") {} else { XCTFail("expected .error") }
        do {
            _ = try await Proofline.identify(userID: "u_1")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? ProoflineError, .notConfigured)
        }
    }
}
