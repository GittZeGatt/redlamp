import Testing
@testable import RedlampUI

/// What the collection sheets say (LIB-45).
@MainActor
struct CollectionSheetTests {
    @Test func `the smart collection editor counts the photos its rules find in words that agree`() {
        #expect(SmartCollectionSheet.matching(0) == "No photos match these rules")
        #expect(SmartCollectionSheet.matching(1) == "1 photo matches these rules")
        #expect(SmartCollectionSheet.matching(1204) == "1,204 photos match these rules")
    }
}
