import AppKit
import RedlampDesign
import RedlampLibrary

/// The Library module's toolbar, under the grid or the loupe, as Lightroom Classic's: the grid, the loupe, Compare
/// and Survey, the cell style and the thumbnail size in the grid or the zoom in the loupe, and the photo in
/// Develop or in Finder. Each button's tooltip names its key. Its controls act on the press itself, as
/// the module picker does, rather than tracking the mouse as AppKit's controls do. In the grid, Group By
/// (LIB-41) and, grouped by moment, the Tighter–Looser slider and the moments without a pick are AppKit's
/// own controls until the library's polish phase (LIB-45), as are the painter's field (LIB-21), shown while
/// it's out, and the progress of a batch with its Stop (LIB-26): photos dropped on a folder, moving or copying,
/// and the Undo or Redo of a rename, move or copy.
final class LibraryToolbarView: NSView, NSTextFieldDelegate, ThemeFollowing {
    static let height: CGFloat = 30

    private let model: EditorModel
    private let grid = ToolbarButton(symbol: "square.grid.2x2", identifier: "library.toolbar.grid")
    private let loupe = ToolbarButton(symbol: "photo", identifier: "library.toolbar.loupe")
    private let compare = ToolbarButton(symbol: "rectangle.split.2x1", identifier: "library.toolbar.compare")
    private let survey = ToolbarButton(symbol: "rectangle.split.2x2", identifier: "library.toolbar.survey")
    private let styles: [GridCellStyle: ToolbarButton]
    private let size = ToolbarSlider(identifier: "library.toolbar.size")
    private let fit = ToolbarButton(title: LoupeZoom.fit.title, identifier: "library.toolbar.fit")
    private let actual = ToolbarButton(title: LoupeZoom.actual.title, identifier: "library.toolbar.actual")
    private let develop = ToolbarButton(symbol: "slider.horizontal.3", identifier: "library.toolbar.develop")
    private let finder = ToolbarButton(symbol: "folder", identifier: "library.toolbar.finder")
    private let painterButton = ToolbarButton(symbol: "paintbrush.pointed", identifier: "library.toolbar.painter")
    /// The keywords the painter paints; empty, the active keyword set's.
    private let paints = NSTextField()
    /// A batch under way (`LibraryMoveProgress`), its Stop, and whether the toolbar was last laid out with them.
    private let moving = NSTextField(labelWithString: "")
    private let movingBar = NSProgressIndicator()
    private let movingStop = ToolbarButton(symbol: "xmark.circle.fill", identifier: "library.toolbar.stop")
    private var showsMoving = false
    private let groupBy = NSPopUpButton(frame: .zero, pullsDown: false)
    private let looseness = NSSlider(
        value: 0, minValue: Double(MomentSetting.tightest), maxValue: Double(MomentSetting.loosest), target: nil,
        action: nil,
    )
    private let tighter = NSTextField(labelWithString: "Tighter")
    private let looser = NSTextField(labelWithString: "Looser")
    private let unpicked = NSButton(title: "", target: nil, action: nil)
    /// The moments-without-a-pick button's width, measured as its title changes, in steps of 40 points, so a
    /// count that changes as photos are picked doesn't lay the window out again.
    private var unpickedWidth: CGFloat = 120
    /// What the toolbar was last laid out for: the grid or the loupe, and which of Group By's controls show.
    private var laidOut: [CGFloat]?
    private var trackers: [Tracker] = []
    /// The bezels behind the views' buttons, the cell styles' and the zoom's, each group as one segmented control.
    private let viewGroup = CALayer()
    private let styleGroup = CALayer()
    private let zoomGroup = CALayer()

    init(model: EditorModel) {
        self.model = model
        var styles: [GridCellStyle: ToolbarButton] = [:]
        let symbols: [GridCellStyle: String] = [
            .compact: "square.grid.3x3.square", .expanded: "rectangle.grid.1x2", .none: "square.grid.3x3",
        ]
        for style in GridCellStyle.allCases {
            styles[style] = ToolbarButton(symbol: symbols[style] ?? "square", identifier: "library.toolbar.\(style)")
        }
        self.styles = styles
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: Self.height))
        grid.toolTip = Self.tip(.gridView)
        loupe.toolTip = Self.tip(.loupeView)
        compare.toolTip = Self.tip(.compareView)
        survey.toolTip = Self.tip(.surveyView)
        develop.toolTip = "Open in Develop (\(ShortcutAction.editTool.combos.first?.display ?? ""))"
        finder.toolTip = Self.tip(.showInFinder)
        fit.toolTip = "Fit (\(ShortcutAction.toggleZoom.combos.first?.display ?? "") or a click)"
        actual.toolTip = "1:1 (\(ShortcutAction.toggleZoom.combos.first?.display ?? "") or a click)"
        size.toolTip = "Thumbnail Size (\(ShortcutAction.smallerThumbnails.combos.first?.display ?? "") and "
            + "\(ShortcutAction.largerThumbnails.combos.first?.display ?? ""))"
        grid.onPress = { model.perform(.gridView) }
        loupe.onPress = { model.perform(.loupeView) }
        compare.onPress = { model.perform(.compareView) }
        survey.onPress = { model.perform(.surveyView) }
        develop.onPress = { model.perform(.editTool) }
        finder.onPress = { model.perform(.showInFinder) }
        fit.onPress = { model.setLoupeZoom(.fit) }
        actual.onPress = { model.setLoupeZoom(.actual) }
        for (style, button) in styles {
            button.toolTip = "\(style.title) (\(ShortcutAction.cycleGridStyle.combos.first?.display ?? "") cycles)"
            button.onPress = { model.setCellStyle(style) }
        }
        size.range = GridSize.range
        size.onChange = { model.setThumbnailSize($0) }
        painterButton.toolTip = "\(Self.tip(.keywordPainter)): click or drag over photos to put keywords on them, ⌥ to take "
            + "them off"
        painterButton.onPress = { model.perform(.keywordPainter) }
        paints.controlSize = .small
        paints.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        paints.delegate = self
        paints.setAccessibilityLabel("Keywords to Paint")
        paints.setAccessibilityIdentifier("library.toolbar.paints")
        moving.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        moving.textColor = LibraryLook.tokens.secondaryLabel.nsColor
        moving.lineBreakMode = .byTruncatingMiddle
        moving.setAccessibilityIdentifier("library.toolbar.moving")
        movingBar.style = .bar
        movingBar.controlSize = .small
        movingBar.isIndeterminate = false
        movingBar.minValue = 0
        movingBar.maxValue = 1
        movingBar.setAccessibilityIdentifier("library.toolbar.movingProgress")
        movingStop.toolTip = "Stop after the photo in hand"
        movingStop.onPress = { model.moveProgress.pressStop() }
        for view in [
            grid,
            loupe,
            compare,
            survey,
            fit,
            actual,
            develop,
            finder,
            size,
            painterButton,
            paints,
            moving,
            movingBar,
            movingStop,
        ]
            + GridCellStyle.allCases.compactMap({ styles[$0] }) as [NSView] {
            addSubview(view)
        }
        setUpGroups()
        for bezel in [viewGroup, styleGroup, zoomGroup] {
            ToolbarLook.install(bezel, in: self)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Library Toolbar")
        setAccessibilityIdentifier("library.toolbar")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func tip(_ action: ShortcutAction) -> String {
        "\(action.title) (\(action.combos.first?.display ?? ""))"
    }

    func followTheme() {
        ToolbarLook.follow([viewGroup, styleGroup, zoomGroup])
        for label in [moving, tighter, looser] {
            label.textColor = LibraryLook.tokens.secondaryLabel.nsColor
        }
        looseness.trackFillColor = LibraryLook.tokens.nativeTint?.nsColor
    }

    private func setUpGroups() {
        let model = model
        groupBy.controlSize = .small
        groupBy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for key in GroupKey.allCases {
            groupBy.addItem(withTitle: key.title)
            groupBy.lastItem?.representedObject = key.rawValue
        }
        groupBy.toolTip = "Group By"
        groupBy.setAccessibilityLabel("Group By")
        groupBy.setAccessibilityIdentifier("library.toolbar.groupBy")
        groupBy.onAction { [weak self] _ in
            guard let self, let raw = groupBy.selectedItem?.representedObject as? String,
                  let key = GroupKey(rawValue: raw) else { return }
            model.setGroupKey(key)
        }
        looseness.controlSize = .small
        looseness.trackFillColor = LibraryLook.tokens.nativeTint?.nsColor
        looseness.numberOfTickMarks = MomentSetting.loosest - MomentSetting.tightest + 1
        looseness.allowsTickMarkValuesOnly = true
        looseness.isContinuous = true
        looseness.toolTip = "Moments: tighter splits at shorter pauses, looser only at longer ones"
        looseness.setAccessibilityLabel("Tighter or Looser Moments")
        looseness.setAccessibilityIdentifier("library.toolbar.looseness")
        looseness.onAction { [weak self] _ in
            guard let self else { return }
            let value = Int(looseness.doubleValue.rounded())
            if value != model.libraryViews.looseness {
                model.setLooseness(value)
            }
        }
        for label in [tighter, looser] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = LibraryLook.tokens.secondaryLabel.nsColor
        }
        unpicked.controlSize = .small
        unpicked.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unpicked.setButtonType(.pushOnPushOff)
        unpicked.bezelStyle = .push
        unpicked.toolTip = ShortcutAction.unpickedMoments.title
        unpicked.setAccessibilityIdentifier("library.toolbar.unpicked")
        unpicked.onAction { _ in model.perform(.unpickedMoments) }
        for view in [groupBy, looseness, tighter, looser, unpicked] as [NSView] {
            addSubview(view)
        }
    }

    /// Group By's controls as the grid's view and its groups have them now.
    private func updateGroups(inGrid: Bool) {
        let state = model.libraryViews
        let groups = model.gridGroups
        let index = GroupKey.allCases.firstIndex(of: state.groupKey) ?? 0
        if groupBy.indexOfSelectedItem != index {
            groupBy.selectItem(at: index)
        }
        Self.set(groupBy, hidden: !inGrid)
        // The photos are listed again as the library starts showing the folder, which grouping needs.
        _ = model.library.count
        let enabled = model.canGroupPhotos || state.groupKey != .ungrouped
        if groupBy.isEnabled != enabled {
            groupBy.isEnabled = enabled
        }
        let moments = inGrid && state.groupKey.usesMoments
        for view in [looseness, tighter, looser] as [NSView] {
            Self.set(view, hidden: !moments)
        }
        if Int(looseness.doubleValue.rounded()) != state.looseness {
            looseness.doubleValue = Double(state.looseness)
        }
        let coverage = groups.coverage
        Self.set(unpicked, hidden: !moments || coverage == nil)
        if let coverage {
            let title = "\(coverage.unpicked.formatted()) of \(coverage.moments.formatted()) "
                + "\(coverage.moments == 1 ? "moment" : "moments") without a pick"
            if unpicked.title != title {
                unpicked.title = title
                unpicked.setAccessibilityLabel(title)
                let font = unpicked.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
                let width = (title as NSString).size(withAttributes: [.font: font]).width + 24
                unpickedWidth = max((width / 40).rounded(.up) * 40, 120)
            }
        }
        let shown: NSControl.StateValue = groups.showsUnpicked ? .on : .off
        if unpicked.state != shown {
            unpicked.state = shown
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                let state = model.libraryViews
                let inGrid = model.libraryView == .grid
                grid.isOn = inGrid
                loupe.isOn = model.libraryView == .loupe
                compare.isOn = model.libraryView == .compare
                survey.isOn = model.libraryView == .survey
                for (style, button) in styles {
                    button.isOn = state.cellStyle == style
                    Self.set(button, hidden: !inGrid)
                }
                Self.set(size, hidden: !inGrid)
                size.value = state.thumbnailSize
                fit.isOn = state.loupeZoom == .fit
                actual.isOn = state.loupeZoom == .actual
                Self.set(fit, hidden: inGrid)
                Self.set(actual, hidden: inGrid)
                updateGroups(inGrid: inGrid)
                updatePainter(inGrid: inGrid)
                let layout: [CGFloat] = [
                    inGrid ? 1 : 0, looseness.isHidden ? 0 : 1, unpicked.isHidden ? 0 : unpickedWidth,
                    paints.isHidden ? 0 : 1,
                ]
                if layout != laidOut {
                    laidOut = layout
                    needsLayout = true
                }
            },
            // Apart from the rest: every step of a held arrow key changes the selection.
            Tracker { [weak self] in
                guard let self else { return }
                let hasPhoto = model.selection != nil
                develop.isEnabled = hasPhoto
                finder.isEnabled = hasPhoto
                loupe.isEnabled = hasPhoto
                compare.isEnabled = hasPhoto
                survey.isEnabled = hasPhoto
            },
            // And a move's progress, which changes ten times a second.
            Tracker { [weak self] in
                guard let self else { return }
                showMoving(model.moveProgress)
            },
        ]
    }

    private func showMoving(_ shown: LibraryMoveProgress) {
        let isMoving = shown.title != nil
        Self.set(moving, hidden: !isMoving)
        Self.set(movingBar, hidden: !isMoving)
        Self.set(movingStop, hidden: !isMoving || shown.stop == nil)
        movingStop.isEnabled = shown.canStop
        if let title = shown.title {
            let progress = shown.progress
            let text = shown.isStopping ? "\(title): stopping after the photo in hand…" : progress.map { progress in
                let steps = "\(RenameModel.count(progress.done)) of \(RenameModel.count(progress.total)) steps"
                return progress.isRollingBack ? "\(title): putting back, \(steps)" : "\(title): \(steps)"
            } ?? "\(title)…"
            if moving.stringValue != text {
                moving.stringValue = text
            }
            let fraction = progress.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 } ?? 0
            if movingBar.doubleValue != fraction {
                movingBar.doubleValue = fraction
            }
        }
        if isMoving != showsMoving {
            showsMoving = isMoving
            needsLayout = true
        }
    }

    /// The painter's button, and while it's out its field, whose placeholder names the keyword set it paints
    /// while the field is empty.
    private func updatePainter(inGrid: Bool) {
        let painter = model.keywordPainter
        painterButton.isOn = painter.isOn
        painterButton.isEnabled = painter.isOn || painter.isAvailable
        Self.set(painterButton, hidden: !inGrid)
        Self.set(paints, hidden: !inGrid || !painter.isOn)
        let placeholder = model.libraryPanels.activeSet.map { "Keywords, or those of “\($0.name)”" }
            ?? "Keywords to paint"
        if paints.placeholderString != placeholder {
            paints.placeholderString = placeholder
        }
        if paints.currentEditor() == nil, paints.stringValue != painter.text {
            paints.stringValue = painter.text
        }
    }

    func controlTextDidChange(_: Notification) {
        model.keywordPainter.text = paints.stringValue
    }

    /// Shows or hides `view` only when that changes it: the trackers set every control again on each change
    /// they read.
    private static func set(_ view: NSView, hidden: Bool) {
        if view.isHidden != hidden {
            view.isHidden = hidden
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        func place(_ view: NSView, width: CGFloat) {
            view.frame = CGRect(x: x, y: (bounds.height - 22) / 2, width: width, height: 22)
            x += width + 2
        }
        for button in [grid, loupe, compare, survey] {
            place(button, width: 28)
        }
        x += 14
        if model.libraryView == .grid {
            for style in GridCellStyle.allCases {
                if let button = styles[style] {
                    place(button, width: 28)
                }
            }
            x += 14
            place(painterButton, width: 28)
            if !paints.isHidden {
                place(paints, width: 200)
            }
            x += 14
            place(groupBy, width: 150)
            if !looseness.isHidden {
                x += 8
                for (view, width) in [(tighter, 44), (looseness, 96), (looser, 40)] as [(NSView, CGFloat)] {
                    place(view, width: width)
                    x += 2
                }
            }
            if !unpicked.isHidden {
                x += 8
                place(unpicked, width: unpickedWidth)
            }
        } else {
            place(fit, width: 40)
            place(actual, width: 40)
        }
        if showsMoving {
            x += 14
            place(moving, width: 240)
            place(movingBar, width: 120)
            if !movingStop.isHidden {
                place(movingStop, width: 22)
            }
        }
        let right = bounds.width - 12
        finder.frame = CGRect(x: right - 28, y: (bounds.height - 22) / 2, width: 28, height: 22)
        develop.frame = CGRect(x: right - 58, y: (bounds.height - 22) / 2, width: 28, height: 22)
        ToolbarLook.place(viewGroup, behind: [grid, loupe, compare, survey])
        ToolbarLook.place(styleGroup, behind: GridCellStyle.allCases.compactMap { styles[$0] })
        ToolbarLook.place(zoomGroup, behind: [fit, actual])
        let sliderWidth = min(200, max(develop.frame.minX - x - 24, 90))
        size.frame = CGRect(
            x: develop.frame.minX - 16 - sliderWidth,
            y: (bounds.height - 22) / 2,
            width: sliderWidth,
            height: 22,
        )
    }
}

/// A toolbar button: a symbol or a title, acting as it's pressed. On, it's lit as a segmented control's chosen
/// segment is; bordered, it has a push button's bezel at rest too, for an action that ends something (Done).
final class ToolbarButton: NSView, ThemeFollowing {
    var onPress: (() -> Void)?
    var isOn = false {
        didSet {
            if isOn != oldValue {
                update()
            }
        }
    }

    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                update()
            }
        }
    }

    var isBordered = false {
        didSet {
            if isBordered != oldValue {
                update()
            }
        }
    }

    /// On a photo's surround (the loupe's, Compare's), in its colours rather than the theme's.
    var onSurround = false {
        didSet {
            if onSurround != oldValue {
                update()
            }
        }
    }

    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let symbol: String?
    /// The symbol's own colours, which the button's state doesn't tint (Survey's ×).
    var palette: [NSColor]? {
        didSet {
            if palette != oldValue {
                needsLayout = true
            }
        }
    }

    /// `palette` draws the symbol in its own colours; `small` sets a title in the system's small size.
    init(
        symbol: String? = nil, title: String? = nil, identifier: String, palette: [NSColor]? = nil,
        small: Bool = false,
    ) {
        self.symbol = symbol
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        if symbol != nil {
            addSubview(image)
        }
        if let title {
            label.stringValue = title
            label.font = .systemFont(ofSize: small ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
            label.alignment = .center
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        update()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var toolTip: String? {
        didSet { setAccessibilityLabel(toolTip) }
    }

    private func update() {
        let tokens = onSurround ? LibraryLook.surroundTokens : LibraryLook.tokens
        let color = (isEnabled ? (isOn ? tokens.value : tokens.label) : tokens.tertiaryLabel).nsColor
        if palette == nil {
            image.contentTintColor = color
        }
        image.alphaValue = isEnabled ? 1 : 0.4
        label.textColor = color
        layer?.backgroundColor = isOn ? ToolbarLook.on(tokens) : isBordered ? ToolbarLook.bezel(tokens) : nil
        setAccessibilityValue(isOn ? "on" : nil)
        setAccessibilityEnabled(isEnabled)
    }

    func followTheme() {
        update()
    }

    override func layout() {
        super.layout()
        image.frame = PixelGrid.snap(bounds.insetBy(dx: 4, dy: 3), scale: backingScale)
        if let symbol {
            image.image = Self.image(symbol, palette: palette, in: image.frame.size)
        }
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    /// The symbol at 13 points (15 in its own colours), smaller where it doesn't fit `size`, as an image view scales
    /// one down, at the middle of an image `size` across.
    private static func image(_ symbol: String, palette: [NSColor]?, in size: CGSize) -> NSImage {
        let pointSize: CGFloat = palette == nil ? 13 : 15
        let own = PixelSymbol.size(symbol, pointSize: pointSize)
        let fit = min(1, size.width / max(own.width, 1), size.height / max(own.height, 1))
        return PixelSymbol.image(symbol, pointSize: pointSize * fit, size: size, palette: palette)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        if isEnabled {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// The thumbnail size's slider, drawn as the system's: a track filled in the accent up to a round knob, which follows
/// the pointer from the press to the release, between a small photo and a large one, as Finder's icon size slider
/// has them. Its track and knob are the theme's, as Develop's sliders' are.
final class ToolbarSlider: NSView, ThemeFollowing {
    var onChange: ((Double) -> Void)?
    var range: ClosedRange<Double> = 0 ... 1
    var value: Double = 0 {
        didSet {
            if value != oldValue {
                needsLayout = true
                setAccessibilityValue(Int(value.rounded()))
            }
        }
    }

    private let track = CALayer()
    private let filled = CALayer()
    private let knob = CALayer()
    private let small = NSImageView()
    private let large = NSImageView()

    init(identifier: String) {
        super.init(frame: .zero)
        wantsLayer = true
        track.cornerRadius = 2
        filled.cornerRadius = 2
        knob.cornerRadius = 7
        knob.borderWidth = 0.5
        knob.shadowOpacity = 1
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        knob.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 14, height: 14), transform: nil)
        for layer in [track, filled, knob] {
            layer.actions = LibraryGridCell.noActions
            self.layer?.addSublayer(layer)
        }
        let icons: [(NSImageView, CGFloat, CGSize)] = [
            (small, 9, CGSize(width: 16, height: 14)), (large, 13, CGSize(width: 20, height: 16)),
        ]
        for (view, size, canvas) in icons {
            view.image = PixelSymbol.image("photo", pointSize: size, size: canvas)
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        followTheme()
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Thumbnail Size")
        setAccessibilityIdentifier(identifier)
    }

    func followTheme() {
        let tokens = LibraryLook.tokens
        track.backgroundColor = tokens.track.cgColor
        knob.backgroundColor = tokens.thumb.cgColor
        knob.borderColor = tokens.thumbStroke.cgColor
        knob.shadowColor = tokens.thumbShadow.cgColor
        for view in [small, large] {
            view.contentTintColor = tokens.secondaryLabel.nsColor
        }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    private var span: (left: CGFloat, width: CGFloat) {
        (25, max(bounds.width - 54, 1))
    }

    override func layout() {
        super.layout()
        let (left, width) = span
        let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
        filled.backgroundColor = LibraryLook.ring
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: left, y: bounds.midY - 2, width: width, height: 4)
        filled.frame = CGRect(x: left, y: bounds.midY - 2, width: width * fraction, height: 4)
        knob.frame = CGRect(x: left + width * fraction - 7, y: bounds.midY - 7, width: 14, height: 14)
        CATransaction.commit()
        let scale = backingScale
        small.frame = PixelGrid.snap(CGRect(x: 2, y: bounds.midY - 7, width: 16, height: 14), scale: scale)
        large.frame = PixelGrid.snap(
            CGRect(x: bounds.width - 22, y: bounds.midY - 8, width: 20, height: 16),
            scale: scale,
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        follow(event)
    }

    override func mouseDragged(with event: NSEvent) {
        follow(event)
    }

    private func follow(_ event: NSEvent) {
        let (left, width) = span
        let x = convert(event.locationInWindow, from: nil).x
        let fraction = min(max((x - left) / width, 0), 1)
        onChange?(range.lowerBound + (range.upperBound - range.lowerBound) * fraction)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onChange?(GridSize.larger(than: value))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onChange?(GridSize.smaller(than: value))
        return true
    }
}

/// The bezels of the Library's bars' buttons, in the theme's colours as Develop's tool strip draws its own.
@MainActor
enum ToolbarLook {
    /// The module picker's chosen segment, on the window's toolbar.
    static let chosen = NSColor(white: 1, alpha: 0.2).cgColor

    /// Behind a group of buttons that go together, as a segmented control's segments do: a well.
    static func group(_ tokens: PaletteTokens) -> CGColor {
        tokens.well.cgColor
    }

    /// A bordered button at rest.
    static func bezel(_ tokens: PaletteTokens) -> CGColor {
        tokens.well.cgColor
    }

    /// The chosen segment, or a button that's on: the selection colour.
    static func on(_ tokens: PaletteTokens) -> CGColor {
        tokens.selection.cgColor
    }

    /// A group's bezel, behind `views`, the union of their frames a little larger; hidden when none is shown.
    static func place(_ bezel: CALayer, behind views: [NSView]) {
        let shown = views.filter { !$0.isHidden }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bezel.isHidden = shown.isEmpty
        if let first = shown.first {
            bezel.frame = shown.dropFirst().reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -2, dy: -2)
        }
        CATransaction.commit()
    }

    /// Groups' bezels in the colours of `tokens` as they are now: the theme's, or the surround's on a photo's.
    static func follow(_ bezels: [CALayer], tokens: PaletteTokens = LibraryLook.tokens) {
        for bezel in bezels {
            bezel.backgroundColor = group(tokens)
        }
    }

    /// Puts a group's bezel in `view`, below the buttons it's to go behind.
    static func install(_ bezel: CALayer, in view: NSView, tokens: PaletteTokens = LibraryLook.tokens) {
        bezel.backgroundColor = group(tokens)
        bezel.cornerRadius = 8
        bezel.actions = LibraryGridCell.noActions
        bezel.isHidden = true
        view.wantsLayer = true
        view.layer?.insertSublayer(bezel, at: 0)
    }
}
