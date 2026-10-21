import AppKit
import SwiftUI

/// Developer self-check, never used in normal runs.
///
/// `BUILD_TIME_SNAPSHOT=<dir>` reads the real build logs into a throwaway history, renders the
/// popover to PNGs, prints a short summary, and exits.
@MainActor
enum DevSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["BUILD_TIME_SNAPSHOT"] }

    static func run(into dir: String) async {
        let suite = "BuildTime.DevSnapshot"
        let store = UserDefaults(suiteName: suite)!
        let model = AppModel(scanner: BuildScanner(historyURL: nil), defaults: store, live: false)
        await model.refresh()

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for period in Period.allCases {
            model.period = period
            await render(PopoverView(height: 1400).environmentObject(model), to: "\(dir)/\(period.rawValue).png", height: 1400)
        }
        await render(PopoverView(showSettings: true, height: 1000).environmentObject(model), to: "\(dir)/settings.png", height: 1000)
        UserDefaults.standard.removePersistentDomain(forName: suite)

        let s = model.summary(.week)
        print("Week: waited \(Fmt.duration(s.waited)) over \(s.builds.count) builds, \(model.packageCount) packages")
        for t in s.targets.prefix(6) {
            print("  \(t.source.label) \(t.project) · \(t.name): \(Fmt.duration(t.average)) ×\(t.builds)")
        }
    }

    private static func render<V: View>(_ view: V, to path: String, height: CGFloat) async {
        let host = NSHostingView(rootView: view
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
