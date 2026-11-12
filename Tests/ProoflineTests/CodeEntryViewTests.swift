import Foundation
import XCTest
@testable import Proofline
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

final class CodeEntryStateAndStringsTests: XCTestCase {
    func testEveryCodeResultMapsToOneState() {
        let cases: [(CodeResult, ProoflineCodeEntryState)] = [
            (.accepted(creator: Fixture.creator, redemptionURL: URL(string: "https://apps.apple.com/redeem"), offerLabel: "20% off"),
             .success(creator: Fixture.creator, offerLabel: "20% off")),
            (.accepted(creator: Fixture.creator, redemptionURL: nil, offerLabel: nil),
             .success(creator: Fixture.creator, offerLabel: nil)),
            (.unknownCode, .notFound),
            (.expired, .expired),
            (.exhausted, .exhausted),
            (.revoked, .revoked),
            (.queued(message: "queued"), .offline),
            (.error(message: "Proofline is not configured"), .failed),
        ]
        for (result, state) in cases { XCTAssertEqual(ProoflineCodeEntryState(result), state) }
    }

    func testMessagesForEveryState() {
        let strings = ProoflineCodeEntryStrings.english
        XCTAssertNil(strings.message(for: .idle))
        XCTAssertEqual(strings.message(for: .submitting), "Applying code")
        XCTAssertEqual(strings.message(for: .success(creator: Fixture.creator, offerLabel: nil)), "Code applied: Sarah Lee")
        XCTAssertEqual(strings.message(for: .success(creator: Fixture.creator, offerLabel: "")), "Code applied: Sarah Lee")
        XCTAssertEqual(strings.message(for: .success(creator: Fixture.creator, offerLabel: "20% off")), "20% off from Sarah Lee")
        XCTAssertEqual(strings.message(for: .notFound), "That code wasn't recognised")
        XCTAssertEqual(strings.message(for: .expired), "That code has expired")
        XCTAssertEqual(strings.message(for: .exhausted), "That code has reached its limit")
        XCTAssertEqual(strings.message(for: .revoked), "That code is no longer valid")
        XCTAssertEqual(strings.message(for: .offline), "You're offline. The code will be applied when you're back online.")
        XCTAssertEqual(strings.message(for: .failed), "Couldn't apply the code. Try again.")
    }

    func testStringsCanBeReplacedAndTokensAreFilledOnce() {
        var strings = ProoflineCodeEntryStrings.english
        strings.success = "Danke! Code von {creator} aktiv"
        strings.successWithOffer = "{creator}: {offer} ({creator})"
        strings.notFound = "Code nicht gefunden"
        XCTAssertEqual(strings.message(for: .success(creator: Fixture.creator, offerLabel: nil)),
                       "Danke! Code von Sarah Lee aktiv")
        XCTAssertEqual(strings.message(for: .success(creator: Fixture.creator, offerLabel: "20%")),
                       "Sarah Lee: 20% (Sarah Lee)")
        XCTAssertEqual(strings.message(for: .notFound), "Code nicht gefunden")

        // Values are never scanned for tokens again, and odd templates do not trap.
        let tricky = CreatorSummary(id: "c", name: "{offer}")
        XCTAssertEqual(strings.message(for: .success(creator: tricky, offerLabel: "{creator}%@")),
                       "{offer}: {creator}%@ ({offer})")
        XCTAssertEqual(ProoflineCodeEntryStrings.fill("100% {creator} %@ %d {unknown} { {creator", ["creator": "S"]),
                       "100% S %@ %d {unknown} { {creator")
        XCTAssertEqual(ProoflineCodeEntryStrings.fill("", [:]), "")
        XCTAssertEqual(ProoflineCodeEntryStrings.fill("{", ["": "x"]), "{")
        XCTAssertEqual(ProoflineCodeEntryStrings.fill("{}{a}}", ["": "x", "a": "y"]), "xy}")
    }

    func testEnglishDefaultsMatchTheShippedStringsFile() throws {
        let url = PrivacyManifestTests.sourcesURL.appendingPathComponent("Resources/en.lproj/Proofline.strings")
        let shipped = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        let keys = ProoflineLocalization.Key.allCases
        XCTAssertEqual(Set(shipped.keys), Set(keys.map(\.rawValue)), "every key is in the file and in the code")
        for key in keys { XCTAssertEqual(shipped[key.rawValue], key.english, key.rawValue) }
    }

    func testThePackageBundleIsFoundWithoutTheTrappingAccessor() throws {
        let bundle = try XCTUnwrap(ProoflineLocalization.packageBundle, "Proofline_Proofline.bundle not found")
        XCTAssertEqual(bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath(),
                       Bundle.module.bundleURL.standardizedFileURL.resolvingSymlinksInPath())
        for key in ProoflineLocalization.Key.allCases {
            XCTAssertEqual(bundle.localizedString(forKey: key.rawValue, value: "missing", table: ProoflineLocalization.table),
                           key.english, key.rawValue)
        }
        // The privacy manifest ships in the same bundle.
        XCTAssertNotNil(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }

    func testLocalisedDefaultsFallBackToEnglish() {
        // The test host has no "Proofline" table, so the defaults are the package's English strings.
        XCTAssertEqual(ProoflineCodeEntryStrings(), .english)
        // No bundle has the key: the text compiled into the SDK.
        XCTAssertEqual(ProoflineLocalization.string(.submit, in: []), "Apply")
        XCTAssertEqual(ProoflineLocalization.string(.offline, in: [Bundle(for: Self.self)]),
                       ProoflineLocalization.Key.offline.english)
    }

    func testAHostTableOverridesThePackageStrings() throws {
        // A bundle laid out like an app that ships its own `Proofline.strings`.
        let root = temporaryDirectory().appendingPathComponent("Host.bundle")
        let lproj = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try #""code_entry.submit" = "Redeem";"#.write(to: lproj.appendingPathComponent("Proofline.strings"),
                                                      atomically: true, encoding: .utf8)
        let host = try XCTUnwrap(Bundle(url: root))
        let package = try XCTUnwrap(ProoflineLocalization.packageBundle)
        XCTAssertEqual(ProoflineLocalization.string(.submit, in: [host, package]), "Redeem")
        XCTAssertEqual(ProoflineLocalization.string(.expired, in: [host, package]), "That code has expired",
                       "keys the host does not translate come from the package")
    }
}

#if canImport(SwiftUI)
@MainActor
final class ProoflineCodeEntryViewTests: XCTestCase {
    private let accepted = CodeResult.accepted(creator: Fixture.creator, redemptionURL: nil, offerLabel: nil)

    func testStateFollowsASubmission() async {
        let spy = SubmitterSpy(result: accepted, delayNanoseconds: 50_000_000)
        let model = CodeEntryModel(submitter: spy.submitter, clearsResultOnEdit: true) { _ in }
        XCTAssertEqual(model.state, .idle)
        model.text = "SARAH20"
        async let done: Void = model.submitTyped()
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(model.state, .submitting)
        XCTAssertNil(model.statusMessage, "the progress indicator stands for the submission")
        await done
        XCTAssertEqual(model.state, .success(creator: Fixture.creator, offerLabel: nil))
        XCTAssertEqual(model.statusMessage, "Code applied: Sarah Lee")
        XCTAssertEqual(spy.submissions.map(\.code), ["SARAH20"])
    }

    func testEditingAfterAResultGoesBackToIdle() async {
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .unknownCode).submitter,
                                   clearsResultOnEdit: true) { _ in }
        model.text = "SARAH2"
        await model.submitTyped()
        XCTAssertEqual(model.state, .notFound)
        model.text = "SARAH2"
        XCTAssertEqual(model.state, .notFound, "writing the same text back is not an edit")
        model.text = "SARAH20"
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.statusMessage)
        XCTAssertTrue(model.canSubmit)
    }

    func testTheOlderViewsKeepTheirResultWhileEditing() async {
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .unknownCode).submitter) { _ in }
        model.text = "SARAH2"
        await model.submitTyped()
        model.text = "SARAH20"
        XCTAssertEqual(model.state, .notFound)
    }

    func testAPastedCodeKeepsItsResult() async {
        // `submitPasted` fills the field before it submits; that must not clear the new result.
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .expired).submitter,
                                   clearsResultOnEdit: true) { _ in }
        await model.submitPasted("SARAH20")
        XCTAssertEqual(model.text, "SARAH20")
        XCTAssertEqual(model.state, .expired)
    }

    func testCustomStringsReachTheStatusLineAndTheAnnouncement() async {
        var strings = ProoflineCodeEntryStrings.english
        strings.offline = "Sin conexion. Se aplicara mas tarde."
        var announced: [String] = []
        let model = CodeEntryModel(submitter: SubmitterSpy(result: .queued(message: "x")).submitter, strings: strings,
                                   announcer: { announced.append($0) }) { _ in }
        await model.submit("CODE", pasted: false)
        XCTAssertEqual(model.state, .offline)
        XCTAssertEqual(model.statusMessage, "Sin conexion. Se aplicara mas tarde.")
        XCTAssertEqual(announced, ["Sin conexion. Se aplicara mas tarde."])
    }

    func testConfigurationSubmitsOnlyWhenItCan() {
        var submitted = 0
        let source = CodeEntryModel(submitter: SubmitterSpy(result: accepted).submitter) { _ in }
        source.text = "SARAH20"
        let binding = ObservedObject(wrappedValue: source).projectedValue.text
        let ready = ProoflineCodeEntryConfiguration(code: binding, state: .idle, strings: .english, canSubmit: true,
                                                    action: { submitted += 1 })
        ready.submit()
        XCTAssertEqual(submitted, 1)
        XCTAssertNil(ready.message)
        XCTAssertFalse(ready.isSubmitting)

        let busy = ProoflineCodeEntryConfiguration(code: binding, state: .submitting, strings: .english,
                                                   canSubmit: false, action: { submitted += 1 })
        busy.submit()
        XCTAssertEqual(submitted, 1, "a second tap or a keyboard submit while in flight sends nothing")
        XCTAssertTrue(busy.isSubmitting)
        XCTAssertEqual(busy.message, "Applying code")

        let failed = ProoflineCodeEntryConfiguration(code: binding, state: .notFound, strings: .english,
                                                     canSubmit: true, action: {})
        XCTAssertEqual(failed.message, "That code wasn't recognised")
        failed.code.wrappedValue = "OTHER"
        XCTAssertEqual(source.text, "OTHER")
    }

    func testTheViewSubmitsThroughTheSameClientPathAsTheOtherViews() async {
        // `ProoflineCodeEntryView.init` builds its model with `CodeEntryModel.defaultSubmitter`,
        // which is `Proofline.submitCode` (typed entry).
        Proofline.install(nil)
        let unconfigured = await CodeEntryModel.defaultSubmitter("SARAH20", false)
        XCTAssertEqual(unconfigured, .error(message: "Proofline is not configured"))

        let h = Harness()
        Proofline.install(h.client)
        defer { Proofline.install(nil) }
        let model = CodeEntryModel(submitter: CodeEntryModel.defaultSubmitter, clearsResultOnEdit: true) { _ in }
        model.text = " sarah20 "
        await model.submitTyped()
        guard case .success = model.state else { return XCTFail("expected success, got \(model.state)") }
        let request = try? await h.transport.firstRequest(to: "code").decode(CodeRequest.self)
        XCTAssertEqual(request?.code, "sarah20")
        XCTAssertEqual(request?.entry, .typed)
    }

    #if canImport(AppKit)
    func testViewsRenderOnMacOS() async {
        let finished = CodeEntryModel(submitter: SubmitterSpy(result: .unknownCode).submitter,
                                      clearsResultOnEdit: true) { _ in }
        await finished.submit("CODE", pasted: false)
        let views: [AnyView] = [
            AnyView(ProoflineCodeEntryView()),
            AnyView(ProoflineCodeEntryView(strings: .english, announcesResult: false, onResult: { _ in })),
            AnyView(ProoflineCodeEntryView(model: finished)),
            AnyView(ProoflineCodeEntryView(onResult: { _ in }) { configuration in
                VStack {
                    TextField(configuration.strings.placeholder, text: configuration.code)
                    Button(configuration.strings.submit) { configuration.submit() }
                        .disabled(!configuration.canSubmit)
                    if let message = configuration.message { Text(message) }
                }
            }),
            AnyView(ProoflineCodeEntryView()
                .textFieldStyle(.roundedBorder)
                .buttonStyle(.borderedProminent)
                .font(.title)),
            AnyView(CodeEntryField(strings: .english)),
            AnyView(PasteCodeButton(strings: .english)),
        ]
        for view in views {
            let host = NSHostingView(rootView: view.frame(width: 320))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }
    #endif
}
#endif
