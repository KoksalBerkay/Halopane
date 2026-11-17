import Foundation
import WebKit

/// Finds elements on the bundled test page so input checks know where to tap.
enum WebFixtureLocator {
    enum Failure: LocalizedError {
        case missing(String), malformed
        var errorDescription: String? {
            switch self {
            case .missing(let id):
                return "Fixture target missing: " + id
            case .malformed:
                return "Fixture returned invalid coordinates."
            }
        }
    }

    static func locate(_ id: String, in web: WKWebView, completion: @escaping (Result<CGPoint, Error>) -> Void) {
        web.callAsyncJavaScript(
            """
            const element = document.getElementById(id);
            if (!element) {
                return {missing: true};
            }
            element.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'instant'});
            const r = element.getBoundingClientRect();
            return {x: (r.left + r.width / 2) / innerWidth, y: (r.top + r.height / 2) / innerHeight};
            """, arguments: ["id": id], in: nil, in: .page
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                guard let fields = value as? [String: Any] else {
                    completion(.failure(Failure.malformed))
                    return
                }
                if fields["missing"] as? Bool == true {
                    completion(.failure(Failure.missing(id)))
                    return
                }
                guard let x = fields["x"] as? Double, let y = fields["y"] as? Double,
                    (0..<1).contains(x), (0..<1).contains(y)
                else {
                    completion(.failure(Failure.malformed))
                    return
                }
                completion(.success(CGPoint(x: x * web.bounds.width, y: y * web.bounds.height)))
            }
        }
    }
}
