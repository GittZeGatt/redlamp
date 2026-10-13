import Foundation
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampRecipes

/// Fujifilm's published LUTs (TON-43): recognised by their headers, imported in the space they
/// name, found in a downloaded pack, and kept on the Mac (DEC-73). Every file here is made up;
/// none of Fujifilm's is committed.
struct FujifilmLUTTests {
    /// The header lines Fujifilm writes, for `gamma` and `gamut` as its files have them.
    static func header(
        gamma: String,
        gamut: String = "F-Gamut to ITU-R BT.709",
        model: String? = "GFX ETERNA 55",
    ) -> [String] {
        ["#title:made up"] + (model.map { ["#model:\($0)"] } ?? []) + [
            "#FUJIFILM Corporation", "#Gamma:\(gamma)", "#Gamut:\(gamut)", "#Version:1.00",
        ]
    }

    /// A Fujifilm-style LUT whose output is the signal it's given, times `gain`. Looks are
    /// identified by their tables, so LUTs meant as different looks need different gains.
    static func lut(
        gamma: String,
        gamut: String = "F-Gamut to ITU-R BT.709",
        size: Int = 5,
        gain: Float = 1,
    ) -> String {
        LookTableFixtures.cube(size: size, header: header(gamma: gamma, gamut: gamut)) { $0 * gain }
    }

    static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func `each of Fujifilm's header styles names its curve and simulation`() throws {
        let gfx = try #require(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to CLASSIC CHROME")))
        #expect(gfx.curve == .fLog2 && gfx.simulation == .classicChrome && gfx.size == 5)
        let wide = try #require(FujifilmLUT.recognise(Self.lut(
            gamma: "F-Log2C to CLASSIC Neg.",
            gamut: "F-GamutC to ITU-R BT.709",
        )))
        #expect(wide.curve == .fLog2C && wide.simulation == .classicNeg)
        let body = LookTableFixtures.cube(
            size: 2,
            header: Self.header(gamma: "F-Log to ETERNA BLEACH BYPASS", model: nil),
        ) { $0 }
        let x100vi = try #require(FujifilmLUT.recognise(body))
        #expect(x100vi.curve == .fLog && x100vi.simulation == .eternaBleachBypass)
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to PRO Neg.Std"))?.simulation == .proNegStd)
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to REALA ACE"))?.simulation == .realaAce)
    }

    @Test func `the wide dynamic range rendering and the log conversions aren't simulations`() {
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to Wide Dynamic Range curve"))?
            .target == .wideDynamicRange)
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to F-Log2"))?.target == .logConversion)
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to SOMETHING NEW"))?.target == .other("SOMETHING NEW"))
    }

    @Test func `other files aren't taken for Fujifilm's`() {
        #expect(FujifilmLUT.recognise(LookTableFixtures.cube(size: 2, header: ["TITLE \"Teal\""]) { $0 }) == nil)
        let noMaker = LookTableFixtures.cube(
            size: 2,
            header: ["#Gamma:F-Log2 to PROVIA", "#Gamut:F-Gamut to ITU-R BT.709"],
        ) { $0 }
        #expect(FujifilmLUT.recognise(noMaker) == nil)
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "F-Log2 to PROVIA", gamut: "F-Gamut to ITU-R BT.2020")) == nil)
        #expect(FujifilmLUT.recognise(Self.lut(gamma: "S-Log3 to PROVIA")) == nil)
    }

    @Test func `a Fujifilm LUT imports in the space it names, whatever the panel chose`() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("FLog2_to_PROVIA_33grid_V.1.00.cube")
        try Self.lut(gamma: "F-Log2 to PROVIA", size: 9).write(to: url, atomically: true, encoding: .utf8)
        let imported = try RecipeLibrary.read(importing: url, tableSpace: .sRGB, reading: InProcessDecoder())
        let recipe = imported.recipe
        #expect(recipe.name == "FLog2_to_PROVIA_33grid_V.1.00" && recipe.group == FujifilmLUT.group)
        let look = try #require(recipe.embeddedBaseLooks.first)
        #expect(look.reference.isFromMakerLUT && look.reference.staysOnThisMac)
        let table = try #require(try look.definition().table)
        #expect(table.space == .sceneLog)
        // The LUT hands back its signal, so middle grey comes out as F-Log2 encodes it once
        // the import's exposure offset has raised it.
        let grey = table.sample(SceneLogEncoding.encode(SIMD3(repeating: 0.18)))
        let expected = CameraLogSpace.fLog2.encode(0.18 * exp2(FujifilmLUT.exposure))
        #expect(abs(grey - SIMD3(repeating: expected)).max() < 3e-3, "\(grey) against \(expected)")
    }

    @Test func `the same file imports as the same look on any Mac`() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("FLog2_to_ACROS.cube")
        try Self.lut(gamma: "F-Log2 to ACROS").write(to: url, atomically: true, encoding: .utf8)
        let first = try RecipeLibrary.read(importing: url, reading: InProcessDecoder()).recipe
        let second = try RecipeLibrary.read(importing: url, reading: InProcessDecoder()).recipe
        #expect(first.id == second.id && first.baseLook == second.baseLook)
        #expect(first.baseLook?.id.hasPrefix(BaseLookReference.makerIDPrefix + "fujifilm-") == true)
    }

    @Test func `a downloaded pack yields one LUT per simulation, F-Log2 and the largest first`() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [(String, String, String, Int)] = [
            ("F-Log/FLog_to_PROVIA.cube", "F-Log to PROVIA", "F-Gamut to ITU-R BT.709", 5),
            ("F-Log2/FLog2_to_PROVIA_small.cube", "F-Log2 to PROVIA", "F-Gamut to ITU-R BT.709", 3),
            ("F-Log2/FLog2_to_PROVIA_large.cube", "F-Log2 to PROVIA", "F-Gamut to ITU-R BT.709", 5),
            ("F-Log2C/FLog2C_to_PROVIA.cube", "F-Log2C to PROVIA", "F-GamutC to ITU-R BT.709", 5),
            ("F-Log2/FLog2_to_WDR.cube", "F-Log2 to Wide Dynamic Range curve", "F-Gamut to ITU-R BT.709", 3),
            ("F-Log2/FLog2_to_FLog2-709.cube", "F-Log2 to F-Log2", "F-Gamut to ITU-R BT.709", 3),
            // Unzipped from a zip made on Windows, the folders are part of the name.
            (
                "x100vi\\F-Log2\\X100VI_FLog2_FGamut_to_ETERNA_BT.709.cube",
                "F-Log2 to ETERNA",
                "F-Gamut to ITU-R BT.709",
                3,
            ),
        ]
        for (path, gamma, gamut, size) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Self.lut(gamma: gamma, gamut: gamut, size: size).write(to: url, atomically: true, encoding: .utf8)
        }
        try LookTableFixtures.cube(size: 2) { $0 }.write(
            to: root.appendingPathComponent("Teal.cube"),
            atomically: true,
            encoding: .utf8,
        )
        let pack = FujifilmLUT.pack(in: root)
        #expect(pack.map(\.lastPathComponent).sorted() == [
            "FLog2_to_PROVIA_large.cube", "x100vi\\F-Log2\\X100VI_FLog2_FGamut_to_ETERNA_BT.709.cube",
        ])
        let summary = RecipeLibrary.read(importing: [root], reading: InProcessDecoder())
        let names = summary.imported.map(\.recipe.name).sorted()
        #expect(names == ["FLog2_to_PROVIA_large", "X100VI_FLog2_FGamut_to_ETERNA_BT.709"])
        #expect(summary.failures.isEmpty)
    }

    @Test func `an exported recipe leaves a Fujifilm look's table on this Mac`() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("FLog2_to_Velvia.cube")
        try Self.lut(gamma: "F-Log2 to Velvia").write(to: url, atomically: true, encoding: .utf8)
        let library = RecipeLibrary(root: root.appendingPathComponent("library"), includeBundled: false)
        let (recipe, _) = try library.install(contentsOf: url, reading: InProcessDecoder())
        let shared = library.exportable(recipe)
        #expect(shared.embeddedBaseLooks.isEmpty)
        #expect(shared.baseLook == recipe.baseLook)
        let file = root.appendingPathComponent("shared.redrecipe")
        try library.export(recipe, to: file)
        let (read, issues) = try RecipeFile.read(file)
        #expect(read.embeddedBaseLooks.isEmpty && read.baseLook == recipe.baseLook)
        #expect(issues.contains { $0.message.contains("must already be installed") })
    }

    @Test func `an imported LUT fills its film slot for recipe cards, until the slot switches back`() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecipeLibrary(root: root.appendingPathComponent("library"), includeBundled: false)
        for (file, gamma, gain) in [
            ("chrome.cube", "F-Log2 to CLASSIC CHROME", Float(0.9)),
            ("acros.cube", "F-Log2 to ACROS", 0.8),
            ("reala.cube", "F-Log2 to REALA ACE", 0.7),
        ] {
            let url = root.appendingPathComponent(file)
            try Self.lut(gamma: gamma, gain: gain).write(to: url, atomically: true, encoding: .utf8)
            try library.install(contentsOf: url, reading: InProcessDecoder())
        }
        #expect(Set(library.filledSlots.keys) == [.chrome, .monochrome])
        var card = CameraRecipeCard()
        card.filmSimulation = FilmSlot.chrome.rawValue
        let chrome = try #require(library.filledSlots[.chrome])
        #expect(card.recipe(id: "local/card", name: "Card", slotLooks: library.filledSlots).baseLook == chrome)
        try library.setUsesImportedLook(.chrome, false)
        let reopened = RecipeLibrary(root: root.appendingPathComponent("library"), includeBundled: false)
        #expect(reopened.filledSlots[.chrome] == nil && reopened.importedSlotLooks[.chrome] != nil)
        #expect(card.recipe(id: "local/card", name: "Card", slotLooks: reopened.filledSlots).baseLook == FilmSlot.chrome
            .baseLook)
    }

    @Test func `a file's name loses the folders a Windows zip put in it`() {
        let url = URL(fileURLWithPath: "/tmp/x100vi\\F-Log2\\X100VI_FLog2_FGamut_to_ETERNA_BT.709_33grid_V.1.00.cube")
        #expect(FujifilmLUT.name(of: url) == "X100VI_FLog2_FGamut_to_ETERNA_BT.709_33grid_V.1.00")
    }
}
