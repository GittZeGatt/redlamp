import AppKit
import Observation
import RedlampDesign

/// What the last Undo or Redo took back or made again, said for a moment over the top of the window's middle, as
/// Lightroom Classic says it (LIB-13): with one Undo for both modules, the change can be the other module's, out of
/// sight, and the notice names that module.
@MainActor
@Observable
@_spi(Harness) public final class UndoNotice {
    /// What's said now; nil once it's gone.
    public private(set) var text: String?
    @ObservationIgnored private var hiding: Task<Void, Never>?

    /// How long a notice stays.
    static let shown = Duration.milliseconds(1500)

    func say(_ text: String) {
        self.text = text
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.shown)
            guard !Task.isCancelled else { return }
            self?.text = nil
        }
    }
}

extension EditorModel {
    @_spi(Harness) public var undoNotice: UndoNotice {
        if let notice = Self.undoNotices.object(forKey: self) {
            return notice
        }
        let notice = UndoNotice()
        Self.undoNotices.setObject(notice, forKey: self)
        return notice
    }

    private static let undoNotices = NSMapTable<EditorModel, UndoNotice>.weakToStrongObjects()

    /// Says that Undo, or Redo when `redone`, reached `title`, a change of `module`'s.
    func sayUndone(_ title: String, redone: Bool, of module: AppModule) {
        let place = module == self.module ? "" : " in \(module.title)"
        undoNotice.say("\(redone ? "Redo" : "Undo") \(title)\(place)")
    }
}

/// The notice, at the top of the modules' middle: shown while there's something to say, clicks going through it to
/// the module shown, and VoiceOver hearing it as it's said.
final class UndoNoticeView: NSView {
    private let model: EditorModel
    private let label = NSTextField(labelWithString: "")
    private var tracker: Tracker?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 8
        label.font = Typography.label.nsFont
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityIdentifier("modules.undoNotice")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// What it says now, for the regression suite and tests; empty while hidden.
    var text: String {
        isHidden ? "" : label.stringValue
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            show(model.undoNotice.text)
        }
    }

    private func show(_ text: String?) {
        guard let text else {
            isHidden = true
            return
        }
        label.stringValue = text
        isHidden = false
        NSAccessibility.post(element: window ?? self, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
