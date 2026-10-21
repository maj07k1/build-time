import Foundation
import SwiftUI

// MARK: - Builds

enum BuildSource: String, Codable, CaseIterable, Identifiable {
    case xcode, swift, npm
    var id: String { rawValue }

    var label: String {
        switch self {
        case .xcode: return "Xcode"
        case .swift: return "SwiftPM"
        case .npm: return "npm"
        }
    }
}

enum BuildKind: String, Codable {
    case build, test
}

/// Time spent on one target (an Xcode target, a Swift module, an npm script) within a build.
struct TargetTime: Codable, Hashable {
    var name: String
    var seconds: TimeInterval
}

struct BuildRecord: Codable, Identifiable, Hashable {
    var id: String
    var source: BuildSource
    var kind: BuildKind
    var project: String
    /// "Build MyApp", "swift build (release, arm64)", "npm run build".
    var title: String
    var start: Date
    var duration: TimeInterval
    /// nil when the log doesn't say.
    var succeeded: Bool?
    var targets: [TargetTime] = []

    var end: Date { start.addingTimeInterval(duration) }
}

// MARK: - Periods

enum Period: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// Completes "You waited 3h for builds …".
    var phrase: String {
        switch self {
        case .today: return "today"
        case .week: return "this week"
        case .month: return "this month"
        }
    }

    var previousPhrase: String {
        switch self {
        case .today: return "yesterday"
        case .week: return "last week"
        case .month: return "last month"
        }
    }

    private var component: Calendar.Component {
        switch self {
        case .today: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// Chart bars: hours for today, days otherwise.
    var bucket: Calendar.Component { self == .today ? .hour : .day }

    func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }

    func previous(before date: Date, calendar: Calendar = .current) -> DateInterval {
        interval(containing: interval(containing: date, calendar: calendar).start.addingTimeInterval(-1), calendar: calendar)
    }
}

// MARK: - App info

/// Release metadata, read from Info.plist so forks and releases can set it without code changes
/// (see build.sh). Links are nil, and hidden in the UI, until configured.
enum AppInfo {
    private static func string(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var version: String { string("CFBundleShortVersionString") ?? "dev" }
    static var sourceURL: URL? { string("BuildTimeSourceURL").flatMap(URL.init(string:)) }
    static var tipJarURL: URL? { string("BuildTimeTipJarURL").flatMap(URL.init(string:)) }
}

// MARK: - Settings

enum MenuBarMode: String, CaseIterable, Identifiable {
    case week, today, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "Time this week"
        case .today: return "Time today"
        case .iconOnly: return "Icon only"
        }
    }
}

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.42, green: 0.47, blue: 0.98)

    static func color(_ source: BuildSource) -> Color {
        switch source {
        case .xcode: return Color(red: 0.25, green: 0.6, blue: 1)
        case .swift: return Color(red: 0.98, green: 0.45, blue: 0.25)
        case .npm: return Color(red: 0.8, green: 0.25, blue: 0.4)
        }
    }

    static func icon(_ source: BuildSource) -> String {
        switch source {
        case .xcode: return "hammer"
        case .swift: return "swift"
        case .npm: return "shippingbox"
        }
    }
}

// MARK: - Formatting

enum Fmt {
    /// "0.8s", "42s", "3m 5s", "12m", "3h 40m".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0.05 { return "0s" }
        if seconds < 9.95 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        let m = (s + 30) / 60
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// The menu bar version: no seconds once past a minute.
    static func short(_ seconds: TimeInterval) -> String {
        seconds < 60 ? duration(seconds) : duration((seconds / 60).rounded() * 60)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func percentChange(_ now: TimeInterval, vs before: TimeInterval) -> String? {
        guard before >= 1 else { return nil }
        let p = Int(((now - before) / before * 100).rounded())
        return p == 0 ? "same as" : (p > 0 ? "↑ \(p)% vs" : "↓ \(-p)% vs")
    }
}
