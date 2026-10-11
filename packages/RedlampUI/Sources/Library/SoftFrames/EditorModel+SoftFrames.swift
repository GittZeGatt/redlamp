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
        let selection = photoSelection
        let proposals = softFrames.proposals { selection.count < 2 || selection.contains($0) }
        guard !proposals.isEmpty else { return false }
        let flags = Dictionary(proposals.map { ($0.photo, $0.flag) }) { $1 }
        cull(.flags(flags), photos: proposals.map(\.photo))
        activity.record(.action, CullingChange.flags(flags).title)
        return true
    }
}
