import Foundation

/// Reads Xcode's build logs: `DerivedData/<Project>-<hash>/Logs/Build/LogStoreManifest.plist` lists
/// every build with its start, end and result; each `<id>.xcactivitylog` next to it holds the
/// per-target detail. Read-only.
enum XcodeLog {
    struct Entry: Equatable {
        var id: String
        var fileName: String
        var title: String
        var scheme: String?
        var start: Date
        var stop: Date
        var succeeded: Bool?
    }

    /// DerivedData, honouring a custom location set in Xcode's preferences.
    static func derivedData(home: URL) -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    /// "MyApp-bcdefghijklmnop" → "MyApp".
    static func projectName(derivedDataFolder name: String) -> String {
        guard let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) > 10 else { return name }
        return String(name[..<dash])
    }

    static func manifest(_ data: Data) -> [Entry] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let logs = plist["logs"] as? [String: Any] else { return [] }
        return logs.compactMap { id, value in
            guard let log = value as? [String: Any],
                  let file = log["fileName"] as? String,
                  let start = log["timeStartedRecording"] as? Double,
                  let stop = log["timeStoppedRecording"] as? Double, stop >= start else { return nil }
            let title = log["title"] as? String ?? log["signature"] as? String ?? "Build"
            // Cleans aren't builds.
            guard !title.hasPrefix("Clean") else { return nil }
            var succeeded: Bool?
            if let observable = log["primaryObservable"] as? [String: Any] {
                switch observable["highLevelStatus"] as? String {
                case "S", "W": succeeded = true
                case "E": succeeded = false
                default: break
                }
                if let errors = observable["totalNumberOfErrors"] as? Int, errors > 0 { succeeded = false }
            }
            return Entry(id: id, fileName: file, title: title,
                         scheme: log["schemeIdentifier-schemeName"] as? String,
                         start: Date(timeIntervalSinceReferenceDate: start),
                         stop: Date(timeIntervalSinceReferenceDate: stop),
                         succeeded: succeeded)
        }
    }

    // MARK: Per-target times

    /// The targets built in one `.xcactivitylog`, slowest first.
    static func targets(logData: Data) -> [TargetTime] {
        guard let raw = Gzip.decompress(logData) ?? (logData.starts(with: Array("SLF".utf8)) ? logData : nil),
              let tokens = SLF.tokens(raw) else { return [] }
        var times: [String: TimeInterval] = [:]
        for section in SLF.sections(tokens) where section.domain.contains("IDEActivityLogDomainType.target") {
            let name = targetName(section.title)
            times[name, default: 0] += max(0, section.stop - section.start)
        }
        return times.map { TargetTime(name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// "Build target MyKit of project MyApp with configuration Debug" → "MyKit".
    static func targetName(_ title: String) -> String {
        var name = title
        for prefix in ["Build target ", "Check dependencies for ", "Analyze target "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if let r = name.range(of: " of project ") { name = String(name[..<r.lowerBound]) }
        if let r = name.range(of: " with configuration ") { name = String(name[..<r.lowerBound]) }
        return name
    }
}

/// Xcode's SLF0 log serialization: a stream of tokens, each a payload followed by a type character.
/// `12#` integer, `<hex>^` double, `-` null, `5"hello` string, `3(` array of 3, `22%Name` class
/// name, `1@` instance of the first class name.
enum SLF {
    enum Token: Equatable {
        case int(UInt64)
        case double(Double)
        case string(String)
        case null
        case array(Int)
        case className(String)
        case instance(Int)
    }

    struct Section: Equatable {
        var domain: String
        var title: String
        /// Seconds since 2001-01-01.
        var start: Double
        var stop: Double
    }

    static func tokens(_ data: Data) -> [Token]? {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Array("SLF0".utf8)) else { return nil }
        var tokens: [Token] = []
        tokens.reserveCapacity(bytes.count / 8)
        var i = 4
        while i < bytes.count {
            let payloadStart = i
            while i < bytes.count, isPayload(bytes[i]) { i += 1 }
            guard i < bytes.count else { break }
            let payload = String(decoding: bytes[payloadStart..<i], as: UTF8.self)
            let type = bytes[i]
            i += 1
            switch type {
            case UInt8(ascii: "#"):
                guard let n = UInt64(payload) else { return tokens }
                tokens.append(.int(n))
            case UInt8(ascii: "^"):
                // The hex digits are the double's bytes, little-endian.
                guard let bits = UInt64(payload, radix: 16) else { return tokens }
                tokens.append(.double(Double(bitPattern: bits.byteSwapped)))
            case UInt8(ascii: "-"):
                tokens.append(.null)
            case UInt8(ascii: "("):
                tokens.append(.array(Int(payload) ?? 0))
            case UInt8(ascii: "@"):
                tokens.append(.instance(Int(payload) ?? 0))
            case UInt8(ascii: "\""), UInt8(ascii: "%"), UInt8(ascii: "*"):
                // Length-prefixed; `*` is JSON in newer logs.
                guard let n = Int(payload), n >= 0, i + n <= bytes.count else { return tokens }
                let text = String(decoding: bytes[i..<i + n], as: UTF8.self)
                i += n
                tokens.append(type == UInt8(ascii: "%") ? .className(text) : .string(text))
            default:
                // Unknown token type: keep what's been read rather than misreading the rest.
                return tokens
            }
        }
        return tokens
    }

    private static func isPayload(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)     // 0-9, a-f
    }

    /// Every log section, at any depth. A section always starts with the same six fields: its type,
    /// domain, title, signature, start and stop time; later fields vary between Xcode versions.
    static func sections(_ tokens: [Token]) -> [Section] {
        var out: [Section] = []
        var i = 0
        while i + 6 < tokens.count {
            defer { i += 1 }
            guard case .instance = tokens[i], case .int = tokens[i + 1],
                  let domain = text(tokens[i + 2]), let title = text(tokens[i + 3]), text(tokens[i + 4]) != nil,
                  case let .double(start) = tokens[i + 5], case let .double(stop) = tokens[i + 6] else { continue }
            out.append(Section(domain: domain, title: title, start: start, stop: stop))
        }
        return out
    }

    private static func text(_ token: Token) -> String? {
        switch token {
        case let .string(s): return s
        case .null: return ""
        default: return nil
        }
    }
}

/// Just enough gzip to open `.xcactivitylog` files: the header is skipped by hand and the DEFLATE
/// body handed to the system's decompressor.
enum Gzip {
    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {                          // FEXTRA
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {     // FNAME, FCOMMENT
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }                 // FHCRC
        guard i < b.count - 8 else { return nil }
        // Apple's "zlib" algorithm is raw DEFLATE, which is what gzip wraps.
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }
}
