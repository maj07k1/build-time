import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var records: [BuildRecord] = []
    @Published private(set) var loaded = false
    @Published private(set) var packageCount = 0
    @Published var period: Period { didSet { defaults.set(period.rawValue, forKey: "period") } }
    @Published var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var includeTests: Bool { didSet { defaults.set(includeTests, forKey: "includeTests") } }
    @Published var hiddenSources: Set<BuildSource> {
        didSet { defaults.set(hiddenSources.map(\.rawValue), forKey: "hiddenSources") }
    }
    /// Folders searched for Swift packages.
    @Published var roots: [String] {
        didSet {
            defaults.set(roots, forKey: "roots")
            Task { await refresh() }
        }
    }

    private let scanner: BuildScanner
    private let defaults: UserDefaults
    private var timer: Timer?
    private var scanning = false
    private var lastPublish = Date.distantPast

    static var defaultRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = ["Desktop", "Developer", "Projects", "Code", "code", "src", "dev", "repos", "Repos", "git", "GitHub", "workspace", "Documents"]
        var seen = Set<String>()
        return names.map { home.appendingPathComponent($0).path }.filter { path in
            // Case-insensitive volumes list "Code" and "code" as the same folder.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
            return seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased()).inserted
        }
    }

    init(scanner: BuildScanner = BuildScanner(), defaults: UserDefaults = .standard, live: Bool = true) {
        self.scanner = scanner
        self.defaults = defaults
        period = Period(rawValue: defaults.string(forKey: "period") ?? "") ?? .week
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .week
        includeTests = defaults.object(forKey: "includeTests") as? Bool ?? true
        hiddenSources = Set((defaults.stringArray(forKey: "hiddenSources") ?? []).compactMap(BuildSource.init(rawValue:)))
        roots = defaults.stringArray(forKey: "roots") ?? Self.defaultRoots
        guard live else { return }

        // npm deletes its 11th-newest log on every command, so this has to keep up.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 3      // lets macOS coalesce wake-ups to save power
        Task { await refresh() }
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let result = await scanner.scan(roots: roots.map { URL(fileURLWithPath: $0) })
        packageCount = result.packages
        // Republish on a new build, and every minute so "today" rolls over and "5m ago" stays current.
        if result.changed || !loaded || Date().timeIntervalSince(lastPublish) > 60 {
            records = result.records
            loaded = true
            lastPublish = Date()
        }
    }

    func clearHistory() {
        Task {
            await scanner.clear()
            records = []
        }
    }

    /// The builds the settings let through.
    var shown: [BuildRecord] {
        records.filter { !hiddenSources.contains($0.source) && (includeTests || $0.kind == .build) }
    }

    func summary(_ period: Period, now: Date = Date()) -> Summary {
        Summary(records: shown, period: period, now: now)
    }

    // MARK: Menu bar

    var menuBarText: String? {
        let period: Period
        switch menuBarMode {
        case .week: period = .week
        case .today: period = .today
        case .iconOnly: return nil
        }
        let waited = summary(period).waited
        return waited >= 1 ? Fmt.short(waited) : nil
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("BuildTime: launch at login failed: %@", String(describing: error))
        }
        objectWillChange.send()
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain Swift packages."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.map(\.path).filter { !roots.contains($0) }
        if !new.isEmpty { roots += new }
    }
}
