# Proofline Swift SDK

Creator attribution for iOS subscription apps. The SDK supports iOS 15+ (macOS 12+ for tests), is written in Swift 6 with strict concurrency, and has no third-party dependencies. Public calls never crash the host app. `identify` is the only call that throws, and every other call returns a documented fallback.

```swift
import Proofline

// At launch
Proofline.configure(appKey: "pk_live_…")

// Universal links: .onOpenURL { Proofline.handle($0) } or .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Proofline.handle($0) }
Proofline.handle(url)

// Purchases: pass the Proofline end-user id as appAccountToken
let token = try await Proofline.identify(userID: "u_123")
_ = try await product.purchase(options: [.appAccountToken(token)])

// Paywall code field (opens Apple's redemption sheet for offer codes)
await Proofline.submitCode("SARAH20")
PasteCodeButton { result in /* update the paywall */ }

// Paywall copy
let attribution = await Proofline.currentAttribution()   // creator name, avatar, offer label

// RevenueCat, without a RevenueCat dependency
await Proofline.syncToRevenueCat { Purchases.shared.attribution.setAttributes($0) }  // "" values clear stale attributes
```

## Options

`ProoflineOptions` takes the following settings:

- `baseURL`
- `debug`: logs through `os.Logger`. It never logs keys or ids.
- `platform` and `appVersion`
- `transport`, `urlOpener` and `storageDirectory`, for tests or custom stacks
- `appGroupIdentifier`, for the App Clip handoff
- `appTransactionIDProvider`: pass `StoreKitAppTransactionIDProvider()` to send `AppTransaction.appTransactionID`, which needs iOS 18.4+
- `revenueCat`: a `RevenueCatAttributeSink`
- `automaticFlush` and `requestTimeout`

## Behaviour

- **Offline queue.** Session, identify, code and confirm events are written to Application Support with atomic JSON writes. They are retried with backoff `min(2^attempts × 5 s, 1 h)` (first retry after 5 s, dropped after 25 attempts) and keep the same `eventId`, so the server can deduplicate them. Each pass sends at most `config.batchSize` events.
- **Kill switch.** The SDK disables itself when `config.enabled` is false or the server answers 403. It then stops sending, drops its queue and re-checks `/config` every 5 minutes.
- **Privacy.** There is no IDFA and no fingerprinting. `installId` is a random UUID. See `Sources/Proofline/Resources/PrivacyInfo.xcprivacy`.

## Development

```sh
swift build && swift test
xcodebuild test -scheme Proofline -destination 'platform=iOS Simulator,name=iPhone 17'
```

`ModelsContractTests` parses `packages/sdk-js/src/types.ts`, so the Codable models and the TypeScript wire types cannot drift apart.
