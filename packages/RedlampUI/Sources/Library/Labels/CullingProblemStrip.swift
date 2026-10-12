import AppKit
import RedlampDesign

/// Over the top of the Library's photos, a culling change some of them didn't get (`EditorModel.cullingProblem`): how
/// many and which, and why, with Select, Try Again and Close (LIB-15), on a caution notice in the theme's colours
/// (`Palette.notice`). Hidden while there's none, so it takes no click meant for the photos under it.
final class CullingProblemStrip: NSView, ThemeFollowing {
    private let model: EditorModel
    private var tracker: Tracker?
    private let message = NSTextField(labelWithString: "")
    private let symbol = NSImageView(
        image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage(),
    )
    private var buttons: [NSButton] = []

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.lineBreakMode = .byTruncatingMiddle
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setAccessibilityIdentifier("library.cullingProblem.message")
        let select = ActionButton(title: "Select") { [weak model] in model?.selectCullingProblem() }
        let retry = ActionButton(title: "Try Again") { [weak model] in _ = model?.retryCulling() }
        let close = ActionButton(title: "") { [weak model] in model?.closeCullingProblem() }
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        close.imagePosition = .imageOnly
        let buttons = [
            (select, "select", "Select the photos it wasn't saved to"),
            (retry, "retry", "Make the change again on those photos"), (close, "close", "Close"),
        ]
        for (button, identifier, tip) in buttons {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.toolTip = tip
            button.setAccessibilityIdentifier("library.cullingProblem.\(identifier)")
        }
        self.buttons = [select, retry, close]
        followTheme()
        let stack = NSStackView(views: [symbol, message, select, retry, close])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("library.cullingProblem")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func followTheme() {
        let tokens = LibraryLook.tokens
        let caution = tokens.notice(.caution)
        layer?.backgroundColor = caution.fill.over(tokens.panelBackground.opacity(0.94)).cgColor
        layer?.borderColor = caution.border.cgColor
        symbol.contentTintColor = caution.glyph.nsColor
        message.textColor = tokens.value.nsColor
        for button in buttons {
            button.contentTintColor = LibraryLook.nativeTint
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in self?.update() }
    }

    private func update() {
        let problem = model.module == .library ? model.cullingProblem : nil
        if isHidden != (problem == nil) {
            isHidden = problem == nil
        }
        message.stringValue = problem?.message ?? ""
        message.toolTip = problem?.message
        setAccessibilityLabel(problem?.message)
    }
}
