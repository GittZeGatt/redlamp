import Accelerate
import CoreGraphics
import Foundation

/// Focus peaking (LIB-38): the pixels where the photo's brightness changes steeply from one pixel to the next, the
/// edges a lens in focus draws and a soft frame lacks. Sharpness is judged at a fixed steepness rather than against
/// the photo's own, so a soft frame shows few marks instead of its least soft edges, and on an image of the photo of
/// one size whatever the camera's, as a camera's peaking reads its viewfinder: the following loupe shows the pixels.
struct PeakingMask: @unchecked Sendable {
    let width: Int
    let height: Int
    /// 255 where an edge is sharp, 0 elsewhere, row after row.
    let marks: Data
    /// The share of the pixels marked.
    let markedShare: Double

    /// The colour marks are drawn in, sRGB: a green apart from sensor clipping's pure red, green and blue.
    static let color: (red: UInt8, green: UInt8, blue: UInt8) = (60, 235, 90)

    /// The marks in `color` on clear, at the mask's size.
    func image() -> CGImage? {
        guard width > 0, height > 0, marks.count == width * height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = Data(count: width * height * 4)
        var planes = [Data](repeating: Data(count: width * height), count: 3)
        let ok = marks.withUnsafeBytes { (alpha: UnsafeRawBufferPointer) -> Bool in
            func buffer(_ base: UnsafeRawPointer?, rowBytes: Int) -> vImage_Buffer {
                vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: rowBytes,
                )
            }
            var alphaPlane = buffer(alpha.baseAddress, rowBytes: width)
            // Premultiplied: each colour is the mark's alpha scaled to the colour's level.
            for (index, level) in [Self.color.red, Self.color.green, Self.color.blue].enumerated() {
                var table = [UInt8](repeating: 0, count: 256)
                for value in 0 ..< 256 {
                    table[value] = UInt8(value * Int(level) / 255)
                }
                let looked = planes[index].withUnsafeMutableBytes { plane -> Bool in
                    var target = buffer(plane.baseAddress, rowBytes: width)
                    return vImageTableLookUp_Planar8(&alphaPlane, &target, &table, vImage_Flags(kvImageNoFlags))
                        == kvImageNoError
                }
                guard looked else { return false }
            }
            return planes[0].withUnsafeBytes { red in
                planes[1].withUnsafeBytes { green in
                    planes[2].withUnsafeBytes { blue in
                        pixels.withUnsafeMutableBytes { target in
                            var (r, g, b) = (
                                buffer(red.baseAddress, rowBytes: width), buffer(green.baseAddress, rowBytes: width),
                                buffer(blue.baseAddress, rowBytes: width),
                            )
                            var output = buffer(target.baseAddress, rowBytes: width * 4)
                            return vImageConvert_Planar8toARGB8888(
                                &alphaPlane, &r, &g, &b, &output, vImage_Flags(kvImageNoFlags),
                            ) == kvImageNoError
                        }
                    }
                }
            }
        }
        guard ok, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )
    }

    /// The mask at most `longEdge` on its long edge, a pixel marked where the pixels it covers had one, so marks
    /// thinner than the step survive at the size the photo is shown.
    func pooled(toLongEdge longEdge: Int) -> PeakingMask {
        let step = Int((Double(max(width, height)) / Double(max(longEdge, 1))).rounded(.up))
        guard step > 1 else { return self }
        let (pooledWidth, pooledHeight) = ((width + step - 1) / step, (height + step - 1) / step)
        var dilated = Data(count: width * height)
        var pooled = Data(count: pooledWidth * pooledHeight)
        let ok = marks.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Bool in
            dilated.withUnsafeMutableBytes { (middle: UnsafeMutableRawBufferPointer) -> Bool in
                pooled.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Bool in
                    guard let sourceBase = source.baseAddress, let middleBase = middle.baseAddress,
                          let targetBase = target.baseAddress else { return false }
                    var input = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: sourceBase), height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width,
                    )
                    var spread = vImage_Buffer(
                        data: middleBase, height: vImagePixelCount(height), width: vImagePixelCount(width),
                        rowBytes: width,
                    )
                    var output = vImage_Buffer(
                        data: targetBase, height: vImagePixelCount(pooledHeight), width: vImagePixelCount(pooledWidth),
                        rowBytes: pooledWidth,
                    )
                    let side = vImagePixelCount(step | 1)
                    guard vImageMax_Planar8(&input, &spread, nil, 0, 0, side, side, vImage_Flags(kvImageEdgeExtend))
                        == kvImageNoError,
                        vImageScale_Planar8(&spread, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                    else { return false }
                    // Resampling leaves pixels part-covered by a mark's spread at about half, and its kernel's
                    // ringing a few levels beside them.
                    var table = [UInt8](repeating: 255, count: 256)
                    for level in 0 ..< 32 {
                        table[level] = 0
                    }
                    return vImageTableLookUp_Planar8(&output, &output, &table, vImage_Flags(kvImageNoFlags))
                        == kvImageNoError
                }
            }
        }
        guard ok else { return self }
        return PeakingMask(width: pooledWidth, height: pooledHeight, marks: pooled, markedShare: markedShare)
    }
}

enum FocusPeaking {
    /// The steepness marked: the Sobel gradient of brightness in 8-bit levels, scaled so a step of n levels from one
    /// pixel to the next reads n. A step of 24 reaches it; a step of 100 spread over ten pixels doesn't. On the
    /// samples it marks 48 times as much of an X-T2's sharp label as of the toys behind it.
    static let threshold: Float = 24

    /// The size peaking reads the photo at, on its long edge: 16 MB of working memory.
    static let longestEdge = 4000

    /// The peaking mask of `image`, read at most `longestEdge` on its long edge; nil when it can't be drawn.
    static func mask(of image: CGImage, longestEdge: Int = Self.longestEdge) -> PeakingMask? {
        let scale = min(1, Double(longestEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard width >= 3, height >= 3, var source = brightness(of: image, width: width, height: height) else {
            return nil
        }
        let count = width * height
        var horizontal = [Float](repeating: 0, count: count)
        var vertical = [Float](repeating: 0, count: count)
        // Sobel's kernels, divided by 4 so a one-pixel step of n levels reads as n / 2 on either side of it.
        let kernels: [[Float]] = [[-1, 0, 1, -2, 0, 2, -1, 0, 1], [-1, -2, -1, 0, 0, 0, 1, 2, 1]].map { kernel in
            kernel.map { $0 / 4 }
        }
        let convolved = source.withUnsafeMutableBufferPointer { source -> Bool in
            var input = vImage_Buffer(
                data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: width * 4,
            )
            func convolve(_ kernel: [Float], into target: inout [Float]) -> Bool {
                target.withUnsafeMutableBufferPointer { target in
                    var output = vImage_Buffer(
                        data: target.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                        rowBytes: width * 4,
                    )
                    return vImageConvolve_PlanarF(
                        &input, &output, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend),
                    ) == kvImageNoError
                }
            }
            return convolve(kernels[0], into: &horizontal) && convolve(kernels[1], into: &vertical)
        }
        guard convolved else { return nil }
        var magnitude = [Float](repeating: 0, count: count)
        vDSP.hypot(horizontal, vertical, result: &magnitude)
        // 255 at and above the threshold, 0 below.
        vDSP.threshold(magnitude, to: threshold, with: .zeroFill, result: &horizontal)
        vDSP.clip(vDSP.multiply(1e6, horizontal), to: 0 ... 255, result: &vertical)
        var marks = [UInt8](repeating: 0, count: count)
        vDSP.convertElements(of: vertical, to: &marks, rounding: .towardZero)
        let marked = Double(vDSP.sum(vertical)) / 255
        return PeakingMask(width: width, height: height, marks: Data(marks), markedShare: marked / Double(count))
    }

    /// The image's brightness, 0 to 255 as its encoded values have it, at `width` by `height`.
    private static func brightness(of image: CGImage, width: Int, height: Int) -> [Float]? {
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
        var grey = [Float](repeating: 0, count: width * height)
        vDSP.convertElements(of: bytes, to: &grey)
        return grey
    }
}
