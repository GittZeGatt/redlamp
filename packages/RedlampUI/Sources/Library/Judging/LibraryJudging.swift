import AppKit
import Foundation
import Observation

/// How far the following loupe magnifies the photo: one, two or four of the screen's pixels to one of the photo's.
public enum LoupeMagnification: Int, CaseIterable, Sendable {
    case actual = 1, double = 2, quadruple = 4

    public var title: String {
        "\(rawValue * 100)%"
    }
}

/// The judging tools of the Library loupe and Compare (LIB-38), for culling from photos whose embedded JPEG hides
/// what the sensor recorded: sensor clipping (Develop's Show Sensor Clipping, the same setting on the same key, ⌥J),
/// a raw histogram beside the photo, focus peaking, the camera's AF point and a loupe that follows the pointer at
/// 100, 200 or 400% with the tools on. Each is drawn over every photo shown, both of Compare's at once.
@MainActor
@Observable
public final class LibraryJudging {
    /// The raw histogram beside each photo.
    public internal(set) var showsHistogram = false
    /// The photo's sharp edges marked over it.
    public internal(set) var showsPeaking = false
    /// Where the camera focused, from the file's maker notes.
    public internal(set) var showsAFPoints = false
    /// The following loupe's magnification; nil while it's off.
    public internal(set) var magnification: LoupeMagnification?
    /// The magnification the following loupe comes back with.
    public internal(set) var lastMagnification = LoupeMagnification.double

    /// What the tools read, kept for the photos shown and those around them.
    @ObservationIgnored let afPoints = AFPointCache()
    @ObservationIgnored let peaking = PeakingCache()
    @ObservationIgnored var clipping: SensorClipping?

    init() {}
}

public extension EditorModel {
    /// The Library's judging tools.
    var libraryJudging: LibraryJudging {
        if let judging = Self.judgings.object(forKey: self) {
            return judging
        }
        let judging = LibraryJudging()
        Self.judgings.setObject(judging, forKey: self)
        return judging
    }

    private static let judgings = NSMapTable<EditorModel, LibraryJudging>.weakToStrongObjects()

    /// Whether the loupe or Compare shows the photos the judging tools draw over.
    internal var showsJudgedPhotos: Bool {
        module == .library && (libraryView == .loupe || libraryView == .compare)
    }

    /// Shows or hides Develop's sensor clipping, which the loupe and Compare draw too: the same setting as Develop's
    /// toolbar button and ⌥J.
    func toggleSensorClipping() {
        showRawClipping.toggle()
        activity.record(.action, ShortcutAction.rawClipping.title)
    }

    func toggleRawHistogram() {
        libraryJudging.showsHistogram.toggle()
        activity.record(.action, "Raw Histogram")
    }

    func toggleFocusPeaking() {
        libraryJudging.showsPeaking.toggle()
        activity.record(.action, "Focus Peaking")
    }

    func toggleAFPoints() {
        libraryJudging.showsAFPoints.toggle()
        activity.record(.action, "AF Point")
    }

    /// Turns the following loupe on at its last magnification, or off.
    func toggleFollowingLoupe() {
        let judging = libraryJudging
        setFollowingLoupe(judging.magnification == nil ? judging.lastMagnification : nil)
    }

    /// The following loupe at `magnification`, or off.
    func setFollowingLoupe(_ magnification: LoupeMagnification?) {
        let judging = libraryJudging
        guard judging.magnification != magnification else { return }
        judging.magnification = magnification
        if let magnification {
            judging.lastMagnification = magnification
        }
        activity.record(.action, magnification.map { "Loupe \($0.title)" } ?? "Loupe Off")
    }

    /// Whether `event` is the key Develop's Show Sensor Clipping answers, as the keymap has it: the Library's views
    /// take it themselves, since the key monitor leaves Develop's view keys to Develop.
    internal func isSensorClippingKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.contains(.command), !flags.contains(.control),
              let character = event.charactersIgnoringModifiers?.lowercased().first else { return false }
        let combo = KeyCombo(.character(character), shift: flags.contains(.shift), option: flags.contains(.option))
        return ShortcutAction.rawClipping.combos.contains(combo)
    }
}
