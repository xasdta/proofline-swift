import Foundation
import XCTest
import Proofline
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

// The code samples of README.md, compiled against the public API only (no `@testable`), so a
// sample cannot drift from the source. Types the samples take from the host app or from RevenueCat
// are stubbed here. Nothing in this file talks to the network: the SDK is not configured.

/// Stands in for RevenueCat's `Purchases.shared.attribution.setAttributes(_:)`.
private final class Purchases: Sendable {
    static let shared = Purchases()
    let attribution = Attribution()
    final class Attribution: Sendable {
        func setAttributes(_ attributes: [String: String]) {}
    }
}

@MainActor
private final class Router {
    var opened: [String] = []
    func open(_ path: String) { opened.append(path) }
}

final class ReadmeSamplesTests: XCTestCase {
    /// README: the overview block. Every call returns its documented fallback while unconfigured.
    func testOverviewSample() async throws {
        let url = URL(string: "https://go.example.com/promo")!
        let text = "sa"

        Proofline.handle(url)
        let link = Proofline.handleLink(url)
        XCTAssertNil(link?.deepLinkPath)

        let token = try? await Proofline.identify(userID: "u_123")
        if !Proofline.isConfigured { XCTAssertNil(token) }

        await Proofline.submitCode("SARAH20")

        let attribution = await Proofline.currentAttribution()
        XCTAssertNil(attribution)

        let creators = await Proofline.suggestCreators(text)
        if let picked = creators.first {
            await Proofline.confirmCreator(picked.id)
        }

        await Proofline.syncToRevenueCat { Purchases.shared.attribution.setAttributes($0) }
    }

    #if canImport(StoreKit)
    /// README: `product.purchase(options: [.appAccountToken(token)])`. Compiled, never run.
    @available(iOS 15.0, macOS 12.0, *)
    func purchaseSample(product: Product) async throws {
        let token = try await Proofline.identify(userID: "u_123")
        _ = try await product.purchase(options: [.appAccountToken(token)])
    }
    #endif

    /// README: Options. The default base URL is the hosted platform.
    func testConfigureSamples() {
        XCTAssertEqual(Proofline.defaultBaseURL.absoluteString, "https://app.proofline.link")
        XCTAssertEqual(ProoflineOptions().baseURL, Proofline.defaultBaseURL)
        // Compiled, not run with a real key (a configured SDK would start a session request).
        let configure: @Sendable () -> Void = { Proofline.configure(appKey: "pk_live_…") }
        _ = configure
    }

    /// README: Deep links.
    func testDeepLinkSample() {
        let url = URL(string: "https://go.example.com/l/fit/sarah/c/Ab3dE5gH7jK9?dl=%2Fworkouts%2F42")!
        let parsed = ProoflineLinks.parse(url)
        XCTAssertEqual(parsed?.clickID, "Ab3dE5gH7jK9")
        XCTAssertEqual(parsed?.deepLinkPath, "/workouts/42")
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        let fromActivity: ProoflineLink? = Proofline.handleLink(activity)
        XCTAssertNil(fromActivity)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testSwiftUISamplesBuild() {
        let router = Router()
        func showPaywallOffer() {}

        // README overview.
        _ = ProoflineCodeEntryView(onResult: { result in _ = result /* update the paywall */ })
        _ = PasteCodeButton { result in _ = result /* update the paywall */ }

        // README: Deep links.
        _ = Text("ContentView")
            .onOpenURL { url in
                if let path = Proofline.handleLink(url)?.deepLinkPath {
                    router.open(path)   // your own routing
                }
            }

        // README: Code entry, default content.
        _ = ProoflineCodeEntryView(onResult: { result in
            if case .accepted = result { showPaywallOffer() }
        })
        .textFieldStyle(.roundedBorder)
        .buttonStyle(.borderedProminent)

        // README: Code entry, custom content.
        _ = ProoflineCodeEntryView(onResult: { _ in }) { entry in
            VStack(alignment: .leading) {
                TextField(entry.strings.placeholder, text: entry.code)
                    .accessibilityLabel(entry.strings.fieldLabel)
                    .onSubmit { entry.submit() }
                Button(entry.strings.submit) { entry.submit() }
                    .disabled(!entry.canSubmit)
                switch entry.state {
                case .submitting: ProgressView().accessibilityLabel(entry.strings.submitting)
                case .success: Label(entry.message ?? "", systemImage: "checkmark.circle")
                case .notFound, .expired, .exhausted, .revoked, .failed: Text(entry.message ?? "").foregroundStyle(.red)
                case .offline: Text(entry.message ?? "")
                case .idle: EmptyView()
                }
            }
        }

        // README: Code entry, strings in code.
        var strings = ProoflineCodeEntryStrings()
        strings.placeholder = "Referral code"
        strings.success = "Thanks! {creator} gets the credit."
        let field = ProoflineCodeEntryView(strings: strings)
        _ = field
        _ = CodeEntryField(strings: strings)
        _ = PasteCodeButton(strings: strings)
        XCTAssertEqual(strings.message(for: .success(creator: CreatorSummary(id: "c", name: "Sarah"), offerLabel: nil)),
                       "Thanks! Sarah gets the credit.")
    }
    #endif
}
