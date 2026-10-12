import AppKit

/// SF Symbols drawn at their own shape with their strokes on whole pixels, at 1x as well as 2x: for controls (a
/// header's + and chevron, a field's buttons, a row's icon) as images, and for views that draw their own (`draw`).
///
/// For a 1x screen AppKit draws a symbol from a representation that CoreUI fits to whole pixels by stretching the
/// glyph: the 11-point semibold +, 9.5 points square at 2x, comes out 10.6 pixels wide and 8.8 tall, its upright
/// blurred across three columns. The symbol's 2x drawing keeps its shape, so each symbol is drawn once at 2x (turned,
/// if it's to be), and its 1x pixels are that drawing averaged 2 by 2, from whichever of its two half-point offsets
/// leaves more of it on whole pixels. Either is then put on whole pixels with the symbol's image centred as near where
/// it's asked for as they allow, the glyph where its image has it: drawn between pixels, a bitmap is resampled.
@MainActor
public enum PixelSymbol {
    private static var glyphs: [String: Glyph] = [:]
    private static var images: [String: NSImage] = [:]
    private static var reps: [String: NSBitmapImageRep] = [:]

    /// The symbol in a canvas `size` points across (the symbol's own image size by default) with its glyph at the
    /// middle: a template an `NSButton` or `NSImageView` tints with its content tint colour, as it does the symbol;
    /// in `color` (opaque) when given one, or in its `palette` colours.
    public static func image(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale? = nil,
        size: CGSize? = nil, color: NSColor? = nil, palette: [NSColor]? = nil, accessibilityDescription: String? = nil,
    ) -> NSImage {
        let symbol = Key(name: name, pointSize: pointSize, weight: weight, scale: scale, degrees: 0, palette: palette)
        let glyph = glyph(symbol)
        let fill = palette != nil ? Fill.own : color.map { Fill($0) } ?? .template
        let canvas = size ?? glyph.size
        let key = "\(symbol.text)|\(fill.text)|\(canvas.width)x\(canvas.height)"
        let image = images[key] ?? {
            let image = NSImage(size: canvas)
            for (scale, pixels) in [(1, glyph.one), (2, glyph.two)] {
                image.addRepresentation(pixels.placed(in: canvas, scale: scale, fill: fill))
            }
            image.isTemplate = palette == nil && color == nil
            images[key] = image
            return image
        }()
        guard let accessibilityDescription, let described = image.copy() as? NSImage else { return image }
        described.accessibilityDescription = accessibilityDescription
        return described
    }

    /// The size of the symbol's own image, as AppKit lays it out.
    public static func size(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> CGSize {
        glyph(Key(name: name, pointSize: pointSize, weight: weight, scale: nil, degrees: 0)).size
    }

    /// Draws the symbol in `color` (opaque, faded by `alpha`) with its image centred at `center`, turned by `degrees`
    /// about it, in pixels `scale` to a point; the current context's pixels must be on the view's whole points.
    public static func draw(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, alpha: CGFloat = 1,
        centeredAt center: CGPoint, rotation degrees: CGFloat = 0, scale: CGFloat,
    ) {
        guard let context = NSGraphicsContext.current else { return }
        let symbol = Key(name: name, pointSize: pointSize, weight: weight, scale: nil, degrees: degrees)
        let glyph = glyph(symbol)
        let factor = scale < 1.5 ? 1 : 2
        let pixels = factor == 1 ? glyph.one : glyph.two
        let fill = Fill(color)
        let key = "\(symbol.text)|\(fill.text)|\(factor)"
        let rep = reps[key] ?? {
            let rep = pixels.bitmap(scale: factor, fill: fill)
            reps[key] = rep
            return rep
        }()
        let size = CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
        let anchor = pixels.anchor
        let x = (center.x * scale - anchor.x).rounded() / scale
        let top = (center.y * scale - anchor.y).rounded() / scale
        let bottom = (center.y * scale - (CGFloat(pixels.height) - anchor.y)).rounded() / scale
        let rect = CGRect(origin: CGPoint(x: x, y: context.isFlipped ? top : bottom), size: size)
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// A symbol at a configuration, turned by `degrees`, in its `palette` colours or as a template.
    private struct Key {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
        let scale: NSImage.SymbolScale?
        let degrees: CGFloat
        var palette: [NSColor]?

        var text: String {
            let colors = palette.map { $0.map { Fill($0).text + "/\($0.alphaComponent)" }.joined(separator: ";") }
            return "\(name)|\(pointSize)|\(weight.rawValue)|\(scale?.rawValue ?? -1)|\(degrees)|\(colors ?? "")"
        }
    }

    /// What a glyph's pixels are filled with: black, for a template, a colour, or the symbol's own colours.
    private struct Fill {
        let red: UInt8, green: UInt8, blue: UInt8
        let ownColors: Bool

        static let template = Fill(red: 0, green: 0, blue: 0, ownColors: false)
        static let own = Fill(red: 0, green: 0, blue: 0, ownColors: true)

        init(red: UInt8, green: UInt8, blue: UInt8, ownColors: Bool) {
            self.red = red
            self.green = green
            self.blue = blue
            self.ownColors = ownColors
        }

        init(_ color: NSColor) {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            func byte(_ value: CGFloat) -> UInt8 {
                UInt8((min(max(value, 0), 1) * 255).rounded())
            }
            self.init(
                red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent),
                ownColors: false,
            )
        }

        var text: String {
            ownColors ? "own" : "\(red),\(green),\(blue)"
        }
    }

    /// The symbol drawn at 2x and at 1x, with the canvas its image would take.
    private struct Glyph {
        let two: Pixels
        let one: Pixels
        let size: CGSize
    }

    private static func glyph(_ key: Key) -> Glyph {
        if let cached = glyphs[key.text] {
            return cached
        }
        var configuration = key.scale.map {
            NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: key.weight, scale: $0)
        } ?? NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: key.weight)
        if let palette = key.palette {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: palette))
        }
        let symbol = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        let size = symbol.map { CGSize(width: ceil($0.size.width), height: ceil($0.size.height)) } ?? .zero
        let drawn = symbol.map { Pixels(drawing: $0, degrees: key.degrees, colored: key.palette != nil) }
            ?? Pixels(width: 0, height: 0, alpha: [], color: [], anchor: .zero)
        let glyph = Glyph(two: drawn.cropped(), one: drawn.sharpestHalf(), size: size)
        glyphs[key.text] = glyph
        return glyph
    }

    /// How much of each pixel a drawing covers, the top row first, with its premultiplied colour when it keeps its
    /// own, and where the symbol's image is centred, in pixels from its top left corner.
    @MainActor private struct Pixels {
        let width: Int
        let height: Int
        let alpha: [Double]
        /// Red, green and blue for each pixel, or empty.
        let color: [Double]
        let anchor: CGPoint

        init(width: Int, height: Int, alpha: [Double], color: [Double], anchor: CGPoint) {
            self.width = width
            self.height = height
            self.alpha = alpha
            self.color = color
            self.anchor = anchor
        }

        /// `symbol` drawn at 2x, turned by `degrees` about its centre, in a square canvas with room for it.
        init(drawing symbol: NSImage, degrees: CGFloat, colored: Bool) {
            let side = Int(ceil(hypot(symbol.size.width, symbol.size.height))) + 4
            let pixels = side * 2
            var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                    data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                    bytesPerRow: pixels * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                ) else { return }
                context.scaleBy(x: 2, y: 2)
                context.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
                context.rotate(by: -degrees * .pi / 180)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                // Its corner on whole 2x pixels, as AppKit draws it, so a quarter turn is exact.
                symbol.draw(in: CGRect(origin: Self.corner(of: symbol), size: symbol.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            let count = pixels * pixels
            let alpha = (0 ..< count).map { Double(bytes[$0 * 4 + 3]) / 255 }
            let color = colored ? (0 ..< count * 3).map { Double(bytes[$0 / 3 * 4 + $0 % 3]) / 255 } : []
            // The image's centre, off the canvas's by what putting its corner on whole pixels moved it, turned.
            let corner = Self.corner(of: symbol)
            let offset = CGPoint(x: corner.x + symbol.size.width / 2, y: corner.y + symbol.size.height / 2)
                .applying(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            let anchor = CGPoint(x: CGFloat(side) + offset.x * 2, y: CGFloat(side) - offset.y * 2)
            self.init(width: pixels, height: pixels, alpha: alpha, color: color, anchor: anchor)
        }

        private static func corner(of symbol: NSImage) -> CGPoint {
            CGPoint(x: -symbol.size.width.rounded() / 2, y: -symbol.size.height.rounded() / 2)
        }

        subscript(x: Int, y: Int) -> Double {
            x >= 0 && y >= 0 && x < width && y < height ? alpha[y * width + x] : 0
        }

        func channel(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            !color.isEmpty && x >= 0 && y >= 0 && x < width && y < height ? color[(y * width + x) * 3 + channel] : 0
        }

        /// The mean coverage of the ink, weighted by its coverage: 1 when every pixel it touches is whole.
        var sharpness: Double {
            let total = alpha.reduce(0.0, +)
            return total > 0 ? alpha.reduce(0.0) { $0 + $1 * $1 } / total : 0
        }

        /// These pixels from `left`, `top`, `width` by `height`, each of them the average of `factor` by `factor`.
        func region(left: Int, top: Int, width: Int, height: Int, factor: Int = 1) -> Pixels {
            let share = 1 / Double(factor * factor)
            func average(_ value: (Int, Int) -> Double, _ x: Int, _ y: Int) -> Double {
                var sum = 0.0
                for dy in 0 ..< factor {
                    for dx in 0 ..< factor {
                        sum += value(left + x * factor + dx, top + y * factor + dy)
                    }
                }
                return sum * share
            }
            let alpha = (0 ..< width * height).map { average({ self[$0, $1] }, $0 % width, $0 / width) }
            let color = color.isEmpty ? [] : (0 ..< width * height * 3).map { index in
                average({ channel($0, $1, index % 3) }, index / 3 % width, index / 3 / width)
            }
            let anchor = CGPoint(
                x: (anchor.x - CGFloat(left)) / CGFloat(factor), y: (anchor.y - CGFloat(top)) / CGFloat(factor),
            )
            return Pixels(width: width, height: height, alpha: alpha, color: color, anchor: anchor)
        }

        /// Its inked pixels and one more on each side.
        func cropped() -> Pixels {
            let inked = alpha.indices.filter { alpha[$0] > 0 }
            guard let first = inked.first
            else { return Pixels(width: 0, height: 0, alpha: [], color: [], anchor: .zero) }
            var (left, top, right, bottom) = (first % width, first / width, first % width, first / width)
            for index in inked {
                (left, right) = (min(left, index % width), max(right, index % width))
                (top, bottom) = (min(top, index / width), max(bottom, index / width))
            }
            return region(left: left - 1, top: top - 1, width: right - left + 3, height: bottom - top + 3)
        }

        /// Each square of 2 by 2 pixels averaged into one, from whichever of the drawing's offsets by a pixel either
        /// way leaves the most of it on whole pixels.
        func sharpestHalf() -> Pixels {
            let halves = [(0, 0), (1, 0), (0, 1), (1, 1)].map { dx, dy in
                region(left: -dx, top: -dy, width: (width + dx + 1) / 2, height: (height + dy + 1) / 2, factor: 2)
                    .cropped()
            }
            var best = halves[0]
            for half in halves.dropFirst() where half.sharpness > best.sharpness + 0.001 {
                best = half
            }
            return best
        }

        /// A bitmap of these pixels, `scale` pixels to a point.
        func bitmap(scale: Int, fill: Fill) -> NSBitmapImageRep {
            rep(width: width, height: height, scale: scale, fill: fill) { $0 }
        }

        /// A bitmap of a canvas `size` points across with the symbol's image at its middle, on whole pixels.
        func placed(in size: CGSize, scale: Int, fill: Fill) -> NSBitmapImageRep {
            let factor = CGFloat(scale)
            let (columns, rows) = (Int((size.width * factor).rounded(.up)), Int((size.height * factor).rounded(.up)))
            let left = Int((CGFloat(columns) / 2 - anchor.x).rounded())
            let top = Int((CGFloat(rows) / 2 - anchor.y).rounded())
            let canvas = rep(width: columns, height: rows, scale: scale, fill: fill) { ($0.0 - left, $0.1 - top) }
            canvas.size = size
            return canvas
        }

        /// A bitmap `width` by `height` whose pixel at `x`, `y` is this one's at `source(x, y)`.
        private func rep(width: Int, height: Int, scale: Int, fill: Fill, source: ((Int, Int)) -> (Int, Int))
            -> NSBitmapImageRep {
            let (columns, rows) = (max(width, 1), max(height, 1))
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: columns, pixelsHigh: rows, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: columns * 4,
                bitsPerPixel: 32,
            ), let data = rep.bitmapData else { return NSBitmapImageRep() }
            let ink = [Double(fill.red), Double(fill.green), Double(fill.blue)].map { $0 / 255 }
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let (sx, sy) = source((x, y))
                    let alpha = min(max(self[sx, sy], 0), 1)
                    let index = (y * columns + x) * 4
                    for channel in 0 ..< 3 {
                        let value = fill.ownColors ? self.channel(sx, sy, channel) : ink[channel] * alpha
                        data[index + channel] = UInt8((min(max(value, 0), 1) * 255).rounded())
                    }
                    data[index + 3] = UInt8((alpha * 255).rounded())
                }
            }
            let factor = CGFloat(scale)
            rep.size = CGSize(width: CGFloat(columns) / factor, height: CGFloat(rows) / factor)
            return rep
        }
    }
}
