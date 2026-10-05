import Foundation

/// A hírcsatornák HTML-jét a PDF-hez készíti elő.
///
/// Képek megtartásakor minden `<img>` helyére egy `⟦RFIMG<n>⟧` helyőrző kerül, ahol `n` a visszaadott
/// URL-lista indexe; a renderer ezt cseréli le a letöltött képre.
enum HTMLCleaner {
    /// Ezek tartalmukkal együtt törlődnek.
    private static let blockTags = ["script", "style", "iframe", "noscript", "svg", "video", "audio",
                                    "form", "button", "object"]
    /// Ezek önálló (záró tag nélküli) elemek.
    private static let voidTags = ["img", "source", "input", "embed", "link", "meta"]
    /// Ennyinél több képet egy cikkből nem töltünk le.
    static let maxImagesPerArticle = 8

    /// Szerzői fotók, logók, ikonok: ezek nem a cikk képei.
    private static let decorativeImageWords = ["avatar", "gravatar", "author", "profile", "logo", "icon", "emoji",
                                               "pixel", "spacer"]

    static func placeholder(_ index: Int) -> String { "⟦RFIMG\(index)⟧" }
    static let placeholderPattern = "⟦RFIMG(\\d+)⟧"

    static func clean(_ html: String, baseURL: URL? = nil, keepImages: Bool = false,
                      leadImage: String? = nil) -> (html: String, imageURLs: [URL]) {
        var result = html
        for tag in blockTags {
            result = result.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: "",
                                                 options: [.regularExpression, .caseInsensitive])
        }

        // A HTML-importáló a <figcaption> margóit figyelmen kívül hagyja, a bekezdésekét nem.
        result = result
            .replacingOccurrences(of: "<figcaption\\b[^>]*>", with: "<p class=\"caption\">",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</figcaption\\s*>", with: "</p>", options: [.regularExpression, .caseInsensitive])

        var imageURLs: [URL] = []
        if keepImages {
            (result, imageURLs) = extractImages(result, baseURL: baseURL)
        }

        result = result.replacingOccurrences(of: "<(\(voidTags.joined(separator: "|")))\\b[^>]*>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            result = "<p><i>A hírcsatorna ehhez a cikkhez nem tartalmaz szöveget.</i></p>"
        } else if !result.contains("<") {
            // Sima szöveges leírás: bekezdésekre bontjuk.
            result = result.components(separatedBy: "\n\n")
                .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
                .joined()
        }

        // A vezetőkép csak akkor kell, ha a cikk szövegében nincs kép (különben többnyire ugyanaz).
        if keepImages, imageURLs.isEmpty, let lead = leadImage.flatMap({ resolve($0, baseURL: baseURL) }) {
            imageURLs = [lead]
            result = "<p>\(placeholder(0))</p>" + result
        }
        return (result, imageURLs)
    }

    private static func extractImages(_ html: String, baseURL: URL?) -> (String, [URL]) {
        guard let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: .caseInsensitive) else {
            return (html, [])
        }
        let source = html as NSString
        var result = ""
        var urls: [URL] = []
        var seen = Set<String>()
        var cursor = 0

        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = NSMaxRange(match.range)
            guard urls.count < maxImagesPerArticle,
                  let url = imageURL(attributes(of: source.substring(with: match.range)), baseURL: baseURL)
            else { continue }
            // Ugyanaz a kép többféle méretben (?width=800) csak egyszer kell.
            let key = (url.host() ?? "") + url.path()
            guard seen.insert(key).inserted else { continue }
            result += placeholder(urls.count)
            urls.append(url)
        }
        result += source.substring(from: cursor)
        return (result, urls)
    }

    private static func imageURL(_ attributes: [String: String], baseURL: URL?) -> URL? {
        // 1–2 pixeles követőképek kihagyása.
        if let width = attributes["width"].flatMap(Int.init), width <= 2 { return nil }
        if let height = attributes["height"].flatMap(Int.init), height <= 2 { return nil }
        // Lusta betöltésnél a valódi cím a data-* attribútumokban van.
        let candidates = [attributes["data-src"], attributes["data-lazy-src"], attributes["data-original"],
                          attributes["src"],
                          attributes["srcset"]?.split(separator: ",").first?.split(separator: " ").first.map(String.init)]
        for candidate in candidates.compactMap({ $0 }) where !candidate.hasPrefix("data:") {
            guard let url = resolve(candidate, baseURL: baseURL) else { continue }
            let path = url.path().lowercased()
            return decorativeImageWords.contains(where: path.contains) ? nil : url
        }
        return nil
    }

    private static func resolve(_ string: String, baseURL: URL?) -> URL? {
        let trimmed = string.decodingHTMLEntities.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func attributes(of tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')") else {
            return [:]
        }
        let source = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            result[name] = source.substring(with: valueRange)
        }
        return result
    }
}
