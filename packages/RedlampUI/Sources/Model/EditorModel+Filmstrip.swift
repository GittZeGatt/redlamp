import CoreGraphics
import Foundation
import Observation

public extension EditorModel {
    /// View › Filmstrip › Hide Automatically, also on the filmstrip's own menu, in Settings ›
    /// Appearance and as the pin on its line of text (UX-43): the filmstrip slides in at the window's
    /// bottom edge and away once the pointer leaves, as Lightroom Classic's Auto Hide & Show does.
    /// Turned off, it stays up and the photo is fitted above it (`makesRoomForFilmstrip`). The app's,
    /// kept across launches; on at first.
    var filmstripHidesAutomatically: Bool {
        get { FilmstripPreference.shared.hidesAutomatically }
        set { FilmstripPreference.shared.hidesAutomatically = newValue }
    }

    /// View › Filmstrip › Show Info Line, beside Hide Automatically in the same three places (UX-42): the line of
    /// text above the thumbnails. Hidden, the filmstrip is that much shorter, and what only the line shows floats at
    /// its top edge while there's any (`FilmstripStatus`). The app's, kept across launches; shown at first.
    var filmstripShowsInfoLine: Bool {
        get { FilmstripPreference.shared.showsInfoLine }
        set { FilmstripPreference.shared.showsInfoLine = newValue }
    }

    /// The filmstrip's thumbnails' size as the menus name it; nil for one dragged between them (UX-42).
    var filmstripSize: FilmstripSize? {
        get { FilmstripSize(cellHeight: FilmstripPreference.shared.cellHeight) }
        set {
            if let newValue {
                FilmstripPreference.shared.resize(to: newValue.cellHeight)
            }
        }
    }

    /// The filmstrip's height, its line of text and its photos, at the size its thumbnails are.
    var filmstripHeight: CGFloat {
        FilmstripPreference.shared.height
    }

    /// Whether the photo is fitted above the filmstrip rather than under it: Hide Automatically is
    /// off, and the filmstrip is shown, with photos to show or why its folder's can't be. Lights Out
    /// keeps the room, so the photo doesn't move.
    var makesRoomForFilmstrip: Bool {
        !filmstripHidesAutomatically && filmstripVisible && (library.count > 0 || library.isOpenFolderUnavailable)
    }
}

/// The filmstrip's thumbnails (UX-42, #376): their cells from today's 96 × 70 points to about twice as large, where
/// the store's 384-pixel grid thumbnails still have a pixel for each of a Retina screen's. The menus name three
/// sizes; dragging the filmstrip's top edge sets any height between the smallest and the largest.
public enum FilmstripSize: CaseIterable, Sendable {
    case small, medium, large

    /// The heights a cell can have, in points.
    static let cellHeights: ClosedRange<CGFloat> = 70 ... 146

    var cellHeight: CGFloat {
        switch self {
        case .small: Self.cellHeights.lowerBound
        case .medium: 104
        case .large: Self.cellHeights.upperBound
        }
    }

    public var title: String {
        switch self {
        case .small: "Small Thumbnails"
        case .medium: "Medium Thumbnails"
        case .large: "Large Thumbnails"
        }
    }

    /// The size whose cells are `cellHeight` tall; nil between them.
    init?(cellHeight: CGFloat) {
        guard let size = Self.allCases.first(where: { abs($0.cellHeight - cellHeight) < 0.5 }) else { return nil }
        self = size
    }

    /// A cell `height` tall, as wide as today's cells are for their height.
    static func cell(height: CGFloat) -> CGSize {
        CGSize(width: (height * 96 / 70).rounded(), height: height)
    }
}

/// The filmstrip's settings, saved in user defaults as they change; `shared` is the app's: Hide Automatically
/// (UX-19), its thumbnails' size and its line of text (UX-42).
@MainActor @Observable
final class FilmstripPreference {
    static let shared = FilmstripPreference()
    static let defaultsKey = "app.redlamp.filmstripHidesAutomatically"
    static let cellHeightKey = "app.redlamp.filmstripCellHeight"
    static let infoLineKey = "app.redlamp.filmstripShowsInfoLine"
    /// The line of text's height, with the gap above it.
    static let infoLineHeight: CGFloat = 28

    var hidesAutomatically: Bool {
        didSet { defaults.set(hidesAutomatically, forKey: Self.defaultsKey) }
    }

    var showsInfoLine: Bool {
        didSet { defaults.set(showsInfoLine, forKey: Self.infoLineKey) }
    }

    /// A thumbnail's cell's height, in points, within `FilmstripSize.cellHeights`.
    private(set) var cellHeight: CGFloat

    /// The filmstrip's height: its line of text while it shows, and its photos.
    var height: CGFloat {
        (showsInfoLine ? Self.infoLineHeight : 0) + FilmstripStripView.height(forCellHeight: cellHeight)
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidesAutomatically = defaults.object(forKey: Self.defaultsKey) == nil || defaults.bool(forKey: Self.defaultsKey)
        showsInfoLine = defaults.object(forKey: Self.infoLineKey) == nil || defaults.bool(forKey: Self.infoLineKey)
        let saved = defaults.object(forKey: Self.cellHeightKey) == nil ? FilmstripSize.small.cellHeight
            : CGFloat(defaults.double(forKey: Self.cellHeightKey))
        cellHeight = min(max(saved, FilmstripSize.cellHeights.lowerBound), FilmstripSize.cellHeights.upperBound)
    }

    /// Cells `height` tall, kept within the sizes there are.
    func resize(to height: CGFloat) {
        let height = min(
            max(height.rounded(), FilmstripSize.cellHeights.lowerBound),
            FilmstripSize.cellHeights.upperBound,
        )
        guard height != cellHeight else { return }
        cellHeight = height
        defaults.set(Double(height), forKey: Self.cellHeightKey)
    }
}
