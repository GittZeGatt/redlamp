import CoreGraphics
import RedlampDesign
import RedlampEngineAPI
import RedlampRecipes
import SwiftUI

/// Base Looks sorted into the browser's and menu's sections.
struct BaseLookGroups {
    var sections: [(name: String, looks: [BaseLookPackage])]

    init(_ looks: [BaseLookPackage]) {
        let reproduction = looks.filter { $0.id == BuiltInBaseLook.reproduction.rawValue }
        let builtIn = looks.filter { BuiltInBaseLook(rawValue: $0.id).map { $0 != .reproduction } ?? false }
        let catalogue = FilmLookCatalog.looks.map(\.baseLookID)
        let stocks = looks.filter { catalogue.contains($0.id) }
            .sorted { (catalogue.firstIndex(of: $0.id) ?? 0) < (catalogue.firstIndex(of: $1.id) ?? 0) }
        let film = looks.filter {
            BuiltInBaseLook(rawValue: $0.id) == nil && $0.id.hasPrefix(RecipeNamespace.bundled + "/")
                && !catalogue.contains($0.id)
        }
        let fujifilm = looks.filter(\.reference.isFromMakerLUT)
        let other = looks.filter { !$0.id.hasPrefix(RecipeNamespace.bundled + "/") && !$0.reference.isFromMakerLUT }
        sections = [
            ("Redlamp", builtIn), ("Film Stocks", stocks), ("Film Styles", film), (FujifilmLUT.group, fujifilm),
            ("Installed", other), ("Reproduction", reproduction),
        ].filter { !$0.1.isEmpty }
    }

    /// The catalogue's current looks, sorted once for each change to it rather than for each
    /// update of a menu that shows them.
    @MainActor static func current(in recipes: RecipeCatalog) -> BaseLookGroups {
        let revision = recipes.revision
        if let last = Cache.last, last.catalog === recipes, last.revision == revision {
            return last.groups
        }
        let groups = BaseLookGroups(recipes.currentBaseLooks)
        Cache.last = Cache(catalog: recipes, revision: revision, groups: groups)
        return groups
    }

    @MainActor private final class Cache {
        static var last: Cache?
        weak var catalog: RecipeCatalog?
        let revision: Int
        let groups: BaseLookGroups

        init(catalog: RecipeCatalog, revision: Int, groups: BaseLookGroups) {
            self.catalog = catalog
            self.revision = revision
            self.groups = groups
        }
    }
}

/// Every Base Look rendered on the current photo, as Lightroom's Profile Browser.
/// Thumbnails render one after another at low priority, so editing stays responsive.
struct BaseLookBrowser: View {
    @Environment(EditorModel.self) private var model
    @State private var thumbnails: [String: CGImage] = [:]

    private static let columns = [GridItem(.adaptive(minimum: 116), spacing: 10)]

    var body: some View {
        let groups = BaseLookGroups.current(in: model.recipes)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups.sections, id: \.name) { section in
                    Text(section.name).font(.headline)
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                        ForEach(section.looks, id: \.self) { look in
                            tile(look)
                        }
                    }
                }
                slotSwitches
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Fujifilm's own film-simulation LUTs import from the Recipes panel and work on any photo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Link("Get Them from Fujifilm…", destination: FujifilmLUT.downloadPage).font(.caption)
                }
            }
            .padding(14)
        }
        .overlayScrollers()
        .frame(width: 420, height: 520)
        .task(id: model.info?.url) { await renderThumbnails(groups.sections.flatMap(\.looks)) }
        .onDisappear { model.previewRecipe(nil) }
    }

    /// For each film slot an imported LUT fills, whether recipe cards use it or Redlamp's own look.
    @ViewBuilder private var slotSwitches: some View {
        let _ = model.recipes.revision
        let library = model.recipes.library
        let imported = library.importedSlotLooks
        let slots = FilmSlot.allCases.filter { imported[$0] != nil }
        if !slots.isEmpty {
            Text("Recipe Cards").font(.headline)
            Text("Cards that name these slots use the LUTs you imported. Turn one off to use Redlamp's own look.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(slots, id: \.self) { slot in
                Toggle(isOn: Binding(
                    get: { !library.slotsKeepingRedlampLooks.contains(slot) },
                    set: { model.recipes.setUsesImportedLook(slot, $0) },
                )) {
                    Text("\(slot.name): \(imported[slot]?.name ?? "")").font(.caption).lineLimit(1)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }

    private func key(_ look: BaseLookPackage) -> String {
        "\(look.id)@\(look.version)#\(look.table?.sha256 ?? "")"
    }

    private func tile(_ look: BaseLookPackage) -> some View {
        let selected = look.matches(model.baseLook)
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))
                if let image = thumbnails[key(look)] {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 78)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                if let icon = FilmIconImage.image(for: look.id, points: 22) {
                    Image(nsImage: icon).padding(3)
                }
            }
            Text(look.name).font(.caption).lineLimit(1)
        }
        .help(look.summary ?? look.name)
        .contentShape(Rectangle())
        .onTapGesture { model.setBaseLook(look.reference) }
        .onHover { inside in
            model.previewRecipe(inside ? Self.previewRecipe(for: look) : nil)
        }
    }

    static func previewRecipe(for look: BaseLookPackage) -> Recipe {
        Recipe(
            id: "local/base-look-preview", name: look.name, group: "", includes: [.baseLook],
            settings: RecipeSettings(), baseLook: look.reference, embeddedBaseLooks: look.table == nil ? [] : [look],
        )
    }

    private func renderThumbnails(_ looks: [BaseLookPackage]) async {
        guard model.info != nil else { return }
        let base = model.recipe
        for look in looks where thumbnails[key(look)] == nil {
            if Task.isCancelled {
                return
            }
            var recipe = base
            recipe.baseLook = look.reference.withAmount(100)
            if look.parameters.isMonochrome {
                recipe.treatment = .blackAndWhite
            }
            var request = StillRequest(recipe: model.anchored(recipe))
            request.maxLongEdge = 232
            if let image = try? await model.engine.renderStill(request) {
                thumbnails[key(look)] = image
            }
            await Task.yield()
        }
    }
}

@_spi(Harness) public enum BaseLookPreviews {
    /// The recipe that previews `look` alone, as hovering it in the browser does.
    @MainActor public static func recipe(for look: BaseLookPackage) -> Recipe {
        BaseLookBrowser.previewRecipe(for: look)
    }
}
