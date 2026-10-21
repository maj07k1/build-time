import Foundation
import Testing
@testable import BuildTime

// MARK: - Fixtures

/// Writes SLF0 tokens the way Xcode does.
struct SLFWriter {
    var out = "SLF0"
    mutating func int(_ n: Int) { out += "\(n)#" }
    mutating func string(_ s: String) { out += "\(s.utf8.count)\"\(s)" }
    mutating func null() { out += "-" }
    mutating func className(_ s: String) { out += "\(s.utf8.count)%\(s)" }
    mutating func instance(_ n: Int) { out += "\(n)@" }
    mutating func array(_ n: Int) { out += "\(n)(" }
    mutating func double(_ d: Double) { out += String(d.bitPattern.byteSwapped, radix: 16) + "^" }

    mutating func section(domain: String, title: String, start: Double, stop: Double, children: Int = 0) {
        instance(1)
        int(2)
        string(domain)
        string(title)
        string(title)
        double(start)
        double(stop)
        array(children)
    }
}

func gzip(_ data: Data) -> Data {
    var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
    out += (try! (data as NSData).compressed(using: .zlib)) as Data
    out += Data(count: 8)       // CRC and size, which the reader doesn't check
    return out
}

func row(_ key: String, _ iteration: Int, _ start: Double, _ end: Double) -> SwiftPMLog.Row {
    SwiftPMLog.Row(key: key, iteration: iteration, start: start, end: end)
}

func record(_ start: Double, _ duration: Double, source: BuildSource = .swift, project: String = "App",
            targets: [TargetTime] = []) -> BuildRecord {
    BuildRecord(id: UUID().uuidString, source: source, kind: .build, project: project, title: "b",
                start: Date(timeIntervalSince1970: start), duration: duration, succeeded: true, targets: targets)
}

// MARK: - Xcode

@Suite struct XcodeTests {
    @Test func tokenizesEveryType() throws {
        var w = SLFWriter()
        w.int(11)
        w.className("IDEActivityLogSection")
        w.instance(1)
        w.string("héllo")
        w.null()
        w.double(1.5)
        w.array(0)
        let tokens = try #require(SLF.tokens(Data(w.out.utf8)))
        #expect(tokens == [.int(11), .className("IDEActivityLogSection"), .instance(1), .string("héllo"),
                           .null, .double(1.5), .array(0)])
    }

    @Test func rejectsOtherFiles() {
        #expect(SLF.tokens(Data("PK\u{3}\u{4}".utf8)) == nil)
    }

    @Test func readsTargetTimesFromGzippedLog() {
        var w = SLFWriter()
        w.int(11)
        w.className("IDEActivityLogSection")
        w.section(domain: "Xcode.IDEActivityLogDomainType.BuildLog", title: "Build MyApp", start: 1000, stop: 1100, children: 2)
        w.section(domain: "Xcode.IDEActivityLogDomainType.target.product-type.framework",
                  title: "Build target MyKit of project MyApp with configuration Debug", start: 1001, stop: 1031)
        w.section(domain: "Xcode.IDEActivityLogDomainType.target.product-type.application",
                  title: "Build target MyApp of project MyApp with configuration Debug", start: 1031, stop: 1100)
        let targets = XcodeLog.targets(logData: gzip(Data(w.out.utf8)))
        #expect(targets == [TargetTime(name: "MyApp", seconds: 69), TargetTime(name: "MyKit", seconds: 30)])
    }

    @Test func readsManifestAndSkipsCleans() throws {
        let plist: [String: Any] = ["logFormatVersion": 11, "logs": [
            "A": ["fileName": "A.xcactivitylog", "title": "Build MyApp", "schemeIdentifier-schemeName": "MyApp",
                  "timeStartedRecording": 800_000_000.0, "timeStoppedRecording": 800_000_042.5,
                  "primaryObservable": ["highLevelStatus": "E", "totalNumberOfErrors": 2]],
            "B": ["fileName": "B.xcactivitylog", "title": "Clean MyApp",
                  "timeStartedRecording": 800_000_100.0, "timeStoppedRecording": 800_000_101.0],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let entries = XcodeLog.manifest(data)
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.title == "Build MyApp")
        #expect(e.succeeded == false)
        #expect(e.stop.timeIntervalSince(e.start) == 42.5)
        #expect(e.start == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    @Test func namesProjectsAndTargets() {
        #expect(XcodeLog.projectName(derivedDataFolder: "MyApp-bcdefghijklmnopqrstuvwxyz") == "MyApp")
        #expect(XcodeLog.projectName(derivedDataFolder: "My-App-bcdefghijklmnopqrstuvwxyz") == "My-App")
        #expect(XcodeLog.targetName("Build target MyKit of project MyApp with configuration Debug") == "MyKit")
        #expect(XcodeLog.targetName("Build target MyKit") == "MyKit")
    }
}

// MARK: - SwiftPM

@Suite struct SwiftPMTests {
    @Test func parsesCommandKeys() {
        #expect(SwiftPMLog.command("CC.My-Kit-arm64-apple-macosx14.0-release.module")
                == .init(target: "My-Kit", arch: "arm64", config: "release", kind: "module"))
        #expect(SwiftPMLog.command("CC.AppPackageTests-x86_64-apple-macosx16.0-debug.test")?.kind == "test")
        #expect(SwiftPMLog.command("C/Users/me/app/.build/debug/swift-version.txt") == nil)
        #expect(SwiftPMLog.command("CPackageStructure") == nil)
    }

    @Test func groupsIterationsIntoBuilds() throws {
        let rows = [
            row("CPackageStructure", 3, 100, 100.1),
            row("CC.App-arm64-apple-macosx14.0-release.module", 3, 100.2, 140),
            row("CC.App-arm64-apple-macosx14.0-release.exe", 3, 140, 141),
            row("CC.App-arm64-apple-macosx16.0-debug.module", 2, 50, 52),
            row("CC.AppTests-arm64-apple-macosx16.0-debug.module", 4, 200, 201),
            row("CC.AppPackageTests-arm64-apple-macosx16.0-debug.test", 4, 201, 202),
            row("CPackageStructure", 5, 300, 300.01),       // no-op
        ]
        let builds = SwiftPMLog.builds(rows: rows, dbPath: "/db", project: "app", after: 2) {
            Date(timeIntervalSince1970: 1_000_000 + $0)
        }.sorted { $0.start < $1.start }
        #expect(builds.count == 2)
        let release = try #require(builds.first)
        #expect(release.title == "swift build (release, arm64)")
        #expect(release.kind == .build)
        #expect(abs(release.duration - 41) < 0.001)
        #expect(release.start == Date(timeIntervalSince1970: 1_000_100))
        #expect(release.targets.first?.name == "App")
        #expect(abs((release.targets.first?.seconds ?? 0) - 40.8) < 0.001)
        #expect(builds[1].kind == .test)
        #expect(builds[1].targets.map(\.name).sorted() == ["AppTests", "Test bundle"])
    }

    @Test func leavesOutIdleGaps() {
        // What's left of an old iteration: instant steps several minutes apart.
        let steps = [row("Na", 1, 0, 0), row("Nb", 1, 460, 460.5), row("Nc", 1, 460.5, 462)]
        #expect(SwiftPMLog.busyTime(steps) == 2)
    }

    @Test func mapsClockByBootTimeWhenItLinesUp() {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        let rows = [row("x", 1, 10, 500)]
        #expect(SwiftPMLog.clockOffset(rows: rows, modified: Date(timeIntervalSince1970: 1_000_501), bootTime: boot) == 1_000_000)
        // Written before the last reboot: pinned to the file's modification time instead.
        #expect(SwiftPMLog.clockOffset(rows: rows, modified: Date(timeIntervalSince1970: 900_000), bootTime: boot) == 899_500)
    }
}

// MARK: - npm

@Suite struct NpmTests {
    let log = """
    0 verbose cli /opt/homebrew/bin/node /opt/homebrew/bin/npm
    7 verbose title npm run build
    8 verbose argv "run" "build" "--workspace" "@vf/web"
    13 verbose cwd /Users/me/Desktop/video
    17 verbose exit 0
    18 info ok
    """

    @Test func readsStartFromFileName() throws {
        let d = try #require(NpmLog.start(fileName: "2026-10-16T13_08_34_021Z-debug-0.log"))
        #expect(abs(d.timeIntervalSince1970 - 1_792_156_114.021) < 0.001)
    }

    @Test func turnsABuildIntoARecord() throws {
        let start = try #require(NpmLog.start(fileName: "2026-10-16T13_08_34_021Z-debug-0.log"))
        let outcome = NpmLog.outcome(fileName: "2026-10-16T13_08_34_021Z-debug-0.log", text: log,
                                     modified: start.addingTimeInterval(12))
        guard case let .build(r) = outcome else { Issue.record("expected a build, got \(outcome)"); return }
        #expect(r.project == "video")
        #expect(r.title == "npm run build (@vf/web)")
        #expect(abs(r.duration - 12) < 0.001)
        #expect(r.succeeded == true)
    }

    @Test func waitsForTheExitLine() {
        let running = log.replacingOccurrences(of: "17 verbose exit 0", with: "")
        #expect(NpmLog.outcome(fileName: "2026-10-16T13_08_34_021Z-debug-0.log", text: running, modified: Date()) == .pending)
    }

    @Test func classifiesCommands() {
        #expect(NpmLog.classify(argv: ["run", "build"])?.kind == .build)
        #expect(NpmLog.classify(argv: ["run", "typecheck"])?.kind == .build)
        #expect(NpmLog.classify(argv: ["run", "-w", "web", "test:unit"])?.script == "test:unit")
        #expect(NpmLog.classify(argv: ["test"])?.kind == .test)
        #expect(NpmLog.classify(argv: ["run", "dev"]) == nil)
        #expect(NpmLog.classify(argv: ["run", "build", "--", "--watch"]) == nil)
        #expect(NpmLog.classify(argv: ["exec", "--yes", "--", "chrome-devtools-mcp"]) == nil)
        #expect(NpmLog.classify(argv: ["install"]) == nil)
    }
}

// MARK: - Stats and formatting

@Suite struct StatsTests {
    @Test func overlappingBuildsCountOnce() {
        #expect(Summary.union([record(0, 10), record(5, 10), record(100, 5)]) == 20)
        #expect(Summary.union([]) == 0)
    }

    @Test func summarizesTheWeek() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        // Friday 2026-10-16 12:00 UTC; the week starts Monday the 12th.
        let now = Date(timeIntervalSince1970: 1_792_152_000)
        let monday = cal.dateInterval(of: .weekOfYear, for: now)!.start.timeIntervalSince1970
        let records = [
            record(monday + 3600, 600, targets: [TargetTime(name: "Kit", seconds: 300)]),
            record(monday + 7200, 60, source: .npm, project: "web", targets: [TargetTime(name: "build", seconds: 60)]),
            record(monday + 86400, 120, targets: [TargetTime(name: "Kit", seconds: 100)]),
            record(monday - 86400 * 7 + 3600, 900),            // last Monday: before this point
            record(monday - 86400 * 2, 300),                   // last Saturday: after it
        ]
        let s = Summary(records: records, period: .week, now: now, calendar: cal)
        #expect(s.builds.count == 3)
        #expect(s.waited == 780)
        #expect(s.previousWaited == 1200)
        #expect(s.previousSoFar == 900)
        #expect(s.projects.first?.project == "App")
        let kit = try #require(s.targets.first)
        #expect(kit.name == "Kit")
        #expect(kit.average == 200)
        #expect(kit.builds == 2)
        #expect(s.buckets.count == 3)
    }

    @Test func formatsDurations() {
        #expect(Fmt.duration(0) == "0s")
        #expect(Fmt.duration(0.84) == "0.8s")
        #expect(Fmt.duration(42) == "42s")
        #expect(Fmt.duration(185) == "3m 5s")
        #expect(Fmt.duration(725) == "12m")
        #expect(Fmt.duration(13_200) == "3h 40m")
        #expect(Fmt.duration(7200) == "2h")
        #expect(Fmt.percentChange(150, vs: 100) == "↑ 50% vs")
        #expect(Fmt.percentChange(150, vs: 0) == nil)
    }
}
