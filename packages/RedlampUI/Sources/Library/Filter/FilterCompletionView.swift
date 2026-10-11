import AppKit

/// The completions of the term being typed in the filter bar's field (LIB-18, LIB-45): a few rows over the grid under
/// the text being typed, drawn as the system draws a menu, the one Tab or Return takes lit in the accent colour, each
/// taken by a click.
final class FilterCompletionView: NSView {
    var onChoose: ((FilterCompletion) -> Void)?
    private(set) var items: [FilterCompletion] = []
    private let material = NSVisualEffectView()
    private let highlight = NSView()
    private var rows: [NSTextField] = []
    private var kinds: [NSTextField] = []
    private var chosenIndex = 0
    static let rowHeight: CGFloat = 24
    private static let inset: CGFloat = 5

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        material.material = .menu
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 8
        material.layer?.masksToBounds = true
        material.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        material.layer?.borderWidth = 1
        addSubview(material)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        material.addSubview(highlight)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Completions")
        setAccessibilityIdentifier("library.filter.completions")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    var chosen: FilterCompletion? {
        items.indices.contains(chosenIndex) ? items[chosenIndex] : nil
    }

    func show(_ items: [FilterCompletion]) {
        guard items != self.items else { return }
        self.items = items
        chosenIndex = 0
        while rows.count < items.count {
            let row = Self.label(.labelColor)
            let kind = Self.label(.secondaryLabelColor)
            kind.alignment = .right
            rows.append(row)
            kinds.append(kind)
            material.addSubview(row)
            material.addSubview(kind)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= items.count
            kinds[index].isHidden = index >= items.count
            if index < items.count {
                row.stringValue = items[index].title
                kinds[index].stringValue = items[index].detail
                row.setAccessibilityIdentifier("library.filter.completion.\(index)")
            }
        }
        isHidden = items.isEmpty
        highlightChosen()
        needsLayout = true
    }

    private static func label(_ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        chosenIndex = (chosenIndex + offset + items.count) % items.count
        highlightChosen()
    }

    private func highlightChosen() {
        for (index, row) in rows.enumerated() {
            let lit = index == chosenIndex && index < items.count
            row.textColor = lit ? .alternateSelectedControlTextColor : .labelColor
            kinds[index].textColor = lit ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
        highlight.isHidden = items.isEmpty
        needsLayout = true
    }

    /// Below `rect`, in `host`'s coordinates, as tall as its rows.
    func place(under rect: CGRect, in host: NSView) {
        let height = CGFloat(items.count) * Self.rowHeight + 2 * Self.inset
        let y = host.isFlipped ? rect.minY : rect.minY - height
        frame = CGRect(x: rect.minX, y: y, width: rect.width, height: height)
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        let width = bounds.width
        for (index, row) in rows.enumerated() where index < items.count {
            let y = Self.inset + CGFloat(index) * Self.rowHeight
            row.frame = CGRect(x: 14, y: y + 4, width: width - 140, height: Self.rowHeight - 8)
            kinds[index].frame = CGRect(x: width - 124, y: y + 4, width: 110, height: Self.rowHeight - 8)
        }
        highlight.frame = CGRect(
            x: Self.inset, y: Self.inset + CGFloat(chosenIndex) * Self.rowHeight,
            width: width - 2 * Self.inset, height: Self.rowHeight,
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - Self.inset) / Self.rowHeight)
        if items.indices.contains(index) {
            onChoose?(items[index])
        }
    }
}
