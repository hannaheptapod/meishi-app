import ImageIO
import Testing
import UIKit
@testable import eMeishi

@MainActor
struct PhotoImportServiceTests {
    @Test
    func downsampleBeforeDecodeLimitsLongestEdge() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let input = try #require(image.jpegData(compressionQuality: 0.9))

        let output = try PhotoImportService.downsampledJPEGData(from: input, maxPixelSize: 300)
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(max(width, height) <= 300)
        #expect(width > height)
    }
}
