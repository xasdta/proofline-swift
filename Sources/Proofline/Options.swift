import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif

/// Settings for `Proofline.configure(appKey:options:)`. Every dependency is injectable so the SDK
/// can be tested without a network, a UI or StoreKit.
public struct ProoflineOptions: Sendable {
    /// Platform base URL; default `https://app.proofline.link`.
    public var baseURL: URL
    /// Log diagnostics through `os.Logger` (subsystem `dev.proofline.sdk`). Never logs keys or ids.
    public var debug: Bool
    /// Sent as `platform`. Defaults to `.ios` on iOS, iPadOS, Mac Catalyst and visionOS, `.unknown` elsewhere.
    public var platform: Platform
    /// Sent as `appVersion`; defaults to `CFBundleShortVersionString`.
    public var appVersion: String?
    /// HTTP transport; defaults to an ephemeral `URLSession`.
    public var transport: (any ProoflineTransport)?
    /// Opens Apple's offer-code redemption URL; defaults to `UIApplication.open` / `NSWorkspace.open`.
    public var urlOpener: (any URLOpening)?
    /// Directory for the offline queue and SDK state. Defaults to
    /// `Application Support/<bundle id>/dev.proofline.sdk/<test|live>/`.
    public var storageDirectory: URL?
    /// App Group shared with your App Clip; the click id the clip stored with
    /// `ProoflineAppClip.storeHandoff(from:appGroupIdentifier:)` is sent with the first session.
    public var appGroupIdentifier: String?
    /// Supplies Apple's `appTransactionID` for the session and identify calls. Off by default; pass
    /// `StoreKitAppTransactionIDProvider()` to opt in.
    public var appTransactionIDProvider: (any AppTransactionIDProviding)?
    /// RevenueCat bridge used by `Proofline.syncToRevenueCat()` and to send the RevenueCat app user id
    /// with `identify`.
    public var revenueCat: (any RevenueCatAttributeSink)?
    /// Flush the offline queue every `SdkConfig.flushIntervalSeconds`. Default true.
    public var automaticFlush: Bool
    /// Per-request timeout in seconds. Default 10.
    public var requestTimeout: TimeInterval

    public init(
        baseURL: URL = Proofline.defaultBaseURL,
        debug: Bool = false,
        platform: Platform = ProoflineOptions.defaultPlatform,
        appVersion: String? = ProoflineOptions.bundleShortVersion,
        transport: (any ProoflineTransport)? = nil,
        urlOpener: (any URLOpening)? = nil,
        storageDirectory: URL? = nil,
        appGroupIdentifier: String? = nil,
        appTransactionIDProvider: (any AppTransactionIDProviding)? = nil,
        revenueCat: (any RevenueCatAttributeSink)? = nil,
        automaticFlush: Bool = true,
        requestTimeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.debug = debug
        self.platform = platform
        self.appVersion = appVersion
        self.transport = transport
        self.urlOpener = urlOpener
        self.storageDirectory = storageDirectory
        self.appGroupIdentifier = appGroupIdentifier
        self.appTransactionIDProvider = appTransactionIDProvider
        self.revenueCat = revenueCat
        self.automaticFlush = automaticFlush
        self.requestTimeout = requestTimeout
    }

    public static var defaultPlatform: Platform {
        #if os(iOS) || os(visionOS)
        return .ios
        #else
        return .unknown
        #endif
    }

    public static var bundleShortVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

// MARK: - Injected protocols

/// Opens a URL outside the app (Apple's offer-code redemption sheet).
public protocol URLOpening: Sendable {
    @MainActor func open(_ url: URL) async -> Bool
}

/// Default opener: `UIApplication.shared.open` on iOS, `NSWorkspace.shared.open` on macOS.
public struct SystemURLOpener: URLOpening {
    public init() {}

    @MainActor
    public func open(_ url: URL) async -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        guard let app = Self.sharedApplication() else { return false }
        return await app.open(url)
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// `UIApplication.shared` looked up at runtime: the property is unavailable when the package is
    /// linked into an app extension, which would otherwise fail the host's build. Nil in extensions.
    @MainActor
    static func sharedApplication() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }
    #endif
}

/// Bridge to RevenueCat without depending on it:
///
/// ```swift
/// struct RC: RevenueCatAttributeSink {
///     func setAttributes(_ a: [String: String]) async { Purchases.shared.attribution.setAttributes(a) }
///     func appUserID() async -> String? { Purchases.shared.appUserID }
/// }
/// ```
public protocol RevenueCatAttributeSink: Sendable {
    /// Receives the five creator-scoped `proofline_*` keys, plus `proofline_end_user_id` once the end
    /// user is known. An empty-string value means "clear this attribute" (RevenueCat deletes an
    /// attribute set to `""`), so pass the dictionary to RevenueCat as is.
    func setAttributes(_ attributes: [String: String]) async
    /// RevenueCat app user id, sent with `identify` as `revenueCatAppUserId`. Default nil.
    func appUserID() async -> String?
}

public extension RevenueCatAttributeSink {
    func appUserID() async -> String? { nil }
}

/// Supplies Apple's `AppTransaction.appTransactionID`.
public protocol AppTransactionIDProviding: Sendable {
    func appTransactionID() async -> String?
}

/// Reads `AppTransaction.shared.appTransactionID` (iOS 18.4+ / macOS 15.4+; nil earlier or when the
/// transaction cannot be verified).
public struct StoreKitAppTransactionIDProvider: AppTransactionIDProviding {
    public init() {}

    public func appTransactionID() async -> String? {
        #if canImport(StoreKit)
        if #available(iOS 18.4, macOS 15.4, tvOS 18.4, watchOS 11.4, visionOS 2.4, *) {
            // UNVERIFIED(S4): stability of appTransactionId across reinstalls is not device-validated.
            guard let result = try? await AppTransaction.shared,
                  case let .verified(transaction) = result
            else { return nil }
            return transaction.appTransactionID
        }
        #endif
        return nil
    }
}
