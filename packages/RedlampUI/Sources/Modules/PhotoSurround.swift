import CoreGraphics
import RedlampCanvas

/// The neutral grey around a photo, in every theme: Develop's canvas clears to it (`CanvasMetalView`), and the
/// Library's loupe, Compare and Survey are drawn on it, so a photo's colours are judged against the same grey in both
/// modules. Lightroom's dark grey, darker with each step of Lights Out.
@MainActor
enum PhotoSurround {
    /// Linear, as the canvas clears to it.
    static func level(lightsOut: Int) -> Double {
        [CanvasMetalView.defaultSurround, 0.003, 0][min(max(lightsOut, 0), 2)]
    }

    /// The same linear grey in the canvas's colour space, for a layer to draw.
    static func color(lightsOut: Int) -> CGColor {
        let level = level(lightsOut: lightsOut)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        return CGColor(colorSpace: space, components: [level, level, level, 1])!
    }
}
