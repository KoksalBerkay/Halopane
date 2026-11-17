import Combine
import Foundation
import SpatialMath
import WebKit

/// Ad blocking lists, site exceptions and backups, compiled into WebKit content rules.
final class AdBlockingStore: ObservableObject {
    typealias Conversion = ContentRuleConversion
    typealias Failure = Conversion.Failure

    /// One list: added from a file, an address, or typed in the rule editor.
    struct Source: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case file, url, editor }
        var id = UUID()
        var name: String
        var kind: Kind
        var address: URL? = nil
        var snapshot: Data
        var enabled = true
        var updated = Date()
        var revision = UUID()
        var count = 0
        var skipped = 0
        var exceptions = 0
        var examples: [Conversion.Example] = []
        var indexKey: String { "Halopane-Rules-v1-" + revision.uuidString }
    }

    /// Everything a settings backup contains.
    struct Backup: Codable {
        var version = 1
        var bundledEnabled = true
        var masterEnabled = true
        var sites: [String] = []
        var sources: [Source] = []
    }

    static let backupLimit = 96 * 1024 * 1024
    private static let snapshotBudget = 64 * 1024 * 1024
    static let exceptionNotice =
        "Exceptions only apply to rules in this list. To stop blocking on a whole site, use the site switch."

    @Published private(set) var state = Backup()
    @Published private(set) var busy: String?
    @Published private(set) var message: String?
    @Published private(set) var lastImport: Source?
    @Published private(set) var unavailable = Set<UUID>()
    private var compiled: [UUID: WKContentRuleList] = [:]
    var onChange: (() -> Void)?
    var onFailure: (() -> Void)?
    private let storage: URL

    init(storage: URL? = nil) {
        self.storage =
            storage
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halopane/AdBlocking", isDirectory: true).appendingPathComponent("settings.json")
        state.sites = UserDefaults.standard.stringArray(forKey: "viture.browser.adExceptions") ?? []
        state.masterEnabled = UserDefaults.standard.object(forKey: "viture.browser.ads") as? Bool ?? true
    }

    var editor: Source? {
        state.sources.first { $0.kind == .editor }
    }
    var userSources: [Source] {
        state.sources.filter { $0.kind != .editor }
    }
    var activeLists: [WKContentRuleList] {
        state.sources.compactMap { $0.enabled ? compiled[$0.id] : nil }
    }

    var report: String {
        let bundled = "Bundled ad blocking: " + (state.bundledEnabled ? "enabled" : "off")
        let rows = state.sources.enumerated().map { index, source in
            let status =
                unavailable.contains(source.id)
                ? "unavailable" : !source.enabled ? "off" : compiled[source.id] == nil ? "not loaded" : "active"
            return
                """
                Ad source \(index + 1) (\(source.kind.rawValue)): \(source.count) rules, \(source.skipped) skipped, \
                \(source.exceptions) exceptions; \(status)
                """
        }
        return ([bundled, "Site exceptions: \(state.sites.count)"] + rows).joined(separator: "\n")
    }

    @MainActor func load() async {
        guard busy == nil, FileManager.default.fileExists(atPath: storage.path) else {
            return
        }
        busy = "Loading saved lists…"
        defer {
            busy = nil
        }
        do {
            let saved = try await Task.detached(priority: .utility) { [storage] in
                let data = try Self.readFile(storage, limit: Self.backupLimit, scope: false)
                return try Self.decodeBackup(data)
            }.value
            state = saved
            onChange?()
            for source in saved.sources where source.enabled {
                do {
                    let encoded = try await Self.encode(source)
                    compiled[source.id] = try await Self.compile(identifier: source.indexKey, json: encoded.json)
                    onChange?()
                } catch {
                    unavailable.insert(source.id)
                }
            }
            if !unavailable.isEmpty {
                failure("Some saved ad lists could not load. Other lists still work.")
            }
        } catch {
            failure("Ad blocking settings could not load. The bundled list is still available.")
        }
    }

    private func failure(_ text: String) {
        message = text
        onFailure?()
    }

    @MainActor private func save(_ next: Backup) async throws {
        try Self.validate(next)
        do {
            try await Task.detached(priority: .utility) { [storage] in
                try FileManager.default.createDirectory(
                    at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: storage, options: .atomic)
            }.value
        } catch {
            throw Failure.storage
        }
        state = next
    }

    @MainActor private func mutate(_ change: (inout Backup) -> Void) async {
        guard busy == nil else {
            return
        }
        busy = "Saving settings…"
        defer {
            busy = nil
        }
        var next = state
        change(&next)
        do {
            try await save(next)
            onChange?()
        } catch {
            failure(error.localizedDescription)
        }
    }

    @MainActor func setBundledEnabled(_ enabled: Bool) async {
        await mutate {
            $0.bundledEnabled = enabled
        }
    }
    @MainActor func setMasterEnabled(_ enabled: Bool) async {
        if enabled != state.masterEnabled {
            await mutate {
                $0.masterEnabled = enabled
            }
        }
    }

    @MainActor func toggleSite(_ host: String) async {
        await mutate { state in
            if state.sites.contains(host) {
                state.sites.removeAll { $0 == host }
            } else if Conversion.validHost(host) {
                state.sites.append(host)
                state.sites.sort()
            }
        }
    }

    @MainActor func removeSites(_ hosts: Set<String>) async {
        await mutate {
            $0.sites.removeAll(where: hosts.contains)
        }
    }

    @MainActor func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard let source = state.sources.first(where: { $0.id == id }), source.enabled != enabled else {
            return
        }
        if !enabled || compiled[id] != nil {
            await mutate { state in
                state.sources = state.sources.map { item in
                    var item = item
                    if item.id == id {
                        item.enabled = enabled
                    }
                    return item
                }
            }
        } else {
            await perform("Compiling list…") {
                let encoded = try await Self.encode(source)
                let list = try await Self.compile(identifier: source.indexKey, json: encoded.json)
                var next = self.state
                guard let index = next.sources.firstIndex(where: { $0.id == id }) else {
                    return
                }
                next.sources[index].enabled = true
                try await self.save(next)
                self.compiled[id] = list
                self.unavailable.remove(id)
                self.onChange?()
            }
        }
    }

    @MainActor func remove(_ id: UUID) async {
        guard busy == nil else {
            return
        }
        busy = "Removing list…"
        defer {
            busy = nil
        }
        guard let source = state.sources.first(where: { $0.id == id }) else {
            return
        }
        var next = state
        next.sources.removeAll { $0.id == id }
        do {
            try await save(next)
            compiled[id] = nil
            unavailable.remove(id)
            onChange?()
            Self.purge([source.indexKey])
        } catch {
            failure(error.localizedDescription)
        }
    }

    @MainActor func reset() async {
        guard busy == nil else {
            return
        }
        busy = "Resetting lists…"
        defer {
            busy = nil
        }
        let keys = state.sources.map(\.indexKey)
        do {
            try await save(Backup())
            compiled.removeAll()
            unavailable.removeAll()
            lastImport = nil
            onChange?()
            Self.purge(keys)
        } catch {
            failure(error.localizedDescription)
        }
    }

    @MainActor func addFile(_ url: URL) async {
        await perform("Reading file…") {
            guard self.userSources.count < Conversion.sourceLimit else {
                throw Failure.sourceLimit
            }
            let data = try await Task.detached(priority: .utility) {
                try Self.readFile(url, limit: Conversion.byteLimit)
            }.value
            try await self.install(
                .init(
                    name: String(url.deletingPathExtension().lastPathComponent.prefix(100)), kind: .file, snapshot: data
                ))
        }
    }

    @MainActor func addURL(_ text: String) async {
        await perform("Downloading list…") {
            guard self.userSources.count < Conversion.sourceLimit else {
                throw Failure.sourceLimit
            }
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), Self.validAddress(url)
            else {
                throw Failure.transport
            }
            let data = try await Self.download(url)
            try await self.install(.init(name: url.host ?? "HTTPS list", kind: .url, address: url, snapshot: data))
        }
    }

    @MainActor func update(_ old: Source) async {
        guard old.kind == .url, let url = old.address else {
            return
        }
        await perform("Updating list…") {
            let data = try await Self.download(url)
            var source = old
            source.snapshot = data
            try await self.install(source)
        }
    }

    @MainActor func saveEditor(_ text: String) async {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let editor {
                await remove(editor.id)
            }
            return
        }
        await perform("Compiling your rules…") {
            guard Conversion.editorExamples(text).isEmpty else {
                throw Failure.compile
            }
            var source = self.editor ?? Source(name: "My rules", kind: .editor, snapshot: Data())
            source.snapshot = Data(text.utf8)
            try await self.install(source)
        }
    }

    func export() throws -> Data {
        try JSONEncoder().encode(state)
    }

    @MainActor func restore(_ url: URL) async {
        await perform("Reading backup…") {
            var next = try await Task.detached(priority: .utility) {
                try Self.decodeBackup(Self.readFile(url, limit: Self.backupLimit))
            }.value
            let old = self.state.sources.map(\.indexKey)
            var pending = [UUID: WKContentRuleList]()
            var newKeys = [String]()
            do {
                for i in next.sources.indices {
                    next.sources[i].revision = UUID()
                    let source = next.sources[i]
                    self.busy = "Compiling list \(i + 1) of \(next.sources.count)…"
                    let encoded = try await Self.encode(source)
                    self.copyStats(encoded.result, to: &next.sources[i])
                    pending[source.id] = try await Self.compile(identifier: source.indexKey, json: encoded.json)
                    newKeys.append(source.indexKey)
                }
                try await self.save(next)
                self.compiled = pending
                self.unavailable.removeAll()
                self.onChange?()
                Self.purge(old)
                let rules = next.sources.reduce(0) { $0 + $1.count }
                let skipped = next.sources.reduce(0) { $0 + $1.skipped }
                let exceptions = next.sources.reduce(0) { $0 + $1.exceptions }
                self.message =
                    """
                    Lists restored: \(next.sources.count). Rules added: \(rules). Skipped: \(skipped). List-only \
                    exceptions: \(exceptions).
                    """
            } catch {
                Self.purge(newKeys)
                throw error
            }
        }
    }

    @MainActor private func install(_ input: Source) async throws {
        var source = input
        source.revision = UUID()
        source.updated = Date()
        busy = "Converting rules…"
        let encoded = try await Self.encode(source)
        copyStats(encoded.result, to: &source)
        var next = state
        let old: Source?
        if let i = next.sources.firstIndex(where: { $0.id == source.id }) {
            old = next.sources[i]
            source.enabled = old?.enabled ?? true
            next.sources[i] = source
        } else {
            old = nil
            next.sources.append(source)
        }
        try Self.validate(next)
        busy = "Compiling in WebKit…"
        let list = try await Self.compile(identifier: source.indexKey, json: encoded.json)
        // Site changes made in the browser while the compiler was busy survive.
        next.sites = state.sites
        next.masterEnabled = state.masterEnabled
        next.bundledEnabled = state.bundledEnabled
        do {
            try await save(next)
        } catch {
            Self.purge([source.indexKey])
            throw error
        }
        compiled[source.id] = list
        unavailable.remove(source.id)
        onChange?()
        if let old {
            Self.purge([old.indexKey])
        }
        lastImport = source
        message =
            """
            Rules added: \(source.count). Skipped as unsupported: \(source.skipped). List-only exceptions: \
            \(source.exceptions).
            """
    }

    private func copyStats(_ result: Conversion.Result, to source: inout Source) {
        source.count = result.entries.count
        source.skipped = result.skipped
        source.exceptions = result.exceptions
        source.examples = result.examples
    }

    @MainActor private func perform(_ progress: String, _ work: () async throws -> Void) async {
        guard busy == nil else {
            return
        }
        busy = progress
        message = nil
        lastImport = nil
        defer {
            busy = nil
        }
        do {
            try await work()
        } catch {
            failure(
                (error as? Failure)?.localizedDescription
                    ?? "The item could not be read. Previous rules are still active.")
        }
    }

    private static func encode(_ source: Source) async throws -> (result: Conversion.Result, json: String) {
        try await Task.detached(priority: .utility) {
            let result = try Conversion.convert(source.snapshot)
            guard !result.entries.isEmpty else {
                throw Failure.empty
            }
            return (result, String(decoding: try result.json(), as: UTF8.self))
        }.value
    }

    static func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw Failure.compile
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
                        compiled, _ in
                        if let compiled {
                            continuation.resume(returning: compiled)
                        } else {
                            continuation.resume(throwing: Failure.compile)
                        }
                    }
                }
            }
        }
    }

    private static func purge(_ identifiers: [String]) {
        let store = WKContentRuleListStore.default()
        for key in identifiers {
            store?.removeContentRuleList(forIdentifier: key) { _ in }
        }
    }

    private static func validate(_ backup: Backup) throws {
        guard backup.version == 1, Set(backup.sources.map(\.id)).count == backup.sources.count,
            backup.sources.filter({ $0.kind == .editor }).count <= 1, backup.sites.count <= 1000,
            backup.sites.allSatisfy(Conversion.validHost),
            backup.sources.allSatisfy({ item in
                (item.kind == .url ? item.address.map(validAddress) == true : item.address == nil) && !item.name.isEmpty
                    && item.name.count <= 100
            })
        else {
            throw Failure.invalidBackup
        }
        guard backup.sources.filter({ $0.kind != .editor }).count <= Conversion.sourceLimit else {
            throw Failure.sourceLimit
        }
        guard backup.sources.allSatisfy({ $0.snapshot.count <= Conversion.byteLimit }),
            backup.sources.reduce(0, { $0 + $1.snapshot.count }) <= snapshotBudget
        else {
            throw Failure.oversized
        }
    }

    private static func decodeBackup(_ data: Data) throws -> Backup {
        guard let result = try? JSONDecoder().decode(Backup.self, from: data) else {
            throw Failure.invalidBackup
        }
        try validate(result)
        return result
    }

    private static func readFile(_ url: URL, limit: Int, scope: Bool = true) throws -> Data {
        let granted = scope && url.startAccessingSecurityScopedResource()
        defer {
            if granted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let meta = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard meta.isRegularFile == true else {
            throw Failure.storage
        }
        if let count = meta.fileSize, count > limit {
            throw Failure.oversized
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw Failure.oversized
        }
        return data
    }

    /// Rejects redirects to addresses that are not allowed list sources.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url.map(AdBlockingStore.validAddress) == true ? request : nil)
        }
    }

    private static func validAddress(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func download(_ url: URL) async throws -> Data {
        guard validAddress(url) else {
            throw Failure.transport
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }
        do {
            let (stream, response) = try await session.bytes(from: url)
            defer {
                stream.task.cancel()
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                http.url.map(validAddress) == true,
                ["text/plain", "application/json", "text/json", "application/octet-stream"].contains(
                    http.mimeType?.lowercased() ?? "application/octet-stream")
            else {
                throw Failure.transport
            }
            if http.expectedContentLength > Int64(Conversion.byteLimit) {
                throw Failure.oversized
            }
            var data = Data()
            for try await byte in stream {
                guard data.count < Conversion.byteLimit else {
                    throw Failure.oversized
                }
                data.append(byte)
            }
            return data
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.transport
        }
    }
}
