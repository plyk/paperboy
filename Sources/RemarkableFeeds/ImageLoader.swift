import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Képek letöltése és e-ink-barát átalakítása: kicsinyítés a tablet felbontására,
/// szürkeárnyalat, JPEG-tömörítés.
enum ImageLoader {
    /// A tartalomterület kb. 383 pt széles, a reMarkable 2 kb. 3,1 pixelt jelenít meg pontonként.
    static let maxPixelSize = 1200
    private static let maxDownloadBytes = 15_000_000
    private static let concurrency = 6

    static func load(_ urls: Set<URL>) async -> [URL: ArticleImage] {
        await withTaskGroup(of: (URL, ArticleImage?).self) { group in
            var pending = Array(urls)
            var images: [URL: ArticleImage] = [:]

            func startNext() {
                guard let url = pending.popLast() else { return }
                group.addTask { (url, await fetch(url)) }
            }

            for _ in 0..<concurrency { startNext() }
            for await (url, image) in group {
                if let image { images[url] = image }
                startNext()
            }
            return images
        }
    }

    private static func fetch(_ url: URL) async -> ArticleImage? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("RemarkableFeeds/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/jpeg, image/png, image/webp, image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count <= maxDownloadBytes
        else { return nil }
        return grayscaleJPEG(from: data)
    }

    static func grayscaleJPEG(from data: Data) -> ArticleImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let width = image.width
        let height = image.height
        // Ikonok, gombok, követőpixelek.
        guard width >= 64, height >= 64 else { return nil }

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Az átlátszó részek fehérek legyenek, ne feketék.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let gray = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, gray,
                                   [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ArticleImage(jpeg: output as Data, pixelWidth: width, pixelHeight: height)
    }
}
