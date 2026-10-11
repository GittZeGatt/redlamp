import AppKit
import RedlampDocument
import RedlampLibrary

/// Where custom labels are named and their colours chosen (LIB-15): the library's custom labels, each with its colour
/// and how many photos have it, and a new label, named with its colour. OK makes each change with an Undo of its own:
/// a colour reaches every photo that has the label, and the new label goes to the photos a culling key would reach.
@MainActor
enum CustomLabelsSheet {
    /// Shows the sheet over the editor window; `photo` is the cell whose context menu opened it, which the new label
    /// goes to with the selection it's in. False when there's no window to show it over, or the library isn't open.
    @discardableResult
    static func present(editor model: EditorModel, giving photo: URL? = nil) -> Bool {
        guard model.module == .library, model.library.service?.isReady == true else { return false }
        let sheet = PanelSheet(title: "Custom Labels", model: model)
        var choices: [(label: CustomLabelCount, popUp: NSPopUpButton)] = []
        let labels = model.customLabelCounts
        if labels.isEmpty {
            sheet.add(nil, NSTextField(labelWithString: "No photo has a custom label yet."))
        } else {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 6
            for label in labels {
                let popUp = colorPopUp(selecting: label.color, identifier: "labels.color.\(label.name)")
                let name = NSTextField(labelWithString: label.name)
                name.lineBreakMode = .byTruncatingMiddle
                name.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
                let count = NSTextField(labelWithString: LibraryPanels.count(label.photos))
                count.textColor = .secondaryLabelColor
                rows.addArrangedSubview(NSStackView(views: [popUp, name, count]))
                choices.append((label, popUp))
            }
            sheet.add("Labels:", scrolled(rows, height: min(CGFloat(labels.count) * 30, 240)))
        }
        let name = NSTextField(string: "")
        name.placeholderString = "Name"
        name.setAccessibilityIdentifier("labels.new.name")
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let color = colorPopUp(selecting: .orange, identifier: "labels.new.color")
        sheet.add("New Label:", NSStackView(views: [name, color]))
        let reached = reached(from: photo, in: model)
        let note = NSTextField(labelWithString: reached > 0
            ? "OK gives it to \(LibraryPanels.count(reached))." : "Select the photos to give it to.")
        note.textColor = .secondaryLabelColor
        sheet.add(nil, note)
        let problem = NSTextField(labelWithString: "")
        problem.textColor = .systemRed
        problem.setAccessibilityIdentifier("labels.problem")
        sheet.add(nil, problem)
        return sheet.begin(button: "OK", first: name) {
            let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                if let label = MetadataField.colorLabel(named: typed) {
                    problem.stringValue = "\(typed) is the \(label.rawValue.capitalized) label: choose it from Set "
                        + "Color Label."
                    return false
                }
                guard model.giveCustomLabel(typed, color: chosen(color), to: photo) else {
                    problem.stringValue = "Select the photos to give it to."
                    return false
                }
            }
            for (label, popUp) in choices where label.name != typed && chosen(popUp) != label.color {
                model.setColor(chosen(popUp), ofCustomLabel: label.name)
            }
            return true
        }
    }

    /// How many photos the new label goes to: `photo` alone when it isn't selected, else the selection.
    private static func reached(from photo: URL?, in model: EditorModel) -> Int {
        if let photo, let id = model.library.photoID(of: photo), !model.photoSelection.contains(id),
           photo != model.selection {
            return 1
        }
        return model.selectedCount
    }

    /// None, then the palette's colours with their swatches, `color` chosen; a colour a newer build gave is offered as
    /// written.
    private static func colorPopUp(selecting color: LabelColor?, identifier: String) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.addItem(withTitle: "None")
        for choice in LabelColor.palette {
            popUp.addItem(withTitle: choice.name)
            popUp.lastItem?.image = GridBadges.swatch(choice.nsColor ?? GridBadges.neutral)
            popUp.lastItem?.representedObject = choice.rawValue
        }
        if let color {
            if let place = LabelColor.palette.firstIndex(of: color) {
                popUp.selectItem(at: place + 1)
            } else {
                popUp.addItem(withTitle: color.name)
                popUp.lastItem?.representedObject = color.rawValue
                popUp.select(popUp.lastItem)
            }
        }
        popUp.setAccessibilityIdentifier(identifier)
        return popUp
    }

    private static func chosen(_ popUp: NSPopUpButton) -> LabelColor? {
        (popUp.selectedItem?.representedObject as? String).map(LabelColor.init(rawValue:))
    }

    /// `rows` in a scroll view `height` points tall, from the top.
    private static func scrolled(_ rows: NSStackView, height: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView = TopClipView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 320),
            scroll.heightAnchor.constraint(equalToConstant: height),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }
}

/// A clip view whose content starts at its top.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool {
        true
    }
}
