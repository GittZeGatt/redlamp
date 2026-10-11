import Foundation

/// One Undo for the window's two modules (LIB-13), as Lightroom Classic has it: ⌘Z in either takes back the newest
/// change of either, and ⇧⌘Z makes again the one taken back last.
///
/// - **Library's changes** are culling's (`EditorModel+Culling`), the panels' (keywords, metadata, collections and
///   stacks, keywords dragged or painted onto photos, photos dropped on a collection; `LibraryPanels+Changes`), the
///   renames and moves (Move to Folder, photos dropped on a folder; `EditorModel+Files`), the Put Backs
///   (`EditorModel+PutBackUndo`), Library Health's (`EditorModel+HealthUndo`) and the imports from Lightroom Classic
///   (`EditorModel+LightroomUndo`), which Redo doesn't make again. Each kind keeps its own steps and makes and takes
///   them back its own way, whichever module is shown.
/// - **Develop's changes** are the steps of the open photo's History (`EditorModel+History`). Undo reaches them
///   while Develop has the photo open, shown or behind Library, where a step taken back is saved and its thumbnail
///   follows. Once Develop lets the photo go (another photo opened there, or made active in Library), its steps
///   leave Undo, as they always left Develop's, and stay in its History as an earlier session.
/// - **One order:** every step has a turn from one clock, given as it goes on Undo and again as it goes on Redo. ⌘Z
///   takes back the step whose turn on Undo is the latest, whatever its kind, and ⇧⌘Z makes again the one taken back
///   last. A change of either module ends every Redo: Develop's steps taken back stay in its History, but ⇧⌘Z no
///   longer makes them again. A change takes its turn as it's asked for, so one whose batch is still running is
///   taken back after it's made.
/// - Undo keeps `libraryUndoLimit` of Library's steps, of all its kinds together, the oldest going first; Develop's
///   History keeps its own. In Recently Trashed, whose photos are in the Trash, Undo and Redo reach a Put Back alone.
extension EditorModel {
    /// The kinds of change Undo takes back, each with an Undo of its own.
    enum UndoKind {
        case develop, culling, panels, files, putBack, health, lightroom

        /// The module whose change it is.
        var module: AppModule {
            self == .develop ? .develop : .library
        }
    }

    /// The steps Library's Undo keeps, of every kind together.
    static let libraryUndoLimit = 20

    /// The kind of change ⌘Z takes back now, of either module; nil when there's none.
    var libraryUndoKind: UndoKind? {
        Self.latest([
            (.develop, developUndoTurn),
            (.culling, cullingUndo.last?.turn),
            (.panels, libraryPanels.undoSteps.last?.turn),
            (.files, fileSteps.undo.last?.turn),
            (.putBack, putBackSteps.undo.last?.turn),
            (.health, healthSteps.undo.last?.turn),
            (.lightroom, lightroomSteps.undo.last?.turn),
        ])
    }

    /// The kind of change ⇧⌘Z makes again now, of either module; nil when there's none.
    var libraryRedoKind: UndoKind? {
        Self.latest([
            (.develop, developRedoTurn),
            (.culling, cullingRedo.last?.turn),
            (.panels, libraryPanels.redoSteps.last?.turn),
            (.files, fileSteps.redo.last?.turn),
            (.putBack, putBackSteps.redo.last?.turn),
            (.health, healthSteps.redo.last?.turn),
        ])
    }

    /// The next turn in Undo and Redo, for a step going on either.
    func nextLibraryTurn() -> Int {
        undoClock.turns += 1
        return undoClock.turns
    }

    /// A change was asked for, and put on Undo: nothing taken back is made again, whatever its kind or module, and
    /// Library's oldest steps beyond `libraryUndoLimit` go, whatever theirs.
    func endLibraryRedo() {
        dropCullingRedo()
        if !libraryPanels.redoSteps.isEmpty {
            libraryPanels.redoSteps.removeAll()
        }
        if !fileSteps.redo.isEmpty {
            fileSteps.redo.removeAll()
        }
        if !putBackSteps.redo.isEmpty {
            putBackSteps.redo.removeAll()
        }
        if !healthSteps.redo.isEmpty {
            healthSteps.redo.removeAll()
        }
        undoClock.redoEnded = undoClock.turns
        limitLibraryUndo()
    }

    // MARK: - ⌘Z and ⇧⌘Z

    /// Undo and Redo, in either module; nil for every other action.
    func performUndoShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .undo: undoNewest()
        case .redo: redoNewest()
        default: nil
        }
    }

    /// Whether `performUndoShortcut` would do something now; nil for the actions it leaves alone. A burst of arrow
    /// presses in the palette, or a run of nudges, is a step not yet recorded, and ⌘Z takes it back.
    func canPerformUndoShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .undo:
            if let kind = libraryUndoKind, undoReaches(kind) {
                return true
            }
            return commandPalette?.hasOpenStep == true || hasOpenNudgeRun
        case .redo:
            guard let kind = libraryRedoKind else { return false }
            return undoReaches(kind)
        default:
            return nil
        }
    }

    /// Whether Undo and Redo reach a change of `kind` now: in Recently Trashed a Put Back alone, and an import from
    /// Lightroom Classic once no import or Undo of one is running.
    private func undoReaches(_ kind: UndoKind) -> Bool {
        switch kind {
        case .putBack: true
        case .lightroom: !library.showsRecentlyTrashed && !isRunningLightroomImport
        default: !library.showsRecentlyTrashed
        }
    }

    /// ⌘Z: the newest change of either module taken back, an open step of Develop's recorded first, and said in
    /// the notice (`UndoNotice`).
    private func undoNewest() -> Bool {
        commandPalette?.endBurst()
        endNudgeRun()
        guard let kind = libraryUndoKind, undoReaches(kind) else { return false }
        let title = undoTitle(of: kind)
        guard takeBackNewest(kind) else { return false }
        if let title {
            sayUndone(title, redone: false, of: kind.module)
        }
        return true
    }

    /// ⇧⌘Z: the change taken back last, of either module, made again, and said in the notice.
    private func redoNewest() -> Bool {
        commandPalette?.endBurst()
        endNudgeRun()
        guard let kind = libraryRedoKind, undoReaches(kind) else { return false }
        let title = redoTitle(of: kind)
        guard makeAgainLast(kind) else { return false }
        if let title {
            sayUndone(title, redone: true, of: kind.module)
        }
        return true
    }

    /// The newest change of `kind` taken back.
    private func takeBackNewest(_ kind: UndoKind) -> Bool {
        switch kind {
        case .develop:
            let step = historyIndex
            undo()
            return historyIndex < step
        case .culling:
            return undoCulling()
        case .panels:
            let restacks = libraryPanels.undoSteps.last?.changes.contains(where: \.isStacks) == true
            guard libraryPanels.undoInLibrary() == true else { return false }
            if restacks {
                restackAfterPanels()
            }
            return true
        case .files:
            return undoFiles()
        case .putBack:
            return undoPutBack()
        case .health:
            return undoHealth()
        case .lightroom:
            return undoLightroomImport()
        }
    }

    /// The change of `kind` taken back last made again.
    private func makeAgainLast(_ kind: UndoKind) -> Bool {
        switch kind {
        case .develop:
            let step = historyIndex
            redo()
            return historyIndex > step
        case .culling:
            return redoCulling()
        case .panels:
            let restacks = libraryPanels.redoSteps.last?.changes.contains(where: \.isStacks) == true
            guard libraryPanels.redoInLibrary() == true else { return false }
            if restacks {
                restackAfterPanels()
            }
            return true
        case .files:
            return redoFiles()
        case .putBack:
            return redoPutBack()
        case .health:
            return redoHealth()
        case .lightroom:
            return false
        }
    }

    /// What Undo would take back of `kind`, as its step is titled.
    private func undoTitle(of kind: UndoKind) -> String? {
        switch kind {
        case .develop: history.indices.contains(historyIndex) ? history[historyIndex].title : nil
        case .culling: cullingUndo.last?.title
        case .panels: libraryPanels.undoSteps.last?.title
        case .files: fileSteps.undo.last?.title
        case .putBack: putBackSteps.undo.last?.title
        case .health: healthSteps.undo.last?.title
        case .lightroom: lightroomSteps.undo.last?.title
        }
    }

    /// What Redo would make again of `kind`, as its step is titled.
    private func redoTitle(of kind: UndoKind) -> String? {
        switch kind {
        case .develop: history.indices.contains(historyIndex + 1) ? history[historyIndex + 1].title : nil
        case .culling: cullingRedo.last?.title
        case .panels: libraryPanels.redoSteps.last?.title
        case .files: fileSteps.redo.last?.title
        case .putBack: putBackSteps.redo.last?.title
        case .health: healthSteps.redo.last?.title
        case .lightroom: nil
        }
    }

    // MARK: - Develop's steps

    /// The turn of the open photo's step ⌘Z takes back, while Develop has the photo open, shown or not.
    private var developUndoTurn: Int? {
        guard canUndo, info != nil, opening == nil, history.indices.contains(historyIndex) else { return nil }
        return undoClock.develop[history[historyIndex].id] ?? 0
    }

    /// The turn of the open photo's step ⇧⌘Z makes again, while Develop has the photo open and no change has been
    /// asked for since it was taken back.
    private var developRedoTurn: Int? {
        guard canRedo, info != nil, opening == nil,
              let turn = undoClock.developRedo[history[historyIndex + 1].id], turn > undoClock.redoEnded
        else { return nil }
        return turn
    }

    /// Develop recorded the step at `historyIndex`: it goes on Undo, newest, and ends every Redo.
    func developStepRecorded() {
        guard history.indices.contains(historyIndex) else { return }
        let clock = undoClock
        if clock.develop.count > history.count + Self.developTurnsKept {
            let current = Set(history.map(\.id))
            clock.develop = clock.develop.filter { current.contains($0.key) }
            clock.developRedo = clock.developRedo.filter { current.contains($0.key) }
        }
        clock.develop[history[historyIndex].id] = nextLibraryTurn()
        endLibraryRedo()
    }

    /// History went from step `old` to step `new`, by Undo, Redo or a click in History: the steps taken back go on
    /// Redo, the one after `new` last, so it's the first made again; the steps made again go on Undo, `new` last.
    func developHistoryMoved(from old: Int, to new: Int) {
        guard history.indices.contains(old), history.indices.contains(new) else { return }
        if new < old {
            for index in stride(from: old, to: new, by: -1) {
                undoClock.developRedo[history[index].id] = nextLibraryTurn()
            }
        } else if new > old {
            for index in old + 1 ... new {
                undoClock.develop[history[index].id] = nextLibraryTurn()
            }
        }
    }

    /// The turns of steps of photos Develop has let go that are kept before they're cleared out.
    private static let developTurnsKept = 64

    // MARK: - The limit

    /// Drops Library's oldest steps from Undo, by their turns, until `libraryUndoLimit` are left. Each kind's steps
    /// are in the order of their turns.
    private func limitLibraryUndo() {
        let counts = cullingUndo.count + libraryPanels.undoSteps.count + fileSteps.undo.count
            + putBackSteps.undo.count + healthSteps.undo.count + lightroomSteps.undo.count
        var excess = counts - Self.libraryUndoLimit
        guard excess > 0 else { return }
        let turns: [(UndoKind, [Int])] = [
            (.culling, cullingUndo.map(\.turn)), (.panels, libraryPanels.undoSteps.map(\.turn)),
            (.files, fileSteps.undo.map(\.turn)), (.putBack, putBackSteps.undo.map(\.turn)),
            (.health, healthSteps.undo.map(\.turn)), (.lightroom, lightroomSteps.undo.map(\.turn)),
        ]
        var dropped: [UndoKind: Int] = [:]
        while excess > 0, let oldest = Self.earliest(turns.map { kind, list in
            (kind, list.dropFirst(dropped[kind, default: 0]).first)
        }) {
            dropped[oldest, default: 0] += 1
            excess -= 1
        }
        for (kind, count) in dropped {
            switch kind {
            case .culling: dropOldestCulling(count)
            case .panels: libraryPanels.undoSteps.removeFirst(count)
            case .files: fileSteps.undo.removeFirst(count)
            case .putBack: putBackSteps.undo.removeFirst(count)
            case .health: healthSteps.undo.removeFirst(count)
            case .lightroom: lightroomSteps.undo.removeFirst(count)
            case .develop: break
            }
        }
    }

    private static func latest(_ kinds: [(UndoKind, Int?)]) -> UndoKind? {
        kinds.compactMap { kind, turn in turn.map { (kind, $0) } }.max { $0.1 < $1.1 }?.0
    }

    private static func earliest(_ kinds: [(UndoKind, Int?)]) -> UndoKind? {
        kinds.compactMap { kind, turn in turn.map { (kind, $0) } }.min { $0.1 < $1.1 }?.0
    }

    private var undoClock: UndoClock {
        if let clock = Self.undoClocks.object(forKey: self) {
            return clock
        }
        let clock = UndoClock()
        Self.undoClocks.setObject(clock, forKey: self)
        return clock
    }

    private static let undoClocks = NSMapTable<EditorModel, UndoClock>.weakToStrongObjects()
}

/// The turns given to the steps of Undo and Redo, one editor's: the last given, Develop's steps' on each, by their
/// IDs, and the last turn given when a change ended every Redo.
@MainActor
private final class UndoClock {
    var turns = 0
    var develop: [UUID: Int] = [:]
    var developRedo: [UUID: Int] = [:]
    var redoEnded = 0
}
