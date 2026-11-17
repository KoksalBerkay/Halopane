import Combine
import CryptoKit
import Foundation
import Network
import WebKit

/// Loads and compiles the bundled EasyList and EasyPrivacy rules.
final class BrowserContentBlocker: ObservableObject {
    @Published private(set) var status = "Ad blocking is getting ready"
    private(set) var list: WKContentRuleList?
    @Published private(set) var ruleCount = 0
    @Published private(set) var updatedLabel = "date unavailable"

    private(set) var localRules: WKContentRuleList?
    @Published private(set) var localStatus = "Local rules: checking"

    func loadLocal(bundle: Bundle = .main, completion: @escaping () -> Void) {
        guard let url = bundle.url(forResource: "halopane-local-site-rules", withExtension: "json") else {
            localStatus = "Local rules: no file; public rules only."
            completion()
            return
        }
        guard let data = try? Data(contentsOf: url), let json = String(data: data, encoding: .utf8),
            let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
            !rules.isEmpty, let store = WKContentRuleListStore.default()
        else {
            localStatus = "Local rules: unreadable or malformed; public rules only."
            completion()
            return
        }
        let digest = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let identifier = "Halopane-Local-" + digest
        let finish: (WKContentRuleList?) -> Void = { [weak self] list in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.localRules = list
                self.localStatus =
                    list == nil ? "Local rules: WebKit rejected the file; public rules only." : "Local rules: loaded."
                completion()
            }
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                finish(list)
            } else {
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                    finish(list)
                }
            }
        }
    }

    func load(bundle: Bundle = .main, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let metaURL = bundle.url(forResource: "content-rules-info", withExtension: "json"),
                let metadata = try? Data(contentsOf: metaURL),
                let info = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any],
                let identifier = info["identifier"] as? String, let count = info["rules"] as? Int,
                let rulesURL = bundle.url(forResource: "content-rules", withExtension: "json"),
                let rules = try? String(contentsOf: rulesURL, encoding: .utf8)
            else {
                DispatchQueue.main.async {
                    self.status = "Ad blocking unavailable: bundled rules missing"
                    completion()
                }
                return
            }
            DispatchQueue.main.async {
                self.ruleCount = count
                let sources = info["sources"] as? [[String: String]] ?? []
                if let version = sources.compactMap({ $0["version"] }).max(), version.count >= 8 {
                    let digits = Array(version)
                    self.updatedLabel =
                        String(digits[0..<4]) + "-" + String(digits[4..<6]) + "-" + String(digits[6..<8])
                }
                let store = WKContentRuleListStore.default()
                let start = Date()
                let finish: (WKContentRuleList?, Error?, Bool) -> Void = { list, error, cached in
                    DispatchQueue.main.async {
                        self.list = list
                        if list != nil {
                            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                            self.status =
                                """
                                Ad blocking: \(identifier), \(count) rules, \(cached ? "loaded" : "compiled") in \
                                \(elapsed) ms
                                """
                        } else {
                            self.status = "Ad blocking unavailable: bundled rules did not compile."
                        }
                        completion()
                    }
                }
                store?.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                    if let list {
                        finish(list, nil, true)
                    } else {
                        store?.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) {
                            finish($0, $1, false)
                        }
                    }
                }
                if store == nil {
                    finish(nil, nil, false)
                }
            }
        }
    }
}
