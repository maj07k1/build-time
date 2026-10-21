import AppKit
import Charts
import SwiftUI

@main
struct BuildTimeApp: App {
    @StateObject private var model = AppModel(live: DevSnapshot.directory == nil)

    init() {
        if let dir = DevSnapshot.directory {
            Task { @MainActor in
                await DevSnapshot.run(into: dir)
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hammer")
            if let text = model.menuBarText { Text(text) }
        }
    }
}

// MARK: - Shell

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings: Bool

    private let height: CGFloat

    init(showSettings: Bool = false, height: CGFloat = 640) {
        self.height = height
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    if showSettings {
                        SettingsView()
                    } else if !model.loaded {
                        ProgressView("Reading build logs…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if model.shown.isEmpty {
                        EmptyNote(icon: "hammer",
                                  text: "No builds yet.\nBuild something in Xcode, with swift build or with npm run build, and it shows up here.")
                    } else {
                        Dashboard(summary: model.summary(model.period))
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 420, height: height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(showSettings ? "Settings" : "Build Time").font(.headline)
            Spacer()
            if !showSettings {
                Picker("Period", selection: $model.period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
            }
            .help(showSettings ? "Close settings" : "Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct SourceIcon: View {
    let source: BuildSource

    var body: some View {
        Image(systemName: Theme.icon(source))
            .foregroundStyle(Theme.color(source))
            .frame(width: 16)
            .help(source.label)
    }
}

// MARK: - Dashboard

struct Dashboard: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeadlineCard(summary: summary)
            if summary.builds.isEmpty {
                EmptyNote(icon: "cup.and.saucer", text: "No builds \(summary.period.phrase) yet.")
            } else {
                ChartCard(summary: summary)
                TargetsCard(summary: summary)
                if summary.projects.count > 1 { ProjectsCard(summary: summary) }
                RecentCard(summary: summary)
            }
            Text("Read from Xcode's DerivedData, SwiftPM's .build folders and npm's logs on this Mac. Builds that overlap count once in the waiting time.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HeadlineCard: View {
    let summary: Summary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("You waited").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.duration(summary.waited))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                    Text("for builds \(summary.period.phrase)").foregroundStyle(.secondary)
                }
                if !summary.builds.isEmpty {
                    HStack(spacing: 12) {
                        stat("\(summary.builds.count)", summary.builds.count == 1 ? "build" : "builds")
                        stat(Fmt.duration(summary.average), "average")
                        if let longest = summary.longest { stat(Fmt.duration(longest.duration), "longest") }
                        if summary.failed > 0 { stat("\(summary.failed)", "failed", color: .red) }
                    }
                }
                if !summary.bySource.isEmpty, summary.bySource.count > 1 || summary.bySource[0].source != .swift {
                    SourceBar(parts: summary.bySource)
                }
                if let line = comparison {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Compared with the same point in the previous period, since this one isn't over yet.
    private var comparison: String? {
        let before = summary.previousSoFar
        let whole = summary.previousWaited < 1 ? "" : " · \(Fmt.duration(summary.previousWaited)) in all"
        guard let change = Fmt.percentChange(summary.waited, vs: before) else {
            return whole.isEmpty ? nil : "Nothing by this point \(summary.period.previousPhrase)\(whole)"
        }
        return "\(change) this point \(summary.period.previousPhrase) (\(Fmt.duration(before)))\(whole)"
    }

    private func stat(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Waiting time split by tool.
struct SourceBar: View {
    let parts: [(source: BuildSource, waited: TimeInterval)]

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.waited })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let gaps = CGFloat(max(0, parts.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(parts, id: \.source) { p in
                        Rectangle().fill(Theme.color(p.source))
                            .frame(width: max(2, (geo.size.width - gaps) * p.waited / total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(parts, id: \.source) { p in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.color(p.source)).frame(width: 7, height: 7)
                        Text("\(p.source.label) \(Fmt.duration(p.waited))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct ChartCard: View {
    let summary: Summary

    var body: some View {
        let byHour = summary.period == .today
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(byHour ? "By hour" : "By day").font(.subheadline.weight(.semibold))
                Chart(summary.buckets) { b in
                    BarMark(x: .value("Time", b.date, unit: byHour ? .hour : .day),
                            y: .value("Minutes", b.seconds / 60))
                        .foregroundStyle(by: .value("Tool", b.source.label))
                        .cornerRadius(2)
                }
                .chartForegroundStyleScale(domain: BuildSource.allCases.map(\.label),
                                           range: BuildSource.allCases.map(Theme.color))
                .chartLegend(.hidden)
                .chartXScale(domain: summary.interval.start...summary.interval.end)
                .chartXAxis {
                    if byHour {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    } else if summary.period == .week {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.day())
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let m = value.as(Double.self) { Text(Fmt.short(m * 60)) }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
    }
}

struct TargetsCard: View {
    let summary: Summary

    var body: some View {
        let targets = Array(summary.targets.prefix(7))
        if !targets.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Slowest targets").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("per build").font(.caption).foregroundStyle(.secondary)
                    }
                    let top = targets[0].average
                    ForEach(targets) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                SourceIcon(source: t.source)
                                Text(t.name).lineLimit(1).truncationMode(.middle)
                                if t.name != t.project {
                                    Text(t.project).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if t.builds > 1 {
                                    Text("×\(t.builds)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text(Fmt.duration(t.average)).monospacedDigit()
                            }
                            .font(.caption)
                            GeometryReader { geo in
                                Capsule().fill(Theme.color(t.source).opacity(0.7))
                                    .frame(width: max(3, geo.size.width * t.average / top))
                            }
                            .frame(height: 4)
                            .padding(.leading, 24)
                        }
                        .help("\(t.name) (\(t.project)): \(Fmt.duration(t.average)) on average over \(t.builds) build\(t.builds == 1 ? "" : "s"), longest \(Fmt.duration(t.longest)), \(Fmt.duration(t.total)) in all")
                    }
                }
            }
        }
    }
}

struct ProjectsCard: View {
    let summary: Summary

    var body: some View {
        let projects = Array(summary.projects.prefix(6))
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("By project").font(.subheadline.weight(.semibold))
                let top = max(1, projects.first?.waited ?? 1)
                ForEach(projects) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(p.project).lineLimit(1)
                            ForEach(p.sources, id: \.self) { s in
                                Image(systemName: Theme.icon(s)).font(.caption2).foregroundStyle(Theme.color(s))
                            }
                            Spacer()
                            Text("\(p.builds) build\(p.builds == 1 ? "" : "s")").foregroundStyle(.secondary)
                            Text(Fmt.duration(p.waited)).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                        }
                        .font(.caption)
                        GeometryReader { geo in
                            Capsule().fill(Theme.accent.opacity(0.7))
                                .frame(width: max(3, geo.size.width * p.waited / top))
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}

struct RecentCard: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent builds").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(summary.builds.prefix(10))) { b in
                HStack(spacing: 10) {
                    SourceIcon(source: b.source)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text("\(b.project) · \(Fmt.ago(b.end))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if b.succeeded == false {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Failed or stopped")
                    }
                    Text(Fmt.duration(b.duration)).font(.callout.weight(.semibold).monospacedDigit())
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preferences").font(.subheadline.weight(.semibold))
            Picker("Menu bar shows", selection: $model.menuBarMode) {
                ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Count test runs", isOn: $model.includeTests)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))

            Divider()

            Text("Sources").font(.subheadline.weight(.semibold))
            ForEach(BuildSource.allCases) { s in
                Toggle(isOn: Binding(
                    get: { !model.hiddenSources.contains(s) },
                    set: { on in if on { model.hiddenSources.remove(s) } else { model.hiddenSources.insert(s) } })) {
                    HStack(spacing: 6) {
                        SourceIcon(source: s)
                        Text(s.label)
                        Text(note(s)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("npm keeps only its last 10 logs and SwiftPM only the latest run of each step, so builds are recorded while the app is running. History starts with whatever was still on disk when you first opened it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Swift package folders").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.packageCount) package\(model.packageCount == 1 ? "" : "s") found")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.roots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text((root as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop looking here")
                }
                .font(.callout)
            }
            HStack {
                Button("Add Folder…") { model.addRoot() }
                if model.roots != AppModel.defaultRoots {
                    Button("Reset") { model.roots = AppModel.defaultRoots }
                }
            }
            Text("Searched up to four levels deep for packages with a .build folder. Xcode and npm are found on their own.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            AboutSection()

            Divider()

            HStack {
                Button("Clear History…") { confirmClear = true }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .confirmationDialog("Clear every recorded build?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
            } message: {
                Text("Builds still in the tools' own logs won't be read again, so this can't be undone.")
            }
        }
    }

    private func note(_ s: BuildSource) -> String {
        switch s {
        case .xcode: return "DerivedData build logs"
        case .swift: return "swift build, swift test"
        case .npm: return "build, typecheck and test scripts"
        }
    }
}

struct AboutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("About").font(.subheadline.weight(.semibold))
                Text("Version \(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Build Time is free and open source. It only reads build logs on this Mac: no network, no analytics.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tip = AppInfo.tipJarURL {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enjoying the app?").font(.callout.weight(.semibold))
                            Text("A tip helps keep it maintained. Entirely optional.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("Leave a tip", destination: tip)
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
            if let source = AppInfo.sourceURL {
                HStack(spacing: 14) {
                    Link(destination: source) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: source.appending(path: "issues")) { Label("Report an issue", systemImage: "exclamationmark.bubble") }
                }
                .font(.caption)
            }
        }
    }
}
