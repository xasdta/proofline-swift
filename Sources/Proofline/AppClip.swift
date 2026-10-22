import Foundation

/// App Clip → full app handoff through a shared App Group container.
///
/// In the App Clip, with the invocation URL (`https://<link host>/l/<app>/<link>/c/<clickId>`):
/// ```swift
/// ProoflineAppClip.storeHandoff(from: url, appGroupIdentifier: "group.com.example.shared")
/// ```
/// In the full app, pass the same `appGroupIdentifier` in `ProoflineOptions`; the first session
/// carries the click id as `appClipClickId` and the handoff file is then deleted.
public enum ProoflineAppClip {
    // UNVERIFIED(S8): App Group handoff from an App Clip on a custom domain is not device-validated.
    static let fileName = "dev.proofline.appclip-handoff.json"

    struct Handoff: Codable, Equatable {
        var clickId: String
        /// ISO 8601, written by the clip.
        var storedAt: String
    }

    /// Stores the click id from an App Clip invocation URL. Returns false when the URL carries no
    /// click id or the App Group container is unavailable. Never throws.
    @discardableResult
    public static func storeHandoff(from url: URL, appGroupIdentifier: String) -> Bool {
        guard let dir = containerDirectory(appGroupIdentifier) else { return false }
        return storeHandoff(from: url, in: dir, now: Date())
    }

    static func storeHandoff(from url: URL, in directory: URL, now: Date) -> Bool {
        guard let clickID = ProoflineLinks.clickID(from: url),
              let data = try? JSONEncoder().encode(Handoff(clickId: clickID, storedAt: ISOTime.string(now)))
        else { return false }
        return (try? FileStore(directory: directory).write(data, to: fileName)) != nil
    }

    /// The stored click id, if any and well-formed.
    static func readHandoff(in directory: URL) -> String? {
        guard let data = try? FileStore(directory: directory).read(fileName),
              let handoff = try? JSONDecoder().decode(Handoff.self, from: data),
              ProoflineLinks.isClickID(handoff.clickId)
        else { return nil }
        return handoff.clickId
    }

    static func clearHandoff(in directory: URL) {
        FileStore(directory: directory).remove(fileName)
    }

    static func containerDirectory(_ appGroupIdentifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
