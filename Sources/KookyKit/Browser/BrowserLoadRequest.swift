import Foundation

struct BrowserLoadRequest: Equatable {
    let url: URL

    var displayString: String { url.absoluteString }

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = Self.explicitURL(from: trimmed) {
            self.url = url
            return
        }

        if let url = Self.webAddress(from: trimmed) {
            self.url = url
            return
        }

        self.url = Self.searchURL(for: trimmed)
    }

    private static func explicitURL(from value: String) -> URL? {
        let lowercased = value.lowercased()
        guard value.contains("://") || lowercased.hasPrefix("about:") else { return nil }
        guard let url = URL(string: value), url.scheme != nil else { return nil }
        return url
    }

    private static func webAddress(from value: String) -> URL? {
        let lowercased = value.lowercased()
        if lowercased == "localhost"
            || lowercased.hasPrefix("localhost:")
            || lowercased.hasPrefix("127.0.0.1")
            || lowercased.hasPrefix("0.0.0.0")
        {
            return URL(string: "http://\(value)")
        }
        let looksLikeHost = lowercased == "localhost"
            || lowercased.hasPrefix("localhost:")
            || lowercased.contains(".")
        guard looksLikeHost else { return nil }
        return URL(string: "https://\(value)")
    }

    private static func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}
