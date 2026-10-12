import AppKit
import RedlampDesign
import RedlampDocument
import RedlampRecipes

/// One row of a sidebar list. Its chevron, icon and title line up with the panel header's
/// chevron, glyph and title, so the lists read as the inspector's panels do. In a source list
/// (LIB-45), its title, icon and count are a Mac sidebar's: the system's font and symbols at the
/// sidebar size chosen in System Settings, in the system's label colours, the count in the secondary one.
final class SidebarCellView: NSTableCellView {
    /// A source list's sizes, for its row size: the title's font matches AppKit's, and every icon has a slot
    /// as wide, so the titles line up.
    @MainActor enum SourceListLayout {
        static func textSize(_ size: NSTableView.RowSizeStyle) -> CGFloat {
            switch size {
            case .small: 11
            case .large: 15
            default: 13
            }
        }

        static func iconSlot(_ size: NSTableView.RowSizeStyle) -> CGFloat {
            switch size {
            case .small: 21
            case .large: 29
            default: 25
            }
        }

        /// AppKit's sidebar symbols: at the title's size, in the large scale.
        static func symbolConfiguration(_ size: NSTableView.RowSizeStyle) -> NSImage.SymbolConfiguration {
            NSImage.SymbolConfiguration(pointSize: textSize(size), weight: .regular, scale: .large)
        }

        static let iconGap: CGFloat = 6
        /// The lines that say what a section holds while it's empty are quieter than its rows, and wrap.
        static let placeholderSize: CGFloat = 11
    }

    /// The height of the line `text` saying what an empty section holds, wrapped to `width`, as its label lays out
    /// its lines: a label shorter than that leaves its last line out.
    static func placeholderHeight(_ text: String, width: CGFloat) -> CGFloat {
        placeholderMeasure.stringValue = text
        // A label draws its text inset by `labelPadding` on each side.
        let bounds = CGRect(
            x: 0, y: 0, width: max(width, 1) + Layout.labelPadding * 2, height: .greatestFiniteMagnitude,
        )
        return placeholderMeasure.cell?.cellSize(forBounds: bounds).height ?? 0
    }

    /// A label set up as those lines' labels are, to measure them.
    private static let placeholderMeasure: NSTextField = {
        let label = NSTextField(labelWithString: "")
        stylePlaceholder(label)
        return label
    }()

    /// A source list's line saying what an empty section holds: quieter than its rows, and wrapping.
    private static func stylePlaceholder(_ label: NSTextField) {
        label.font = .systemFont(ofSize: SourceListLayout.placeholderSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
    }

    /// Positions from where the row starts (the panel's padding, then a level further in for
    /// each level down), taken from the panel header's layout.
    @MainActor enum Layout {
        /// The Develop panels' control rows, with their labels' font and their glyphs' size.
        static let rowHeight = Metrics.controlRowMinHeight
        static let rowFont = Typography.label.nsFont
        static let iconPointSize: CGFloat = 11
        static let indent: CGFloat = 13
        static let chevronSize = Symbol.layoutSize("chevron.right", pointSize: 9, weight: .bold)
        static let iconCenter = chevronSize.width + 8 + Metrics.panelSymbolSlot / 2
        static let titleInset = chevronSize.width + 8 + Metrics.panelSymbolSlot + 6
        /// A label's text sits this far into its frame.
        static let labelPadding: CGFloat = 2
        /// When even its value after doesn't fit beside it, a history step's title keeps this
        /// share of the row (at least `minimumTitle`) and both truncate.
        static let titleShare: CGFloat = 0.6
        static let minimumTitle: CGFloat = 56
        static let valuesGap: CGFloat = 8
    }

    private let node: SidebarNode
    private let model: EditorModel
    private let look: SidebarOutlineView.Look
    private let rowSize: NSTableView.RowSizeStyle
    private let label = NSTextField(labelWithString: "")
    private var chevron: ChevronView?
    private var icon: NSView?
    private var trailing: NSView?
    /// What a folder's row or Recently Trashed's shows, for `refreshFolder` and `refreshTrash`.
    private var decoration: FolderDecoration?
    private var values: HistoryValuesView?
    private var amountSlider: NSSlider?
    private var hoverArea: NSTrackingArea?
    /// A source list's line saying what an empty section holds, which wraps.
    private var wraps = false

    /// A group's or earlier session's chevron points down while its rows show.
    var isExpanded: Bool {
        didSet { chevron?.isExpanded = isExpanded }
    }

    init(
        node: SidebarNode, model: EditorModel, isExpanded: Bool = false, look: SidebarOutlineView.Look = .panel,
        rowSize: NSTableView.RowSizeStyle = .medium,
    ) {
        self.node = node
        self.model = model
        self.isExpanded = isExpanded
        self.look = look
        self.rowSize = rowSize
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.font = look == .sourceList ? .systemFont(ofSize: SourceListLayout.textSize(rowSize)) : Layout.rowFont
        addSubview(label)
        var symbol: String?
        switch node.kind {
        case let .group(name):
            label.stringValue = name
            label.textColor = Palette.secondaryLabel.nsColor
            showChevron()
            symbol = "folder"
        case let .recipe(recipe):
            label.stringValue = recipe.name
            label.textColor = Palette.label.nsColor
            toolTip = [recipe.summary, "Hover to preview, click to apply"].compactMap(\.self).joined(separator: "\n")
            if model.recipes.isFavorite(recipe) {
                trailing = SymbolImageView("star.fill", pointSize: 9, color: Palette.secondaryLabel.nsColor)
            } else if recipe.usesLookTable {
                trailing = SymbolImageView("cube", pointSize: 9, color: Palette.tertiaryLabel.nsColor)
            }
        case let .recipeAmount(title, amount):
            label.stringValue = "Amount  \(Int(amount.rounded()))"
            label.font = .systemFont(ofSize: 11)
            label.textColor = Palette.secondaryLabel.nsColor
            toolTip = "Strength of “\(title)”. 0 leaves the photo as it was; 200 goes twice as far."
            let slider = NSSlider(value: amount, minValue: 0, maxValue: 200, target: nil, action: nil)
            slider.controlSize = .small
            slider.isContinuous = true
            slider.setAccessibilityLabel("Recipe Amount")
            let model = model
            let label = label
            slider.onAction { slider in
                if model.editStart == nil {
                    model.beginEdit()
                }
                model.setRecipeAmount(slider.doubleValue)
                label.stringValue = "Amount  \(Int(slider.doubleValue.rounded()))"
                if NSApp.currentEvent?.type == .leftMouseUp {
                    model.endEdit(.recipe, "Recipe Amount", value: EditorModel.recipeAmountText)
                }
            }
            amountSlider = slider
            addSubview(slider)
        case let .placeholder(text):
            label.stringValue = text
            if look == .sourceList {
                Self.stylePlaceholder(label)
                wraps = true
            } else {
                label.textColor = Palette.tertiaryLabel.nsColor
            }
        case let .snapshot(snapshot):
            label.stringValue = snapshot.name
            symbol = "camera.viewfinder"
        case .history, .session, .earlierStep:
            showHistory(node.kind)
        case let .folder(row):
            decorate(row)
        case let .recentlyTrashed(row):
            setAccessibilityIdentifier("folders.recently-trashed")
            show(Self.trashDecoration(row))
        case let .source(row):
            setAccessibilityIdentifier(row.identifier)
            if row.hasChildren, look == .panel {
                showChevron()
            }
            show(Self.sourceDecoration(row))
        case .libraryHealth:
            setAccessibilityIdentifier("sources.health")
            if look == .panel {
                showChevron()
            }
            show(Self.healthDecoration)
        }
        if let symbol {
            showIcon(symbol)
        }
        if let trailing {
            addSubview(trailing)
        }
        if let values {
            addSubview(values)
        }
        needsLayout = true
    }

    private func decorate(_ row: FolderRow) {
        setAccessibilityIdentifier("folders." + row.url.standardizedFileURL.path)
        if row.hasSubfolders, look == .panel {
            showChevron()
        }
        show(Self.folderDecoration(row))
    }

    /// Shows `row`, the folder's row as it is now, in place: only what changed, so a count that changes
    /// sets its text and nothing else.
    func refreshFolder(_ row: FolderRow) {
        show(Self.folderDecoration(row))
    }

    /// Shows Recently Trashed's row as it is now, in place.
    func refreshTrash(_ row: TrashRow) {
        show(Self.trashDecoration(row))
    }

    /// Shows a source's row as it is now, in place: a count that changes sets its text and nothing else.
    func refreshSource(_ row: SourceRow) {
        show(Self.sourceDecoration(row))
    }

    /// Shows `shown` over what the row showed.
    private func show(_ shown: FolderDecoration) {
        let before = decoration
        guard shown != before else { return }
        decoration = shown
        var relayout = false
        if shown.name != before?.name {
            label.stringValue = shown.name
            relayout = true
        }
        if shown.nameTone != before?.nameTone {
            label.textColor = color(of: shown.nameTone)
        }
        if shown.help != before?.help {
            toolTip = shown.help
        }
        if shown.accessibilityLabel != before?.accessibilityLabel {
            setAccessibilityLabel(shown.accessibilityLabel)
        }
        if shown.symbol != before?.symbol || shown.iconTone != before?.iconTone || shown.nameTone != before?.nameTone {
            icon?.removeFromSuperview()
            // A source list's selected row has its icon in the accent colour with its name.
            showIcon(
                shown.symbol,
                tone: look == .sourceList && shown.nameTone == .emphasized ? .emphasized : shown.iconTone,
            )
            relayout = true
        }
        if let count = trailing as? FolderCountView, let text = shown.count {
            count.text = text
        } else if shown.count != before?.count || shown.isMissing != before?.isMissing {
            trailing?.removeFromSuperview()
            trailing = trailing(shown)
            if let trailing, before != nil {
                addSubview(trailing)
            }
            relayout = true
        }
        if relayout, before != nil {
            needsLayout = true
        }
    }

    /// A name's colour for `tone`: the panels' palette, or a source list's system colours, its selected row's name in
    /// the accent colour, as AppKit sets a selected row's while its list doesn't have the keyboard.
    private func color(of tone: Tone) -> NSColor {
        switch (look, tone) {
        case (.panel, .primary): Palette.label.nsColor
        case (.panel, .group): Palette.secondaryLabel.nsColor
        case (.panel, .dimmed): Palette.tertiaryLabel.nsColor
        case (.panel, .emphasized): Palette.labelHover.nsColor
        case (.sourceList, .dimmed): .tertiaryLabelColor
        case (.sourceList, .emphasized): .controlAccentColor
        case (.sourceList, _): .labelColor
        }
    }

    /// The view at the end of a folder's row: its count, or a missing root's question mark.
    private func trailing(_ decoration: FolderDecoration) -> NSView? {
        let sourceList = look == .sourceList
        if let count = decoration.count {
            return sourceList
                ? FolderCountView(
                    count, font: FontSpec(size: SourceListLayout.textSize(rowSize), monospacedDigits: true),
                    color: .secondaryLabelColor,
                )
                : FolderCountView(count)
        }
        guard decoration.isMissing else { return nil }
        return SymbolImageView(
            "questionmark.circle", pointSize: sourceList ? SourceListLayout.textSize(rowSize) : 10,
            color: sourceList ? .tertiaryLabelColor : Palette.tertiaryLabel.nsColor,
        )
    }

    private func showChevron() {
        let view = ChevronView()
        view.isExpanded = isExpanded
        addSubview(view)
        chevron = view
    }

    /// The row's icon: drawn in the panels' colour, or in a source list an image view with AppKit's sidebar symbol. It
    /// isn't the cell's `imageView`, nor the title its `textField`: AppKit lays those out itself, over these frames.
    private func showIcon(_ symbol: String, tone: Tone = .group) {
        guard look == .sourceList else {
            let color = tone == .dimmed ? Palette.tertiaryLabel : Palette.secondaryLabel
            let image = SymbolImageView(symbol, pointSize: Layout.iconPointSize, color: color.nsColor)
            addSubview(image)
            icon = image
            return
        }
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.symbolConfiguration = SourceListLayout.symbolConfiguration(rowSize)
        image.imageScaling = .scaleNone
        image.contentTintColor = switch tone {
        case .dimmed: .tertiaryLabelColor
        case .emphasized: .controlAccentColor
        default: .labelColor
        }
        image.setAccessibilityElement(false)
        addSubview(image)
        icon = image
    }

    override var isFlipped: Bool {
        true
    }

    /// In a source list the row takes the clicks on its title, icon and count, as AppKit's rows do: a text field in a
    /// list that selects keeps a right-click to itself in a window that isn't key, and the row's menu never opens.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return look == .sourceList && hit != nil ? self : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Laid out by hand on the pixel grid, as SwiftUI rounds (a leftover half point goes
    /// down), rather than by Auto Layout, which rounds it up.
    override func layout() {
        super.layout()
        let scale = backingScale
        func centeredY(_ size: CGSize) -> CGFloat {
            PixelGrid.round((bounds.height - size.height) / 2, scale: scale)
        }
        let iconCenter: CGFloat
        var titleX: CGFloat
        if look == .sourceList {
            let slot = SourceListLayout.iconSlot(rowSize)
            iconCenter = slot / 2
            titleX = icon == nil ? 0 : slot + SourceListLayout.iconGap
        } else {
            iconCenter = Layout.iconCenter
            titleX = Layout.titleInset
        }
        if let amountSlider {
            let width = min(max(bounds.width * 0.55, 80), 160)
            amountSlider.frame = CGRect(
                x: bounds.width - width - 2, y: centeredY(CGSize(width: width, height: 16)), width: width, height: 16,
            )
        }
        if let chevron {
            let size = Layout.chevronSize
            chevron.frame = CGRect(x: 0, y: centeredY(size), width: size.width, height: size.height)
        }
        if let image = icon {
            let size = image.intrinsicContentSize
            image.frame = CGRect(
                x: PixelGrid.round(iconCenter - size.width / 2, scale: scale), y: centeredY(size),
                width: size.width, height: size.height,
            )
        }
        var titleMaxX = amountSlider.map { $0.frame.minX - 4 } ?? bounds.width
        if let trailing {
            var size = trailing.intrinsicContentSize
            // A label draws its text inset by `labelPadding` on each side of its intrinsic width:
            // its frame gets both, reaching past the row's edge so the text ends there.
            let padding = trailing is NSTextField ? Layout.labelPadding : 0
            size.width += padding * 2
            trailing.frame = CGRect(
                x: PixelGrid.round(bounds.width - size.width + padding, scale: scale), y: centeredY(size),
                width: size.width, height: size.height,
            )
            titleMaxX = trailing.frame.minX + padding - 6
        }
        var size = label.intrinsicContentSize
        if let values {
            titleMaxX = place(values, from: titleX, to: titleMaxX, title: size.width)
        }
        if wraps {
            size.height = ceil(Self.placeholderHeight(
                label.stringValue,
                width: titleMaxX - titleX - Layout.labelPadding,
            ))
        }
        titleX -= Layout.labelPadding
        label.frame = CGRect(x: titleX, y: centeredY(size), width: max(titleMaxX - titleX, 0), height: size.height)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func contextMenu() -> NSMenu? {
        let menu = NSMenu()
        switch node.kind {
        case let .snapshot(snapshot):
            menu.addItem(NSMenuItem(title: "Delete Snapshot") { [model] in model.deleteSnapshot(snapshot) })
        case let .recipe(recipe):
            let favorite = model.recipes.isFavorite(recipe)
            menu.addItem(NSMenuItem(title: favorite ? "Remove from Favorites" : "Add to Favorites") { [model] in
                model.recipes.setFavorite(recipe, !favorite)
            })
            menu.addItem(NSMenuItem(title: "Export…") { [model] in RecipeActions.export(recipe, model: model) })
            menu.addItem(NSMenuItem(title: "Duplicate to My Recipes") { [model] in
                var copy = recipe
                copy.id = RecipeNamespace.newLocalID()
                copy.version = 1
                copy.name = "\(recipe.name) Copy"
                copy.group = "My Recipes"
                copy.embeddedBaseLooks = model.recipes.library.exportable(recipe).embeddedBaseLooks
                model.recipes.save(copy)
            })
            if model.recipes.isUserRecipe(recipe) {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Delete Recipe") { [model] in model.recipes.delete(recipe) })
            }
        case let .folder(row):
            return Self.folderMenu(row, model: model, anchor: self)
        case let .source(row):
            return Self.sourceMenu(row, model: model, anchor: self)
        case .libraryHealth:
            return Self.healthMenu(model: model)
        default:
            return nil
        }
        return menu
    }

    // MARK: - Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        guard case .recipe = node.kind else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        label.textColor = Palette.labelHover.nsColor
        guard model.info != nil, case let .recipe(recipe) = node.kind else { return }
        model.previewRecipe(recipe)
    }

    override func mouseExited(with _: NSEvent) {
        label.textColor = Palette.label.nsColor
        guard model.info != nil else { return }
        model.previewRecipe(nil)
    }
}

// MARK: - History

extension SidebarCellView {
    /// A step of this session, an earlier session, or one of its steps.
    private func showHistory(_ kind: SidebarNode.Kind) {
        switch kind {
        case let .history(step, _, current, future):
            showStep(step, current: current, undone: future)
            toolTip = future ? "\(step.name)\nUndone: click to go back to it" : step.name
            setAccessibilityLabel(step.name + (current ? ", current step" : future ? ", undone" : ""))
        case let .session(session):
            label.stringValue = session.title
            label.textColor = Palette.secondaryLabel.nsColor
            showChevron()
            showIcon("clock")
            let count = session.steps.count
            let steps = NSTextField(labelWithString: "\(count) step\(count == 1 ? "" : "s")")
            steps.font = Typography.caption.nsFont
            steps.textColor = Palette.tertiaryLabel.nsColor
            trailing = steps
            toolTip = "An earlier session with this photo, started \(session.title)"
        case let .earlierStep(step, session):
            showStep(step, current: false, undone: false)
            toolTip = "\(step.name)\nFrom \(session.title): click to bring it back as a new step"
            setAccessibilityLabel("\(step.name), from \(session.title)")
        default:
            break
        }
    }

    /// Puts a step's values at the end of the row and returns where its title must end. The
    /// title comes first: short of room, the value before goes, then both truncate.
    private func place(
        _ values: HistoryValuesView,
        from titleX: CGFloat,
        to titleMaxX: CGFloat,
        title: CGFloat,
    ) -> CGFloat {
        let scale = backingScale
        let available = titleMaxX - titleX
        // A label draws its text inset by `labelPadding` on both sides of its intrinsic width.
        let title = title + Layout.labelPadding
        let width = if title + Layout.valuesGap + values.fullWidth <= available {
            values.fullWidth
        } else {
            max(min(
                values.afterWidth,
                available - Layout.valuesGap - min(title, max(available * Layout.titleShare, Layout.minimumTitle)),
            ), 0)
        }
        let height = values.intrinsicContentSize.height
        values.frame = CGRect(
            x: PixelGrid.round(titleMaxX - width, scale: scale),
            y: PixelGrid.round((bounds.height - height) / 2, scale: scale), width: width, height: height,
        )
        return values.frame.minX - Layout.valuesGap
    }

    /// The step's action's icon, its title, and the value it changed before and after.
    private func showStep(_ step: HistoryStep, current: Bool, undone: Bool) {
        label.stringValue = step.title
        label.textColor = (undone ? Palette.tertiaryLabel : current ? Palette.labelHover : Palette.label).nsColor
        showIcon(step.action.symbol, tone: undone ? .dimmed : .group)
        if let after = step.after {
            values = HistoryValuesView(before: step.before, after: after, dimmed: undone)
        }
    }
}

/// A group's chevron, drawn as a panel header's is, and turned down while the group is open.
private final class ChevronView: LayerDrawnView {
    var isExpanded = false {
        didSet {
            if isExpanded != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    override func drawContent(in _: CGRect) {
        Symbol.draw(
            "chevron.right", pointSize: 9, weight: .bold, color: Palette.secondaryLabel,
            centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), rotation: isExpanded ? 90 : 0, scale: backingScale,
        )
    }
}
