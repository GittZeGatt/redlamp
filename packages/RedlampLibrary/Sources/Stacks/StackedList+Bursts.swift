import Foundation

/// Lists whose found bursts start open (DEC-64): every frame of a burst the library finds by itself has its cell, the
/// burst marked as one by its first cell's badge, until it's closed; pairs and stacks made by hand start closed. A view
/// says so as it makes its list and as the list changes, whatever `StackedList.opensFoundBursts` says.
public extension StackedList {
    /// `list` with `stacks` shown, every stack closed but, with `opensBursts`, the bursts.
    init(_ list: PhotoList, stacks: Stacks, opensBursts: Bool) {
        self.init(list, stacks: stacks, open: false, bursts: opensBursts)
    }

    /// This list after its list or its stacks changed, as `updated(list:stacks:changed:selection:)` makes it, with
    /// `opensBursts` a burst none of whose photos was in a burst or a manual stack here coming open.
    func updated(
        list newList: PhotoList? = nil, stacks newStacks: Stacks? = nil, changed: [Int64] = [], opensBursts: Bool,
        selection: inout StackSelection,
    ) -> (list: StackedList, diff: PhotoListDiff) {
        let new = remade(list: newList ?? list, stacks: newStacks ?? stacks, bursts: opensBursts)
        var named = changed
        for cell in new where (new.isStacked(cell) || isStacked(cell)) && isShown(cell) {
            if badges(of: cell) != new.badges(of: cell) {
                named.append(cell)
            }
        }
        let diff = PhotoListDiff(
            from: PhotoList(source: list.source, sort: list.sort, ids: ContiguousArray(self)),
            to: PhotoList(source: new.list.source, sort: new.list.sort, ids: ContiguousArray(new)), changed: named,
        )
        selection.carry(from: self, to: new)
        return (new, diff)
    }
}
