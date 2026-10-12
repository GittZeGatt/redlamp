import AppKit
import RedlampDesign

/// An SF Symbol in the frame SwiftUI gives it, drawn at its own shape on whole pixels at the frame's centre
/// (`PixelSymbol`); `NSImageView` fits it to its (smaller) alignment rect. Clickable when given an action, as a plain
/// SwiftUI button would be.
final class SymbolImageView: LayerDrawnView {
    private let name: String
    private let pointSize: CGFloat
    private let weight: FontSpec.Weight
    private let size: CGSize
    private let color: NSColor
    var onClick: (() -> Void)?
    var isEnabled = true {
        didSet { setNeedsContentDisplay() }
    }

    init(_ name: String, pointSize: CGFloat, weight: FontSpec.Weight = .regular, color: NSColor) {
        self.name = name
        self.pointSize = pointSize
        self.weight = weight
        size = Symbol.layoutSize(name, pointSize: pointSize, weight: weight)
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        size
    }

    override func drawContent(in _: CGRect) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        PixelSymbol.draw(
            name, pointSize: pointSize, weight: weight.nsWeight, color: resolved.withAlphaComponent(1),
            alpha: resolved.alphaComponent * (isEnabled ? 1 : 0.5), centeredAt: CGPoint(x: bounds.midX, y: bounds.midY),
            scale: backingScale,
        )
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}
