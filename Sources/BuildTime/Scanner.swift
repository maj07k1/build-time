import Foundation

/// Everything recorded so far. The tools' own logs are short-lived (npm keeps 10, SwiftPM only each
/// step's latest run), so builds are copied here as soon as they're seen.
struct History: Codable {
    var records: [BuildRecord] = []
    /// `build.db` path → the newest iteration already recorded.
    var swiftSeen: [String: Int] = [:]
    /// npm log file names and Xcode log ids already handled, including ones that weren't builds.
    var npmSeen: Set<String> = []
    var xcodeSeen: Set<String> = []

    /// Builds older than this are dropped.
    static let keep: TimeInterval = 400 * 86400
}

struct ScanResult {
    var records: [BuildRecord]
    var packages: Int
    var changed: Bool
}

actor BuildScanner {
    private let home: URL
    private let historyURL: URL?
    private let derivedData: URL
    private let npmLogs: URL
    private var history = History()
    private var loadedHistory = false
    private var stamps: [String: Date] = [:]
    private var packages: [URL] = []
    private var discovered: (roots: [URL], at: Date)?
    private var reported = false

    /// - Parameter historyURL: where builds are kept between launches; nil keeps them in memory.
    init(home: URL? = nil, historyURL: URL? = BuildScanner.defaultHistoryURL,
         derivedData: URL? = nil, npmLogs: URL? = nil) {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.home = home
        self.historyURL = historyURL
        self.derivedData = derivedData ?? XcodeLog.derivedData(home: home)
        self.npmLogs = npmLogs ?? home.appendingPathComponent(".npm/_logs")
    }

    static var defaultHistoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BuildTime/history.json")
    }

    func scan(roots: [URL], now: Date = Date()) -> ScanResult {
        loadHistory()
        var changed = false
        if scanXcode() { changed = true }
        if scanSwift(roots: roots, now: now) { changed = true }
        if scanNpm(now: now) { changed = true }
        if changed {
            let cutoff = now.addingTimeInterval(-History.keep)
            history.records.removeAll { $0.start < cutoff }
            history.records.sort { $0.start > $1.start }
            saveHistory()
        }
        let first = !reported
        reported = true
        return ScanResult(records: history.records, packages: packages.count, changed: changed || first)
    }

    /// Forgets recorded builds. Logs already read stay marked, so they don't come back.
    func clear() {
        history.records = []
        saveHistory()
    }

    // MARK: Sources

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Whether `url` changed since it was last handled. Marks it handled.
    private func isNew(_ url: URL) -> Date? {
        guard let m = modified(url), stamps[url.path] != m else { return nil }
        stamps[url.path] = m
        return m
    }

    private func add(_ record: BuildRecord) {
        guard !history.records.contains(where: { $0.id == record.id }) else { return }
        history.records.append(record)
    }

    private func scanXcode() -> Bool {
        var changed = false
        let folders = (try? FileManager.default.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let logs = folder.appendingPathComponent("Logs/Build")
            let manifest = logs.appendingPathComponent("LogStoreManifest.plist")
            guard isNew(manifest) != nil, let data = try? Data(contentsOf: manifest) else { continue }
            let project = XcodeLog.projectName(derivedDataFolder: folder.lastPathComponent)
            for entry in XcodeLog.manifest(data) {
                let id = "xcode|\(folder.lastPathComponent)|\(entry.id)"
                guard !history.xcodeSeen.contains(id) else { continue }
                history.xcodeSeen.insert(id)
                let targets = (try? Data(contentsOf: logs.appendingPathComponent(entry.fileName), options: .mappedIfSafe))
                    .map(XcodeLog.targets(logData:)) ?? []
                add(BuildRecord(id: id, source: .xcode, kind: entry.title.hasPrefix("Test") ? .test : .build,
                                project: project, title: entry.title, start: entry.start,
                                duration: entry.stop.timeIntervalSince(entry.start), succeeded: entry.succeeded,
                                targets: targets))
                changed = true
            }
        }
        return changed
    }

    private func scanSwift(roots: [URL], now: Date) -> Bool {
        // Finding packages walks folders, so it's done every few minutes, not every scan.
        if discovered == nil || discovered!.roots != roots || now.timeIntervalSince(discovered!.at) > 300 {
            packages = SwiftPMLog.discover(roots: roots)
            discovered = (roots, now)
        }
        var changed = false
        let boot = SwiftPMLog.bootTime
        for package in packages {
            let db = package.appendingPathComponent(".build/build.db")
            // Mid-build the newest iteration is incomplete, so wait for SwiftPM to finish.
            guard !SwiftPMLog.isBuilding(package: package), let mtime = isNew(db) else { continue }
            guard let rows = SwiftPMLog.rows(db: db) else {
                stamps[db.path] = nil      // locked or half-written; try again next time
                continue
            }
            let newest = rows.map(\.iteration).max() ?? 0
            var after = history.swiftSeen[db.path] ?? 0
            if newest < after { after = 0 }     // `.build` was deleted and started over
            let offset = SwiftPMLog.clockOffset(rows: rows, modified: mtime, bootTime: boot)
            let builds = SwiftPMLog.builds(rows: rows, dbPath: db.path, project: package.lastPathComponent, after: after) {
                Date(timeIntervalSince1970: offset + $0)
            }
            for b in builds where b.end <= mtime.addingTimeInterval(120) { add(b) }
            if history.swiftSeen[db.path] != newest {
                history.swiftSeen[db.path] = newest
                changed = true
            }
            if !builds.isEmpty { changed = true }
        }
        return changed
    }

    private func scanNpm(now: Date) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: npmLogs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let names = Set(files.map(\.lastPathComponent))
        var changed = false
        for url in files where url.lastPathComponent.hasSuffix("-debug-0.log") && !history.npmSeen.contains(url.lastPathComponent) {
            guard let mtime = isNew(url), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            switch NpmLog.outcome(fileName: url.lastPathComponent, text: text, modified: mtime) {
            case .pending:
                // A log with no exit line for hours belongs to a command that was killed.
                if now.timeIntervalSince(mtime) > 6 * 3600 { history.npmSeen.insert(url.lastPathComponent) }
                continue
            case .ignored:
                break
            case let .build(record):
                add(record)
            }
            history.npmSeen.insert(url.lastPathComponent)
            changed = true
        }
        // Forget logs npm has deleted, so the set doesn't grow forever.
        let kept = history.npmSeen.intersection(names)
        if kept.count != history.npmSeen.count {
            history.npmSeen = kept
            changed = true
        }
        return changed
    }

    // MARK: Persistence

    private func loadHistory() {
        guard !loadedHistory else { return }
        loadedHistory = true
        guard let url = historyURL, let data = try? Data(contentsOf: url) else { return }
        if let h = try? JSONDecoder().decode(History.self, from: data) { history = h }
    }

    private func saveHistory() {
        guard let url = historyURL, let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
