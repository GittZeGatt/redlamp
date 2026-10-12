import Foundation
import Observation

/// A crop aspect typed in, as Lightroom's Enter Custom… takes one: a ratio (21 × 9) or a size in
/// pixels (1080 × 1350). It crops as typed, so 1080 × 1350 makes a portrait crop of any photo.
public struct CustomCropAspect: Hashable, Sendable {
    public let width: Double
    public let height: Double

    /// How many the Aspect menu keeps, the most recent first.
    public static let kept = 5
    /// How many times longer one side can be than the other: a crop any longer would be a sliver.
    public static let longest = 20.0

    /// Nil unless both are positive and neither is more than `longest` times the other.
    public init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              max(width / height, height / width) <= Self.longest
        else { return nil }
        self.width = width
        self.height = height
    }

    /// As typed: `21 × 9`, `21x9`, `21:9`, `1080 × 1350`, `8.5 x 11`, or one number, a ratio to 1
    /// (`2.39`). Nil for anything else, or an aspect `init(width:height:)` refuses.
    public init?(_ text: String) {
        guard let (width, height) = Self.numbers(in: text) else { return nil }
        self.init(width: width, height: height)
    }

    /// The two numbers in `text`, with `×`, `x`, `:`, `/` or a space between them; one number is a
    /// ratio to 1. Either `.` or `,` marks decimals.
    static func numbers(in text: String) -> (width: Double, height: Double)? {
        let scanner = Scanner(string: text.replacingOccurrences(of: ",", with: "."))
        guard let width = scanner.scanDouble() else { return nil }
        guard !scanner.isAtEnd else { return (width, 1) }
        _ = scanner.scanCharacters(from: CharacterSet(charactersIn: "×xX:/"))
        guard let height = scanner.scanDouble(), scanner.isAtEnd else { return nil }
        return (width, height)
    }

    /// Width over height.
    public var ratio: Double {
        width / height
    }

    /// As the Aspect menu and the history name it: `21 × 9`.
    public var title: String {
        "\(Self.format(width)) × \(Self.format(height))"
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0 ... 3)))
    }
}

public extension EditorModel {
    /// The aspects typed in, the most recent first, listed after the presets in the Aspect menu.
    /// They are the app's, as the overlay choices are: every editor shares them, kept across launches.
    var customCropAspects: [CustomCropAspect] {
        get { CustomCropAspect.Store.shared.aspects }
        set { CustomCropAspect.Store.shared.aspects = Array(newValue.prefix(CustomCropAspect.kept)) }
    }

    /// Crops to an aspect typed in (Enter Custom…) and puts it first among them in the Aspect menu,
    /// where the oldest beyond `CustomCropAspect.kept` gives way.
    func enterCropAspect(_ aspect: CustomCropAspect) {
        customCropAspects = [aspect] + customCropAspects.filter { $0 != aspect }
        setCropAspect(.custom(aspect))
    }

    /// Takes the aspects typed in out of the Aspect menu. The crop stays as it is.
    func clearCustomCropAspects() {
        customCropAspects = []
        if case .custom = cropAspect {
            cropAspect = .free
        }
    }
}

extension CustomCropAspect {
    /// The aspects typed in, saved in user defaults as they change; `shared` is the app's.
    @MainActor @Observable
    final class Store {
        static let shared = Store()

        var aspects: [CustomCropAspect] {
            didSet { CustomCropAspect.save(aspects, in: defaults) }
        }

        @ObservationIgnored private let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            aspects = CustomCropAspect.saved(in: defaults)
        }
    }

    private static let defaultsKey = "app.redlamp.cropAspects"

    /// Kept as `[width, height]` pairs, most recent first. A pair this version can't use is left out.
    static func saved(in defaults: UserDefaults = .standard) -> [CustomCropAspect] {
        guard let data = defaults.data(forKey: defaultsKey),
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data)
        else { return [] }
        let aspects = pairs.compactMap { $0.count == 2 ? CustomCropAspect(width: $0[0], height: $0[1]) : nil }
        return Array(aspects.prefix(kept))
    }

    static func save(_ aspects: [CustomCropAspect], in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(aspects.map { [$0.width, $0.height] }) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
