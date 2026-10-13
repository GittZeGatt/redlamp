import Foundation

/// A Lightroom Classic catalog of a folder, made by the run with the tables the import reads: three photos
/// rated, picked, rejected and labelled, one in the Quick Collection, a keyword with a synonym, a title, a
/// collection in a set, and two smart collections, one whose rule maps and one whose doesn't.
@_spi(Harness) public enum LightroomScratchCatalog {
    /// `otherRoots` are root folders the catalog names without photos in them, such as one that has moved.
    public static func make(of folder: URL, tag: String, otherRoots: [URL] = []) throws -> URL {
        let url = folder.deletingLastPathComponent()
            .appending(path: "lightroom-\(tag)/Lightroom Catalog.lrcat")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let database = try SQLiteDatabase(path: url.path)
        let root = folder.standardizedFileURL.path + "/"
        func text(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        let title = "Tram \(tag)"
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(title)</rdf:li></rdf:Alt></dc:title>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        try database.execute("""
        CREATE TABLE Adobe_variablesTable (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, name, value);
        CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
          absolutePath UNIQUE NOT NULL DEFAULT '', name NOT NULL DEFAULT '', relativePathFromCatalog);
        CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, parentId INTEGER,
          pathFromRoot NOT NULL DEFAULT '', rootFolder INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
          baseName NOT NULL DEFAULT '', extension NOT NULL DEFAULT '', folder INTEGER NOT NULL DEFAULT 0,
          idx_filename NOT NULL DEFAULT '', sidecarExtensions);
        CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
          colorLabels NOT NULL DEFAULT '', copyName, masterImage INTEGER, pick NOT NULL DEFAULT 0, rating,
          rootFile INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL,
          includeOnExport INTEGER NOT NULL DEFAULT 1, includeParents INTEGER NOT NULL DEFAULT 1,
          includeSynonyms INTEGER NOT NULL DEFAULT 1, keywordType, lc_name, name, parent INTEGER);
        CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER NOT NULL DEFAULT 0,
          tag INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE AgLibraryKeywordSynonym (id_local INTEGER PRIMARY KEY, keyword INTEGER NOT NULL DEFAULT 0,
          lc_name, name);
        CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, creationId NOT NULL DEFAULT '',
          name NOT NULL DEFAULT '', parent INTEGER, systemOnly NOT NULL DEFAULT '');
        CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER NOT NULL DEFAULT 0,
          image INTEGER NOT NULL DEFAULT 0, positionInCollection);
        CREATE TABLE AgLibraryCollectionContent (id_local INTEGER PRIMARY KEY,
          collection INTEGER NOT NULL DEFAULT 0, content, owningModule);
        CREATE TABLE AgLibraryIPTC (id_local INTEGER PRIMARY KEY, caption, copyright, image INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE Adobe_AdditionalMetadata (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, image INTEGER,
          xmp NOT NULL DEFAULT '');
        INSERT INTO Adobe_variablesTable VALUES (1, 'v', 'Adobe_DBVersion', '1300025');
        INSERT INTO AgLibraryRootFolder VALUES (2, 'r', \(text(root)), \(text(folder.lastPathComponent)), NULL);
        INSERT INTO AgLibraryFolder VALUES (3, 'f', NULL, 'Shoot/', 2);
        INSERT INTO AgLibraryFile VALUES (11, 'a', 'LR_0001', 'jpg', 3, 'LR_0001.jpg', NULL),
          (12, 'b', 'LR_0002', 'jpg', 3, 'LR_0002.jpg', NULL), (13, 'c', 'LR_0003', 'jpg', 3, 'LR_0003.jpg', NULL);
        INSERT INTO Adobe_images VALUES (21, 'i1', 'Red', NULL, NULL, 1, 5, 11),
          (22, 'i2', \(text("Client \(tag)")), NULL, NULL, -1, 2, 12), (23, 'i3', '', NULL, NULL, 0, NULL, 13),
          (24, 'i4', '', 'Copy 1', 21, 0, 4, 11);
        INSERT INTO AgLibraryKeyword VALUES (30, 'k0', 1, 1, 1, NULL, NULL, NULL, NULL),
          (31, 'k1', 1, 1, 1, NULL, \(text("places \(tag)")), \(text("Places \(tag)")), 30),
          (32, 'k2', 1, 1, 1, NULL, 'lisbon', 'Lisbon', 31);
        INSERT INTO AgLibraryKeywordSynonym VALUES (40, 32, 'lisboa', 'Lisboa');
        INSERT INTO AgLibraryKeywordImage VALUES (41, 21, 32);
        INSERT INTO AgLibraryCollection VALUES (50, 'com.adobe.ag.library.group', \(
            text("Lightroom \(tag)")
        ), NULL, ''),
          (51, 'com.adobe.ag.library.collection', 'Trip', 50, ''),
          (52, 'com.adobe.ag.library.collection', 'Quick Collection', NULL, '1'),
          (53, 'com.adobe.ag.library.smart_collection', 'Five stars', 50, ''),
          (54, 'com.adobe.ag.library.smart_collection', 'Edited this week', 50, '');
        INSERT INTO AgLibraryCollectionImage VALUES (60, 51, 21, 'a'), (61, 52, 23, 'a');
        INSERT INTO AgLibraryCollectionContent VALUES
          (70, 53, 's = { { criteria = "rating", operation = "==", value = 5, value2 = 0, }, combine = "intersect", }',
           'ag.library.smart_collection'),
          (71, 54, 's = { { criteria = "touchTime", operation = "inLast", value = 7, value2 = "days", }, '
           || 'combine = "intersect", }', 'ag.library.smart_collection');
        INSERT INTO Adobe_AdditionalMetadata VALUES (80, 'x1', 21, \(text(packet)));
        """)
        for (offset, other) in otherRoots.enumerated() {
            let id = 100 + offset
            let path = other.standardizedFileURL.path + "/"
            try database.execute("""
            INSERT INTO AgLibraryRootFolder VALUES (\(id), 'r\(id)', \(text(path)), \(text(other
                    .lastPathComponent)), NULL);
            """)
        }
        return url
    }
}
