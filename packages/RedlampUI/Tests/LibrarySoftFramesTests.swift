import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The soft-frame check in the Library (LIB-42): its marks in the grid's cells, legible at every size and style and
/// apart from the user's own flags; and with a library, a folder's bursts measured in the background, the terms in
/// the filter, Accept as one change with Undo, and a frame the user decided never proposed against.
@MainActor
@Suite(.serialized)
struct LibrarySoftFramesTests {
    @Test func `a proposal's marks fit inside the thumbnail at every size and style, and give way to the user's flag`() {
        // Thumbnails alone show no badges: there the dashed frame marks a proposal.
        let proposed = SoftFrames.Entry(verdict: .proposed, relative: 1)
        let soft = SoftFrames.Entry(verdict: .soft, relative: 0.38)
        for style in GridCellStyle.allCases {
            for size in GridSize.steps {
                let geometry = GridCellGeometry(size: CGFloat(size), style: style)
                let cell = LibraryGridCell()
                cell.place(CGRect(origin: .zero, size: geometry.cellSize), geometry: geometry, scale: 2)
                cell.configure(
                    LibraryItem(url: URL(fileURLWithPath: "/Photos/A_0001.JPG")),
                    row: 0,
                    image: nil,
                    edge: 0,
                )
                let badged = style != .none
                cell.softFrame = proposed
                #expect(cell.softFrameMarks.proposed == (badged ? .proposedPick : nil), "\(size) in \(style)")
                #expect(
                    cell.softFrameMarks.frame != nil && cell.softFrameMarks.softness == nil,
                    "the frame in every style",
                )
                cell.softFrame = soft
                let marks = cell.softFrameMarks
                #expect(marks.proposed == (badged ? .proposedReject : nil) && marks.frame != nil, "\(size) in \(style)")
                let pill = marks.softness ?? .null
                #expect(badged ? geometry.image.contains(pill) : marks.softness == nil, "\(size) in \(style): \(pill)")

                var picked = LibraryItem(url: URL(fileURLWithPath: "/Photos/A_0002.JPG"))
                picked.metadata.flag = .pick
                cell.configure(picked, row: 1, image: nil, edge: 0)
                #expect(cell.softFrameMarks.proposed == nil && cell.softFrameMarks.softness == nil)
                #expect(cell.softFrameMarks.frame == nil, "a decided frame's own flag, and no proposal")
                cell.softFrame = nil
            }
        }
        #expect(GridBadges.softness(soft, width: 300) == .softness("62% softer", compact: false))
        #expect(GridBadges.softness(soft, width: 40) == .softness("Soft", compact: true))
    }

    @Test func `the Proposals menu checks what's shown and the terms the filter has, and answers each choice`() throws {
        let menu = FilterProposalsMenu()
        menu.update(shown: .bestTwo, terms: [.soft])
        #expect(menu.item(.bestTwo)?.state == .on && menu.item(.off)?.state == .off)
        #expect(menu.item(.soft)?.state == .on && menu.item(.proposed)?.state == .off)
        menu.update(shown: nil, terms: [])
        #expect(menu.item(.off)?.state == .on && menu.item(.soft)?.state == .off)
        var chosen: [FilterProposalsMenu.Choice] = []
        menu.onChoose = { chosen.append($0) }
        let items = try #require(menu.menu)
        for choice in [FilterProposalsMenu.Choice.runsOnly, .changedByYou, .accept] {
            try items.performActionForItem(at: items.index(of: #require(menu.item(choice))))
        }
        #expect(chosen == [.runsOnly, .changedByYou, .accept])
        #expect(menu.item(.accept)?.title == "Accept Proposals" && menu.item(.onePerMoment)?.title == "One per Moment")
    }

    /// A folder of two bursts: four frames whose third is out of focus, then, ten minutes later, three whose last
    /// moved.
    private static func shoot(_ sandbox: SourcesSandbox) throws -> [URL] {
        let folder = sandbox.folder("Shoot")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try SoftFrameSamples.writeBurst(
            [.sharp(shift: 0), .sharp(shift: 1), .blurred(sigma: 2), .sharp(shift: 2)], to: folder, name: "A_",
            start: start, interval: 0.2,
        )
        let second = try SoftFrameSamples.writeBurst(
            [.sharp(shift: 0), .brighter, .motion(length: 9)], to: folder, name: "B_",
            start: start.addingTimeInterval(600), interval: 0.2, seed: 2,
        )
        return first + second
    }

    @Test func `a folder's bursts are measured, its proposals filtered and accepted with Undo`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let frames = try Self.shoot(sandbox)
        let model = try await sandbox.open()
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 7 && model.library.showsIndexIDs }
        let softFrames = model.librarySoftFrames
        model.showProposals(.runsOnly)
        try await sandbox.eventually(seconds: 60) {
            softFrames.verdicts.photos(.soft).count == 2 && softFrames.verdicts.photos(.proposed).count == 2
        }
        func id(_ url: URL) throws -> Int64 {
            try #require(model.library.photoID(of: url))
        }
        #expect(try Set(softFrames.verdicts.photos(.soft)) == [id(frames[2]), id(frames[6])])
        #expect(try softFrames.mark(of: id(frames[2]), url: frames[2])?.verdict == .soft)
        #expect(softFrames.measuredCount == 7)

        model.libraryFilters?.toggle(.soft)
        try await sandbox.eventually { Set(model.items.map(\.name)) == ["A_0003.JPG", "B_0003.JPG"] }
        #expect(Set(model.items.map(\.name)) == ["A_0003.JPG", "B_0003.JPG"])
        model.libraryFilters?.toggle(.soft)
        try await sandbox.eventually { model.items.count == 7 }

        #expect(model.acceptProposals())
        try await sandbox.eventually { !model.isWritingCulling }
        await sandbox.service?.settled()
        let flags = Dictionary(uniqueKeysWithValues: model.items.map { ($0.name, $0.metadata.flag) })
        #expect(flags["A_0003.JPG"] == .reject && flags["B_0003.JPG"] == .reject)
        #expect(flags.values.count { $0 == .pick } == 2 && flags.values.count { $0 == nil } == 3)
        try await sandbox.eventually { softFrames.verdicts.photos(.proposed).isEmpty }
        #expect(!model.acceptProposals(), "nothing left to accept")

        #expect(model.perform(.undo))
        try await sandbox.eventually { !model.isWritingCulling && model.items.allSatisfy { $0.metadata.flag == nil } }
        #expect(model.items.allSatisfy { $0.metadata.flag == nil }, "one Undo takes every flag back")
    }

    @Test func `a folder listed from the disk before the library took it over is judged by its photos' index IDs`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Other/A.JPG"])
        let model = try await sandbox.open()
        let frames = try Self.shoot(sandbox)
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 7 }
        let service = try #require(sandbox.service)
        try await SourcesSandbox
            .eventually { await service.canShow(sandbox.folder("Shoot"), includingSubfolders: false) }
        let softFrames = model.librarySoftFrames
        model.showProposals(.runsOnly)
        try await sandbox.eventually(seconds: 60) {
            softFrames.mark(of: model.library.photoID(of: frames[2]), url: frames[2])?.verdict == .soft
        }
        print("SOFT-FRAMES the folder's IDs are the index's: \(model.library.showsIndexIDs)")
        #expect(softFrames.mark(of: model.library.photoID(of: frames[6]), url: frames[6])?.verdict == .soft)
        #expect(model.acceptProposals())
        try await sandbox.eventually { !model.isWritingCulling }
        await service.settled()
        let rejected = model.items.filter { $0.metadata.flag == .reject }.map(\.name).sorted()
        #expect(rejected == ["A_0003.JPG", "B_0003.JPG"])
    }

    @Test func `a frame the user decided is never proposed against, and overruling one is Changed by You`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let frames = try Self.shoot(sandbox)
        let model = try await sandbox.open()
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 7 && model.library.showsIndexIDs }
        let softFrames = model.librarySoftFrames
        model.showProposals(.runsOnly)
        try await sandbox.eventually(seconds: 60) { softFrames.verdicts.photos(.soft).count == 2 }

        try await sandbox.cull(.flagPick, [frames[2]])
        try await sandbox.eventually { softFrames.verdicts.photos(.changed).count == 1 }
        let soft = try #require(model.library.photoID(of: frames[2]))
        #expect(softFrames.verdicts.verdict(of: soft) == .changed && softFrames.mark(of: soft, url: frames[2]) == nil)
        model.libraryFilters?.toggle(.changedByYou)
        try await sandbox.eventually { model.items.map(\.name) == ["A_0003.JPG"] }
        #expect(model.items.map(\.name) == ["A_0003.JPG"], "the soft frame picked")
        model.libraryFilters?.toggle(.changedByYou)

        model.showProposals(nil)
        #expect(!softFrames.shows && softFrames.mark(of: soft, url: frames[2]) == nil)
    }
}
