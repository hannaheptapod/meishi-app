import CoreGraphics
import Testing
@testable import eMeishi

struct CardThumbnailServiceTests {
    @Test func landscapeLongEdgeFitsInvisibleFrame() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 200, height: 100))
        #expect(abs(size.width - 58) < 0.001)
        #expect(abs(size.height - 29) < 0.001)
    }

    @Test func portraitLongEdgeFitsInvisibleFrame() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 100, height: 200))
        #expect(abs(size.width - 29) < 0.001)
        #expect(abs(size.height - 58) < 0.001)
    }

    @Test func thumbnailCanScaleUpWithoutCropping() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 20, height: 10))
        #expect(abs(size.width - 58) < 0.001)
        #expect(abs(size.height - 29) < 0.001)
    }
}
