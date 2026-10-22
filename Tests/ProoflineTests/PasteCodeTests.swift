#if canImport(SwiftUI)
import Foundation
import SwiftUI
import XCTest
@testable import Proofline
#if canImport(AppKit)
import AppKit
#endif
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// Records submissions; optionally holds them until released.
final class SubmitterSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, Bool)] = []
    let result: CodeResult
    let delayNanoseconds: UInt64

    init(result: CodeResult, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    var submissions: [(code: String, pasted: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return calls.map { (code: $0.0, pasted: $0.1) }
    }

    var submitter: CodeSubmitter {
        { code, pasted in
            self.record(code, pasted)
            if self.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: self.delayNanoseconds) }
            return self.result
        }
    }

    private func record(_ code: String, _ pasted: Bool) {
        lock.lock(); defer { lock.unlock() }
        calls.append((code, pasted))
    }
}

@MainActor
final class CodeEntryModelTests: XCTestCase {
    private let accepted = CodeResult.accepted(creator: Fixture.creator, redemptionURL: nil,
                                               offerLabel: "20% off your first 3 months")

    func testTypedCodeIsNormalizedAndSubmittedAsTyped() async {
        let spy = SubmitterSpy(result: accepted)
        var results: [CodeResult] = []
        let model = CodeEntryModel(submitter: spy.submitter) { results.append($0) }
        model.text = "  SARAH20 "
        XCTAssertTrue(model.canSubmit)
        await model.submitTyped()
        XCTAssertEqual(spy.submissions.map(\.code), ["SARAH20"])
        XCTAssertEqual(spy.submissions.map(\.pasted), [false])
        XCTAssertEqual(results, [accepted])
        XCTAssertEqual(model.phase, .finished(accepted))
        XCTAssertEqual(model.statusMessage, "20% off your first 3 months from Sarah Lee")
    }

    func testPastedTextUsesTheFirstLineAndFillsTheField() async {
        let spy = SubmitterSpy(result: .unknownCode)
        let model = CodeEntryModel(submitter: spy.submitter) { _ in }
        await model.submitPasted("\n  SARAH20  \nshared from a story")
        XCTAssertEqual(model.text, "SARAH20")
        XCTAssertEqual(spy.submissions.map(\.code), ["SARAH20"])
        XCTAssertEqual(spy.submissions.map(\.pasted), [true])
        XCTAssertEqual(model.statusMessage, "That code wasn't recognised")
    }

    func testInvalidInputIsRejectedLocally() async {
        let spy = SubmitterSpy(result: accepted)
        var results: [CodeResult] = []
        let model = CodeEntryModel(submitter: spy.submitter) { results.append($0) }
        model.text = "   "
        XCTAssertFalse(model.canSubmit)
        await model.submitTyped()
        await model.submitPasted(String(repeating: "X", count: 65))
        XCTAssertTrue(spy.submissions.isEmpty)
        XCTAssertEqual(results.count, 2)
        guard case .error = results[0] else { return XCTFail("expected .error") }
        XCTAssertEqual(model.statusMessage, "Couldn't apply the code. Try again.")
    }

    func testDoubleTapSendsOneRequest() async {
        let spy = SubmitterSpy(result: accepted, delayNanoseconds: 50_000_000)
        let model = CodeEntryModel(submitter: spy.submitter) { _ in }
        model.text = "SARAH20"
        async let first: Void = model.submitTyped()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(model.isSubmitting)
        XCTAssertFalse(model.canSubmit)
        let second = await model.submit("SARAH20", pasted: false)
        XCTAssertNil(second, "ignored while in flight")
        await first
        XCTAssertEqual(spy.submissions.count, 1)
        XCTAssertFalse(model.isSubmitting)
    }

    func testStatusMessagesForEveryResult() async {
        let cases: [(CodeResult, String)] = [
            (.accepted(creator: Fixture.creator, redemptionURL: nil, offerLabel: nil), "Code applied: Sarah Lee"),
            (.unknownCode, "That code wasn't recognised"),
            (.expired, "That code has expired"),
            (.exhausted, "That code has reached its limit"),
            (.revoked, "That code is no longer valid"),
            (.queued(message: "x"), "You're offline. The code will be applied when you're back online."),
            (.error(message: "x"), "Couldn't apply the code. Try again."),
        ]
        for (result, message) in cases {
            let spy = SubmitterSpy(result: result)
            let model = CodeEntryModel(submitter: spy.submitter) { _ in }
            XCTAssertNil(model.statusMessage)
            await model.submit("CODE", pasted: false)
            XCTAssertEqual(model.statusMessage, message)
        }
    }

    func testQueuedStatusDoesNotAskTheUserToRetry() async {
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .queued(message: "x")).submitter) { _ in }
        await model.submit("CODE", pasted: false)
        let message = try? XCTUnwrap(model.statusMessage)
        XCTAssertFalse(message?.localizedCaseInsensitiveContains("try again") ?? true,
                       "a queued code is sent automatically; retrying would queue a duplicate")
    }

    func testResultIsAnnouncedToVoiceOver() async {
        var announced: [String] = []
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .expired).submitter,
                                   announcer: { announced.append($0) }) { _ in }
        await model.submit("CODE", pasted: false)
        XCTAssertEqual(announced, ["That code has expired"])
        // Local validation errors are announced too.
        await model.submit("   ", pasted: false)
        XCTAssertEqual(announced, ["That code has expired", "Couldn't apply the code. Try again."])
    }

    func testNoAnnouncementWhenTheHostHidesTheStatus() async {
        var announced: [String] = []
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .expired).submitter, announcesResult: false,
                                   announcer: { announced.append($0) }) { _ in }
        await model.submit("CODE", pasted: false)
        XCTAssertTrue(announced.isEmpty)
        XCTAssertEqual(model.statusMessage, "That code has expired")
    }

    func testSystemAnnouncerIsSafeWithoutAWindow() {
        CodeEntryModel.postAccessibilityAnnouncement("Code applied")
    }

    func testDefaultSubmitterGoesThroughTheFacade() async {
        Proofline.install(nil)
        let result = await CodeEntryModel.defaultSubmitter("SARAH20", false)
        XCTAssertEqual(result, .error(message: "Proofline is not configured"))
    }

    #if canImport(AppKit)
    func testViewsRenderOnMacOS() {
        let spy = SubmitterSpy(result: .expired)
        let views: [AnyView] = [
            AnyView(PasteCodeButton()),
            AnyView(CodeEntryField(placeholder: "Code", showsStatus: false)),
            AnyView(PasteCodeButton(model: CodeEntryModel(submitter: spy.submitter) { _ in })),
            AnyView(CodeEntryField(model: CodeEntryModel(submitter: spy.submitter) { _ in })),
        ]
        for view in views {
            let host = NSHostingView(rootView: view.frame(width: 320))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }
    #endif

    #if os(iOS)
    func testPasteTargetAcceptsPlainTextAndForwardsIt() async throws {
        guard #available(iOS 16.0, *) else { return }
        let view = PasteTargetView(frame: .zero)
        let received = expectation(description: "pasted")
        var pasted: [String] = []
        view.onPaste = { text in
            pasted.append(text)
            received.fulfill()
        }
        let identifiers = view.pasteConfiguration?.acceptableTypeIdentifiers ?? []
        XCTAssertTrue(identifiers.contains(UTType.plainText.identifier))
        XCTAssertTrue(view.control.target === view)
        let text = NSItemProvider(object: "SARAH20" as NSString)
        XCTAssertTrue(view.canPaste([text]))
        XCTAssertFalse(view.canPaste([NSItemProvider()]))
        view.paste(itemProviders: [NSItemProvider(), text])
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(pasted, ["SARAH20"])
        XCTAssertGreaterThan(view.intrinsicContentSize.width, 0)
    }

    func testSharedApplicationLookupIsSafe() {
        // The xctest runner may or may not host a UIApplication; either answer must not crash.
        let app = SystemURLOpener.sharedApplication()
        if let app { XCTAssertTrue(app === UIApplication.shared) }
    }

    func testPasteCodeButtonHasATappableSizeOnIOS() {
        let host = UIHostingController(rootView: PasteCodeButton(showsStatus: false))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertGreaterThanOrEqual(size.height, 44)
        XCTAssertGreaterThanOrEqual(size.width, 44)
        let field = UIHostingController(rootView: CodeEntryField())
        XCTAssertGreaterThan(field.sizeThatFits(in: CGSize(width: 320, height: 1000)).height, 0)
    }
    #endif
}
#endif
