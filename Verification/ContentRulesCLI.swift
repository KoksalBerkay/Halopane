import CryptoKit
import Foundation

@main struct ContentRulesCLI {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            FileHandle.standardError.write(
                Data("Usage: convert-content-rules.sh easylist.txt easyprivacy.txt output-directory\n".utf8))
            throw ContentRuleConversion.Failure.storage
        }
        let sourceURLs = args[1...2].map { URL(fileURLWithPath: $0) }
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        var sources = [[String: String]]()
        var contents = [String]()
        for url in sourceURLs {
            let data = try Data(contentsOf: url)
            guard data.count <= ContentRuleConversion.byteLimit, var text = String(data: data, encoding: .utf8) else {
                throw ContentRuleConversion.Failure.encoding
            }
            if text.hasPrefix("\u{FEFF}") {
                text.removeFirst()
            }
            let version =
                text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("! Version: ") }.map {
                    String($0.dropFirst(11))
                } ?? "unknown"
            sources.append([
                "file": url.lastPathComponent, "url": "https://easylist.to/easylist/" + url.lastPathComponent,
                "version": version, "sha256": hex(data)
            ])
            contents.append(text)
        }
        let entries = ContentRuleConversion.bundled(contents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entries)
        let version = String(hex(data).prefix(16))
        let metadata: [String: Any] = [
            "identifier": "Halopane-Easy-1-" + version, "rules": entries.count,
            "pathRules": max(0, entries.count - 45_000), "sources": sources, "license": "CC BY-SA 3.0",
            "licenseURL": "https://creativecommons.org/licenses/by-sa/3.0/"
        ]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("content-rules.json"), options: .atomic)
        try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        .write(to: output.appendingPathComponent("content-rules-info.json"), options: .atomic)
        print("\(entries.count) rules (\(version))")
    }
    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
