import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary

/// The import grid's thumbnails (LIB-27): the previews browsing made into the store, decoded at the
/// cell's size on the scheduler's on-screen lane, and kept in memory within a byte budget; until a
/// photo's is made, the provisional preview its session holds (a large JPEG's EXIF thumbnail).
@MainActor
final class ImportThumbnails {
    let store: PhotoStore
    let pixelSize: Int
    private let scheduler: WorkScheduler
    private let cache = NSCache<NSString, CGImage>()
    private let provisional = NSCache<NSString, CGImage>()
    private var loading: Set<String> = []

    /// The long edge thumbnails are decoded at: a cell's image at 2x.
    static let standardPixelSize = 320

    init(
        store: PhotoStore,
        pixelSize: Int = ImportThumbnails.standardPixelSize,
        scheduler: WorkScheduler = LibraryIndexer.scheduler,
    ) {
        self.store = store
        self.pixelSize = pixelSize
        self.scheduler = scheduler
        cache.totalCostLimit = 96 << 20
        provisional.totalCostLimit = 16 << 20
    }

    /// The photo's thumbnail, or its provisional preview while that's all there is.
    func image(for photo: ImportPhoto) -> CGImage? {
        cache.object(forKey: photo.id as NSString) ?? provisional.object(forKey: photo.id as NSString)
    }

    /// Decodes `photo`'s preview once browsing has made it, or meanwhile the provisional preview `session`
    /// holds, unless it's in memory already, and calls `loaded` with it on the main thread.
    func load(_ photo: ImportPhoto, session: ImportSession?, loaded: @escaping @MainActor (String, CGImage) -> Void) {
        let id = photo.id
        switch photo.state {
        case .previewed:
            guard let key = photo.primary.contentKey, cache.object(forKey: id as NSString) == nil,
                  loading.insert(id).inserted
            else { return }
            let (store, size, modified, pixelSize) = (store, photo.primary.size, photo.primary.modified, pixelSize)
            decode(id, loading: id, into: cache, loaded: loaded) {
                store.data(for: key, tier: .grid, size: size, modified: modified)
                    .flatMap { StoreThumbnails.decode($0, pixelSize: pixelSize) }
            }
        case .provisional:
            let mark = id + "#provisional"
            guard let session, image(for: photo) == nil, loading.insert(mark).inserted else { return }
            let pixelSize = pixelSize
            decode(id, loading: mark, into: provisional, loaded: loaded) {
                session.provisionalPreview(id, edge: pixelSize)
            }
        default:
            return
        }
    }

    private func decode(
        _ id: String, loading mark: String, into cache: NSCache<NSString, CGImage>,
        loaded: @escaping @MainActor (String, CGImage) -> Void,
        _ image: @escaping @Sendable () -> CGImage?,
    ) {
        Task { [weak self] in
            let image = try? await self?.scheduler.run(.onScreen, key: "import-thumbnail:" + mark, image)
            guard let self else { return }
            loading.remove(mark)
            guard let image = image ?? nil else { return }
            cache.setObject(image, forKey: id as NSString, cost: image.bytesPerRow * image.height)
            if cache === self.cache {
                provisional.removeObject(forKey: id as NSString)
            }
            loaded(id, image)
        }
    }
}
