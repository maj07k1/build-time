import Foundation
import SQLite3

/// Reads SwiftPM's build database, `<package>/.build/build.db`. llbuild keeps one row per build step
/// with the iteration (one per `swift build` or `swift test`) it last ran in, and its start and end
/// in seconds since boot. Only each step's latest run is kept, so the app records every new
/// iteration as it appears. Read-only.
enum SwiftPMLog {
    struct Row: Equatable {
        var key: String
        var iteration: Int
        var start: Double
        var end: Double
    }

    /// A compile or link step: "C.MyKit-arm64-apple-macosx14.0-release.module".
    struct Command: Equatable {
        var target: String
        var arch: String
        var config: String
        var kind: String
    }

    static func rows(db: URL) -> [Row]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(handle, 500)
        let sql = "SELECT k.key, r.built_at, r.start, r.end FROM rule_results r JOIN key_names k ON k.id = r.key_id WHERE r.start > 0"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(statement, 0))
            let key = sqlite3_column_blob(statement, 0).map { String(decoding: Data(bytes: $0, count: n), as: UTF8.self) } ?? ""
            rows.append(Row(key: key, iteration: Int(sqlite3_column_int64(statement, 1)),
                            start: sqlite3_column_double(statement, 2), end: sqlite3_column_double(statement, 3)))
        }
        return rows
    }

    /// Parses a step's key. Keys start with a kind letter, "C" for commands.
    static func command(_ key: String) -> Command? {
        guard key.hasPrefix("CC.") else { return nil }
        let name = key.dropFirst(3)
        guard let dot = name.lastIndex(of: "."), let apple = name.range(of: "-apple-") else { return nil }
        let kind = String(name[name.index(after: dot)...])
        let head = name[..<apple.lowerBound]                    // "MyKit-arm64"
        guard let archDash = head.lastIndex(of: "-") else { return nil }
        let rest = name[apple.upperBound..<dot]                 // "macosx14.0-release"
        guard let configDash = rest.lastIndex(of: "-") else { return nil }
        return Command(target: String(head[..<archDash]), arch: String(head[head.index(after: archDash)...]),
                       config: String(rest[rest.index(after: configDash)...]), kind: kind)
    }

    /// Turns the steps of every iteration after `after` into builds.
    /// - Parameter wall: converts llbuild's clock to a date.
    static func builds(rows: [Row], dbPath: String, project: String, after: Int,
                       wall: (Double) -> Date) -> [BuildRecord] {
        let iterations = Dictionary(grouping: rows.filter { $0.iteration > after && $0.end >= $0.start }, by: \.iteration)
        return iterations.compactMap { iteration, steps in
            guard let first = steps.map(\.start).min() else { return nil }
            let duration = busyTime(steps)
            guard duration >= 0.5 else { return nil }      // a no-op build
            let commands = steps.compactMap { s in command(s.key).map { (s, $0) } }
            var targets: [String: TimeInterval] = [:]
            for (step, c) in commands where !c.kind.hasSuffix("entitlements") {
                // SwiftPM's synthetic "<Package>PackageTests" product is the test bundle being linked.
                let name = c.target.hasSuffix("PackageTests") ? "Test bundle" : c.target
                targets[name, default: 0] += step.end - step.start
            }
            let testing = commands.contains { $0.1.kind == "test" || $0.1.target.hasSuffix("Tests") }
            let configs = Array(Set(commands.map(\.1.config))).sorted()
            let arches = Array(Set(commands.map(\.1.arch))).sorted()
            let detail = (configs + arches).joined(separator: ", ")
            let start = wall(first)
            return BuildRecord(
                id: "swift|\(dbPath)|\(iteration)|\(Int(start.timeIntervalSince1970))",
                source: .swift, kind: testing ? .test : .build, project: project,
                title: (testing ? "swift test" : "swift build") + (detail.isEmpty ? "" : " (\(detail))"),
                start: start, duration: duration, succeeded: nil,
                targets: targets.filter { $0.value >= 0.05 }
                    .map { TargetTime(name: $0.key, seconds: $0.value) }
                    .sorted { $0.seconds > $1.seconds })
        }
    }

    /// The iteration's span, minus idle gaps longer than a minute. Later builds overwrite the steps
    /// they rerun, so an old iteration can be left with a few instant steps minutes apart.
    static func busyTime(_ steps: [Row]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (start: Double, end: Double)?
        for s in steps.sorted(by: { $0.start < $1.start }) {
            if let c = current, s.start - c.end <= 60 {
                current = (c.start, max(c.end, s.end))
            } else {
                if let c = current { total += c.end - c.start }
                current = (s.start, s.end)
            }
        }
        if let c = current { total += c.end - c.start }
        return total
    }

    /// How to turn llbuild's seconds-since-boot into dates for one database. If the newest step
    /// lines up with the file's modification time, it was written since this boot and the boot time
    /// is exact. Otherwise it's from an earlier boot, so the newest step is pinned to the mtime.
    static func clockOffset(rows: [Row], modified: Date, bootTime: Date) -> TimeInterval {
        let newest = rows.map(\.end).max() ?? 0
        let byBoot = bootTime.timeIntervalSince1970
        if abs(byBoot + newest - modified.timeIntervalSince1970) < 120 { return byBoot }
        return modified.timeIntervalSince1970 - newest
    }

    static var bootTime: Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// A `.build/.lock` belongs to a SwiftPM process that's still running.
    static func isBuilding(package: URL) -> Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent(".build/.lock").path)
    }

    /// Folders holding a `.build/build.db`, up to `depth` levels below each root.
    static func discover(roots: [URL], depth: Int = 4) -> [URL] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", "Library", "Pods", "DerivedData", "build", "dist", "vendor", "Carthage"]
        var found: [URL] = []
        var seen = Set<String>()
        func visit(_ dir: URL, _ level: Int) {
            guard seen.insert(dir.standardizedFileURL.path).inserted else { return }
            if fm.fileExists(atPath: dir.appendingPathComponent(".build/build.db").path) { found.append(dir) }
            guard level < depth,
                  let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for child in children where !skip.contains(child.lastPathComponent) {
                let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isDirectory == true, v?.isSymbolicLink != true { visit(child, level + 1) }
            }
        }
        for root in roots { visit(root, 0) }
        return found
    }
}
