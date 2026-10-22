import Foundation

/// Small named blobs persisted by the SDK (state and offline queue). Writes must be atomic.
protocol PersistentStore: Sendable {
    /// The blob, or nil when it does not exist. Throws when it may exist but cannot be read (an I/O
    /// error, or iOS data protection before the first unlock after a reboot), so the caller can tell
    /// a fresh install from an unreadable one.
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, to name: String) throws
    func remove(_ name: String)
}

/// Files in a directory the SDK owns. Each write goes to a temporary file that replaces the target
/// atomically, so a crash mid-write never leaves a torn file. The SDK reads and writes contents only;
/// it never reads file timestamps or disk space (no required-reason APIs).
struct FileStore: PersistentStore {
    let directory: URL

    /// No I/O here; the directory is created on first write.
    init(directory: URL) { self.directory = directory }

    func read(_ name: String) throws -> Data? {
        do {
            return try Data(contentsOf: fileURL(name))
        } catch {
            if Self.isFileNotFound(error) { return nil }
            throw error
        }
    }

    /// Only "no such file" means missing; every other failure (permissions, data protection, I/O)
    /// is reported as an error.
    static func isFileNotFound(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isFileNotFound(underlying)
        }
        return false
    }

    func write(_ data: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(visionOS)
        // Background flushes must work after the first unlock.
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: fileURL(name), options: options)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(name))
    }

    private func fileURL(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: false) }

    /// `Application Support/<bundle id>/dev.proofline.sdk/<test|live>/`. The bundle id keeps
    /// non-sandboxed macOS apps apart; test and live keys never share an install id or queue.
    static func defaultDirectory(appKey: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let env = appKey.hasPrefix("pk_live_") ? "live" : "test"
        var dir = base
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            dir = dir.appendingPathComponent(bundleID, isDirectory: true)
        }
        return dir.appendingPathComponent("dev.proofline.sdk", isDirectory: true)
            .appendingPathComponent(env, isDirectory: true)
    }
}

/// Non-persistent fallback when no directory is usable (and for tests).
final class MemoryStore: PersistentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    init() {}

    func read(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return blobs[name]
    }

    func write(_ data: Data, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        blobs[name] = data
    }

    func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        blobs[name] = nil
    }
}

/// Everything the SDK remembers between launches (`state.v1.json`).
struct PersistedState: Codable, Equatable {
    /// Random UUID created on first launch. Not a device identifier.
    var installId: String
    var endUserId: String?
    /// True once a session event with `firstLaunch: true` has been queued.
    var sessionRecorded: Bool = false
    /// Last attribution the server returned (served when offline).
    var attribution: Attribution?
    /// Last config the server returned.
    var config: SdkConfig?
    /// Remote kill switch, remembered so a disabled SDK stays quiet across launches.
    var disabled: Bool = false
    /// Parameters of the last successful identify; a repeat call returns the cached id.
    var lastIdentifyKey: String?
    /// Recently handled click ids, so the same link opened twice (scene + URL callbacks) is sent once.
    var handledClickIds: [String] = []

    static let fileName = "state.v1.json"
    static let maxHandledClickIds = 50

    init(installId: String) { self.installId = installId }

    private enum CodingKeys: String, CodingKey {
        case installId, endUserId, sessionRecorded, attribution, config, disabled, lastIdentifyKey, handledClickIds
    }

    /// Tolerant decoding: fields added in later versions default instead of failing the whole file.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installId = try c.decode(String.self, forKey: .installId)
        endUserId = try c.decodeIfPresent(String.self, forKey: .endUserId)
        sessionRecorded = try c.decodeIfPresent(Bool.self, forKey: .sessionRecorded) ?? false
        attribution = try? c.decodeIfPresent(Attribution.self, forKey: .attribution)
        config = try? c.decodeIfPresent(SdkConfig.self, forKey: .config)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        lastIdentifyKey = try c.decodeIfPresent(String.self, forKey: .lastIdentifyKey)
        handledClickIds = try c.decodeIfPresent([String].self, forKey: .handledClickIds) ?? []
    }

    mutating func rememberClickID(_ id: String) {
        handledClickIds.removeAll { $0 == id }
        handledClickIds.append(id)
        if handledClickIds.count > Self.maxHandledClickIds {
            handledClickIds.removeFirst(handledClickIds.count - Self.maxHandledClickIds)
        }
    }
}

/// Durable FIFO of events awaiting delivery (`queue.v1.json`, a JSON array of `QueuedEvent`).
/// Pure value type: the client persists it after every change.
struct OfflineQueue: Equatable {
    static let fileName = "queue.v1.json"
    /// Oldest events are dropped beyond this many.
    static let capacity = 200
    /// An event is dropped after this many failed attempts (sdk-js `DEFAULT_MAX_ATTEMPTS`)...
    static let maxAttempts = 25
    /// ...or once it is this old.
    static let maxAge: TimeInterval = 30 * 24 * 3600
    /// Backoff `min(2^attempts * 5 s, 1 h)`, where `attempts` is the number of failed tries before
    /// this one — the same schedule as sdk-js `backoffMs(previous)`: 5 s, 10 s, 20 s, ...
    static let baseDelay: TimeInterval = 5
    static let maxDelay: TimeInterval = 3600

    private(set) var events: [QueuedEvent] = []

    init(events: [QueuedEvent] = []) { self.events = events }

    var count: Int { events.count }
    var isEmpty: Bool { events.isEmpty }

    static func backoff(attempts: Int) -> TimeInterval {
        let exp = min(max(attempts, 0), 20)
        return min(baseDelay * pow(2, Double(exp)), maxDelay)
    }

    /// Adds an event; an event with the same id replaces nothing (idempotent enqueue).
    mutating func enqueue(_ body: QueuedEvent.Body, now: Date) {
        guard !events.contains(where: { $0.id == body.eventId }) else { return }
        let stamp = ISOTime.string(now)
        events.append(QueuedEvent(body: body, enqueuedAt: stamp, nextAttemptAt: stamp))
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }

    /// Appends existing events (keeping their attempts and schedule), skipping ids already queued.
    mutating func append(_ more: [QueuedEvent]) {
        for event in more where !events.contains(where: { $0.id == event.id }) { events.append(event) }
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }

    /// Events whose `nextAttemptAt` has passed, oldest first, at most `limit`.
    func due(now: Date, limit: Int) -> [QueuedEvent] {
        Array(events.filter { (ISOTime.date($0.nextAttemptAt) ?? .distantPast) <= now }.prefix(limit))
    }

    mutating func remove(id: String) { events.removeAll { $0.id == id } }

    /// Records a failed attempt and schedules the retry; drops the event when it is exhausted.
    mutating func recordFailure(id: String, now: Date) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        var e = events[i]
        let previous = e.attempts
        e.attempts = previous + 1
        if e.attempts >= Self.maxAttempts {
            events.remove(at: i)
            return
        }
        e.nextAttemptAt = ISOTime.string(now.addingTimeInterval(Self.backoff(attempts: previous)))
        events[i] = e
    }

    /// Drops events older than `maxAge`.
    mutating func pruneExpired(now: Date) {
        events.removeAll { e in
            guard let enqueued = ISOTime.date(e.enqueuedAt) else { return true }
            return now.timeIntervalSince(enqueued) > Self.maxAge
        }
    }

    mutating func removeAll() { events.removeAll() }
}
