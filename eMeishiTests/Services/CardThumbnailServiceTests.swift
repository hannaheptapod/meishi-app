import CoreGraphics
import Testing
import UIKit
@testable import eMeishi

@MainActor
struct CardThumbnailServiceTests {
    @Test func landscapeLongEdgeFitsInvisibleFrame() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 200, height: 100))
        #expect(abs(size.width - 64) < 0.001)
        #expect(abs(size.height - 32) < 0.001)
    }

    @Test func portraitLongEdgeFitsInvisibleFrame() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 100, height: 200))
        #expect(abs(size.width - 32) < 0.001)
        #expect(abs(size.height - 64) < 0.001)
    }

    @Test func thumbnailCanScaleUpWithoutCropping() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 20, height: 10))
        #expect(abs(size.width - 64) < 0.001)
        #expect(abs(size.height - 32) < 0.001)
    }

    @Test func displayDecoderDownsamplesBeforeRendering() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let data = try #require(source.jpegData(compressionQuality: 0.9))
        let decoded = try #require(
            await CardImageDecodingService.shared.image(
                from: data,
                maximumPixelSize: 120,
                cacheIdentifier: "downsample-test"
            )
        )

        #expect(decoded.image.size.width <= 120)
        #expect(decoded.image.size.height <= 120)
        #expect(abs((decoded.image.size.width / decoded.image.size.height) - 2) < 0.01)
    }
}
