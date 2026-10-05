import Foundation

struct ParsedFeed {
    var title: String?
    var items: [ParsedItem]
}

struct ParsedItem {
    var id: String
    var title: String
    var link: String?
    var date: Date?
    var author: String?
    var html: String
    var imageURL: String?
}

enum FeedError: LocalizedError {
    case invalidURL
    case http(Int)
    case notAFeed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Érvénytelen URL"
        case .http(let code): "HTTP \(code)"
        case .notAFeed: "Nem RSS/Atom hírcsatorna"
        }
    }
}

enum FeedFetcher {
    static func fetch(_ urlString: String) async throws -> ParsedFeed {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw FeedError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("RemarkableFeeds/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        return try FeedParser.parse(data)
    }
}

/// RSS 2.0, RSS 1.0 (RDF) és Atom feldolgozó.
final class FeedParser: NSObject, XMLParserDelegate {
    private var isFeed = false
    private var sawFirstElement = false
    private var title: String?
    private var items: [ParsedItem] = []
    private var fields: [String: String]?
    private var itemLink: String?
    private var itemImage: String?
    private var text = ""

    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let ok = parser.parse()
        // Kisebb XML-hibák esetén is használjuk, amit addig sikerült kiolvasni.
        guard delegate.isFeed, ok || !delegate.items.isEmpty else { throw FeedError.notAFeed }
        return ParsedFeed(title: delegate.title, items: delegate.items)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if !sawFirstElement {
            sawFirstElement = true
            isFeed = ["rss", "feed", "rdf:rdf"].contains(name)
        }
        text = ""
        if name == "item" || name == "entry" {
            fields = [:]
            itemLink = nil
            itemImage = nil
        } else if fields != nil, itemImage == nil,
                  ["enclosure", "media:content", "media:thumbnail"].contains(name),
                  let url = attributeDict["url"], isImage(attributeDict) {
            itemImage = url
        } else if fields != nil, name == "link", let href = attributeDict["href"],
                  (attributeDict["rel"] ?? "alternate") == "alternate", itemLink == nil {
            itemLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        if name == "item" || name == "entry", let fields {
            items.append(makeItem(fields))
            self.fields = nil
        } else if fields != nil {
            if !value.isEmpty, fields?[name] == nil { fields?[name] = value }
        } else if name == "title", title == nil, !value.isEmpty {
            title = value.decodingHTMLEntities
        }
    }

    private func makeItem(_ f: [String: String]) -> ParsedItem {
        let title = (f["title"] ?? "").strippingTags.decodingHTMLEntities
        let link = itemLink ?? f["link"]
        let html = f["content:encoded"] ?? f["content"] ?? f["description"] ?? f["summary"] ?? ""
        return ParsedItem(
            id: f["guid"] ?? f["id"] ?? link ?? title,
            title: title.isEmpty ? "(cím nélkül)" : title,
            link: link,
            date: DateParser.parse(f["pubdate"] ?? f["published"] ?? f["updated"] ?? f["dc:date"]),
            author: (f["dc:creator"] ?? f["name"] ?? f["author"])?.decodingHTMLEntities,
            html: html,
            imageURL: itemImage
        )
    }

    private func isImage(_ attributes: [String: String]) -> Bool {
        if let type = attributes["type"] { return type.hasPrefix("image/") }
        if let medium = attributes["medium"] { return medium == "image" }
        return true
    }
}

enum DateParser {
    private static let rfc822: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss Z",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let isoOptions: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime],
        [.withInternetDateTime, .withFractionalSeconds],
    ]

    private static let iso: [ISO8601DateFormatter] = isoOptions.map { options in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    static func parse(_ string: String?) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        for formatter in iso { if let date = formatter.date(from: string) { return date } }
        for formatter in rfc822 { if let date = formatter.date(from: string) { return date } }
        return nil
    }
}

extension String {
    var strippingTags: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
                     "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bdquo": "„"]
        var result = ""
        var rest = self[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let semi = rest[afterAmp...].prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest[afterAmp...]
                continue
            }
            let entity = String(rest[afterAmp..<semi])
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                decoded = named[entity]
            }
            if let decoded {
                result += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                result += "&"
                rest = rest[afterAmp...]
            }
        }
        return result + rest
    }
}
