import AppKit
import RedlampDesign
import RedlampLibrary

/// The Attribute section's Proposals menu (LIB-42): what the soft-frame check proposes, or Off; its proposed picks,
/// soft frames and the frames Changed by You, each as the filter's term; and Accept Proposals. One control: the
/// section has no room for more in a window 1,600 points wide.
final class FilterProposalsMenu: NSPopUpButton {
    enum Choice: Int, CaseIterable {
        case off = 1, onePerMoment, bestTwo, runsOnly
        case proposed = 10, soft, changedByYou
        case accept = 20

        /// The mode it shows proposals in, for the first four.
        var mode: SoftFrames.Mode?? {
            switch self {
            case .off: .some(nil)
            case .onePerMoment: .onePerMoment
            case .bestTwo: .bestTwo
            case .runsOnly: .runsOnly
            default: nil
            }
        }

        var trait: LibraryQuery.Trait? {
            switch self {
            case .proposed: .proposed
            case .soft: .soft
            case .changedByYou: .changedByYou
            default: nil
            }
        }

        var title: String {
            switch self {
            case .off: "Off"
            case .onePerMoment, .bestTwo, .runsOnly: mode??.title ?? ""
            case .proposed, .soft, .changedByYou: trait?.title ?? ""
            case .accept: "Accept Proposals"
            }
        }
    }

    var onChoose: ((Choice) -> Void)?

    init() {
        super.init(frame: .zero, pullsDown: true)
        controlSize = .small
        font = Typography.caption.nsFont
        bezelStyle = .flexiblePush
        isBordered = false
        toolTip = "Soft frames: the sharpest frame of each burst or moment at the camera's focus point, proposed until "
            + "accepted"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Proposals", action: nil, keyEquivalent: ""))
        for choice in Choice.allCases {
            if choice == .proposed || choice == .accept {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: choice.title, action: #selector(chose(_:)), keyEquivalent: "")
            item.tag = choice.rawValue
            item.target = self
            menu.addItem(item)
        }
        self.menu = menu
        setAccessibilityIdentifier("library.filter.proposals")
        setAccessibilityLabel("Proposals")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Checks the mode proposals are shown in, or Off, and the terms the filter has.
    func update(shown mode: SoftFrames.Mode?, terms: Set<LibraryQuery.Trait>) {
        for item in itemArray {
            guard let choice = Choice(rawValue: item.tag) else { continue }
            let on = choice.mode.map { $0 == mode } ?? choice.trait.map(terms.contains) ?? false
            item.state = on ? .on : .off
        }
    }

    /// The item of `choice`, for the regression suite to choose.
    func item(_ choice: Choice) -> NSMenuItem? {
        itemArray.first { $0.tag == choice.rawValue }
    }

    @objc private func chose(_ item: NSMenuItem) {
        if let choice = Choice(rawValue: item.tag) {
            onChoose?(choice)
        }
    }
}
