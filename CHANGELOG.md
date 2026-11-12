# Changelog

All notable changes to the Proofline Swift SDK. The project follows [Semantic Versioning](https://semver.org).

## 0.1.0 (2026-11-12)

### Added

- `Proofline.configure(appKey:options:)`. It takes a publishable key (`pk_test_…`/`pk_live_…`), and `ProoflineOptions` lets you inject every dependency: transport, URL opener, storage directory, App Group, `appTransactionID` provider, RevenueCat bridge, automatic flush and request timeout.
- `Proofline.handle(_:)` for a URL or an `NSUserActivity` (universal links). It queues a session event that carries the click id, once per click id. Links handled before `configure` are buffered.
- `Proofline.identify(userID:revenueCatAppUserID:appTransactionID:)`. It returns the end-user UUID to pass as the StoreKit `appAccountToken`. Offline it returns the last known id and queues the call. It throws only `ProoflineError`. `Proofline.appAccountToken(...)` is the non-throwing variant.
- `Proofline.submitCode(_:pasted:openRedemption:)`. For Apple offer codes it opens Apple's redemption URL. When offline it returns `.queued`.
- `Proofline.suggestCreators(_:)` for a "Who sent you?" prompt. It returns up to five `CreatorSummary` values whose handle or name starts with the text the user typed (a leading `@` is ignored; `""` lists the top creators), ranked by aggregate data only; pass the chosen `id` to `confirmCreator(_:)`. It is a read, so it is never queued: it returns `[]` when nothing matches, when the app turned the prompt off (`confirmCreatorEnabled`), for a query over 50 characters, when the SDK is disabled, and on failure or cancellation.
- `Proofline.confirmCreator(_:)`, `currentAttribution()` (cached for 60 s, with an offline fallback), `remoteConfig()` and `flush()`.
- `Proofline.syncToRevenueCat` takes a closure, a `RevenueCatAttributeSink` or the sink set in the options. It writes the five creator-scoped `proofline_*` subscriber attributes, with `""` (`RevenueCatAttributes.clearValue`; RevenueCat: delete) for values the current attribution does not set, so a previous creator's code or handle is cleared. `proofline_end_user_id` is written once the end user is known and never cleared. The JavaScript SDK writes the same update.
- `Proofline.handleLink(_:)` for a URL or an `NSUserActivity`. It records the click like `handle(_:)` and returns a `ProoflineLink` (`clickID`, `deepLinkPath`): the in-app path the link carries in its `dl` query parameter, validated, for the app to route on. `ProoflineLinks.parse(_:)` is the pure parser.
- SwiftUI `ProoflineCodeEntryView`: a ready-made, unstyled code field with submit, progress and status states (`ProoflineCodeEntryState`), a `content` closure for custom layouts (`ProoflineCodeEntryConfiguration`), accessibility labels and a result announcement. All strings come from `ProoflineCodeEntryStrings`, localisable through a `Proofline.strings` table (English ships in the package's resources). `CodeEntryField` and `PasteCodeButton` take the same `strings:`.
- `confirmCreator(_:)` trims its argument and sends it only when it is a UUID in the server's form (RFC 9562, versions 1 to 8), as the JavaScript SDK does.
- App Clip handoff: `ProoflineAppClip.storeHandoff(from:appGroupIdentifier:)` in the clip, with `ProoflineOptions.appGroupIdentifier` or `Proofline.setAppClipClickID(_:)` in the app.
- SwiftUI `PasteCodeButton`, which uses `UIPasteControl` on iOS 16+ and falls back to a text field elsewhere, and `CodeEntryField`.
- A durable offline queue: JSON files in Application Support, atomic writes, idempotent `eventId`s, backoff `min(2^attempts × 5 s, 1 h)` over the failed attempts so far (5 s, 10 s, 20 s, … as in sdk-js), at most 200 events, 25 attempts and 30 days. A state file that exists but cannot be read (for example before the first unlock) is not treated as a first launch: the process uses a temporary install id, writes nothing, and switches to the stored identity once the file can be read.
- Remote kill switch. It is triggered by `config.enabled == false` or an HTTP 403 with Proofline's error body (a bare 403, such as a CDN or firewall page, is retried). The SDK then stops sending, drops its queue and re-checks `/config` every 5 minutes. A 401 stops the SDK for the rest of the process.
- A privacy manifest: no tracking and no tracking domains. Purchase history, user ID and product interaction are declared as linked and not used for tracking. The SDK uses no required-reason APIs.
