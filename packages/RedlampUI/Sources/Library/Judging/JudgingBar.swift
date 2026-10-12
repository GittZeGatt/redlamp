import AppKit
import RedlampDesign

/// The judging tools' buttons (LIB-38), in the loupe's caption row and Compare's bar: sensor clipping (Develop's
/// button, on Develop's key), the raw histogram, focus peaking, the AF point, and the following loupe with its
/// magnifications, shown while it's on. Each button's tooltip names what it shows. The tools are one group and the
/// magnifications another, each drawn as a segmented control.
final class JudgingBar: NSView, ThemeFollowing {
    static let height: CGFloat = 22
    private static let iconWidth: CGFloat = 26
    private static let titleWidth: CGFloat = 40
    private static let gap: CGFloat = 4

    private let model: EditorModel
    let clipping: ToolbarButton
    let histogram: ToolbarButton
    let peaking: ToolbarButton
    let afPoint: ToolbarButton
    let loupe: ToolbarButton
    let magnifications: [LoupeMagnification: ToolbarButton]
    private var tracker: Tracker?
    private let toolsGroup = CALayer()
    private let magnificationsGroup = CALayer()

    /// `prefix` starts the buttons' identifiers: `library.loupe.judging` or `library.compare.judging`.
    init(model: EditorModel, prefix: String) {
        self.model = model
        clipping = ToolbarButton(symbol: "camera.aperture", identifier: "\(prefix).clipping")
        histogram = ToolbarButton(symbol: "chart.bar.xaxis", identifier: "\(prefix).histogram")
        peaking = ToolbarButton(symbol: "scope", identifier: "\(prefix).peaking")
        afPoint = ToolbarButton(symbol: "dot.viewfinder", identifier: "\(prefix).afPoint")
        loupe = ToolbarButton(symbol: "plus.magnifyingglass", identifier: "\(prefix).loupe")
        var magnifications: [LoupeMagnification: ToolbarButton] = [:]
        for magnification in LoupeMagnification.allCases {
            let button = ToolbarButton(
                title: magnification.title,
                identifier: "\(prefix).loupe.\(magnification.rawValue)",
                small: true,
            )
            button.toolTip = "Loupe at \(magnification.title)"
            button.onPress = { model.setFollowingLoupe(magnification) }
            magnifications[magnification] = button
        }
        self.magnifications = magnifications
        super.init(frame: CGRect(x: 0, y: 0, width: 160, height: Self.height))
        let key = ShortcutAction.rawClipping.combos.first?.display ?? ""
        clipping.toolTip = "\(ShortcutAction.rawClipping.title) (\(key))"
        histogram.toolTip = "Raw Histogram: what the sensor clipped in each channel"
        peaking.toolTip = "Focus Peaking: the sharp edges marked"
        afPoint.toolTip = "AF Point: where the camera focused"
        loupe.toolTip = "Loupe: magnifies the photo under the pointer"
        clipping.onPress = { model.toggleSensorClipping() }
        histogram.onPress = { model.toggleRawHistogram() }
        peaking.onPress = { model.toggleFocusPeaking() }
        afPoint.onPress = { model.toggleAFPoints() }
        loupe.onPress = { model.toggleFollowingLoupe() }
        for button in [clipping, histogram, peaking, afPoint, loupe]
            + LoupeMagnification.allCases.compactMap({ magnifications[$0] }) {
            addSubview(button)
        }
        ToolbarLook.install(toolsGroup, in: self)
        ToolbarLook.install(magnificationsGroup, in: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Judging Tools")
        setAccessibilityIdentifier(prefix)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    func followTheme() {
        ToolbarLook.follow([toolsGroup, magnificationsGroup])
    }

    /// The bar's width: its five buttons, and the magnifications while the following loupe is on.
    var width: CGFloat {
        let icons = 5 * Self.iconWidth + 4 * Self.gap
        guard model.libraryJudging.magnification != nil else { return icons }
        return icons + 8 + CGFloat(LoupeMagnification.allCases.count) * (Self.titleWidth + Self.gap)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let judging = model.libraryJudging
            clipping.isOn = model.showRawClipping
            histogram.isOn = judging.showsHistogram
            peaking.isOn = judging.showsPeaking
            afPoint.isOn = judging.showsAFPoints
            loupe.isOn = judging.magnification != nil
            for (magnification, button) in magnifications {
                button.isOn = judging.magnification == magnification
                button.isHidden = judging.magnification == nil
            }
            superview?.needsLayout = true
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in [clipping, histogram, peaking, afPoint, loupe] {
            button.frame = CGRect(x: x, y: 0, width: Self.iconWidth, height: Self.height)
            x += Self.iconWidth + Self.gap
        }
        x += 8
        for magnification in LoupeMagnification.allCases {
            magnifications[magnification]?.frame = CGRect(x: x, y: 0, width: Self.titleWidth, height: Self.height)
            x += Self.titleWidth + Self.gap
        }
        ToolbarLook.place(toolsGroup, behind: [clipping, histogram, peaking, afPoint, loupe])
        ToolbarLook.place(magnificationsGroup, behind: LoupeMagnification.allCases.compactMap { magnifications[$0] })
    }
}
