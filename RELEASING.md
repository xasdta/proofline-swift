# Releasing the Proofline Swift SDK

Swift Package Manager installs a package from a git repository that has `Package.swift` at its root and a tag named like the version (`0.1.0`). The SDK lives in `sdks/swift` of the monorepo, so a release goes to a mirror repository that holds only this directory. `scripts/release-swift-sdk.sh` builds the mirror history with `git subtree split --prefix sdks/swift` and prints the commands that publish it. It pushes nothing unless you pass `--push`.

Nothing has been published yet: there is no mirror repository and no tag.

## Before the first release

1. **Licence: done.** The SDK is MIT licensed (`sdks/swift/LICENSE`, which ends up at the root of the mirror).
2. **Create the mirror repository**, empty (no README, no licence, no `.gitignore`: the first push must be the split history). For example `github.com/<owner>/proofline-swift`. Its name is the package name in consumers' `Package.swift`.
3. **Update the install snippet** in `README.md` ("Install") with the mirror's URL and name, and commit.

## Release steps

Run everything from the monorepo root, on the commit you want to release.

1. Set the version in two places and make them agree:
   - `Proofline.sdkVersion` in `sdks/swift/Sources/Proofline/Proofline.swift` (sent to the platform with every session)
   - the heading in `sdks/swift/CHANGELOG.md`: replace `(unreleased)` with the date, for example `## 0.1.0 (2026-11-20)`
2. Test:

   ```sh
   cd sdks/swift
   swift build && swift test
   xcodebuild test -scheme Proofline -destination 'platform=iOS Simulator,name=iPhone 17'
   ```

   The iOS run matters: `UIPasteControl` and the UIKit paths only compile and run there.

3. Commit. The script refuses to run with uncommitted or untracked files, because a release is cut from committed history only.
4. Build the mirror history (nothing is pushed):

   ```sh
   scripts/release-swift-sdk.sh 0.1.0 git@github.com:<owner>/proofline-swift.git
   ```

   It checks that the tree is clean, that the version equals `Proofline.sdkVersion`, and that the changelog has a dated section for it. Then it writes the split history to the local branch `swift-sdk-mirror` and prints three commands: create the tag, push the branch, push the tag.

5. Look at what would be published:

   ```sh
   git log --oneline -5 swift-sdk-mirror
   git ls-tree --name-only swift-sdk-mirror     # Package.swift, Sources, Tests, README.md, ...
   ```

6. Publish, either by running the three printed commands or by running the script again with `--push`:

   ```sh
   scripts/release-swift-sdk.sh 0.1.0 git@github.com:<owner>/proofline-swift.git --push
   ```

   The tag is created locally as `swift-sdk/0.1.0` (apart from the monorepo's own tags) and pushed to the mirror as `0.1.0`. A version that already exists on the mirror is never replaced; fix forward with a new version.

7. Check that it resolves: in a scratch Xcode project, File → Add Package Dependencies…, enter the mirror URL, pick "Up to Next Major" from `0.1.0`, `import Proofline`, build.
8. Open the next `(unreleased)` section in `CHANGELOG.md`.

`git subtree split` is deterministic: the same monorepo history gives the same mirror commits, so every later release fast-forwards the mirror. Never commit to the mirror directly; a commit made there is not in the monorepo and the next push would be rejected.

## What is in the mirror

Everything under `sdks/swift`: `Package.swift`, `Sources`, `Tests`, `README.md`, `CHANGELOG.md`, this file. The package resources are the privacy manifest (`Resources/PrivacyInfo.xcprivacy`) and the English strings (`Resources/en.lproj/Proofline.strings`); `Package.swift` declares `defaultLocalization: "en"` for them.

The tests that compare the SDK with the JavaScript SDK (`ModelsContractTests` and the "identical to sdk-js" tests) read `packages/sdk-js/src` from the monorepo. In the mirror those files do not exist, and the tests are skipped there; they run in the monorepo, which is where a release is tested.

## CocoaPods

There is no podspec: CocoaPods itself is in maintenance mode. Swift Package Manager is the supported way to install the SDK.

## Privacy checklist for every release

`PrivacyManifestTests` enforces the first three; check the last one by hand when a release adds a view or a request.

- No IDFA, no `identifierForVendor`, no App Tracking Transparency.
- No required-reason APIs (the manifest's `NSPrivacyAccessedAPITypes` is empty and the sources are scanned for them).
- The manifest declares no tracking and no tracking domains.
- The clipboard is read only by `PasteCodeButton`, after the user taps the system paste control. No other code may read it.
