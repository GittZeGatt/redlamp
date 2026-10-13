import Foundation
import RedlampEngineAPI

/// Fujifilm's published film-simulation LUTs (TON-43), recognised by the comment lines Fujifilm
/// writes at the top of each file:
///
/// ```
/// #FUJIFILM Corporation
/// #Gamma:F-Log2 to CLASSIC CHROME
/// #Gamut:F-Gamut to ITU-R BT.709
/// ```
///
/// A recognised file imports with the curve and gamut it names, whatever an import panel
/// chose. Users download the files from Fujifilm; their terms allow that for personal use and
/// forbid passing the files on, so the looks get an id under `BaseLookReference.makerIDPrefix`
/// and stay on the Mac they were imported on (DEC-73).
public struct FujifilmLUT: Sendable, Hashable {
    /// What a LUT renders.
    public enum Target: Sendable, Hashable {
        case simulation(FujifilmSimulation)
        /// Fujifilm's wide dynamic range rendering ("WDR").
        case wideDynamicRange
        /// The log signal again, in BT.709 primaries.
        case logConversion
        /// A target this build doesn't know, as the file names it.
        case other(String)
    }

    public var curve: CameraLogSpace
    public var target: Target
    /// The table's size, when the header gives it before the first entry.
    public var size: Int?

    /// Where Fujifilm publishes them.
    public static let downloadPage = URL(string: "https://www.fujifilm-x.com/global/support/download/lut/")!

    /// How their output is decoded. Provisional until the real-photo evaluation (TON-45):
    /// sRGB matched cameras' JPEGs on a chart as well as BT.1886's 2.4 gamma, or better.
    public static let output = LookTableOutput.sRGB

    /// Stops added to Redlamp's scene light before it's encoded for the LUT. Fujifilm's LUTs
    /// render middle grey at L* 46 to 49, Redlamp's tone curve at L* 64; provisional until
    /// the real-photo evaluation (TON-45).
    public static let exposure: Float = 0.9

    /// The group imported Fujifilm LUTs join.
    public static let group = "Fujifilm LUTs"

    /// The space the table is read in.
    public var space: ImportedTableSpace {
        .cameraLog(curve, output: Self.output, exposure: Self.exposure)
    }

    /// The film simulation it renders, if it renders one.
    public var simulation: FujifilmSimulation? {
        if case let .simulation(simulation) = target {
            simulation
        } else {
            nil
        }
    }

    /// Reads the header of a `.cube` file's text; nil unless Fujifilm made it for a BT.709
    /// display.
    public static func recognise(_ text: some StringProtocol) -> FujifilmLUT? {
        var maker = false
        var gamma: Substring?
        var gamut: Substring?
        var size: Int?
        for line in text.split(whereSeparator: \.isNewline).prefix(40) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let comment = line.dropFirst()
                if comment.uppercased().hasPrefix("FUJIFILM") {
                    maker = true
                } else if let value = value(of: "Gamma", in: comment) {
                    gamma = value
                } else if let value = value(of: "Gamut", in: comment) {
                    gamut = value
                }
            } else if line.hasPrefix("LUT_3D_SIZE") {
                size = line.split(separator: " ").last.flatMap { Int($0) }
            } else if let first = line.first, first.isNumber || first == "-" || first == "." {
                break
            }
        }
        guard maker, let gamma, let gamut, let rendering = split(gamma), let primaries = split(gamut),
              key(primaries.1).hasSuffix("BT709") else { return nil }
        let targetName = rendering.1
        let curve: CameraLogSpace
        switch (key(rendering.0), key(primaries.0)) {
        case (_, "FGAMUTC"): curve = .fLog2C
        case ("FLOG", "FGAMUT"): curve = .fLog
        case ("FLOG2", "FGAMUT"): curve = .fLog2
        default: return nil
        }
        let target: Target = if key(targetName).hasPrefix("FLOG") {
            .logConversion
        } else if key(targetName).hasPrefix("WIDEDYNAMICRANGE") || key(targetName) == "WDR" {
            .wideDynamicRange
        } else if let simulation = FujifilmSimulation(named: targetName) {
            .simulation(simulation)
        } else {
            .other(String(targetName))
        }
        return FujifilmLUT(curve: curve, target: target, size: size)
    }

    /// Reads the start of a file; nil for anything but one of Fujifilm's LUTs.
    public static func recognise(contentsOf url: URL) -> FujifilmLUT? {
        guard url.pathExtension.lowercased() == "cube", let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return recognise(String(decoding: data, as: UTF8.self))
    }

    /// The simulation LUTs in a downloaded pack, one per simulation: F-Log2 first, then
    /// F-Log2 C, then F-Log, and the largest table of each. Fujifilm's zips are made on
    /// Windows, so unzipped on a Mac a file's name can hold the folders, `F-Log2\…\x.cube`.
    public static func pack(in folder: URL) -> [URL] {
        let files = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        )
        var best: [FujifilmSimulation: (url: URL, rank: Int)] = [:]
        while let url = files?.nextObject() as? URL {
            guard let lut = recognise(contentsOf: url), let simulation = lut.simulation else { continue }
            let preference = [CameraLogSpace.fLog2, .fLog2C, .fLog].firstIndex(of: lut.curve) ?? 3
            let rank = preference * 1000 - (lut.size ?? 0)
            if best[simulation].map({ rank < $0.rank || rank == $0.rank && url.path < $0.url.path }) ?? true {
                best[simulation] = (url, rank)
            }
        }
        return best.values.map(\.url).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// A file's name without its folders or extension.
    public static func name(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.split(separator: "\\").last.map(String.init) ?? name
    }

    /// The recipe `table`, read in `space`, imports as. Its ids come from the table, so the
    /// same file imported on another Mac is the same look, and a shared recipe built on it
    /// finds it there.
    public func recipe(for table: LookTable, name: String) -> Recipe {
        let key = String(table.contentHash.prefix(16)).lowercased()
        let look = BaseLookPackage(
            id: BaseLookReference.makerIDPrefix + "fujifilm-\(key)",
            name: name,
            summary: "Imported from Fujifilm's published LUT; it stays on this Mac",
            slot: simulation?.slot?.rawValue,
            parameters: .identity,
            table: table,
        )
        return Recipe(
            id: "\(RecipeNamespace.local)/fujifilm-\(key)",
            name: name,
            group: Self.group,
            tags: ["lut", "fujifilm"],
            includes: [.baseLook],
            settings: RecipeSettings(),
            baseLook: look.reference,
            embeddedBaseLooks: [look],
            created: Date(),
        )
    }

    /// `Key:value` in a comment, with the value trimmed.
    private static func value(of key: String, in comment: Substring) -> Substring? {
        guard let colon = comment.firstIndex(of: ":"),
              comment[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame
        else { return nil }
        return comment[comment.index(after: colon)...].drop { $0 == " " }
    }

    /// `A to B` as its two sides.
    private static func split(_ text: Substring) -> (Substring, Substring)? {
        guard let range = text.range(of: " to ", options: .caseInsensitive) else { return nil }
        return (text[..<range.lowerBound], text[range.upperBound...])
    }

    /// Letters and digits only, upper-cased: `CLASSIC Neg.` and `Classic-Neg` read alike.
    static func key(_ text: some StringProtocol) -> String {
        String(text.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// Fujifilm's film simulations, as its LUTs name them.
public enum FujifilmSimulation: String, Sendable, Hashable, CaseIterable {
    case provia, velvia, astia, classicChrome, classicNeg, nostalgicNeg, realaAce, proNegStd, proNegHi
    case eterna, eternaBleachBypass, acros, monochrome, sepia

    init?(named name: some StringProtocol) {
        let keys: [String: FujifilmSimulation] = [
            "PROVIA": .provia, "STANDARD": .provia, "VELVIA": .velvia, "VIVID": .velvia, "ASTIA": .astia,
            "SOFT": .astia, "CLASSICCHROME": .classicChrome, "CLASSICNEG": .classicNeg,
            "CLASSICNEGATIVE": .classicNeg, "NOSTALGICNEG": .nostalgicNeg, "NOSTALGICNEGATIVE": .nostalgicNeg,
            "REALAACE": .realaAce, "PRONEGSTD": .proNegStd, "PRONEGHI": .proNegHi, "ETERNA": .eterna,
            "ETERNABLEACHBYPASS": .eternaBleachBypass, "ETERNABB": .eternaBleachBypass, "ACROS": .acros,
            "MONOCHROME": .monochrome, "SEPIA": .sepia,
        ]
        guard let simulation = keys[FujifilmLUT.key(name)] else { return nil }
        self = simulation
    }

    /// The film slot recipe cards name it by (TON-44); Reala Ace has none yet (TON-47).
    public var slot: FilmSlot? {
        switch self {
        case .provia: .standard
        case .velvia: .vividSlide
        case .astia: .softSlide
        case .classicChrome: .chrome
        case .classicNeg: .negativeClassic
        case .nostalgicNeg: .negativeNostalgic
        case .proNegStd: .negativeStandard
        case .proNegHi: .negativeHigh
        case .eterna: .cinema
        case .eternaBleachBypass: .bleach
        case .acros, .monochrome: .monochrome
        case .sepia: .sepia
        case .realaAce: nil
        }
    }
}
