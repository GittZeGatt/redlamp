import AppKit
import SwiftUI

/// Draws SF Symbols where SwiftUI lays out an `Image(systemName:)`: in the frame SwiftUI gives it, put on the pixel
/// grid, the symbol at its own shape on whole pixels (`PixelSymbol`) at the frame's centre. The frame isn't the
/// image's size (the 9 pt chevron's is 8 × 11 against an image 7 wide; the 9 pt triangle's 9 × 10 against 9 × 9), so
/// the symbol is centred in it rather than filling it.
@MainActor
public enum Symbol {
    private static var frames: [String: CGSize] = [:]

    /// The frame SwiftUI lays `Image(systemName: name)` out in at this size and weight.
    public static func layoutSize(_ name: String, pointSize: CGFloat, weight: FontSpec.Weight) -> CGSize {
        let key = "\(name)|\(pointSize)|\(weight)"
        if let cached = frames[key] {
            return cached
        }
        let size = NSHostingView(rootView: Image(systemName: name).font(FontSpec(size: pointSize, weight: weight).font))
            .fittingSize
        frames[key] = size
        return size
    }

    /// Draws a symbol as SwiftUI would with `.font(...)`, `.foregroundStyle(color)`, an
    /// optional `.rotationEffect` and `.position(center)`.
    public static func draw(
        _ name: String,
        pointSize: CGFloat,
        weight: FontSpec.Weight = .regular,
        color: RGBA,
        centeredAt center: CGPoint,
        rotation degrees: CGFloat = 0,
        scale: CGFloat,
    ) {
        let frame = PixelGrid.centered(layoutSize(name, pointSize: pointSize, weight: weight), at: center, scale: scale)
        // A translucent colour is drawn opaque with its alpha as the fraction: as a palette colour, its alpha was
        // applied twice (a 45% white chevron came out at ~20%).
        PixelSymbol.draw(
            name, pointSize: pointSize, weight: weight.nsWeight,
            color: color.opacity(1 / max(color.alpha, 0.001)).nsColor,
            alpha: color.alpha, centeredAt: CGPoint(x: frame.midX, y: frame.midY), rotation: degrees, scale: scale,
        )
    }
}
