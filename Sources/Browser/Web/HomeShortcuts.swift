import Combine
import CryptoKit
import Foundation
import Network
import WebKit

/// One tile on the Home page.
struct HomeShortcut: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var group: String
    var icon: String?
    var monogram: String?

    static var blank: Self {
        Self(id: UUID().uuidString, name: "", url: "", group: "Saved", icon: nil, monogram: nil)
    }

    var fields: [String: String] {
        [
            "name": name, "url": url, "group": group, "icon": icon ?? "",
            "monogram": monogram ?? String(name.prefix(1)).uppercased()
        ]
    }
}

/// The Home page shortcuts: saved order, groups and icons.
final class HomeShortcutStore: ObservableObject {
    @Published private(set) var items: [HomeShortcut] = []
    @Published private(set) var canUndo = false
    @Published private(set) var error: String?
    private var lastItems: [HomeShortcut]?
    private var iconTasks: [String: Task<Void, Never>] = [:]
    private struct Layout: Codable {
        let version: Int
        let items: [HomeShortcut]
    }
    private static let defaults: [HomeShortcut] = {
        struct Seed: Decodable { let name: String, url: String, group: String, icon: String?, monogram: String? }
        guard let url = Bundle.main.url(forResource: "home-sites", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let seeds = try? JSONDecoder().decode([Seed].self, from: data)
        else {
            return []
        }
        return seeds.map {
            HomeShortcut(
                id: "default:" + $0.url, name: $0.name, url: $0.url, group: $0.group, icon: $0.icon,
                monogram: $0.monogram)
        }
    }()
    private let file: URL
    private let cacheFile: URL
    private struct CachedIcon: Codable {
        var icon: String
        var updated: Date
    }
    private var defaultCache: [String: CachedIcon] = [:]
    private let iconConnection = NWPathMonitor()
    private var defaultFetches = Set<String>()
    private var lastAttempt: [String: Date] = [:]

    init(file: URL? = nil) {
        self.file =
            file
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VitureHome", isDirectory: true).appendingPathComponent("layout.json")
        cacheFile = self.file.deletingLastPathComponent().appendingPathComponent("default-icons-v1.json")
        if let data = try? Data(contentsOf: cacheFile) {
            defaultCache = (try? JSONDecoder().decode([String: CachedIcon].self, from: data)) ?? [:]
        }

        let file = self.file
        var layout = Self.defaults
        if FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file),
                let saved = try? JSONDecoder().decode(Layout.self, from: data), saved.version == 1
            {
                layout = saved.items
            } else {
                let backup = file.deletingPathExtension().appendingPathExtension("backup-\(UUID().uuidString).json")
                try? FileManager.default.copyItem(at: file, to: backup)
                error = "Saved Home layout could not be read. Showing defaults."
            }
        }
        items = applyingDefaults(to: layout)
        iconConnection.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else {
                return
            }
            Task { @MainActor [weak self] in
                self?.warmDefaultIcons()
            }
        }
        iconConnection.start(queue: DispatchQueue(label: "Halopane.DefaultIcons", qos: .utility))
    }

    deinit {
        iconConnection.cancel()
    }

    private func applyingDefaults(to input: [HomeShortcut]) -> [HomeShortcut] {
        input.map { item in
            var item = item
            if let icon = Self.bundledIcon(for: item.url) {
                item.icon = icon
            } else if item.id == "default:" + item.url, item.icon == nil {
                item.icon = defaultCache[item.url]?.icon
            }
            return item
        }
    }

    @MainActor private func warmDefaultIcons() {
        let now = Date()
        for seed in Self.defaults where seed.icon == nil {
            let address = seed.url
            guard let url = URL(string: address), !defaultFetches.contains(address),
                now.timeIntervalSince(lastAttempt[address] ?? .distantPast) > 900,
                now.timeIntervalSince(defaultCache[address]?.updated ?? .distantPast) > 45 * 24 * 3600
            else {
                continue
            }
            defaultFetches.insert(address)
            lastAttempt[address] = now
            Task { @MainActor [weak self] in
                let icon = await HomeFavicon.load(for: url, declared: HomeFavicon.defaultIconCandidates(for: url))
                guard let self else {
                    return
                }
                self.defaultFetches.remove(address)
                guard let icon else {
                    return
                }
                self.defaultCache[address] = CachedIcon(icon: icon, updated: Date())
                let cache = self.defaultCache, file = self.cacheFile
                // Serialize these small atomic writes on the main actor to avoid
                // an older download snapshot replacing a newer completion.
                if let encoded = try? JSONEncoder().encode(cache) {
                    try? FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? encoded.write(to: file, options: .atomic)
                }
                let refreshed = self.items.map { item -> HomeShortcut in
                    guard item.id == "default:" + address, item.url == address else {
                        return item
                    }
                    var item = item
                    item.icon = icon
                    return item
                }
                self.items = refreshed
                if let previous = self.lastItems,
                    let index = previous.firstIndex(where: { $0.id == "default:" + address && $0.url == address })
                {
                    self.lastItems?[index].icon = icon
                }
            }
        }
    }

    private static func bundledIcon(for address: String) -> String? {
        func host(_ address: String) -> String? {
            guard let host = URL(string: address)?.host?.lowercased() else {
                return nil
            }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        guard let target = host(address) else {
            return nil
        }
        return defaults.first { host($0.url) == target }?.icon
    }

    var groups: [String] {
        var seen = Set<String>()
        return items.map(\.group).filter { seen.insert($0).inserted }
    }
    func add(title: String, address: String, group: String, declaredIcons: [URL] = []) -> Bool {
        guard !items.contains(where: { $0.url == address }) else {
            return false
        }
        var item = HomeShortcut.blank
        item.name =
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? URL(string: address)?.host ?? address : title
        item.url = address
        item.group = group
        return update(item, declaredIcons: declaredIcons)
    }
    func update(_ input: HomeShortcut, declaredIcons: [URL] = []) -> Bool {
        var item = input
        let raw = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = raw.contains("://") ? raw : "https://" + raw
        guard var parts = URLComponents(string: destination), let url = parts.url,
            url.host?.contains(".") == true, BrowserDestination.isWebURL(url),
            parts.user == nil, parts.password == nil,
            !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        parts.fragment = nil
        item.url = parts.url?.absoluteString ?? url.absoluteString
        item.name = String(item.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let group = String(item.group.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        item.group =
            groups.first { $0.caseInsensitiveCompare(group) == .orderedSame } ?? (group.isEmpty ? "Saved" : group)
        var next = items
        if let index = next.firstIndex(where: { $0.id == item.id }) {
            if URL(string: next[index].url)?.host != URL(string: item.url)?.host {
                item.icon = Self.bundledIcon(for: item.url)
                item.monogram = nil
            }
            if item.group == next[index].group {
                next[index] = item
            } else {
                next.remove(at: index)
                let last = next.lastIndex { $0.group == item.group }
                next.insert(item, at: last.map { $0 + 1 } ?? next.count)
            }
        } else {
            guard next.count < 80 else {
                return false
            }
            item.icon = Self.bundledIcon(for: item.url)
            next.insert(item, at: next.lastIndex { $0.group == item.group }.map { $0 + 1 } ?? next.count)
        }
        guard commit(next) else {
            return false
        }
        if item.icon == nil, let destination = URL(string: item.url) {
            resolveIcon(for: item.id, address: item.url, url: destination, declared: declaredIcons)
        } else {
            iconTasks.removeValue(forKey: item.id)?.cancel()
        }
        return true
    }

    private func resolveIcon(for id: String, address: String, url: URL, declared: [URL]) {
        iconTasks[id]?.cancel()
        iconTasks[id] = Task { @MainActor [weak self] in
            let icon = await HomeFavicon.load(for: url, declared: declared)
            guard !Task.isCancelled, let self else {
                return
            }
            self.iconTasks[id] = nil
            guard let icon,
                let index = self.items.firstIndex(where: { $0.id == id && $0.url == address && $0.icon == nil })
            else {
                return
            }
            var next = self.items
            next[index].icon = icon
            // Background icon resolution must not replace the user's Undo snapshot.
            if self.save(next) {
                self.items = next
                if let prev = self.lastItems?.firstIndex(where: { $0.id == id && $0.url == address }) {
                    self.lastItems?[prev].icon = icon
                }
            }
        }
    }
    func move(group: String, from: IndexSet, to: Int) {
        let indices = items.indices.filter { items[$0].group == group }
        guard !from.isEmpty, from.allSatisfy(indices.indices.contains), (0...indices.count).contains(to) else {
            return
        }
        let list = indices.map { items[$0] }
        let moved = from.map { list[$0] }
        var remaining = list.enumerated().filter { !from.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moved, at: to - from.filter { $0 < to }.count)
        var next = items
        for (index, item) in zip(indices, remaining) {
            next[index] = item
        }
        _ = commit(next)
    }
    func remove(_ id: String) {
        remove([id])
    }
    func remove(_ ids: [String]) {
        _ = commit(items.filter { !ids.contains($0.id) })
    }
    func restoreDefaults() {
        _ = commit(applyingDefaults(to: Self.defaults))
    }
    func undo() {
        if let lastItems, save(lastItems) {
            items = lastItems
            self.lastItems = nil
            canUndo = false
        }
    }
    @discardableResult private func commit(_ next: [HomeShortcut]) -> Bool {
        if next == items {
            return true
        }
        guard save(next) else {
            return false
        }
        lastItems = items
        items = next
        canUndo = true
        return true
    }
    private func save(_ next: [HomeShortcut]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Layout(version: 1, items: next))
            try data.write(to: file, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "Couldn’t save Home shortcuts."
            return false
        }
    }
}
