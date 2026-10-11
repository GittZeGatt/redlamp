import AppKit
import Observation
import RedlampDesign
import RedlampDocument

/// The Library module's left column: the Library panel (LIB-23), the Folders panel and the Collections panel, which
/// choose the source the grid and the filmstrip show.
final class LibraryFoldersColumn: PanelColumnScrollView {
    init(model: EditorModel) {
        let add = SymbolImageView("plus", pointSize: 11, color: Palette.secondaryLabel.nsColor)
        add.toolTip = "Add Folder…"
        add.setAccessibilityRole(.button)
        add.setAccessibilityLabel("Add Folder…")
        add.onClick = { FolderActions.add(model: model) }
        let insets = NSEdgeInsets(top: 0, left: 0, bottom: Metrics.panelBottomPadding, right: 0)
        let folders = PanelSectionView(
            section: .folders, model: model, accessory: add, insets: insets, rows: [FolderOutlineView(model: model)],
        )
        super.init(views: [SourcePanels.library(model: model), folders, SourcePanels.collections(model: model)])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The Library module's right column, as Lightroom Classic's: the active photo's file and badges, then the
/// Keywording, Keyword List and Metadata panels (LIB-21, LIB-22), each collapsible, which are open kept between
/// launches (`LibraryPanels`). F8 and ⌥⌘→ show and hide it.
final class LibraryInfoColumn: PanelColumnScrollView {
    private let model: EditorModel

    init(model: EditorModel) {
        self.model = model
        let panels = model.libraryPanels
        func section(_ panel: LibraryPanels.Panel, _ rows: [NSView]) -> PanelSectionView {
            let section = PanelSectionView(
                title: panel.title, symbol: panel.symbol, rows: rows,
                actions: PanelSectionView.Actions(
                    isExpanded: { panels.isExpanded(panel) },
                    isEdited: { false },
                    toggle: { solo in panels.toggle(panel, solo: solo) },
                    reset: {},
                ),
            )
            section.identify(as: "library.\(panel.rawValue)")
            return section
        }
        super.init(views: [
            section(.photo, [PhotoPanelView(model: model)]),
            section(.keywording, [KeywordingPanelView(panels: panels)]),
            section(.keywordList, [KeywordListPanelView(model: model, panels: panels)]),
            section(.metadata, [MetadataPanelView(model: model, panels: panels)]),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            model.libraryPanels.follow()
        }
    }
}
