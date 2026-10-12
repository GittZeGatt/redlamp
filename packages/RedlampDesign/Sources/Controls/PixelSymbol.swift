import AppKit

/// SF Symbols for small buttons (a header's + and chevron, a field's buttons), drawn at the symbol's own size with
/// its strokes on whole pixels at 1x as well as 2x.
///
/// For a 1x screen AppKit draws a symbol from a representation that CoreUI fits to whole pixels by stretching the
/// glyph: the 11-point semibold +, 9.5 points square at 2x, comes out 10.6 pixels wide and 8.8 tall, its upright
/// blurred across three columns. The symbol's 2x drawing keeps its shape, so both of these images' bitmaps are made
/// from it: the 2x one as it is, its glyph's centre (its ink's centroid) as near the image's middle as whole pixels
/// allow, and the 1x one averaged 2 by 2 from it, at whichever of the two half-point offsets leaves more of the glyph
/// on whole pixels.
@MainActor
public enum PixelSymbol {
    private static var images: [String: NSImage] = [:]

    /// A template image of the symbol, `size` points across with the glyph at its middle: an `NSButton` tints it
    /// with its content tint colour, as it does the symbol.
    public static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, size: CGSize)
        -> NSImage {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(size.width)x\(size.height)"
        if let cached = images[key] {
            return cached
        }
        let image = NSImage(size: size)
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) {
            let center = glyphCenter(symbol)
            for scale in [1, 2] {
                if let rep = bitmap(symbol, center: center, size: size, scale: scale) {
                    image.addRepresentation(rep)
                }
            }
        }
        image.isTemplate = true
        images[key] = image
        return image
    }

    /// Where the glyph's ink is centred, from the symbol's origin.
    private static func glyphCenter(_ symbol: NSImage) -> CGPoint {
        let margin: CGFloat = 1
        let canvas = CGSize(width: symbol.size.width + 2 * margin, height: symbol.size.height + 2 * margin)
        let ink = Coverage(symbol, at: CGPoint(x: margin, y: margin), in: canvas)
        var total = 0.0, x = 0.0, y = 0.0
        for row in 0 ..< ink.height {
            for column in 0 ..< ink.width {
                let value = ink[column, row]
                total += value
                x += value * (Double(column) + 0.5)
                y += value * (Double(ink.height - row) - 0.5)
            }
        }
        guard total > 0 else { return CGPoint(x: symbol.size.width / 2, y: symbol.size.height / 2) }
        return CGPoint(x: x / total / 2 - margin, y: y / total / 2 - margin)
    }

    /// The symbol's bitmap at `scale`, from its 2x drawing with the glyph's centre near the image's middle.
    private static func bitmap(_ symbol: NSImage, center: CGPoint, size: CGSize, scale: Int) -> NSBitmapImageRep? {
        /// Drawn off whole 2x pixels, a symbol is resampled, and blurred.
        func origins(_ centred: CGFloat) -> [CGFloat] {
            let whole = (centred * 2).rounded() / 2
            return scale == 2 ? [whole] : [whole, whole + (centred < whole ? -0.5 : 0.5)]
        }
        var best: Coverage?
        for y in origins(size.height / 2 - center.y) {
            for x in origins(size.width / 2 - center.x) {
                let drawn = Coverage(symbol, at: CGPoint(x: x, y: y), in: size).reduced(by: 2 / scale)
                if let current = best, drawn.sharpness <= current.sharpness + 0.001 {
                    continue
                }
                best = drawn
            }
        }
        guard let best, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: best.width, pixelsHigh: best.height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: best.width * 4, bitsPerPixel: 32,
        ), let data = rep.bitmapData else { return nil }
        for (index, value) in best.values.enumerated() {
            data[index * 4] = 0
            data[index * 4 + 1] = 0
            data[index * 4 + 2] = 0
            data[index * 4 + 3] = UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        rep.size = size
        return rep
    }

    /// How much of each pixel a drawing covers, the top row first.
    private struct Coverage {
        let width: Int
        let height: Int
        let values: [Double]

        init(width: Int, height: Int, values: [Double]) {
            self.width = width
            self.height = height
            self.values = values
        }

        /// `symbol` drawn at 2x with its origin at `origin`, in a canvas `size` points across.
        @MainActor init(_ symbol: NSImage, at origin: CGPoint, in size: CGSize) {
            let width = Int((size.width * 2).rounded(.up)), height = Int((size.height * 2).rounded(.up))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                ) else { return }
                context.scaleBy(x: 2, y: 2)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                symbol.draw(in: CGRect(origin: origin, size: symbol.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            let values = (0 ..< width * height).map { Double(bytes[$0 * 4 + 3]) / 255 }
            self.init(width: width, height: height, values: values)
        }

        subscript(x: Int, y: Int) -> Double {
            values[y * width + x]
        }

        /// Each square of `factor` by `factor` pixels averaged into one.
        func reduced(by factor: Int) -> Coverage {
            guard factor > 1 else { return self }
            let columns = width / factor, rows = height / factor
            var values = [Double](repeating: 0, count: columns * rows)
            for y in 0 ..< rows * factor {
                for x in 0 ..< columns * factor {
                    values[(y / factor) * columns + x / factor] += self[x, y] / Double(factor * factor)
                }
            }
            return Coverage(width: columns, height: rows, values: values)
        }

        /// The mean coverage of the ink, weighted by its coverage: 1 when every pixel it touches is whole.
        var sharpness: Double {
            let total = values.reduce(0, +)
            return total > 0 ? values.reduce(0) { $0 + $1 * $1 } / total : 0
        }
    }
}
