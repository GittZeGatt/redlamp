#if DEBUG || REDLAMP_PROFILING
    import AppKit
    @_spi(Harness) import RedlampUI

    /// The grid's chrome as the library's polish leaves it (LIB-45): the toolbar's views, one segmented control with
    /// Compare and Survey among them, and the loupe's own Auto Advance (DEC-68), each worked with the mouse.
    enum GridChromeScenarios {
        static let all: [Scenario] = [views, loupeAutoAdvance]

        static let views = Scenario(
            "library.toolbar-views",
            "The toolbar's Grid, Loupe, Compare and Survey show each view with a click, the one shown lit",
            claims: [.action(.compareView), .action(.surveyView), .feature("library.grid")],
        ) { app in
            let names = try app.showGrid()
            try app.clickView("grid.\(names[0])")
            try app.clickView("grid.\(names[2])", modifiers: .shift)
            try app.wait("three photos selected") { $0.selectedPhotos.count >= 3 }
            for (button, view) in [
                ("survey", LibraryView.survey), ("compare", .compare), ("loupe", .loupe), ("grid", .grid),
            ] {
                try app.clickView("library.toolbar.\(button)")
                try app.wait("the toolbar's \(button) to show it, lit") { model in
                    model.libraryView == view && Views.editorWindow
                        .flatMap { Views.accessible("library.toolbar.\(button)", in: $0) }?
                        .accessibilityValue() as? String == "on"
                }
            }
            app.covered([.action(.compareView), .action(.surveyView), .feature("library.grid")], via: .mouse)
            try app.backToDevelop()
        }

        static let loupeAutoAdvance = Scenario(
            "library.loupe-auto-advance",
            "The loupe's Auto Advance is on until its button in the caption row turns it off there, and a rating then "
                + "stays on the photo; the button turns it on again",
            claims: [.action(.autoAdvance), .feature("library.loupe")],
        ) { app in
            try app.withCulling { _ in
                let names = try app.selectFromKeyboard(1).map { $0[0] }
                try app.press(.loupeView)
                try app.wait("the loupe, Auto Advance on, its button lit") { model in
                    model.libraryView == .loupe && model.autoAdvance && Views.editorWindow
                        .flatMap { Views.accessible("library.loupe.autoAdvance", in: $0) }?
                        .accessibilityValue() as? String == "on"
                }
                try app.clickView("library.loupe.autoAdvance")
                try app.wait("a click to turn it off in the loupe") { !$0.autoAdvance(in: .loupe) }
                try app.press(.rating2)
                try app.wait("two stars on \(names[0]), staying on it") { model in
                    model.selection?.lastPathComponent == names[0] && model.photoMetadata.rating == 2
                }
                try app.clickView("library.loupe.autoAdvance")
                try app.wait("a click to turn it on again") { $0.autoAdvance(in: .loupe) }
                try app.press(.rating3)
                try app.wait("three stars, moving on to \(names[1])") { $0.selection?.lastPathComponent == names[1] }
                app.covered([.action(.autoAdvance), .feature("library.loupe")], via: .mouse)
            }
        }
    }
#endif
