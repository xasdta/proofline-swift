# Proofline Swift SDK

Creator attribution for iOS subscription apps. The SDK supports iOS 15+ (macOS 12+ for tests), is written in Swift 6 with strict concurrency, and has no third-party dependencies. Public calls never crash the host app. `identify` is the only call that throws, and every other call returns a documented fallback.

```swift
import Proofline

// At launch, with the publishable key from the app's Setup page.
Proofline.configure(appKey: "pk_live_…")

// Universal links: .onOpenURL { Proofline.handle($0) } or .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Proofline.handle($0) }
Proofline.handle(url)
// ...or, to also learn where the link wants the user to land (see "Deep links"):
let link = Proofline.handleLink(url)                     // link?.deepLinkPath == "/workouts/42"

// Purchases: pass the Proofline end-user id as appAccountToken
let token = try await Proofline.identify(userID: "u_123")
_ = try await product.purchase(options: [.appAccountToken(token)])

// Paywall code field (opens Apple's redemption sheet for offer codes)
await Proofline.submitCode("SARAH20")
ProoflineCodeEntryView(onResult: { result in /* update the paywall */ })   // ready-made field, see "Code entry"
PasteCodeButton { result in /* update the paywall */ }                     // one-tap paste, no permission prompt

// Paywall copy
let attribution = await Proofline.currentAttribution()   // creator name, avatar, offer label

// "Who sent you?" prompt, when there is no attribution yet
let creators = await Proofline.suggestCreators(text)     // up to 5 matches for what the user typed
await Proofline.confirmCreator(picked.id)                // the creator they tapped (a creator UUID)

// RevenueCat, without a RevenueCat dependency
await Proofline.syncToRevenueCat { Purchases.shared.attribution.setAttributes($0) }  // "" values clear stale attributes
```

## Install

Swift Package Manager. In Xcode: File → Add Package Dependencies…, then enter `https://github.com/xasdta/proofline-swift`. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/xasdta/proofline-swift", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "Proofline", package: "proofline-swift")]),
]
```

The package has no dependencies.

## Deep links

A Proofline link can carry an in-app path, set on the link in the dashboard (for example `/workouts/42`). When the link opens the installed app, the platform appends it to the universal link as the `dl` query parameter. `Proofline.handleLink(_:)` records the click exactly as `handle(_:)` does and returns the parsed link:

```swift
ContentView()
    .onOpenURL { url in
        if let path = Proofline.handleLink(url)?.deepLinkPath {
            router.open(path)   // your own routing
        }
    }
```

- `ProoflineLink` has `clickID: String` and `deepLinkPath: String?`. `handleLink` returns nil when the URL is not a Proofline click link. There is an `NSUserActivity` overload for `.onContinueUserActivity` and the app delegate.
- Call one of `handle(_:)` and `handleLink(_:)` per URL. Both record a click id once.
- `handleLink` still returns the link while the remote kill switch is on (nothing is recorded then), so routing keeps working.
- `ProoflineLinks.parse(_:)` is the same parser without any recording.
- `deepLinkPath` comes from the URL, and anyone can craft a URL, so treat it as untrusted input: match it against the routes your app knows and never load it as a web URL. The SDK only returns a value that starts with exactly one `/`, is at most 512 UTF-16 code units long and has no control characters or backslashes; anything else gives `nil` (the click still counts).
- The path is only known when the link opened the app. After an install from the App Store (a deferred open) the app is launched without the link, and the SDK's `/session` answer does not carry the path, so `deepLinkPath` is not available there.

## Code entry

`ProoflineCodeEntryView` is a ready-made code field: a text field, a submit button, a progress indicator while the code is checked, and a status line for success, "code not found", expired, used up, withdrawn, offline and failure. It submits through `Proofline.submitCode`, the same path as `CodeEntryField` and `PasteCodeButton`, so Apple offer codes open Apple's redemption sheet. It never reads the clipboard.

```swift
ProoflineCodeEntryView(onResult: { result in
    if case .accepted = result { showPaywallOffer() }
})
.textFieldStyle(.roundedBorder)
.buttonStyle(.borderedProminent)
```

The default content sets no font, colour, text-field style or button style, so the modifiers you put on the view (`.font`, `.tint`, `.textFieldStyle`, `.buttonStyle`, `.foregroundStyle`) style it. For a different layout, pass a `content` closure. It receives a `ProoflineCodeEntryConfiguration`: the `code` binding, `state`, the `message` for that state, `canSubmit`, `isSubmitting`, the `strings`, and `submit()`:

```swift
ProoflineCodeEntryView(onResult: { _ in }) { entry in
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
```

`ProoflineCodeEntryState` is `.idle`, `.submitting`, `.success(creator:offerLabel:)`, `.notFound`, `.expired`, `.exhausted`, `.revoked`, `.offline` or `.failed`. `.offline` means the entry is queued and sent when the connection is back, so the user does not need to retry. The state returns to `.idle` when the user edits the code after a result. `onResult` receives the full `CodeResult` (including the redemption URL).

**Accessibility.** The field has an accessibility label that stays when the placeholder is gone, the progress indicator is labelled, and the result message is posted as an accessibility announcement (a status line that merely appears is not read out). Pass `announcesResult: false` if you announce it yourself.

**Localisation.** Every string comes from `ProoflineCodeEntryStrings`. Its defaults are looked up in this order: a `Proofline.strings` table in your app's main bundle, the table shipped in the package (`Sources/Proofline/Resources/en.lproj/Proofline.strings`, English), then the same English text compiled into the SDK. To add a language, copy that file into your app as `<language>.lproj/Proofline.strings` and translate the values; keep the `{creator}` and `{offer}` tokens. You can also set strings in code:

```swift
var strings = ProoflineCodeEntryStrings()
strings.placeholder = "Referral code"
strings.success = "Thanks! {creator} gets the credit."
let field = ProoflineCodeEntryView(strings: strings)
```

`CodeEntryField` and `PasteCodeButton` take the same `strings:` argument. `PasteCodeButton` is the only view that reads the clipboard, and only after the user taps the system paste control.

## Options

`ProoflineOptions` takes the following settings:

- `baseURL`: the Proofline platform the SDK talks to. The default, `Proofline.defaultBaseURL`
  (`https://app.proofline.link`), is the hosted platform; set it only when you run your own platform.
- `debug`: logs through `os.Logger`. It never logs keys or ids.
- `platform` and `appVersion`
- `transport`, `urlOpener` and `storageDirectory`, for tests or custom stacks
- `appGroupIdentifier`, for the App Clip handoff
- `appTransactionIDProvider`: pass `StoreKitAppTransactionIDProvider()` to send `AppTransaction.appTransactionID`, which needs iOS 18.4+
- `revenueCat`: a `RevenueCatAttributeSink`
- `automaticFlush` and `requestTimeout`

## Behaviour

- **Offline queue.** Session, identify, code and confirm events are written to Application Support with atomic JSON writes. They are retried with backoff `min(2^attempts × 5 s, 1 h)` (first retry after 5 s, dropped after 25 attempts) and keep the same `eventId`, so the server can deduplicate them. Each pass sends at most `config.batchSize` events. The queue holds at most 200 events (the oldest are dropped first), the same cap as the JavaScript SDK.
- **Creator ids.** `confirmCreator(_:)` trims its argument and sends it only when it is a UUID in the form the server accepts (RFC 9562, versions 1 to 8); anything else returns `false` without a request. The JavaScript SDK applies the same rule.
- **RevenueCat attributes.** `syncToRevenueCat` writes the five creator-scoped attributes (`proofline_creator_id`, `proofline_creator_handle`, `proofline_program_id`, `proofline_tier`, `proofline_code`) and uses `""` (`RevenueCatAttributes.clearValue`) for the ones the current attribution does not set; RevenueCat deletes an attribute set to an empty string. `proofline_end_user_id` is written once the end user is known and is never cleared. The JavaScript SDK writes the same update.
- **Kill switch.** The SDK disables itself when `config.enabled` is false or the server answers 403 with its `{ error: { code, message } }` body. It then stops sending, drops its queue and re-checks `/config` every 5 minutes. A 403 without that body (a CDN or firewall page) is retried with backoff instead.
- **"Who sent you?" suggestions.** `suggestCreators(_:)` lists active creators in the app's active programs whose handle or name starts with the query, ranked by attributed users and link clicks over the last 30 days. Nothing about the asking user is used, and only `id`, `name`, `handle` and `avatarUrl` come back. It is a read: never queued or retried, and `[]` when nothing matches, the prompt is off (App settings → Creator confirmation prompt), the query is over 50 characters, or the request fails or is cancelled. Requests count towards the SDK rate limit (120 per minute per install), so debounce typing.
- **Privacy.** There is no IDFA and no fingerprinting. `installId` is a random UUID, declared as a Device ID (linked, not tracking) in `Sources/Proofline/Resources/PrivacyInfo.xcprivacy`. The clipboard is read only by `PasteCodeButton`, after the user taps the system paste control. The App Review guide in the docs has the matching App Store Connect answers.

## Development

```sh
swift build && swift test
xcodebuild test -scheme Proofline -destination 'platform=iOS Simulator,name=iPhone 17'
```

`ModelsContractTests` parses `packages/sdk-js/src/types.ts`, so the Codable models and the TypeScript wire types cannot drift apart. `ReadmeSamplesTests` compiles the code samples of this README. Releasing is described in `RELEASING.md`.
