import AppKit
import RedlampDesign
import RedlampDocument

/// The Photo panel (LIB-13): the active photo's file and badges, each field's name and value in a form as the system
/// lays one out (LIB-45), a value cut short whole in its tooltip.
final class PhotoPanelView: PanelStackView {
    private let model: EditorModel
    private var values: [Field: NSTextField] = [:]
    private var tracker: Tracker?

    private enum Field: CaseIterable {
        case name, folder, size, modified, rating, flag, label, marked, edited

        var title: String {
            switch self {
            case .name: "File Name"
            case .folder: "Folder"
            case .size: "File Size"
            case .modified: "Modified"
            case .rating: "Rating"
            case .flag: "Flag"
            case .label: "Label"
            case .marked: "Marked"
            case .edited: "Edited"
            }
        }
    }

    init(model: EditorModel) {
        self.model = model
        super.init(spacing: 0)
        setAccessibilityIdentifier("photo")
        var rows: [(label: String?, control: NSView)] = []
        for field in Field.allCases {
            let value = PanelControls.label("—")
            value.lineBreakMode = field == .name || field == .folder ? .byTruncatingMiddle : .byTruncatingTail
            value.setAccessibilityIdentifier("photo.\(field)")
            values[field] = value
            rows.append((field.title, value))
        }
        let form = PanelControls.form(rows)
        form.rowSpacing = 5
        form.row(at: Field.allCases.firstIndex(of: .rating) ?? 0).topPadding = 6
        addFullWidth(form)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            _ = model.library.revision
            let item = model.selection.flatMap(model.library.item(for:))
            for field in Field.allCases {
                guard let value = values[field] else { continue }
                let text = item.map { Self.value(field, of: $0) } ?? "—"
                if value.stringValue != text {
                    value.stringValue = text
                    value.toolTip = text
                }
            }
        }
    }

    private static func value(_ field: Field, of item: LibraryItem) -> String {
        let metadata = item.metadata
        switch field {
        case .name: return item.name
        case .folder: return URL(fileURLWithPath: item.folderPath).lastPathComponent
        case .size: return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case .modified: return item.modified.formatted(date: .abbreviated, time: .shortened)
        case .rating: return metadata.rating > 0 ? String(repeating: "★", count: metadata.rating) : "None"
        case .flag: return metadata.flag.map { $0 == .pick ? "Pick" : "Rejected" } ?? "None"
        case .label: return metadata.label.map(\.rawValue.capitalized) ?? metadata.customLabel ?? "None"
        case .marked: return metadata.mark ? "Yes" : "No"
        case .edited: return item.hasEdits ? "Yes" : "No"
        }
    }
}
