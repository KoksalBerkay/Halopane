import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds and downloads a website icon for a Home page shortcut, as a data URL.
enum HomeFavicon {
    struct Icon {
        let dataURL: String
        let description: String
        let size: Int
        let source: URL?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()
    private static let linkTag = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(
        pattern: #"\s([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)

    static func defaultIconCandidates(for page: URL) -> [URL] {
        let assets: [String: [String]] = [
            "youtube.com": ["https://www.youtube.com/s/desktop/bb2198ae/img/favicon_144x144.png"],
            "google.com": [
                "https://www.gstatic.com/images/branding/product/2x/googleg_48dp.png",
                "https://www.google.com/images/branding/googleg/1x/googleg_standard_color_128dp.png"
            ],
            "www.hbomax.com": [
                "https://cdn.prod.website-files.com/6911e6b4bcc8af690d496a26/6911e6b4bcc8af690d496fc9_small-hboMax-logo.jpg",
                "https://cdn.prod.website-files.com/6911e6b4bcc8af690d496a26/6911e6b4bcc8af690d497038_HBO%20Max_White.jpg"
            ],
            "disneyplus.com": [
                "https://static-assets.bamgrid.com/product/disneyplus/favicons/disPlus-favicon-180x180.7d56f648dc95f591721935193bc827cb.png"
            ],
            "primevideo.com": [
                "https://m.media-amazon.com/images/G/01/digital/video/DVUI/favicons/apple-touch-icon-152x152.png"
            ],
            "xbox.com": [
                "https://assets.play.xbox.com/playxbox/static/media/apple-icon-180.8db22303.png",
                "https://play.xbox.com/assets/favicon-kfvt2gv3.svg"
            ],
            "luna.amazon.com": [
                "https://assets.aboutamazon.com/7a/8e/5e9c4a55462ba17c4f27036f2547/amazon-luna-logo.png"
            ]
        ]
        return (assets[page.host?.lowercased() ?? ""] ?? []).compactMap { URL(string: $0) }
    }

    static func valid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false && url.user == nil
            && url.password == nil
    }

    static func iconLinks(in html: String, base: URL) -> [URL] {
        matches(linkTag, in: html, limit: 100).compactMap { match -> (URL, Int)? in
            guard let range = Range(match.range, in: html) else {
                return nil
            }
            let tag = String(html[range])
            var attrs: [String: String] = [:]
            for field in matches(attribute, in: tag, limit: 20) {
                guard let key = Range(field.range(at: 1), in: tag),
                    let value = (2...4).compactMap({ Range(field.range(at: $0), in: tag) }).first
                else {
                    continue
                }
                attrs[String(tag[key]).lowercased()] = String(tag[value])
            }
            let rel = (attrs["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let touch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard touch || rel.contains("icon"), let href = attrs["href"], !href.isEmpty,
                let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                valid(url)
            else {
                return nil
            }
            let size =
                (attrs["sizes"] ?? "").split(separator: " ").compactMap {
                    Int($0.split(separator: "x").first ?? "")
                }.max() ?? 0
            let vector = url.pathExtension.lowercased() == "svg" || (attrs["sizes"] ?? "").lowercased() == "any"
            return (url, touch ? 1000 + size : (vector ? 900 : min(768, size)))
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String, limit: Int) -> [NSTextCheckingResult] {
        var output: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) { match, _, stop in
            if let match {
                output.append(match)
            }
            if output.count >= limit {
                stop.pointee = true
            }
        }
        return output
    }

    static func load(for page: URL, declared: [URL]) async -> String? {
        await inspectedIcon(for: page, declared: declared)?.dataURL
    }

    static func inspectedIcon(for page: URL, declared: [URL]) async -> Icon? {
        guard valid(page), var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            return nil
        }
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        guard let origin = parts.url else {
            return nil
        }
        var seen = Set<URL>()
        var best: Icon?
        func tryIcons(_ urls: [URL], limit: Int) async -> Bool {
            for url in urls.prefix(limit) where valid(url) && seen.insert(url).inserted {
                guard !Task.isCancelled else {
                    return false
                }
                guard let (bytes, response) = await read(url, limit: 512 * 1024, allowPartial: false),
                    let icon = image(bytes, mime: response.mimeType, source: response.url)
                else {
                    continue
                }
                if best == nil || icon.size > (best?.size ?? 0) {
                    best = icon
                }
                if icon.size >= 96 {
                    return true
                }
            }
            return false
        }
        if await tryIcons(declared, limit: 4) {
            return best
        }
        var base = origin
        var discovered: [URL] = []
        if let (bytes, response) = await read(origin, limit: 192 * 1024, allowPartial: true), let url = response.url {
            base = url
            discovered = iconLinks(in: String(decoding: bytes, as: UTF8.self), base: url)
        }
        if await tryIcons(discovered, limit: 6) {
            return best
        }
        let paths = ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon.ico"]
        let fallback = paths.flatMap { path in
            [base, origin].compactMap { URL(string: path, relativeTo: $0)?.absoluteURL }
        }
        _ = await tryIcons(fallback, limit: 6)
        return best
    }

    private static func read(_ url: URL, limit: Int, allowPartial: Bool) async -> (Data, HTTPURLResponse)? {
        guard !Task.isCancelled, valid(url) else {
            return nil
        }
        do {
            let (stream, response) = try await session.bytes(from: url)
            defer {
                stream.task.cancel()
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let final = http.url, valid(final)
            else {
                return nil
            }
            if !allowPartial, http.expectedContentLength > Int64(limit) {
                return nil
            }
            var data = Data()
            for try await byte in stream {
                if data.count == limit {
                    return allowPartial ? (data, http) : nil
                }
                data.append(byte)
            }
            return (data, http)
        } catch {
            return nil
        }
    }

    static func image(_ data: Data, mime: String?, source origin: URL? = nil) -> Icon? {
        // SVGs are shown only in an img element, where WebKit disables scripts
        // and external loads. Reject large or mislabeled responses.
        if mime == "image/svg+xml", data.count <= 40 * 1024,
            let svg = String(data: data, encoding: .utf8),
            svg.range(of: #"<svg[\s>]"#, options: .regularExpression) != nil
        {
            return Icon(
                dataURL: "data:image/svg+xml;base64," + data.base64EncodedString(), description: "SVG", size: 4096,
                source: origin)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let indexes = 0..<min(16, CGImageSourceGetCount(source))
        func dimensions(_ index: Int) -> (Int, Int) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return (
                properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            )
        }
        guard
            let index = indexes.max(by: {
                min(dimensions($0).0, dimensions($0).1) < min(dimensions($1).0, dimensions($1).1)
            })
        else {
            return nil
        }
        let (width, height) = dimensions(index)
        guard min(width, height) >= 16, max(width, height) <= 4096,
            max(width, height) <= min(width, height) * 3
        else {
            return nil
        }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160
            ] as CFDictionary
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
            return nil
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return Icon(
            dataURL: "data:image/png;base64," + png.base64EncodedString(), description: "\(width)×\(height)",
            size: min(width, height), source: origin)
    }
}
