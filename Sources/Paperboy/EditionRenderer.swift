import AppKit

/// Egy címke napi kiadását PDF-be rendereli: címoldal tartalomjegyzékkel,
/// majd minden cikk új oldalon. A tartalomjegyzék bejegyzései PDF-belső linkek.
@MainActor
enum EditionRenderer {
    /// reMarkable 2: 1404×1872 px @ 226 dpi. A Paper Pro is 3:4 arányú, ott arányosan nagyít.
    static let pageSize = CGSize(width: 447, height: 596)
    static let margins = NSEdgeInsets(top: 30, left: 34, bottom: 36, right: 30)

    private static let destinationKey = NSAttributedString.Key("RFDestination")
    private static let gray = NSColor(white: 0.35, alpha: 1)

    static func render(title: String, date: Date, articles: [Article]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Paperboy"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info)
        else { return Data() }

        var pageNumber = 0
        draw(contents(title: title, date: date, articles: articles), destination: "toc",
             in: context, pageNumber: &pageNumber)
        for (index, article) in articles.enumerated() {
            draw(body(of: article), destination: "a\(index)", in: context, pageNumber: &pageNumber)
        }
        context.closePDF()
        return data as Data
    }

    // MARK: - Tartalom

    private static func contents(title: String, date: Date, articles: [Article]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(masthead())
        text.append(paragraph(title, font: sans(26, .bold), after: 2))
        let dateText = date.formatted(.dateTime.year().month(.wide).day().weekday(.wide)
            .locale(Locale(identifier: "hu_HU")))
        text.append(paragraph("\(dateText) · \(articles.count) cikk", font: sans(10), color: gray, after: 14))

        var lastFeed: String?
        for (index, article) in articles.enumerated() {
            if article.feedName != lastFeed {
                lastFeed = article.feedName
                text.append(paragraph(article.feedName.uppercased(), font: sans(8.5, .semibold), color: gray,
                                      before: 10, after: 4, extra: [.kern: 0.6]))
            }
            text.append(paragraph(article.title, font: serif(11.5), after: 6, indent: 8,
                                  extra: [destinationKey: "a\(index)"]))
        }
        return text
    }

    /// Kis fejléc a címoldal tetején: logó és „PAPERBOY” felirat.
    private static func masthead() -> NSAttributedString {
        let logoHeight: CGFloat = 15
        let attachment = NSTextAttachment()
        attachment.image = PaperboyLogo.image(height: logoHeight)
        // A logó alja a szöveg alapvonalára kerüljön.
        attachment.bounds = CGRect(x: 0, y: -1, width: logoHeight * PaperboyLogo.aspectRatio, height: logoHeight)
        let line = NSMutableAttributedString(attachment: attachment)
        line.append(NSAttributedString(string: "  PAPERBOY\n", attributes: [
            .font: sans(9, .bold), .foregroundColor: gray, .kern: 2.2,
        ]))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 14
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func body(of article: Article) -> NSAttributedString {
        let text = NSMutableAttributedString()
        var meta = article.feedName
        if let published = article.published {
            meta += " · " + published.formatted(.dateTime.month(.abbreviated).day().hour().minute()
                .locale(Locale(identifier: "hu_HU")))
        }
        let metaLine = NSMutableAttributedString(attributedString: paragraph(meta, font: sans(8.5), color: gray, after: 6))
        metaLine.insert(NSAttributedString(string: "    ↑ Tartalom", attributes: [
            .font: sans(8.5, .semibold), .foregroundColor: gray, destinationKey: "toc",
        ]), at: metaLine.length - 1)
        text.append(metaLine)

        text.append(paragraph(article.title, font: sans(17, .bold), after: 4, lineHeight: 1.05))
        if let author = article.author, !author.isEmpty {
            text.append(paragraph(author, font: sans(9.5), color: gray, after: 4))
        }
        text.append(paragraph("", font: sans(6)))
        text.append(content(of: article))
        if let link = article.link {
            text.append(paragraph("Forrás: \(link)", font: sans(8), color: gray, before: 10))
        }
        return text
    }

    /// A cikk már tisztított HTML-je (`HTMLCleaner`), a képhelyőrzők helyén a letöltött képekkel.
    private static func content(of article: Article) -> NSAttributedString {
        let document = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: Charter, Georgia, serif; font-size: 11.5px; line-height: 1.35; color: #000; }
        p { margin: 0 0 7px 0; }
        h1, h2, h3, h4, h5 { font-family: -apple-system, 'Helvetica Neue', sans-serif; font-size: 13px; margin: 10px 0 4px 0; }
        a { color: #000; text-decoration: none; }
        blockquote { margin: 6px 0 6px 12px; font-style: italic; }
        li { margin-bottom: 3px; }
        pre, code { font-family: Menlo, monospace; font-size: 9px; }
        p.caption { font-size: 9px; color: #555; margin: 2px 0 12px 0; }
        </style></head><body>\(article.html)</body></html>
        """
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let imported = try? NSMutableAttributedString(data: Data(document.utf8), options: options,
                                                             documentAttributes: nil)
        else { return paragraph(article.html.strippingTags.decodingHTMLEntities, font: serif(11.5)) }
        imported.removeAttribute(.link, range: NSRange(location: 0, length: imported.length))
        insertImages(article.images, into: imported)
        if !imported.string.hasSuffix("\n") { imported.append(NSAttributedString(string: "\n")) }
        return imported
    }

    private static func insertImages(_ images: [Int: ArticleImage], into text: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: HTMLCleaner.placeholderPattern) else { return }
        let matches = regex.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        // Hátulról cserélünk, hogy a korábbi tartományok érvényesek maradjanak.
        for match in matches.reversed() {
            let index = Int((text.string as NSString).substring(with: match.range(at: 1))) ?? -1
            // A kép saját sorba kerül; ahol már eleve sortörés van, oda nem kell újabb.
            let string = text.string as NSString
            let lineBreaks: Set<unichar> = [0x0A, 0x2028, 0x2029]
            let atLineStart = match.range.location == 0 || lineBreaks.contains(string.character(at: match.range.location - 1))
            let atLineEnd = NSMaxRange(match.range) >= string.length || lineBreaks.contains(string.character(at: NSMaxRange(match.range)))
            guard let image = images[index],
                  let attachment = attachment(for: image, newlineBefore: !atLineStart, newlineAfter: !atLineEnd) else {
                text.replaceCharacters(in: match.range, with: "")
                continue
            }
            text.replaceCharacters(in: match.range, with: attachment)
        }
    }

    private static func attachment(for image: ArticleImage, newlineBefore: Bool,
                                   newlineAfter: Bool) -> NSAttributedString? {
        guard let nsImage = NSImage(data: image.jpeg) else { return nil }
        let maxWidth = pageSize.width - margins.left - margins.right
        let maxHeight = (pageSize.height - margins.top - margins.bottom) * 0.7
        // Pontban legfeljebb annyi, ahány pixel: a kis képeket nem nagyítjuk fel.
        let scale = min(1, maxWidth / CGFloat(image.pixelWidth), maxHeight / CGFloat(image.pixelHeight))
        let size = CGSize(width: CGFloat(image.pixelWidth) * scale, height: CGFloat(image.pixelHeight) * scale)
        nsImage.size = size

        let attachment = NSTextAttachment()
        attachment.image = nsImage
        attachment.bounds = CGRect(origin: .zero, size: size)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 8
        let result = NSMutableAttributedString(string: newlineBefore ? "\n" : "")
        result.append(NSAttributedString(attachment: attachment))
        if newlineAfter { result.append(NSAttributedString(string: "\n")) }
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Lapozás és rajzolás

    private static func draw(_ text: NSAttributedString, destination: String, in context: CGContext,
                             pageNumber: inout Int) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let contentSize = CGSize(width: pageSize.width - margins.left - margins.right,
                                 height: pageSize.height - margins.top - margins.bottom)
        let origin = CGPoint(x: margins.left, y: margins.top)
        var isFirstPage = true

        while true {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)

            pageNumber += 1
            context.beginPDFPage(nil)
            if isFirstPage {
                context.addDestination(destination as CFString, at: CGPoint(x: 0, y: pageSize.height))
                isFirstPage = false
            }

            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            drawPageNumber(pageNumber)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()

            addLinks(layout: layout, storage: storage, container: container, glyphs: glyphs,
                     origin: origin, context: context)
            context.endPDFPage()

            // Üres oldal: a hátralévő elem nem fér el egy oldalon sem, nincs értelme tovább próbálni.
            if NSMaxRange(glyphs) >= layout.numberOfGlyphs || glyphs.length == 0 { break }
        }
    }

    private static func addLinks(layout: NSLayoutManager, storage: NSTextStorage, container: NSTextContainer,
                                 glyphs: NSRange, origin: CGPoint, context: CGContext) {
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(destinationKey, in: characters) { value, range, _ in
            guard let name = value as? String else { return }
            let linkGlyphs = NSIntersectionRange(layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
            guard linkGlyphs.length > 0 else { return }
            let rect = layout.boundingRect(forGlyphRange: linkGlyphs, in: container)
            // A layout fentről lefelé számol, a PDF alulról felfelé.
            let pdfRect = CGRect(x: origin.x + rect.minX, y: pageSize.height - origin.y - rect.maxY,
                                 width: rect.width, height: rect.height)
            context.setDestination(name as CFString, for: pdfRect)
        }
    }

    private static func drawPageNumber(_ number: Int) {
        let label = NSAttributedString(string: "\(number)", attributes: [.font: sans(8), .foregroundColor: gray])
        let size = label.size()
        label.draw(at: CGPoint(x: (pageSize.width - size.width) / 2,
                               y: pageSize.height - margins.bottom / 2 - size.height / 2))
    }

    // MARK: - Stílusok

    private static func paragraph(_ string: String, font: NSFont, color: NSColor = .black,
                                  before: CGFloat = 0, after: CGFloat = 0, lineHeight: CGFloat = 1,
                                  indent: CGFloat = 0,
                                  extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = lineHeight
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        attributes.merge(extra) { _, new in new }
        return NSAttributedString(string: string + "\n", attributes: attributes)
    }

    private static func serif(_ size: CGFloat) -> NSFont {
        NSFont(name: "Charter-Roman", size: size) ?? NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
    }

    private static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}
