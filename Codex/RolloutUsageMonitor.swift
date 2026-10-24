import Foundation
import CoreServices
import SQLite3
import Darwin

struct PassiveUsageReading {
    let snapshot: UsageSnapshot
    let authentication: Data
}

/// Only the state database can associate a rollout with the current account and thread.
/// File events select work to read; they never establish ownership or freshness.
final class RolloutUsageReader {
    static let maximumAge: TimeInterval = 300
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64
        var pending = Data()
        var discarding = false
        var lastRead: Date
        var anchor = Data()
        var threadID: String
        var inheritedThrough: Date?
    }
    private let home: URL
    private let originalHomePath: String
    private static let quotaKey = Data("\"rate_limits\"".utf8)
    private let now: () -> Date
    private var authentication: Data?
    private var hasObservedAuthentication = false
    private var cursors: [String: Cursor] = [:]
    private var current: [String: String] = [:]
    private var threadIDs: [String: String] = [:]
    private var pendingPaths = Set<String>()
    private var recent: [String] = []
    private var databaseFingerprint: [String] = []
    private(set) var authenticationChanged = false
    private(set) var needsRegistrationRetry = false

    init(home: URL, now: @escaping () -> Date = Date.init) {
        originalHomePath = home.standardizedFileURL.path
        self.home = home.resolvingSymlinksInPath().standardizedFileURL; self.now = now
    }

    private func canonicalPath(_ raw: String) -> String {
        // Resolve the configured root once; never stat every historical rollout on a database update.
        let path = URL(fileURLWithPath: raw, isDirectory: false).standardizedFileURL.path
        if path.hasPrefix(originalHomePath + "/") { return home.path + path.dropFirst(originalHomePath.count) }
        return path
    }

    func read(changedPaths: [String] = []) -> [PassiveUsageReading] {
        authenticationChanged = false; needsRegistrationRetry = false
        do {
            let identity = try AppServerUsageProvider.authenticationIdentity(home: home)
            defer { hasObservedAuthentication = true }
            if authentication != identity {
                authenticationChanged = hasObservedAuthentication
                authentication = identity; cursors.removeAll(); current.removeAll(); databaseFingerprint = []
            }
            guard let identity, let account = try AppServerUsageProvider.authenticationAccountID(home: home) else { return [] }
            let indexChanged = try updateCurrentRollouts(account: account)
            cursors = cursors.filter { current[$0.key] != nil && threadIDs[$0.key] == $0.value.threadID }
            let changed = changedPaths.map(canonicalPath)
            pendingPaths.formUnion(changed.filter { $0.hasSuffix(".jsonl") && current[$0] == nil })
            if pendingPaths.count > 64 { pendingPaths = Set(pendingPaths.sorted().suffix(64)) }
            needsRegistrationRetry = !pendingPaths.isEmpty
            var paths = changedPaths.isEmpty || indexChanged ? Set(recent.prefix(24)).union(cursors.keys) : Set<String>()
            paths.formUnion(changed.filter { current[$0] != nil })
            paths.formUnion(pendingPaths.filter { current[$0] != nil })
            pendingPaths.subtract(paths)
            let directories = changed.filter { path in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            }
            let leaves = directories.filter { parent in !directories.contains { $0 != parent && $0.hasPrefix(parent + "/") } }
            if !leaves.isEmpty {
                let discovered = current.keys.filter { path in leaves.contains { path.hasPrefix($0 + "/") } }.compactMap { path -> (String, Date)? in
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                          attributes[.type] as? FileAttributeType == .typeRegular,
                          let date = attributes[.modificationDate] as? Date else { return nil }
                    return (path, date)
                }.sorted { $0.1 > $1.1 }.prefix(24)
                paths.formUnion(discovered.map { $0.0 })
            }
            var readings: [PassiveUsageReading] = []
            for path in paths where current[path] != nil {
                readings += read(path: path, account: account).map { PassiveUsageReading(snapshot: $0, authentication: identity) }
            }
            // Authentication is checked around both the database and rollout reads.
            guard try AppServerUsageProvider.authenticationIdentity(home: home) == identity,
                  try AppServerUsageProvider.authenticationAccountID(home: home) == account else {
                authenticationChanged = true; authentication = nil; cursors.removeAll(); current.removeAll(); databaseFingerprint = []
                return []
            }
            if try updateCurrentRollouts(account: account) {
                // Active threads also update unrelated database fields. Revalidate ownership
                // without discarding good quota events whenever the database changes.
                readings = readings.filter { reading in
                    let path = reading.snapshot.sourceFile
                    guard let cursor = cursors[path] else { return false }
                    return current[path] == account && threadIDs[path] == cursor.threadID
                }
                cursors = cursors.filter { current[$0.key] == account && threadIDs[$0.key] == $0.value.threadID }
                needsRegistrationRetry = true
            }
            if cursors.count > 64 {
                let keep = Set(cursors.sorted { $0.value.lastRead > $1.value.lastRead }.prefix(64).map(\.key))
                cursors = cursors.filter { keep.contains($0.key) }
            }
            return readings.sorted { $0.snapshot.capturedAt < $1.snapshot.capturedAt }
        } catch {
            // Missing/unsupported/busy local state never grants permission or causes an RPC.
            current.removeAll(); databaseFingerprint = []
            if (try? AppServerUsageProvider.authenticationIdentity(home: home)) != authentication {
                authenticationChanged = true; authentication = nil; cursors.removeAll()
            }
            return []
        }
    }

    private func updateCurrentRollouts(account: String) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        func fingerprint(_ url: URL) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return url.path }
            return "\(url.path):\(a[.systemFileNumber] ?? 0):\(a[.size] ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        let databases = files.filter { $0.lastPathComponent.range(of: #"^state(?:_[0-9]+)?\.sqlite$"#, options: .regularExpression) != nil }
        func modified(_ url: URL) -> Date {
            [url, URL(fileURLWithPath: url.path + "-wal")].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
            }.max() ?? .distantPast
        }
        guard let database = databases.sorted(by: { modified($0) == modified($1) ? $0.lastPathComponent > $1.lastPathComponent : modified($0) > modified($1) }).first else {
            current.removeAll(); recent = []; databaseFingerprint = []; return true
        }
        let fingerprint = [fingerprint(database), fingerprint(URL(fileURLWithPath: database.path + "-wal")), account]
        guard fingerprint != databaseFingerprint else { return false }
        let reader = try ReadOnlyDatabase(url: database, kind: "state")
        let statement = try reader.prepare("SELECT rollout_path, creator_account_id, id FROM threads ORDER BY updated_at DESC")
        defer { sqlite3_finalize(statement) }
        var paths: [String: String] = [:]
        var newest: [String] = []
        var ids: [String: String] = [:]
        while try reader.step(statement) == SQLITE_ROW {
            guard let rawPath = sqlite3_column_text(statement, 0), let rawOwner = sqlite3_column_text(statement, 1) else { continue }
            let path = canonicalPath(String(cString: rawPath))
            let owner = String(cString: rawOwner)
            guard let rawID = sqlite3_column_text(statement, 2) else { continue }
            let id = String(cString: rawID)
            // Duplicate/ambiguous registrations cannot establish ownership.
            if let previous = paths[path], previous != owner || ids[path] != id { paths[path] = "" }
            else { paths[path] = owner; ids[path] = id }
            if owner == account { newest.append(path) }
        }
        current = paths.filter { $0.value == account }; threadIDs = ids
        recent = newest.filter { current[$0] != nil }
        databaseFingerprint = fingerprint
        return true
    }

    private func read(path: String, account: String) -> [UsageSnapshot] {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { cursors.removeValue(forKey: path); return [] }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        let size = UInt64(max(0, info.st_size))
        let inode = UInt64(info.st_ino)
        var cursor = cursors[path]
        var replaced = cursor == nil || cursor?.inode != inode || size < cursor!.offset
        if let cursor, !replaced, !cursor.anchor.isEmpty {
            try? handle.seek(toOffset: cursor.offset - UInt64(cursor.anchor.count))
            replaced = (try? handle.read(upToCount: cursor.anchor.count)) != cursor.anchor
        }
        if replaced {
            try? handle.seek(toOffset: 0)
            guard let header = try? handle.read(upToCount: 64 * 1024), let end = header.firstIndex(of: 10),
                  let entry = try? JSONSerialization.jsonObject(with: header.prefix(upTo: end)) as? [String: Any],
                  entry["type"] as? String == "session_meta", let metadata = entry["payload"] as? [String: Any],
                  let thread = metadata["id"] as? String, thread == threadIDs[path],
                  let created = UsageDecoder.timestamp(entry["timestamp"] as? String) else { return [] }
            let inherited = Self.optionalValue(metadata, "forked_from_id") != nil || Self.optionalValue(metadata, "history_base") != nil ||
                (metadata["source"] as? [String: Any])?["subagent"] != nil
            let offset = size > 1024 * 1024 ? size - 1024 * 1024 : 0
            cursor = Cursor(inode: inode, offset: offset, discarding: offset > 0, lastRead: now(),
                threadID: thread, inheritedThrough: inherited ? created : nil)
        }
        guard var cursor else { return [] }
        try? handle.seek(toOffset: cursor.offset)
        var snapshots: [UsageSnapshot] = []
        while let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty {
            cursor.offset += UInt64(data.count); cursor.lastRead = now(); cursor.pending.append(data)
            while let end = cursor.pending.firstIndex(of: 10) {
                let line = cursor.pending.prefix(upTo: end)
                if !cursor.discarding, line.range(of: Self.quotaKey) != nil, let snapshot = Self.decode(line, account: account, source: path, now: now(), threadID: cursor.threadID, inheritedThrough: cursor.inheritedThrough) { snapshots.append(snapshot) }
                cursor.pending.removeSubrange(...end); cursor.discarding = false
            }
            if cursor.pending.count > 1024 * 1024 { cursor.pending.removeAll(); cursor.discarding = true }
        }
        try? handle.seek(toOffset: cursor.offset > 64 ? cursor.offset - 64 : 0)
        cursor.anchor = (try? handle.read(upToCount: Int(min(cursor.offset, 64)))) ?? Data()
        cursors[path] = cursor
        return snapshots
    }

    private static func optionalValue(_ object: [String: Any], _ key: String, _ alias: String? = nil) -> Any? {
        if let value = object[key], !(value is NSNull) { return value }
        if let alias, let value = object[alias], !(value is NSNull) { return value }
        return nil
    }

    static func decode(_ data: Data, account: String, source: String, now: Date, threadID: String? = nil, inheritedThrough: Date? = nil) -> UsageSnapshot? {
        guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              entry["type"] as? String == "event_msg", let payload = entry["payload"] as? [String: Any],
              payload["type"] as? String == "token_count", let limits = payload["rate_limits"] as? [String: Any],
              optionalValue(limits, "limit_id", "limitId") == nil || optionalValue(limits, "limit_id", "limitId") as? String == "codex",
              optionalValue(payload, "thread_id", "threadId") == nil || optionalValue(payload, "thread_id", "threadId") as? String == threadID,
              optionalValue(limits, "limit_name", "limitName") == nil ||
                (optionalValue(limits, "limit_name", "limitName") as? String)?.lowercased() == "codex",
              let captured = UsageDecoder.timestamp(entry["timestamp"] as? String),
              inheritedThrough.map({ captured > $0 }) ?? true,
              captured <= now, now.timeIntervalSince(captured) <= maximumAge else { return nil }
        let (five, weekly) = UsageDecoder.windows(limits)
        let windows = [five, weekly].compactMap { $0 }
        guard !windows.isEmpty, windows.allSatisfy({ $0.usedPercent <= 100 && $0.resetsAt.timeIntervalSince1970.isFinite && $0.resetsAt > captured }) else { return nil }
        return UsageSnapshot(fiveHour: five, weekly: weekly, capturedAt: captured, accountID: account, sourceFile: source)
    }
}

/// One recursive native stream discovers new date directories, new threads and restored rollouts.
/// The stream is registered before the initial bounded tail read; rescans also cover delayed DB registration.
final class RolloutUsageMonitor {
    private let home: URL
    private let queue = DispatchQueue(label: "keeper.passive-usage", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let reader: RolloutUsageReader
    private let receive: ([PassiveUsageReading], Bool) -> Void
    private var stream: FSEventStreamRef?
    private var running = false
    private var retry: DispatchWorkItem?

    init(home: URL, now: @escaping () -> Date = Date.init, receive: @escaping ([PassiveUsageReading], Bool) -> Void) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.reader = RolloutUsageReader(home: home, now: now); self.receive = receive
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit { stop() }

    func start() {
        queue.async { [self] in
            guard !running else { return }; running = true
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            stream = FSEventStreamCreate(nil, { _, context, count, paths, flags, _ in
                guard let context else { return }
                let monitor = Unmanaged<RolloutUsageMonitor>.fromOpaque(context).takeUnretainedValue()
                let rawPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let paths = rawPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
                let relevant = paths.prefix(count).filter { path in
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return path == monitor.home.path || path.hasPrefix(monitor.home.appendingPathComponent("sessions").path + "/") ||
                        path == monitor.home.appendingPathComponent("sessions").path || name == "auth.json" ||
                        name.range(of: #"^state(?:_[0-9]+)?\.sqlite(?:-wal)?$"#, options: .regularExpression) != nil
                }
                let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                    kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
                let fullRescan = (0..<count).contains { flags[$0] & dropped != 0 }
                guard fullRescan || !relevant.isEmpty else { return }
                monitor.scan(paths: fullRescan ? [monitor.home.path] : relevant)
            }, &context, [home.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
            if let stream { FSEventStreamSetDispatchQueue(stream, queue); FSEventStreamStart(stream) }
            scan()
        }
    }
    func rescan() { queue.async { [weak self] in self?.scan() } }
    func stop() {
        let close = { [self] in
            running = false; retry?.cancel(); retry = nil
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            stream = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { close() } else { queue.sync(execute: close) }
    }
    private func scan(paths: [String] = [], retryRegistration: Bool = true) {
        guard running else { return }
        let readings = reader.read(changedPaths: paths)
        if !readings.isEmpty || reader.authenticationChanged { receive(readings, reader.authenticationChanged) }
        if retryRegistration, reader.needsRegistrationRetry {
            retry?.cancel()
            let retry = DispatchWorkItem { [weak self] in self?.scan(retryRegistration: false) }
            self.retry = retry; queue.asyncAfter(deadline: .now() + 1, execute: retry)
        }
    }
}
