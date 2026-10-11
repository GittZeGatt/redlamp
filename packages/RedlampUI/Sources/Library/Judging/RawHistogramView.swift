import AppKit
import RedlampDesign
import RedlampEngineAPI

/// The raw histogram beside a photo in the loupe and Compare (LIB-38), read from the raw rather than the embedded
/// JPEG, which hides clipping: the photo's histogram as Redlamp develops it from the raw (Develop's histogram, drawn
/// as Develop draws it), and under it what the sensor clipped, each channel's share of the photo as Develop's sensor
/// clipping finds it and the share of the photosites the decoder counted at the clip point. Said to VoiceOver.
final class RawHistogramView: NSView {
    static let size = CGSize(width: 212, height: 108)
    private static let curveHeight: CGFloat = 54

    /// What the raw said.
    struct Reading: Equatable {
        /// Each channel's share of the photo the sensor clipped in, red, green and blue.
        var clipped: SIMD3<Double>
        /// The share where all three did.
        var clippedInAll: Double
        /// The share of the photosites at the sensor's clip point, as the decoder counted them; nil when it doesn't
        /// count them, as for a linear DNG.
        var photosites: Double?
        /// The photo's histogram as Redlamp develops it from the raw.
        var histogram: Histogram?
    }

    enum State: Equatable {
        /// The raw is being read.
        case reading
        /// The photo has no sensor data: a JPEG, HEIC or TIFF.
        case notRaw
        /// The raw couldn't be read.
        case unreadable
        case read(Reading)
    }

    var state = State.reading {
        didSet {
            if state != oldValue {
                setAccessibilityValue(summary)
                needsDisplay = true
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Raw Histogram")
        setAccessibilityValue(summary)
    }

    convenience init() {
        self.init(frame: CGRect(origin: .zero, size: Self.size))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    /// `Clipped on the sensor: 0.3% of photosites; red 1.2%, green 0.4%, blue 0%, all three 0.1% of the photo`, as
    /// VoiceOver and the regression suite read it.
    var summary: String {
        switch state {
        case .reading: "Reading the raw"
        case .notRaw: "No sensor data: not a raw file"
        case .unreadable: "The raw couldn't be read"
        case let .read(reading): Self.summary(of: reading)
        }
    }

    private static func summary(of reading: Reading) -> String {
        var parts: [String] = []
        for (index, name) in ["red", "green", "blue"].enumerated() {
            parts.append("\(name) \(percent(reading.clipped[index]))")
        }
        parts.append("all three \(percent(reading.clippedInAll)) of the photo")
        let photosites = reading.photosites.map { "\(percent($0)) of photosites; " } ?? ""
        return "Clipped on the sensor: \(photosites)\(parts.joined(separator: ", "))"
    }

    static func percent(_ share: Double) -> String {
        switch share {
        case 0: "0%"
        case ..<0.001: "<0.1%"
        case ..<0.1: String(format: "%.1f%%", share * 100)
        default: String(format: "%.0f%%", share * 100)
        }
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let curve = CGRect(x: 6, y: 6, width: bounds.width - 12, height: Self.curveHeight)
        NSColor(white: 1, alpha: 0.06).setFill()
        NSBezierPath(roundedRect: curve, xRadius: 4, yRadius: 4).fill()
        let value: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Palette.label.nsColor,
        ]
        guard case let .read(reading) = state else {
            (summary as NSString).draw(at: CGPoint(x: 10, y: curve.maxY + 8), withAttributes: value)
            return
        }
        if let histogram = reading.histogram {
            Self.drawCurves(histogram, in: curve.insetBy(dx: 2, dy: 3), context: context)
        }
        let title: [NSAttributedString.Key: Any] = [
            .font: Typography.caption.nsFont, .foregroundColor: Palette.secondaryLabel.nsColor,
        ]
        let worst = reading.photosites ?? max(reading.clipped.max(), reading.clippedInAll)
        ("Clipped on the sensor" as NSString).draw(at: CGPoint(x: 8, y: curve.maxY + 5), withAttributes: title)
        let total = (Self.percent(worst) as NSString)
        let width = total.size(withAttributes: value).width
        total.draw(at: CGPoint(x: bounds.width - 8 - width, y: curve.maxY + 5), withAttributes: value)
        let rows: [(String, NSColor, Double)] = [
            ("R", .systemRed, reading.clipped.x), ("G", .systemGreen, reading.clipped.y),
            ("B", .systemBlue, reading.clipped.z), ("All", .white, reading.clippedInAll),
        ]
        var x: CGFloat = 8
        let y = curve.maxY + 24
        for (name, color, share) in rows {
            let label = NSAttributedString(
                string: "\(name) ", attributes: [.font: Typography.caption.nsFont, .foregroundColor: color],
            )
            label.draw(at: CGPoint(x: x, y: y))
            x += label.size().width
            let text = Self.percent(share) as NSString
            text.draw(at: CGPoint(x: x, y: y), withAttributes: value)
            x += max(text.size(withAttributes: value).width + 8, 34)
        }
    }

    /// Red, green and blue as Develop's histogram draws them: added together, on a square-root scale whose top is
    /// the busiest bin but the ends'.
    private static func drawCurves(_ histogram: Histogram, in rect: CGRect, context: CGContext) {
        let channels: [([UInt32], CGColor)] = [
            (histogram.red, CGColor(srgbRed: 0.95, green: 0.25, blue: 0.25, alpha: 0.55)),
            (histogram.green, CGColor(srgbRed: 0.25, green: 0.9, blue: 0.35, alpha: 0.55)),
            (histogram.blue, CGColor(srgbRed: 0.3, green: 0.45, blue: 1.0, alpha: 0.55)),
        ]
        let peak = channels.flatMap { $0.0.dropFirst().dropLast() }.max() ?? 0
        guard peak > 0 else { return }
        let scale = Double(peak).squareRoot()
        context.saveGState()
        context.setBlendMode(.plusLighter)
        for (bins, color) in channels where bins.count > 1 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for (index, count) in bins.enumerated() {
                let x = rect.minX + CGFloat(index) / CGFloat(bins.count - 1) * rect.width
                let height = min(Double(count).squareRoot() / scale, 1) * rect.height
                path.addLine(to: CGPoint(x: x, y: rect.maxY - height))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        }
        context.restoreGState()
    }
}
