import Foundation
import Testing
@testable import RedlampUI

/// Aspects typed in (Enter Custom…): what reads as one, and the five most recent kept between
/// launches.
struct CropAspectTests {
    @Test func `a ratio or a size in pixels reads as typed, whatever goes between its numbers`() throws {
        for text in ["21 × 9", "21x9", "21X9", "21:9", "21/9", "21 9", "  21 ×9  "] {
            let aspect = try #require(CustomCropAspect(text), "\(text)")
            #expect(aspect.width == 21 && aspect.height == 9, "\(text)")
        }
        let size = try #require(CustomCropAspect("1080 × 1350"))
        #expect(size.ratio == 0.8, "portrait, as typed")
        #expect(size.title == "1080 × 1350")
        for text in ["8.5 x 11", "8,5 x 11"] {
            #expect(CustomCropAspect(text) == CustomCropAspect(width: 8.5, height: 11), "\(text)")
        }
        #expect(CustomCropAspect("2.39") == CustomCropAspect(width: 2.39, height: 1), "one number is a ratio to 1")
    }

    @Test func `anything else is refused, and so is a sliver`() {
        let refused = [
            "", "  ", "wide", "21 ×", "× 9", "21 × 9 mm", "21 × 9 × 4", "21 by 9", "0 × 9", "21 × 0", "-21 × 9",
            "nan", "inf × 1",
        ]
        for text in refused {
            #expect(CustomCropAspect(text) == nil, "\(text)")
        }
        #expect(CustomCropAspect("20 × 1") != nil && CustomCropAspect("1 × 20") != nil)
        #expect(CustomCropAspect("21 × 1") == nil && CustomCropAspect("1 × 21") == nil, "beyond 20 times the other")
    }

    @MainActor
    @Test func `the aspects typed in are remembered between launches, the five most recent`() throws {
        let suite = "CropAspectTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CustomCropAspect.Store(defaults: defaults).aspects.isEmpty, "nothing saved yet")

        let typed = ["21 × 9", "1080 × 1350", "8.5 × 11"].compactMap { CustomCropAspect($0) }
        CustomCropAspect.Store(defaults: defaults).aspects = typed
        #expect(CustomCropAspect.Store(defaults: defaults).aspects == typed)
        let data = try #require(defaults.data(forKey: "app.redlamp.cropAspects"))
        #expect(try JSONSerialization.jsonObject(with: data) as? [[Double]] == [[21, 9], [1080, 1350], [8.5, 11]])

        let later = "[[21, 9], [0, 9], [1, 2, 3], [4, 5], [6, 7], [7, 8], [9, 10], [11, 12]]"
        defaults.set(Data(later.utf8), forKey: "app.redlamp.cropAspects")
        #expect(
            CustomCropAspect.Store(defaults: defaults).aspects.map(\.title) == [
                "21 × 9",
                "4 × 5",
                "6 × 7",
                "7 × 8",
                "9 × 10",
            ],
            "the pairs it can't use left out, and five kept",
        )
        defaults.set(Data("not the aspects".utf8), forKey: "app.redlamp.cropAspects")
        #expect(CustomCropAspect.Store(defaults: defaults).aspects.isEmpty, "unreadable")
    }
}
