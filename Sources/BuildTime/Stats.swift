import Foundation

struct TargetStat: Identifiable, Equatable {
    var source: BuildSource
    var project: String
    var name: String
    var builds: Int
    var total: TimeInterval
    var longest: TimeInterval
    var id: String { "\(source.rawValue)|\(project)|\(name)" }
    var average: TimeInterval { total / Double(max(1, builds)) }
}

struct ProjectStat: Identifiable, Equatable {
    var project: String
    var sources: [BuildSource]
    var builds: Int
    var waited: TimeInterval
    var id: String { project }
}

struct Bucket: Identifiable, Equatable {
    var date: Date
    var source: BuildSource
    var seconds: TimeInterval
    var id: String { "\(date.timeIntervalSince1970)|\(source.rawValue)" }
}

struct Summary {
    var period: Period
    var interval: DateInterval
    var builds: [BuildRecord]
    /// Time at least one build was running. Parallel builds count once, so this is time spent waiting.
    var waited: TimeInterval
    /// Every build's duration added up.
    var total: TimeInterval
    var failed: Int
    /// The whole previous period, and the part of it up to the same point as now.
    var previousWaited: TimeInterval
    var previousSoFar: TimeInterval
    var bySource: [(source: BuildSource, waited: TimeInterval)]
    var projects: [ProjectStat]
    var targets: [TargetStat]
    var buckets: [Bucket]

    var average: TimeInterval { total / Double(max(1, builds.count)) }
    var longest: BuildRecord? { builds.max { $0.duration < $1.duration } }

    init(records: [BuildRecord], period: Period, now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        interval = period.interval(containing: now, calendar: calendar)
        let previous = period.previous(before: now, calendar: calendar)
        let interval = interval
        let builds = records.filter { interval.contains($0.start) && $0.start < interval.end }
            .sorted { $0.start > $1.start }
        self.builds = builds
        waited = Self.union(builds)
        total = builds.reduce(0) { $0 + $1.duration }
        failed = builds.filter { $0.succeeded == false }.count
        let before = records.filter { previous.contains($0.start) && $0.start < previous.end }
        previousWaited = Self.union(before)
        let samepoint = previous.start.addingTimeInterval(now.timeIntervalSince(interval.start))
        previousSoFar = Self.union(before.filter { $0.start < samepoint })

        bySource = BuildSource.allCases.compactMap { s in
            let b = builds.filter { $0.source == s }
            return b.isEmpty ? nil : (source: s, waited: Summary.union(b))
        }

        projects = Dictionary(grouping: builds, by: \.project).map { project, b in
            ProjectStat(project: project, sources: BuildSource.allCases.filter { s in b.contains { $0.source == s } },
                        builds: b.count, waited: Summary.union(b))
        }
        .sorted { $0.waited > $1.waited }

        var targets: [String: TargetStat] = [:]
        for b in builds {
            for t in b.targets where t.seconds >= 0.5 {
                let key = "\(b.source.rawValue)|\(b.project)|\(t.name)"
                var stat = targets[key] ?? TargetStat(source: b.source, project: b.project, name: t.name, builds: 0, total: 0, longest: 0)
                stat.builds += 1
                stat.total += t.seconds
                stat.longest = max(stat.longest, t.seconds)
                targets[key] = stat
            }
        }
        // Slowest per build, not most total time: that's the one worth speeding up.
        self.targets = targets.values.sorted { $0.average > $1.average }

        var buckets: [String: Bucket] = [:]
        for b in builds {
            let day = calendar.dateInterval(of: period.bucket, for: b.start)?.start ?? b.start
            let key = "\(day.timeIntervalSince1970)|\(b.source.rawValue)"
            buckets[key, default: Bucket(date: day, source: b.source, seconds: 0)].seconds += b.duration
        }
        self.buckets = buckets.values.sorted { $0.date < $1.date }
    }

    /// Length of the union of the builds' time spans.
    static func union(_ builds: [BuildRecord]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (start: Date, end: Date)?
        for b in builds.sorted(by: { $0.start < $1.start }) {
            if let c = current, b.start <= c.end {
                current = (c.start, max(c.end, b.end))
            } else {
                if let c = current { total += c.end.timeIntervalSince(c.start) }
                current = (b.start, b.end)
            }
        }
        if let c = current { total += c.end.timeIntervalSince(c.start) }
        return total
    }
}
