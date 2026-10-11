#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    /// The judging tools in the Library loupe and Compare (LIB-38), worked by keys and clicks on the working folder's
    /// raws, what each draws read from the views' accessibility values: Develop's ⌥J paints the sensor's clipping
    /// over the loupe's photo from the raw, the bar's buttons show the raw histogram, focus peaking, the AF point and
    /// the following loupe, a step keeps them on for the next photo, and Compare draws each over both photos.
    enum JudgingScenarios {
        static let all: [Scenario] = [judging]

        /// The Pixel 4a's street lights, which its sensor clipped (UX-05), and the Nikon Z 6's frame, whose maker
        /// notes give the AF area.
        private static let clipped = "PXL_20201121_100251397.dng"
        private static let focused = "DSC_0750.NEF"

        /// What's drawn over the photo of the view carrying `identifier`, as its accessibility value says.
        @MainActor private static func spoken(_ identifier: String) -> String {
            guard let root = Views.editorWindow?.contentView?.superview else { return "" }
            let view = Views.all(NSView.self, in: root).first { $0.accessibilityIdentifier() == identifier }
            return view?.accessibilityValue() as? String ?? ""
        }

        /// Whether the sensor clipping of the photo in the view carrying `identifier` has come in.
        @MainActor private static func clippingRead(_ identifier: String) -> Bool {
            let value = spoken(identifier)
            return value.contains("sensor clipping marked") || value.contains("nothing clipped on the sensor")
        }

        /// Every judging tool off, sensor clipping among them, which Develop's scenarios after this one render with.
        @MainActor private static func allOff(_ model: EditorModel) {
            let judging = model.libraryJudging
            if model.showRawClipping {
                model.toggleSensorClipping()
            }
            if judging.showsHistogram {
                model.toggleRawHistogram()
            }
            if judging.showsPeaking {
                model.toggleFocusPeaking()
            }
            if judging.showsAFPoints {
                model.toggleAFPoints()
            }
            model.setFollowingLoupe(nil)
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        static let judging = Scenario(
            "library.judging",
            "In the loupe ⌥J paints what the sensor clipped from the raw, and the bar's buttons show the raw histogram, "
                + "focus peaking, the AF point and a loupe following the pointer at 400%; → keeps them on for the next "
                + "photo, C draws each over both photos, and ⌥J and the buttons turn them off",
            claims: [.action(.rawClipping), .action(.loupeView), .action(.compareView)],
        ) { app in
            try app.withCulling { names in
                defer { _ = try? app.main { allOff($0) } }
                try app.expect(
                    names.contains(clipped) && names.contains(focused), "The folder lacks \(clipped) or \(focused)",
                )
                try app.click(.identifier("grid.\(clipped)"))
                try app.wait("\(clipped) active") { $0.selection?.lastPathComponent == clipped }
                try app.press(.loupeView)
                try app.wait("the loupe") { $0.libraryView == .loupe }

                try app.press(.rawClipping)
                try app.wait("⌥J: sensor clipping on") { $0.showRawClipping }
                let firstMarks = try app.milliseconds {
                    try app.wait("the sensor's clipping marked over \(clipped)", timeout: 60) { _ in
                        spoken("library.loupe").contains("sensor clipping marked")
                    }
                }

                try app.clickView("library.loupe.judging.histogram")
                try app.wait("the raw histogram on") { $0.libraryJudging.showsHistogram }
                try app.wait("the raw histogram's reading", timeout: 30) { _ in
                    spoken("library.loupe.histogram").hasPrefix("Clipped on the sensor: ")
                }
                let histogram = try app.main { _ in spoken("library.loupe.histogram") }
                try app.expect(histogram.contains("of photosites"), "The histogram reads \(histogram)")

                try app.clickView("library.loupe.judging.peaking")
                try app.wait("focus peaking over \(clipped)", timeout: 30) { _ in
                    spoken("library.loupe").contains("focus peaking")
                }
                try app.clickView("library.loupe.judging.afPoint")
                try app.wait("the AF point on") { $0.libraryJudging.showsAFPoints }

                try app.clickView("library.loupe.judging.loupe")
                try app.wait("the following loupe at 200%") { $0.libraryJudging.magnification == .double }
                try app.clickView("library.loupe.judging.loupe.4")
                try app.wait("the following loupe at 400%") { $0.libraryJudging.magnification == .quadruple }
                try app.hover(.identifier("library.loupe"), at: CGPoint(x: 0.4, y: 0.45))
                try app.wait("the lens over the photo") { _ in spoken("library.loupe").contains("loupe at 400%") }

                // A step keeps the tools on: the next photo comes with its own.
                let next = try app.main { model -> String? in
                    let order = model.gridCellPhotos.map { $0[0] }
                    return order.firstIndex(of: clipped).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
                }
                if let next {
                    try app.press(.nextPhoto)
                    try app.wait("→: \(next) in the loupe") { $0.selection?.lastPathComponent == next }
                    try app.wait("\(next)'s focus peaking", timeout: 30) { _ in
                        spoken("library.loupe").contains("focus peaking")
                    }
                }

                try app.press(.gridView)
                try app.wait("the grid") { $0.libraryView == .grid }
                try app.click(.identifier("grid.\(focused)"))
                try app.wait("\(focused) active") { $0.selection?.lastPathComponent == focused }
                try app.press(.loupeView)
                try app.wait("\(focused)'s AF area, its clipping and peaking", timeout: 60) { _ in
                    let value = spoken("library.loupe")
                    return value.contains("AF point") && value
                        .contains("focus peaking") && clippingRead("library.loupe")
                }

                try app.press(.compareView)
                try app.wait("Compare") { $0.libraryView == .compare }
                let sides = ["library.compare.select", "library.compare.candidate"]
                try app.wait("each tool over both photos", timeout: 60) { _ in
                    sides.allSatisfy { clippingRead($0) && spoken($0).contains("focus peaking") }
                }
                try app.expect(
                    try app.main { _ in spoken("library.compare.select").contains("AF point") },
                    "\(focused)'s AF area isn't drawn in Compare",
                )
                try app.hover(.identifier("library.compare.select"), at: CGPoint(x: 0.5, y: 0.5))
                try app.wait("a lens over the same point of both photos") { _ in
                    sides.allSatisfy { spoken($0).contains("loupe at 400%") }
                }

                try app.press(.rawClipping)
                try app.wait("⌥J in Compare: sensor clipping off") { !$0.showRawClipping }
                for tool in ["histogram", "peaking", "afPoint", "loupe"] {
                    try app.clickView("library.compare.judging.\(tool)")
                }
                try app.wait("every tool off") { model in
                    let judging = model.libraryJudging
                    return !judging.showsHistogram && !judging.showsPeaking && !judging.showsAFPoints
                        && judging.magnification == nil
                }
                try app.wait("nothing drawn over either photo") { _ in
                    sides.allSatisfy { !spoken($0).contains("focus peaking") && !clippingRead($0) }
                }
                let cost = try app.main { $0.libraryJudging.rawCost }
                app.recorder.write("judging", [
                    "firstMarksMs": firstMarks, "opened": cost.opened, "openingMs": milliseconds(cost.opening),
                    "rendered": cost.rendered, "renderingMs": milliseconds(cost.rendering),
                ])
                try app.press(.gridView)
                try app.wait("the grid") { $0.libraryView == .grid }
            }
        }
    }
#endif
