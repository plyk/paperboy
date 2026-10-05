import AppKit

/// A Paperboy-logó (talpas „P” zöld ponttal) vektoros rajzolása.
/// A geometria megegyezik a `Design/paperboy-icon.svg` fájléval (1024-es SVG-koordináták).
enum PaperboyLogo {
    static let ink = NSColor(srgbRed: 0x1D / 255, green: 0x1F / 255, blue: 0x24 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 0x2F / 255, green: 0x7D / 255, blue: 0x5B / 255, alpha: 1)

    /// A „P” befoglaló téglalapja az SVG-ben.
    private static let svgBounds = CGRect(x: 300, y: 215, width: 465, height: 490)
    /// Szélesség / magasság.
    static let aspectRatio = svgBounds.width / svgBounds.height

    /// A betű (a betűszem lyukként benne marad), a téglalap közepére illesztve.
    static func letterPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        // Külső körvonal: szár talpakkal és a betű öble.
        path.move(to: CGPoint(x: 300, y: 215))
        path.line(to: CGPoint(x: 580, y: 215))
        path.appendArc(withCenter: CGPoint(x: 580, y: 400), radius: 185, startAngle: -90, endAngle: 90, clockwise: false)
        path.line(to: CGPoint(x: 470, y: 585))
        path.line(to: CGPoint(x: 470, y: 665))
        path.line(to: CGPoint(x: 530, y: 665))
        path.line(to: CGPoint(x: 530, y: 705))
        path.line(to: CGPoint(x: 300, y: 705))
        path.line(to: CGPoint(x: 300, y: 665))
        path.line(to: CGPoint(x: 360, y: 665))
        path.line(to: CGPoint(x: 360, y: 255))
        path.line(to: CGPoint(x: 300, y: 255))
        path.close()
        // Betűszem.
        path.move(to: CGPoint(x: 470, y: 295))
        path.line(to: CGPoint(x: 570, y: 295))
        path.appendArc(withCenter: CGPoint(x: 570, y: 400), radius: 105, startAngle: -90, endAngle: 90, clockwise: false)
        path.line(to: CGPoint(x: 470, y: 505))
        path.close()
        path.transform(using: transform(fitting: rect))
        return path
    }

    /// A betűszembe kerülő pont.
    static func dotPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: CGRect(x: 566 - 74, y: 400 - 74, width: 148, height: 148))
        path.transform(using: transform(fitting: rect))
        return path
    }

    /// Színes logó (a PDF-ekhez és az alkalmazás felületéhez).
    static func image(height: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: height * aspectRatio, height: height), flipped: false) { rect in
            ink.setFill()
            letterPath(in: rect).fill()
            green.setFill()
            dotPath(in: rect).fill()
            return true
        }
    }

    /// Egyszínű sablonkép a menüsorba; szinkronizálás közben a pont gyűrűvé válik.
    static func menuBarImage(isSyncing: Bool) -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let area = rect.insetBy(dx: 1.5, dy: 1)
            NSColor.black.set()
            letterPath(in: area).fill()
            let dot = dotPath(in: area)
            if isSyncing {
                dot.transform(using: shrink(dot.bounds, by: 0.7))
                dot.lineWidth = 1.1
                dot.stroke()
            } else {
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// SVG-koordinátákból (lefelé növekvő y) a téglalapba, AppKit-koordinátákba (felfelé növekvő y).
    private static func transform(fitting rect: CGRect) -> AffineTransform {
        let scale = min(rect.width / svgBounds.width, rect.height / svgBounds.height)
        let offsetX = rect.minX + (rect.width - svgBounds.width * scale) / 2
        let offsetY = rect.minY + (rect.height - svgBounds.height * scale) / 2
        var transform = AffineTransform(translationByX: offsetX, byY: offsetY)
        transform.scale(x: scale, y: -scale)
        transform.translate(x: -svgBounds.minX, y: -svgBounds.maxY)
        return transform
    }

    /// Kicsinyítés a saját középpontja körül.
    private static func shrink(_ bounds: CGRect, by factor: CGFloat) -> AffineTransform {
        var transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        transform.scale(factor)
        transform.translate(x: -bounds.midX, y: -bounds.midY)
        return transform
    }
}
