import Foundation
import RedlampDocument
import RedlampLibrary

public extension EditorModel {
    /// The soft-frame check's proposals in the Library (LIB-42).
    var librarySoftFrames: LibrarySoftFrames {
        if let softFrames = Self.softFrames.object(forKey: self) {
            return softFrames
        }
        let softFrames = LibrarySoftFrames(model: self, defaults: library.defaults)
        Self.softFrames.setObject(softFrames, forKey: self)
        return softFrames
    }

    private static let softFrames = NSMapTable<EditorModel, LibrarySoftFrames>.weakToStrongObjects()

    /// Shows the proposals in `mode`, or hides them with nil.
    func showProposals(_ mode: SoftFrames.Mode?) {
        let softFrames = librarySoftFrames
        if let mode {
            softFrames.setMode(mode)
        }
        softFrames.setShows(mode != nil)
        activity.record(.action, mode.map { "Proposals: \($0.title)" } ?? "Proposals Off")
    }

    /// Accepts the soft-frame check's proposals as one change with Undo, through culling: a pick for each frame
    /// proposed, a reject for each soft one, and nothing for the frames the user decided, which are never proposed
    /// against. Those of the selection when several photos are selected, else every one the grid shows. False when
    /// there's none to accept.
    @discardableResult
    func acceptProposals() -> Bool {
        let softFrames = librarySoftFrames
        guard module == .library, !softFrames.verdicts.isEmpty else { return false }
        let selected = selectedIDs
        let photos: [Int64] = selected.count > 1 ? selected : Array(library.photoIDs)
        var flags: [Int64: PhotoFlag] = [:]
        var accepted: [Int64] = []
        for photo in photos {
            guard let url = library.url(ofPhoto: photo) else { continue }
            switch softFrames.entry(listed: photo, url: url)?.verdict ?? SoftFrames.Verdict.none {
            case .proposed: flags[photo] = .pick
            case .soft: flags[photo] = .reject
            case .none, .changed: continue
            }
            accepted.append(photo)
        }
        guard !accepted.isEmpty else { return false }
        cull(.flags(flags), photos: accepted)
        activity.record(.action, CullingChange.flags(flags).title)
        return true
    }
}
