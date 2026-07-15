import Foundation
import Testing
@testable import eMeishi

@MainActor
struct ExternalURLNormalizerTests {
    @Test
    func omittedSchemeDefaultsToHTTPS() {
        #expect(ExternalURLNormalizer.websiteURL(from: "example.com/path")?.absoluteString == "https://example.com/path")
    }

    @Test(arguments: ["javascript:alert(1)", "mailto:test@example.com", "file:///tmp/a", "   "])
    func rejectsNonWebSchemes(_ value: String) {
        #expect(ExternalURLNormalizer.websiteURL(from: value) == nil)
    }

    @Test
    func permitsHTTPAndHTTPS() {
        #expect(ExternalURLNormalizer.websiteURL(from: "http://example.com")?.scheme == "http")
        #expect(ExternalURLNormalizer.websiteURL(from: "https://example.com")?.scheme == "https")
    }
}
