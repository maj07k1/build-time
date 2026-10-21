import Foundation

/// Reads npm's debug logs, `~/.npm/_logs/<start time>-debug-0.log`. npm writes one per command and
/// keeps only the last 10, so the app picks each up while it can. The start time is in the file
/// name; the file is last written when the command exits. Read-only.
enum NpmLog {
    enum Outcome: Equatable {
        /// Still running: the log has no exit line yet.
        case pending
        /// Not a build or test: installs, dev servers, watchers, `npx`.
        case ignored
        case build(BuildRecord)
    }

    struct Parsed: Equatable {
        var argv: [String] = []
        var cwd: String?
        var exit: Int?
    }

    /// "2026-10-16T13_08_34_021Z-debug-0.log" → that moment (UTC).
    static func start(fileName: String) -> Date? {
        guard let t = fileName.range(of: "Z-") else { return nil }
        let stamp = fileName[..<t.lowerBound]                  // 2026-10-16T13_08_34_021
        let parts = stamp.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let time = parts[1].split(separator: "_")
        guard time.count == 4 else { return nil }
        let iso = "\(parts[0])T\(time[0]):\(time[1]):\(time[2]).\(time[3])Z"
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    static func parse(_ text: String) -> Parsed {
        var p = Parsed()
        var sawArgv = false
        for line in text.split(separator: "\n") {
            // "8 verbose argv "run" "build"". Commands spawned together can share a log; the first wins.
            let fields = line.split(separator: " ", maxSplits: 3)
            guard fields.count >= 3, fields[1] == "verbose" else { continue }
            let rest = fields.count > 3 ? String(fields[3]) : ""
            switch fields[2] {
            case "argv" where !sawArgv:
                sawArgv = true
                p.argv = quoted(rest)
            case "cwd" where p.cwd == nil:
                p.cwd = rest
            case "exit":
                p.exit = Int(rest.trimmingCharacters(in: .whitespaces))
            default:
                break
            }
        }
        return p
    }

    private static func quoted(_ s: String) -> [String] {
        var out: [String] = []
        var current: String?
        var escaped = false
        for ch in s {
            if var c = current {
                if escaped { c.append(ch); escaped = false; current = c; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" { out.append(c); current = nil } else { c.append(ch); current = c }
            } else if ch == "\"" {
                current = ""
            }
        }
        return out
    }

    /// Which npm commands count, and as what. `npm run <script>` counts when the script builds,
    /// type-checks or tests; dev servers, watchers and installs don't.
    static func classify(argv: [String]) -> (kind: BuildKind, script: String)? {
        guard let command = argv.first, !argv.contains(where: { $0.hasPrefix("--watch") }) else { return nil }
        switch command {
        case "test", "t", "tst":
            return (.test, "test")
        case "run", "run-script", "rum", "urn":
            break
        default:
            return nil
        }
        // The script is the first argument that isn't a flag or a flag's value.
        var script: String?
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "--" { break }
            if a.hasPrefix("-") {
                if ["--workspace", "-w", "--prefix"].contains(a) { i += 1 }
                i += 1
                continue
            }
            script = a
            break
        }
        guard let script else { return nil }
        let s = script.lowercased()
        if ["dev", "start", "serve", "watch", "preview", "storybook"].contains(where: s.contains) { return nil }
        if ["test", "spec", "e2e", "jest", "vitest"].contains(where: s.contains) { return (.test, script) }
        if ["build", "compile", "check", "tsc", "bundle", "dist", "package", "pack", "prepare", "generate", "codegen"]
            .contains(where: s.contains) { return (.build, script) }
        return nil
    }

    static func outcome(fileName: String, text: String, modified: Date) -> Outcome {
        guard let start = start(fileName: fileName) else { return .ignored }
        let p = parse(text)
        guard let exit = p.exit else { return .pending }
        guard let match = classify(argv: p.argv) else { return .ignored }
        let (kind, script) = match
        let duration = modified.timeIntervalSince(start)
        // Longer than 3 hours is a watcher or a server that slipped through, not a build.
        guard duration >= 0, duration < 3 * 3600 else { return .ignored }

        var workspace: String?
        if let w = p.argv.firstIndex(where: { $0 == "--workspace" || $0 == "-w" }), w + 1 < p.argv.count {
            workspace = p.argv[w + 1]
        }
        let folder = p.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "npm"
        let title = (kind == .test && script == "test" ? "npm test" : "npm run \(script)")
            + (workspace.map { " (\($0))" } ?? "")
        return .build(BuildRecord(
            id: "npm|\(fileName)", source: .npm, kind: kind,
            project: folder, title: title, start: start, duration: duration,
            succeeded: exit == 0, targets: [TargetTime(name: script, seconds: duration)]))
    }
}
