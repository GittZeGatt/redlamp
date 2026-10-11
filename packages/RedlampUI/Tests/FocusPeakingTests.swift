import Accelerate
import CoreGraphics
import Foundation
import Testing
@testable import RedlampUI

/// Focus peaking (LIB-38): a photo's sharp edges marked and a soft one's not, at a fixed steepness, read at one size
/// whatever the photo's, and pooled to the size it's shown without losing a mark.
struct FocusPeakingTests {
    /// A board of `squares` by `squares` squares of greys 40 and 200, `size` pixels across, its edges spread by a
    /// tent `blur` pixels wide, as a lens out of focus spreads them.
    private static func board(size: Int, squares: Int, blur: Int = 0) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ), let data = context.data else { return nil }
        let square = CGFloat(size) / CGFloat(squares)
        for row in 0 ..< squares {
            for column in 0 ..< squares {
                context.setFillColor(gray: (row + column).isMultiple(of: 2) ? 40 / 255 : 200 / 255, alpha: 1)
                context.fill(CGRect(
                    x: CGFloat(column) * square,
                    y: CGFloat(row) * square,
                    width: square,
                    height: square,
                ))
            }
        }
        if blur > 0 {
            var copy = [UInt8](repeating: 0, count: size * size)
            copy.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(
                    data: data, height: vImagePixelCount(size), width: vImagePixelCount(size), rowBytes: size,
                )
                var output = vImage_Buffer(
                    data: target.baseAddress, height: vImagePixelCount(size), width: vImagePixelCount(size),
                    rowBytes: size,
                )
                let side = UInt32(blur | 1)
                _ = vImageTentConvolve_Planar8(
                    &input,
                    &output,
                    nil,
                    0,
                    0,
                    side,
                    side,
                    0,
                    vImage_Flags(kvImageEdgeExtend),
                )
                data.copyMemory(from: target.baseAddress!, byteCount: size * size)
            }
        }
        return context.makeImage()
    }

    @Test func `a sharp board is marked along its edges, and the same board out of focus isn't`() throws {
        let sharpBoard = try #require(Self.board(size: 1024, squares: 8))
        let sharp = try #require(FocusPeaking.mask(of: sharpBoard))
        #expect(sharp.width == 1024 && sharp.height == 1024)
        // Each edge marks the two pixels beside it: 7 inner edges each way.
        let unmarked = 1 - 14.0 / 1024
        #expect(abs(sharp.markedShare - (1 - unmarked * unmarked)) < 0.01, "\(sharp.markedShare)")
        let softBoard = try #require(Self.board(size: 1024, squares: 8, blur: 41))
        let soft = try #require(FocusPeaking.mask(of: softBoard))
        #expect(soft.markedShare < 0.001, "\(soft.markedShare)")
    }

    @Test func `a photo larger than peaking's size is read at that size`() throws {
        let large = try #require(Self.board(size: 5000, squares: 10))
        let mask = try #require(FocusPeaking.mask(of: large))
        #expect(mask.width == FocusPeaking.longestEdge && mask.height == FocusPeaking.longestEdge)
        #expect(mask.markedShare > 0.005)
    }

    @Test func `pooled to the size shown, the mask keeps a mark wherever the photo had one`() {
        var marks = Data(count: 1000 * 600)
        marks[300 * 1000 + 503] = 255
        let mask = PeakingMask(width: 1000, height: 600, marks: marks, markedShare: 1 / 600_000)
        let pooled = mask.pooled(toLongEdge: 100)
        #expect(pooled.width == 100 && pooled.height == 60)
        let marked = pooled.marks.enumerated().filter { $0.element != 0 }.map(\.offset)
        #expect(
            !marked.isEmpty && marked.allSatisfy { abs($0 % 100 - 50) <= 1 && abs($0 / 100 - 30) <= 1 },
            "\(marked)",
        )
        #expect(mask.pooled(toLongEdge: 2000).width == 1000, "never larger than the mask")
    }

    @Test func `the marks are drawn in peaking's colour on clear`() throws {
        var marks = Data(count: 40 * 30)
        marks[10 * 40 + 20] = 255
        let image = try #require(PeakingMask(width: 40, height: 30, marks: marks, markedShare: 0).image())
        #expect(image.width == 40 && image.height == 30 && image.alphaInfo == .premultipliedFirst)
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let mark = 10 * image.bytesPerRow + 20 * 4
        let color = PeakingMask.color
        #expect((0 ..< 4).map { bytes[mark + $0] } == [255, color.red, color.green, color.blue], "alpha first")
        #expect((0 ..< 4).map { bytes[mark + 4 + $0] } == [0, 0, 0, 0], "clear beside it")
    }

    @Test(.measuresSpeed) func `peaking a photo takes a fraction of a second`() throws {
        let photo = try #require(Self.board(size: 6000, squares: 40))
        _ = FocusPeaking.mask(of: photo)
        let clock = ContinuousClock()
        var mask: PeakingMask?
        let took = clock.measure { mask = FocusPeaking.mask(of: photo) }
        let pooling = try clock.measure { _ = try #require(mask).pooled(toLongEdge: 2560).image() }
        #expect(took < .milliseconds(400), "\(took) to read a 36 MP photo at 4,000 pixels")
        #expect(pooling < .milliseconds(150), "\(pooling) to pool it for the screen")
    }
}
