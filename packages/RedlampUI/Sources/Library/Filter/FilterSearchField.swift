import AppKit
import RedlampDesign

/// The filter bar's search field (LIB-45, DEC-66): the query's terms as tokens, taken out with Delete, edited with a
/// double-click and moved by dragging, in a field drawn as the system's search field, a magnifying glass at its start
/// and at its end a button that clears it and the two that open the Attribute row and the Metadata columns.
/// `NSSearchField` has no tokens of its own, so this is a token field with the search field's shape and insets.
///
/// The term being typed stays text until a space after it, outside quotes and parentheses, makes it a token: the
/// field tokenizes at spaces only while no quote or parenthesis is open in the text being typed (`followTyping`).
final class FilterSearchField: NSTokenField {
    static let height: CGFloat = 28
    private static let leading: CGFloat = 24
    private static let buttonWidth: CGFloat = 20

    let clearButton = FilterSearchField.button(
        "xmark.circle.fill", identifier: "library.filter.clear", tip: "Clear the Filter",
    )
    let attributeButton = FilterSearchField.button(
        "line.3.horizontal.decrease.circle", identifier: "library.filter.attribute", tip: "Attribute Row",
    )
    let metadataButton = FilterSearchField.button(
        "tablecells", identifier: "library.filter.metadata", tip: "Metadata Columns",
    )
    private let glass = NSImageView()

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height))
        controlSize = .large
        font = .systemFont(ofSize: NSFont.systemFontSize)
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .none
        tokenStyle = .rounded
        tokenizingCharacterSet = Self.tokenizing
        completionDelay = 0
        cell?.isScrollable = true
        cell?.wraps = false
        (cell as? Cell)?.trailing = 3 * Self.buttonWidth + 6
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        addSubview(glass)
        for button in [clearButton, attributeButton, metadataButton] {
            addSubview(button)
        }
        setAccessibilityIdentifier("library.filter.text")
        setAccessibilityLabel("Filter")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A space or a line's end ends a term; a line's end alone while a quote or a parenthesis is open.
    private static let tokenizing = CharacterSet(charactersIn: " \n")
    private static let tokenizingInsideQuotes = CharacterSet(charactersIn: "\n")

    private static func button(_ symbol: String, identifier: String, tip: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
            target: nil, action: nil,
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.refusesFirstResponder = true
        button.toolTip = tip
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(tip)
        return button
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        glass.frame = CGRect(x: 8, y: (height - 16) / 2, width: 16, height: 16)
        var x = bounds.width - 5
        for button in [metadataButton, attributeButton, clearButton] {
            x -= Self.buttonWidth
            button.frame = CGRect(
                x: x,
                y: (height - Self.buttonWidth) / 2,
                width: Self.buttonWidth,
                height: Self.buttonWidth,
            )
        }
    }

    /// Lights a row's button while its row is open.
    func setOpen(attribute: Bool, metadata: Bool) {
        for (button, open) in [(attributeButton, attribute), (metadataButton, metadata)] {
            let tint: NSColor = open ? .controlAccentColor : .secondaryLabelColor
            if button.contentTintColor != tint {
                button.contentTintColor = tint
                button.setAccessibilityValue(open ? "on" : "off")
            }
        }
    }

    // MARK: - What it shows

    /// The query's text as the field shows it: its tokens, and the term being typed, each apart from the next by a
    /// space. Each token is a term (`FilterQueryTerms`).
    var text: String {
        FilterQueryTerms.joined(pieces.map(\.text))
    }

    /// A token, or text being typed.
    enum Piece: Equatable {
        case token(String)
        case typing(String)

        var text: String {
            switch self {
            case let .token(term), let .typing(term): term
            }
        }
    }

    /// The tokens and the text between them as the field editor has them while the field is edited; else its tokens.
    var pieces: [Piece] {
        guard let storage = (currentEditor() as? NSTextView)?.textStorage else {
            return (objectValue as? [Any] ?? []).compactMap { ($0 as? String).map(Piece.token) }
        }
        var pieces: [Piece] = []
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                let term = (attachment.attachmentCell as? NSCell)?.representedObject as? String ?? ""
                pieces += Array(repeating: .token(term), count: range.length)
            } else {
                pieces.append(.typing((storage.string as NSString).substring(with: range)))
            }
        }
        return pieces
    }

    /// The text being typed where the cursor is, where it starts in `text` and the cursor's place in it, in
    /// characters; nil when the cursor isn't in text being typed, or something is selected.
    var typing: (text: String, start: Int, cursor: Int)? {
        guard let editor = currentEditor() as? NSTextView, editor.selectedRange.length == 0 else { return nil }
        let location = editor.selectedRange.location
        var offset = 0
        var text = ""
        for piece in pieces {
            let length = piece.utf16Length
            let trimmed = String(piece.text.drop { $0.isWhitespace })
            let start = text.isEmpty || text.last?.isWhitespace == true ? text.count : text.count + 1
            if case let .typing(typed) = piece, location >= offset, location <= offset + length {
                let index = String.Index(utf16Offset: location - offset, in: typed)
                let cursor = typed.distance(from: typed.startIndex, to: index) - (typed.count - trimmed.count)
                guard cursor >= 0, !trimmed.isEmpty else { return nil }
                return (trimmed, start, cursor)
            }
            if !trimmed.isEmpty {
                text += (start > text.count ? " " : "") + trimmed
            }
            offset += length
        }
        return nil
    }

    /// Shows `text`'s terms as tokens; with `typing`, while the field is edited, the last term, unfinished, as text
    /// being typed, the cursor after it. Nothing it changes reaches the delegate as typed (`isShowing`).
    func show(_ text: String, typing: Bool) {
        var terms = FilterQueryTerms.split(text)
        let last = typing && currentEditor() != nil && !FilterQueryTerms.isFinished(text) ? terms.popLast() : nil
        isShowing = true
        defer { isShowing = false }
        objectValue = terms
        guard let editor = currentEditor() as? NSTextView else { return }
        if let last {
            tokenizingCharacterSet = Self.tokenizingInsideQuotes
            editor.insertText(last, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        }
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        followTyping()
    }

    /// While `show` changes what the field shows, whose changes aren't typing.
    private(set) var isShowing = false

    /// Tokenizes at spaces unless a quote or a parenthesis is open in the text being typed.
    func followTyping() {
        let open = typing.map { FilterQueryTerms.isOpen($0.text) } ?? false
        let wanted = open ? Self.tokenizingInsideQuotes : Self.tokenizing
        if tokenizingCharacterSet != wanted {
            tokenizingCharacterSet = wanted
        }
    }

    /// Where the text being typed starts, in the bar's coordinates, for the completions to be shown under it.
    func typingOrigin(in view: NSView) -> CGPoint {
        let fallback = convert(CGPoint(x: Self.leading + 4, y: bounds.maxY), to: view)
        guard let editor = currentEditor() as? NSTextView, let layout = editor.layoutManager,
              let container = editor.textContainer else { return fallback }
        var location = editor.selectedRange.location
        let string = editor.string as NSString
        while location > 0, string.character(at: location - 1) != 0xFFFC, string.character(at: location - 1) != 0x20 {
            location -= 1
        }
        let glyphs = layout.glyphRange(
            forCharacterRange: NSRange(location: location, length: 0),
            actualCharacterRange: nil,
        )
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let x = editor.convert(CGPoint(x: rect.minX + editor.textContainerOrigin.x, y: 0), to: self).x
        return convert(CGPoint(x: min(max(x - 8, 0), bounds.width - 200), y: bounds.maxY), to: view)
    }

    /// Keeps the text inside the magnifying glass and the buttons, as the search field's own cell does.
    final class Cell: NSTokenFieldCell {
        var trailing: CGFloat = 0

        override func drawingRect(forBounds rect: CGRect) -> CGRect {
            let drawn = super.drawingRect(forBounds: rect)
            return CGRect(
                x: drawn.minX + FilterSearchField.leading, y: drawn.minY,
                width: max(drawn.width - FilterSearchField.leading - trailing, 0), height: drawn.height,
            )
        }
    }
}

private extension FilterSearchField.Piece {
    var utf16Length: Int {
        switch self {
        case .token: 1
        case let .typing(text): text.utf16.count
        }
    }
}

/// The query's text as the filter bar's field shows it (LIB-45): a term runs to the next space outside quotes and
/// parentheses, so `camera:"Canon EOS R5"` and `(camera:Z6 OR camera:X-T5)` are one term each, and `OR` is a term of
/// its own. The terms joined by single spaces are the same query.
enum FilterQueryTerms {
    static func split(_ text: String) -> [String] {
        var terms: [String] = []
        var term = ""
        var state = State()
        for character in text {
            if character.isWhitespace, state.isOutside {
                if !term.isEmpty {
                    terms.append(term)
                    term = ""
                }
                continue
            }
            state.read(character)
            term.append(character)
        }
        if !term.isEmpty {
            terms.append(term)
        }
        return terms
    }

    /// `pieces`, each a term or text being typed, joined as the query's text: apart by a space, text being typed
    /// keeping a space at its end.
    static func joined(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            let trimmed = piece.drop { $0.isWhitespace }
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty, !(text.last?.isWhitespace ?? false) {
                text.append(" ")
            }
            text.append(contentsOf: trimmed)
        }
        return text
    }

    /// Whether a quote or a parenthesis is still open at the end of `text`.
    static func isOpen(_ text: String) -> Bool {
        var state = State()
        text.forEach { state.read($0) }
        return !state.isOutside
    }

    /// Whether `text` ends with a space outside quotes and parentheses, the last term finished.
    static func isFinished(_ text: String) -> Bool {
        guard let last = text.last, last.isWhitespace else { return text.isEmpty }
        return !isOpen(text)
    }

    /// `term` with a quote and parentheses left open closed, as the language reads them at the end of a query.
    static func closed(_ term: String) -> String {
        var state = State()
        term.forEach { state.read($0) }
        return term + (state.quoted ? "\"" : "") + String(repeating: ")", count: state.depth)
    }

    private struct State {
        var quoted = false
        var depth = 0

        var isOutside: Bool {
            !quoted && depth == 0
        }

        mutating func read(_ character: Character) {
            if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == "(" {
                depth += 1
            } else if !quoted, character == ")" {
                depth = max(depth - 1, 0)
            }
        }
    }
}
