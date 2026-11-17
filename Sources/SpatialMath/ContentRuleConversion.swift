import Foundation

/// Converts Adblock Plus rules into WebKit content blocker rules.
public enum ContentRuleConversion {
    public static let byteLimit = 16 * 1024 * 1024
    public static let ruleLimit = 150_000
    public static let sourceLimit = 10
    /// One WebKit content blocker rule.
    public struct Entry: Codable, Equatable {
        public var trigger: Trigger
        public var action: Action
        public struct Trigger: Codable, Equatable {
            public var filter: String
            public var types: [String]? = nil
            public var load: [String]? = nil
            public var include: [String]? = nil
            public var exclude: [String]? = nil
            public var caseSensitive: Bool? = nil
            enum CodingKeys: String, CodingKey {
                case filter = "url-filter", types = "resource-type", load = "load-type"
                case include = "if-domain", exclude = "unless-domain", caseSensitive = "url-filter-is-case-sensitive"
            }
        }
        public struct Action: Codable, Equatable {
            public var type: String
            public var selector: String? = nil
        }
    }
    /// A skipped or invalid line, shown to the user.
    public struct Example: Codable, Equatable {
        public let line: Int
        public let text: String
        public let reason: String
        public init(line: Int, text: String, reason: String) {
            self.line = line
            self.text = text
            self.reason = reason
        }
    }
    /// Converted rules plus counts of what was skipped.
    public struct Result {
        public var entries: [Entry] = []
        public var skipped = 0
        public var exceptions = 0
        public var examples: [Example] = []
        public func json() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(entries)
        }
    }
    public enum Failure: LocalizedError {
        case oversized, tooMany, encoding, invalidJSON, empty, invalidBackup, sourceLimit, transport, storage, compile
        public var errorDescription: String? {
            switch self {
            case .oversized:
                return "A list exceeds the 16 MiB input limit."
            case .tooMany:
                return "A list exceeds 150,000 rules. No rules were cut."
            case .encoding:
                return "Choose UTF-8 filter text or WebKit JSON."
            case .invalidJSON:
                return "The WebKit list must be a JSON array of rule objects."
            case .empty:
                return "This list has no supported rules."
            case .invalidBackup:
                return "This is not a supported Halopane ad blocking backup."
            case .sourceLimit:
                return "Halopane can store up to 10 added lists."
            case .transport:
                return "The HTTPS download failed, timed out or returned an unsupported file."
            case .storage:
                return "Ad blocking settings could not be saved."
            case .compile:
                return "WebKit rejected this list. Previous rules are still active."
            }
        }
    }

    private static let hostPattern = #"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+ "#
        .trimmingCharacters(in: .whitespaces)
    private static let hostOnly = try! NSRegularExpression(pattern: "^" + hostPattern + "$")
    private static let network = try! NSRegularExpression(
        pattern: #"^\|\|("# + hostPattern + #")(\^|/[a-zA-Z0-9_./%-]+)$"#)
    private static let legacyHost = try! NSRegularExpression(
        pattern: #"^\|\|("# + hostPattern + #")\^(?:\$third-party)?$"#)
    private static let adPath = try! NSRegularExpression(
        pattern:
            #"(?:^|[/_.-])(?:ads?|adserver|advert(?:s|ising)?|preroll|midroll|vast|vmap|ima|adtag|adbreak)(?:$|[/_.-])"#,
        options: .caseInsensitive)
    private static let domains = try! NSRegularExpression(pattern: hostPattern)
    private static let resources = [
        "image": "image", "stylesheet": "style-sheet", "script": "script", "font": "font",
        "xmlhttprequest": "raw", "media": "media", "document": "document"
    ]
    private static let bundledTypes = ["image", "style-sheet", "script", "font", "raw", "media", "svg-document"]

    private static func captures(_ re: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { idx in
            Range(match.range(at: idx), in: text).map { String(text[$0]) } ?? ""
        }
    }
    public static func validHost(_ host: String) -> Bool {
        host.utf8.count <= 253 && host.split(separator: ".").allSatisfy { $0.count <= 63 }
            && captures(hostOnly, host) != nil
    }
    private static func escape(_ value: String) -> String {
        // Only characters possible in validated host and literal path patterns.
        value.replacingOccurrences(of: ".", with: "\\.")
    }
    private static func filters(_ host: String, _ path: String, legacy: Bool = false) -> String {
        func literal(_ value: String) -> String {
            let escaped = escape(value)
            return legacy ? escaped.replacingOccurrences(of: "-", with: "\\-") : escaped
        }
        return "^https?://([a-z0-9-]+\\.)*" + literal(host) + (path == "^" ? "[:/]" : "(:[0-9]+)?" + literal(path))
    }
    private static func scope(_ value: String, separator: Character) -> ([String]?, [String]?)? {
        let list = value.split(separator: separator, omittingEmptySubsequences: false)
        guard !list.isEmpty, list.count <= 128 else {
            return nil
        }
        let positive = list.filter { !$0.hasPrefix("~") }
        guard positive.isEmpty || positive.count == list.count else {
            return nil
        }
        let names = list.map { String($0.dropFirst(positive.isEmpty ? 1 : 0)) }
        guard names.allSatisfy(validHost) else {
            return nil
        }
        let namesWithSubdomains = Array(Set(names)).sorted().map { "*" + $0 }
        return positive.isEmpty ? (nil, namesWithSubdomains) : (namesWithSubdomains, nil)
    }

    enum Disposition { case trivia, rule(Entry), unsupported(String) }
    private static let plainCSS = try! NSRegularExpression(
        pattern: #"^(?:[a-zA-Z_*]|[.#\[])[a-zA-Z0-9_*.#, >+~:()=\[\]'"$|^-]*$"#)
    private static let pseudo = try! NSRegularExpression(pattern: #":([a-z-]+)"#, options: .caseInsensitive)
    // Doubled combinators, empty list items, a trailing combinator, or a bare `.` or `#`.
    private static let brokenSelectorSyntax = #"(?:[>+~]\s*[>+~]|,\s*,|[>+~,]\s*$|[.#](?=[\s.#,>+~]|$))"#

    private static func selectorOK(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.utf8.count <= 2048, captures(plainCSS, selector) != nil,
            selector.range(of: brokenSelectorSyntax, options: .regularExpression) == nil
        else {
            return false
        }
        var stack: [Character] = []
        var quote: Character?
        for c in selector {
            if let q = quote {
                if c == q {
                    quote = nil
                }
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
            case "[", "(":
                stack.append(c)
            case "]":
                if stack.popLast() != "[" {
                    return false
                }
            case ")":
                if stack.popLast() != "(" {
                    return false
                }
            default:
                break
            }
        }
        let allowed = Set([
            "not", "is", "where", "has", "first-child", "last-child", "only-child", "nth-child", "nth-of-type",
            "first-of-type", "last-of-type", "empty", "checked", "disabled", "enabled"
        ])
        guard stack.isEmpty, quote == nil else {
            return false
        }
        return pseudo.matches(in: selector, range: NSRange(location: 0, length: selector.utf16.count)).allSatisfy {
            Range($0.range(at: 1), in: selector).map { allowed.contains(selector[$0].lowercased()) } ?? false
        }
    }
    private static func classify(_ line: String) -> Disposition {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[Adblock") {
            return .trivia
        }
        if trimmed.contains("#@#") {
            return .unsupported("Cosmetic exception")
        }
        if trimmed.contains("#?#") || trimmed.contains("#$#") || trimmed.contains("#%#") || trimmed.contains("##+") {
            return .unsupported("Scriptlet or procedural cosmetic rule")
        }
        if let marker = trimmed.range(of: "##") {
            let selector = String(trimmed[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard selectorOK(selector) else {
                return .unsupported("Invalid or unsupported CSS selector")
            }
            let hosts = String(trimmed[..<marker.lowerBound]).lowercased()
            var entryTrigger = Entry.Trigger(filter: ".*")
            if !hosts.isEmpty {
                guard let (inc, exc) = scope(hosts, separator: ",") else {
                    return .unsupported("Invalid or mixed domain scope")
                }
                entryTrigger.include = inc
                entryTrigger.exclude = exc
            }
            return .rule(Entry(trigger: entryTrigger, action: .init(type: "css-display-none", selector: selector)))
        }
        let exception = trimmed.hasPrefix("@@")
        let rule = exception ? String(trimmed.dropFirst(2)) : trimmed
        let parts = rule.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard let pattern = parts.first, let groups = captures(network, String(pattern).lowercased()),
            validHost(groups[1])
        else {
            return .unsupported("Unsupported URL pattern (use a hostname or literal path)")
        }
        var entryTrigger = Entry.Trigger(filter: filters(groups[1], groups[2]))
        var types = Set<String>()
        if parts.count == 2 {
            for raw in parts[1].split(separator: ",", omittingEmptySubsequences: false) {
                let tag = raw.lowercased()
                if tag == "third-party" {
                    entryTrigger.load = ["third-party"]
                } else if tag == "~third-party" {
                    entryTrigger.load = ["first-party"]
                } else if let kind = resources[tag] {
                    types.insert(kind)
                } else if tag.hasPrefix("domain="), entryTrigger.include == nil, entryTrigger.exclude == nil {
                    guard let (inc, exc) = scope(String(tag.dropFirst(7)), separator: "|") else {
                        return .unsupported("Invalid or mixed domain scope")
                    }
                    entryTrigger.include = inc
                    entryTrigger.exclude = exc
                } else {
                    return .unsupported("Unsupported filter option")
                }
            }
        }
        if !types.isEmpty {
            entryTrigger.types = types.sorted()
        }
        return .rule(Entry(trigger: entryTrigger, action: .init(type: exception ? "ignore-previous-rules" : "block")))
    }

    public static func editorExamples(_ text: String) -> [Example] {
        var errors: [Example] = []
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            if case let .unsupported(reason) = classify(line) {
                errors.append(.init(line: i + 1, text: String(line.prefix(110)), reason: reason))
            }
        }
        return errors
    }

    public static func convert(_ data: Data) throws -> Result {
        guard data.count <= byteLimit else {
            throw Failure.oversized
        }
        guard var input = String(data: data, encoding: .utf8), !input.contains("\0") else {
            throw Failure.encoding
        }
        if input.hasPrefix("\u{FEFF}") {
            input.removeFirst()
        }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
            !input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Adblock")
        {
            return try webKitJSON(Data(input.utf8))
        }
        var result = Result()
        var blocks: [Entry] = [], exceptions: [Entry] = [], cosmetic: [Entry] = []
        func skip(_ index: Int, _ line: String, _ reason: String) {
            result.skipped += 1
            if result.examples.count < 8 {
                result.examples.append(.init(line: index + 1, text: String(line.prefix(110)), reason: reason))
            }
        }
        for (i, line) in input.components(separatedBy: .newlines).enumerated() {
            switch classify(line) {
            case .trivia:
                continue
            case let .unsupported(reason):
                skip(i, line, reason)
            case let .rule(entry):
                switch entry.action.type {
                case "ignore-previous-rules":
                    exceptions.append(entry)
                case "css-display-none":
                    cosmetic.append(entry)
                default:
                    blocks.append(entry)
                }
            }
            if blocks.count + exceptions.count + cosmetic.count > ruleLimit {
                throw Failure.tooMany
            }
        }
        result.entries = blocks + exceptions + cosmetic
        result.exceptions = exceptions.count
        return result
    }

    private static func webKitJSON(_ data: Data) throws -> Result {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw Failure.invalidJSON
        }
        guard raw.count <= ruleLimit else {
            throw Failure.tooMany
        }
        var result = Result()
        let allowedTrigger = Set([
            "url-filter", "resource-type", "load-type", "if-domain", "unless-domain", "url-filter-is-case-sensitive"
        ])
        for (i, rule) in raw.enumerated() {
            if Set(rule.keys) == ["trigger", "action"], let trigger = rule["trigger"] as? [String: Any],
                Set(trigger.keys).isSubset(of: allowedTrigger), let action = rule["action"] as? [String: Any],
                let type = action["type"] as? String,
                ["block", "ignore-previous-rules", "css-display-none", "block-cookies", "make-https"].contains(type),
                Set(action.keys).isSubset(of: ["type", "selector"]),
                (type == "css-display-none"
                    ? (action["selector"] as? String).map(selectorOK) == true : action["selector"] == nil),
                let bytes = try? JSONSerialization.data(withJSONObject: rule),
                let entry = try? JSONDecoder().decode(Entry.self, from: bytes), !entry.trigger.filter.isEmpty,
                !(entry.trigger.include != nil && entry.trigger.exclude != nil)
            {
                result.entries.append(entry)
                if type == "ignore-previous-rules" {
                    result.exceptions += 1
                }
            } else {
                result.skipped += 1
                if result.examples.count < 8 {
                    result.examples.append(
                        .init(
                            line: i + 1, text: "JSON rule \(i+1)", reason: "Invalid rule or unsupported trigger/action")
                    )
                }
            }
        }
        return result
    }

    /// Stable port of the original build profile. It intentionally keeps the
    /// conservative third-party subset and exact historical ordering.
    public static func bundled(_ texts: [String]) -> [Entry] {
        struct Path: Hashable {
            let host: String
            let path: String
            let types: [String]
        }
        var blocked = Set<String>(), allowed = Set<String>(), paths = Set<Path>()
        for text in texts {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                if line.hasPrefix("@@") {
                    let lower = line.lowercased()
                    for m in domains.matches(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) {
                        if let matchRange = Range(m.range, in: lower) {
                            allowed.insert(String(lower[matchRange]))
                        }
                    }
                } else if let parts = captures(legacyHost, line) {
                    blocked.insert(parts[1])
                } else {
                    let split = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let pattern = split.first, let groups = captures(network, String(pattern)), groups[2] != "^",
                        captures(adPath, groups[2]) != nil
                    else {
                        continue
                    }
                    let options = split.count == 2 ? Set(split[1].split(separator: ",").map(String.init)) : []
                    guard options.allSatisfy({ $0 == "third-party" || ($0 != "document" && resources[$0] != nil) })
                    else {
                        continue
                    }
                    paths.insert(
                        .init(host: groups[1], path: groups[2], types: options.compactMap { resources[$0] }.sorted()))
                }
            }
        }
        func suffixes(_ host: String) -> [String] {
            var parts = host.split(separator: ".")
            var result = [String]()
            while parts.count > 1 {
                result.append(parts.joined(separator: "."))
                parts.removeFirst()
            }
            return result
        }
        let protected = Set(allowed.flatMap(suffixes))
        let keep = blocked.filter { !protected.contains($0) && allowed.isDisjoint(with: suffixes($0)) }
            .sorted { a, b in
                let da = a.filter { $0 == "." }.count, db = b.filter { $0 == "." }.count
                return da == db ? a < b : da > db
            }.prefix(45_000)
        func entry(_ host: String, _ path: String, _ types: [String]) -> Entry {
            Entry(
                trigger: .init(filter: filters(host, path, legacy: true), types: types, load: ["third-party"]),
                action: .init(type: "block"))
        }
        var output = keep.map { entry($0, "^", bundledTypes) }
        let covered = Set(keep).union(allowed)
        for pathRule in paths.sorted(by: { a, b in
            if a.host != b.host {
                return a.host < b.host
            }
            if a.path != b.path {
                return a.path < b.path
            }
            return a.types.lexicographicallyPrecedes(b.types)
        }) where !protected.contains(pathRule.host) && covered.isDisjoint(with: suffixes(pathRule.host)) {
            output.append(
                entry(pathRule.host, pathRule.path, pathRule.types.isEmpty ? bundledTypes : pathRule.types))
            if output.count == 49_000 {
                break
            }
        }
        return output
    }
}
