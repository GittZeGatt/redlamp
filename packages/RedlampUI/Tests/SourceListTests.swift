import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Library module's left side as a Mac source list (LIB-45): its sections keep their layout, the source shown is
/// the list's selection, a header collapses its section and Option-click leaves it the only one open, and the rows
/// take their look and their drop target from AppKit.
@MainActor
@Suite(.serialized)
struct SourceListTests {
    private func column(_ model: EditorModel) -> (LibraryFoldersColumn, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 800), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let column = LibraryFoldersColumn(model: model)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        return (column, window)
    }

    private func views<View: NSView>(_: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { view -> [View] in
            if let match = view as? View {
                return [match]
            }
            return views(View.self, in: view)
        }
    }

    private func section(_ identifier: String, in root: NSView) throws -> SourceListSectionView {
        try #require(views(SourceListSectionView.self, in: root).first { $0.accessibilityIdentifier() == identifier })
    }

    @Test func `the sections lay out once and keep their frames from one layout to the next`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Trip/C.JPG"])
        let model = try await sandbox.open()
        let (column, window) = column(model)
        defer { window.contentView = nil }
        try await sandbox.counts { $0.isCounted }
        try await sandbox.eventually { model.library.roots.count == 1 }
        column.layoutSubtreeIfNeeded()
        let sections = views(SourceListSectionView.self, in: column)
        #expect(sections.map { $0.accessibilityIdentifier() } == [
            "sources.library", "sidebar.folders", "sources.collections",
        ])
        let lists = views(SidebarOutlineView.self, in: column)
        #expect(lists.count == 3 && lists.allSatisfy { $0.style == .sourceList && $0.refusesFirstResponder })
        let frames = (sections + lists).map(\.frame)
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()
        #expect((sections + lists).map(\.frame) == frames, "a second layout moves nothing")
        for (above, below) in zip(sections, sections.dropFirst()) {
            #expect(
                below.frame.minY >= above.frame.maxY,
                "\(below.accessibilityIdentifier()) starts below the one above",
            )
        }
        let headers = sections.map(\.header)
        #expect(headers.map { $0.accessibilityIdentifier() } == [
            "sources.library.header", "sidebar.folders.header", "sources.collections.header",
        ])
    }

    @Test func `the source shown is the list's selection, and a folder open is the Folders list's`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG"])
        let model = try await sandbox.open()
        let (column, window) = column(model)
        defer { window.contentView = nil }
        try await sandbox.counts { $0.isCounted }
        let library = try #require(views(LibraryOutlineView.self, in: column).first)
        let folders = try #require(views(FolderOutlineView.self, in: column).first)
        @MainActor func selected(_ list: SidebarOutlineView) -> [SidebarNode.Kind] {
            list.selectedRowIndexes.compactMap { (list.item(atRow: $0) as? SidebarNode)?.kind }
        }
        @MainActor func allPhotographsSelected() -> Bool {
            if case let .source(row)? = selected(library).first {
                return row.source == .allPhotographs
            }
            return false
        }
        @MainActor func rootSelected() -> Bool {
            if case let .folder(row)? = selected(folders).first {
                return row.isOpen && row.isRoot
            }
            return false
        }

        #expect(model.librarySources.show(.allPhotographs))
        try await sandbox.eventually { allPhotographsSelected() }
        #expect(allPhotographsSelected(), "All Photographs is the Library section's selection")
        #expect(selected(folders).isEmpty, "no folder is open")

        model.showFolder(sandbox.root)
        try await sandbox.eventually { rootSelected() }
        #expect(rootSelected(), "the folder open is the Folders list's selection")
        #expect(selected(library).isEmpty, "the Library section's source no longer shown")
    }

    @Test func `a click on a header collapses its section, and Option-click leaves it the only one open`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG"])
        let model = try await sandbox.open()
        let (column, window) = column(model)
        defer { window.contentView = nil }
        let folders = try section("sidebar.folders", in: column)
        let collections = try section("sources.collections", in: column)
        func click(_ header: NSView, option: Bool = false) throws {
            let point = header.convert(CGPoint(x: 30, y: header.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: option ? .option : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1,
            ))
            header.mouseDown(with: event)
        }
        #expect(model.expandedSidebarSections.contains(.folders) && model.librarySources.isExpanded(.collections))

        try click(folders.header)
        #expect(!model.expandedSidebarSections.contains(.folders))
        try await sandbox.eventually { !folders.isExpanded }
        column.layoutSubtreeIfNeeded()
        #expect(folders.frame.height == SourceListSectionView.Layout.spacing + SourceListSectionView.Layout
            .headerHeight)

        try click(collections.header, option: true)
        #expect(model.librarySources.isExpanded(.collections))
        #expect(!model.librarySources.isExpanded(.library) && !model.expandedSidebarSections.contains(.folders))
        try click(collections.header, option: true)
        #expect(!model.librarySources.isExpanded(.collections), "Option-click on the only one open closes it")
    }

    @Test func `a row's title is as tall as its line in both looks, and an empty section's line wraps`() throws {
        let model = EditorModel(engine: StubEngine())
        @MainActor func title(_ kind: SidebarNode.Kind, look: SidebarOutlineView.Look) throws -> NSTextField {
            let cell = SidebarCellView(node: SidebarNode(kind), model: model, look: look, rowSize: .medium)
            cell.frame = CGRect(x: 0, y: 0, width: 220, height: look == .panel ? 24 : 32)
            cell.layoutSubtreeIfNeeded()
            return try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        }
        let row = SourceRow(source: .marked, count: 12)
        for look in [SidebarOutlineView.Look.panel, .sourceList] {
            let label = try title(.source(row), look: look)
            #expect(label.frame.height >= label.intrinsicContentSize.height, "\(look): nothing of the title is cut")
        }
        let line = try title(.placeholder(LibrarySourcesText.noCollections), look: .sourceList)
        #expect(line.frame.height > line.intrinsicContentSize.height, "the line wraps onto a second")
    }

    @Test func `a source list's row leaves its drop target and its selection to AppKit`() {
        let row = SidebarRowView()
        row.drawsHighlights = false
        row.isDropTarget = true
        #expect(row.isTargetForDropOperation)
        row.isDropTarget = false
        #expect(!row.isTargetForDropOperation)
        let panel = SidebarRowView()
        panel.isDropTarget = true
        #expect(!panel.isTargetForDropOperation, "a panel's row outlines the drop itself")
    }
}
