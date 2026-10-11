import Foundation
import RedlampLibrary

/// What the import window's grid groups the shown source's photos by (DEC-69): a card's by moment until Group By
/// says otherwise, any other source's only once Group By says so. Moments are found as the library finds its own
/// (`ImportPhoto.moments`), from the capture times browsing has read; days are the camera's clock's.
enum ImportGrouping: String, CaseIterable, Sendable {
    case none, moment, day

    var title: String {
        switch self {
        case .none: "None"
        case .moment: "Moment"
        case .day: "Day"
        }
    }

    /// What a source is grouped by until Group By is chosen for it.
    static func standard(for kind: ImportSource.Kind) -> ImportGrouping {
        kind == .card ? .moment : .none
    }

    /// `photos`, as listed, in their groups: the newest group first and each group's photos newest first, with each
    /// group's run of them. Ungrouped, the photos stay as listed, in one group without a name.
    func arrange(_ photos: [ImportPhoto]) -> (photos: [ImportPhoto], groups: [ImportGroup]) {
        switch self {
        case .none:
            return (photos, [ImportGroup(name: "", places: 0 ..< photos.count)])
        case .moment:
            let moments = ImportPhoto.moments(of: photos)
            return Self.gather(moments.reversed().map { ($0.name, $0.places.reversed()) }, from: photos)
        case .day:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
            let newest = photos.indices.sorted { lhs, rhs in
                (photos[lhs].captured, rhs) > (photos[rhs].captured, lhs)
            }
            var runs: [(String, [Int])] = []
            var day: Date?
            for place in newest {
                let start = calendar.startOfDay(for: photos[place].captured)
                if start != day {
                    day = start
                    runs.append((Self.dayName.string(from: start), []))
                }
                runs[runs.count - 1].1.append(place)
            }
            return Self.gather(runs, from: photos)
        }
    }

    private static func gather(
        _ runs: [(String, [Int])], from photos: [ImportPhoto],
    ) -> (photos: [ImportPhoto], groups: [ImportGroup]) {
        var ordered: [ImportPhoto] = []
        ordered.reserveCapacity(photos.count)
        var groups: [ImportGroup] = []
        for (name, places) in runs where !places.isEmpty {
            let start = ordered.count
            ordered.append(contentsOf: places.map { photos[$0] })
            groups.append(ImportGroup(name: name, places: start ..< ordered.count))
        }
        return (ordered, groups.isEmpty ? [ImportGroup(name: "", places: 0 ..< 0)] : groups)
    }

    /// `5 October 2026`, as the library names a day.
    private static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}

/// One of the groups the import window's grid shows: its name in words, and its photos' places among the shown
/// source's (`ImportWindowModel.photos`).
struct ImportGroup: Equatable, Sendable {
    let name: String
    let places: Range<Int>
}
