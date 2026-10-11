import CoreGraphics
import Foundation
import RedlampDocument

/// What the soft-frame measure found in a photo's largest embedded preview (LIB-42): kept in the index by the photo's
/// content key, so a rename or a move keeps it, and measured again only when the measure changes (`version`). It's
/// derived from the photo alone, never written to a sidecar, and an index rebuilt measures it again.
public struct PhotoSharpness: Sendable, Hashable {
    /// The measure's version: a result another version measured is measured again.
    public static let version = 1

    /// Where the frame was measured.
    public enum Focus: Int, Sendable, Hashable {
        /// Not measured: its file has no preview of `LargestPreview.smallestEdge` pixels or more, or can't be read.
        case unmeasured = 0
        /// Around the AF point its maker notes or EXIF give (`AFPointReader`).
        case afPoint = 1
        /// Where the camera gives no AF point, in a grid of cells over the whole preview: its burst is judged in the
        /// cell where its sharpest frame is sharpest (`SoftFrames`).
        case grid = 2
    }

    public var focus: Focus
    /// The score at the AF point (`SharpnessMeasure`); 0 unless `focus` is `.afPoint`.
    public var score: Float
    /// The grid's cells' scores, `SharpnessMeasure.columns` by `rows`, row after row from the top; empty unless
    /// `focus` is `.grid`.
    public var cells: [Float]

    public init(focus: Focus, score: Float = 0, cells: [Float] = []) {
        self.focus = focus
        self.score = score
        self.cells = cells
    }

    public static let unmeasured = PhotoSharpness(focus: .unmeasured)
}

/// Measures photos for soft frames (LIB-42).
public enum SharpnessReader {
    /// `url`'s sharpness, its upright size `imageSize` (as the index has it, which Fujifilm's and SubjectArea's AF
    /// points are counted in): reading the file on `scheduler`'s background lane, which waits while anything on screen
    /// does, and drawing and measuring its preview there.
    public static func measure(
        _ url: URL, imageSize: CGSize?, scheduler: WorkScheduler,
    ) async throws -> PhotoSharpness {
        let points = try await scheduler.run(.background) { AFPointReader.read(url, imageSize: imageSize) }
        if let points, let preview = await LargestPreview.open(url),
           let rect = SharpnessMeasure.region(around: points.areas, width: preview.width, height: preview.height) {
            return try await scheduler.run(.background) {
                preview.region(rect).map { PhotoSharpness(focus: .afPoint, score: SharpnessMeasure.score($0)) }
                    ?? .unmeasured
            }
        }
        guard let preview = await LargestPreview.open(url, longEdge: SharpnessMeasure.gridEdge) else {
            return .unmeasured
        }
        return try await scheduler.run(.background) { grid(of: preview) }
    }

    /// The whole preview measured in cells.
    static func grid(of preview: LargestPreview) -> PhotoSharpness {
        guard let plane = preview.whole(longEdge: SharpnessMeasure.gridEdge) else { return .unmeasured }
        let cells = SharpnessMeasure.cells(plane)
        return cells.isEmpty ? .unmeasured : PhotoSharpness(focus: .grid, cells: cells)
    }
}
