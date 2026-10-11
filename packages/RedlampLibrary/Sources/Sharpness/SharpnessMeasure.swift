import Accelerate
import CoreGraphics
import Foundation

/// A photo's brightness, 0 to 255 as its encoded values have it, row after row.
struct GreyPlane: Sendable {
    let width: Int
    let height: Int
    let pixels: [Float]
}

/// How sharp a frame is, measured on its largest embedded preview without a model (LIB-42): the energy of the
/// brightness's gradient (Sobel's, Tenengrad's measure) divided by the brightness's variance over the same pixels.
/// Blur, from a focus missed, the camera's shake or the subject's movement, takes the finest detail first, so the
/// gradient falls faster than the variance; dividing by the variance leaves out the region's contrast, so a frame a
/// third of a stop brighter than the next, or a subject turning a lighter side, doesn't read as sharper. The number
/// means something only beside the same region of the frames shot with it: frames are judged against their own burst
/// (`SoftFrames`), never on a scale of their own.
///
/// On the test bursts (`SoftFrameSamples`, `SharpnessMeasureTests`), a frame moved a pixel or two, or a third of a stop
/// brighter, scores within 1% of the sharpest; a Gaussian blur of a pixel scores 0.40 of it, of two pixels 0.04, a
/// motion of five pixels 0.20 and a focus missed behind the subject 0.02. Real previews hold less fine detail than the
/// test scenes' drawn edges, so their soft frames fall less far: on the sample raws' previews, a blur of a pixel takes
/// a region's gradient energy to between 0.3 and 0.86 of its own, the least where the region has least texture.
enum SharpnessMeasure {
    /// The region measured around an AF point, as a share of the preview's long edge: at least `regionShare`, the
    /// AF area's own size when it's larger, at most `largestRegionShare`, and never under `smallestRegion` pixels.
    static let regionShare = 0.08
    static let largestRegionShare = 0.25
    static let smallestRegion = 64

    /// Where a camera gives no AF point, the whole preview is measured in a grid of cells, `columns` by `rows` over
    /// the frame as stored, at most `gridEdge` pixels on its long edge (JPEG's own scaling halves it as it decodes).
    static let columns = 6
    static let rows = 4
    static let gridEdge = 3000

    /// Added to the variance: a region flat but for noise and JPEG's blocks, within about two levels, scores low
    /// rather than as sharp as its noise.
    static let varianceFloor: Float = 4

    /// The score of all of `plane`.
    static func score(_ plane: GreyPlane) -> Float {
        guard plane.width >= 3, plane.height >= 3, let energy = gradientEnergy(plane) else { return 0 }
        let count = vDSP_Length(plane.pixels.count)
        var mean: Float = 0
        var meanSquare: Float = 0
        vDSP_meanv(plane.pixels, 1, &mean, count)
        vDSP_measqv(plane.pixels, 1, &meanSquare, count)
        let variance = max(meanSquare - mean * mean, 0)
        var energyMean: Float = 0
        vDSP_meanv(energy, 1, &energyMean, vDSP_Length(energy.count))
        return energyMean / (variance + varianceFloor)
    }

    /// The scores of `plane`'s cells, `columns` by `rows`, row after row from the top.
    static func cells(_ plane: GreyPlane, columns: Int = Self.columns, rows: Int = Self.rows) -> [Float] {
        guard plane.width >= 3 * columns, plane.height >= 3 * rows, let energy = gradientEnergy(plane) else {
            return []
        }
        var scores: [Float] = []
        scores.reserveCapacity(columns * rows)
        let width = plane.width
        plane.pixels.withUnsafeBufferPointer { pixels in
            energy.withUnsafeBufferPointer { energy in
                guard let pixelBase = pixels.baseAddress, let energyBase = energy.baseAddress else { return }
                for row in 0 ..< rows {
                    let top = row * plane.height / rows
                    let bottom = (row + 1) * plane.height / rows
                    for column in 0 ..< columns {
                        let left = column * width / columns
                        let length = vDSP_Length((column + 1) * width / columns - left)
                        var sums: (pixels: Float, squares: Float, energy: Float) = (0, 0, 0)
                        for line in top ..< bottom {
                            var sum: Float = 0
                            var squares: Float = 0
                            var gradient: Float = 0
                            let start = line * width + left
                            vDSP_sve(pixelBase + start, 1, &sum, length)
                            vDSP_svesq(pixelBase + start, 1, &squares, length)
                            vDSP_sve(energyBase + start, 1, &gradient, length)
                            sums.pixels += sum
                            sums.squares += squares
                            sums.energy += gradient
                        }
                        let count = Float(Int(length) * (bottom - top))
                        let mean = sums.pixels / count
                        let variance = max(sums.squares / count - mean * mean, 0)
                        scores.append(sums.energy / count / (variance + varianceFloor))
                    }
                }
            }
        }
        return scores
    }

    /// Each pixel's squared Sobel gradient, the kernels divided by 4 so a one-pixel step of n levels reads n / 2 on
    /// either side of it.
    private static func gradientEnergy(_ plane: GreyPlane) -> [Float]? {
        let count = plane.width * plane.height
        guard plane.pixels.count == count else { return nil }
        var source = plane.pixels
        var horizontal = [Float](repeating: 0, count: count)
        var vertical = [Float](repeating: 0, count: count)
        let kernels: [[Float]] = [[-1, 0, 1, -2, 0, 2, -1, 0, 1], [-1, -2, -1, 0, 0, 0, 1, 2, 1]].map { kernel in
            kernel.map { $0 / 4 }
        }
        let convolved = source.withUnsafeMutableBufferPointer { source -> Bool in
            var input = vImage_Buffer(
                data: source.baseAddress, height: vImagePixelCount(plane.height),
                width: vImagePixelCount(plane.width), rowBytes: plane.width * 4,
            )
            func convolve(_ kernel: [Float], into target: inout [Float]) -> Bool {
                target.withUnsafeMutableBufferPointer { target in
                    var output = vImage_Buffer(
                        data: target.baseAddress, height: vImagePixelCount(plane.height),
                        width: vImagePixelCount(plane.width), rowBytes: plane.width * 4,
                    )
                    return vImageConvolve_PlanarF(
                        &input, &output, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend),
                    ) == kvImageNoError
                }
            }
            return convolve(kernels[0], into: &horizontal) && convolve(kernels[1], into: &vertical)
        }
        guard convolved else { return nil }
        vDSP.square(horizontal, result: &horizontal)
        vDSP.square(vertical, result: &vertical)
        vDSP.add(horizontal, vertical, result: &horizontal)
        return horizontal
    }

    /// The region measured around `areas` (in the stored photo, 0 ... 1) in a preview `width` by `height`: a square
    /// centred on the areas the camera focused, or those it chose when it focused none, in the preview's pixels.
    static func region(around areas: [AFPoints.Area], width: Int, height: Int) -> CGRect? {
        let focused = areas.filter(\.inFocus)
        let chosen = focused.isEmpty ? areas : focused
        guard let first = chosen.first, width > 0, height > 0 else { return nil }
        let union = chosen.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let longEdge = Double(max(width, height))
        let areaSide = max(union.width * Double(width), union.height * Double(height))
        let side = min(
            max(areaSide, longEdge * regionShare, Double(smallestRegion)), longEdge * largestRegionShare,
            Double(min(width, height)),
        ).rounded()
        let centre = CGPoint(x: union.midX * Double(width), y: union.midY * Double(height))
        guard (0 ... Double(width)).contains(centre.x), (0 ... Double(height)).contains(centre.y) else { return nil }
        let x = min(max(centre.x - side / 2, 0), Double(width) - side).rounded()
        let y = min(max(centre.y - side / 2, 0), Double(height) - side).rounded()
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

extension GreyPlane {
    /// `image`'s brightness, drawn at `width` by `height` (its own size by default) into one byte a pixel: decoding a
    /// JPEG into grey, ImageIO reads its luminance alone.
    init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let width = width ?? image.width
        let height = height ?? image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var pixels = [Float](repeating: 0, count: width * height)
        vDSP.convertElements(of: bytes, to: &pixels)
        self.init(width: width, height: height, pixels: pixels)
    }
}
