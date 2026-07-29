import Foundation
import Testing
@testable import eMeishi

struct OCRBackgroundTaskManagerTests {
    @Test
    func jobIdentifierIsConcreteAndMatchesPermittedPrefix() {
        let jobID = OCRJobID(rawValue: UUID(uuidString: "D84285F7-D10F-41D6-BB6D-9703822D67C1")!)
        let identifier = OCRBackgroundTaskManager.taskIdentifier(jobID: jobID)

        #expect(identifier == "com.jinks.emeishi.ocr.D84285F7-D10F-41D6-BB6D-9703822D67C1")
        #expect(!identifier.hasSuffix(".*"))
        #expect(identifier.hasPrefix(OCRBackgroundTaskManager.permittedIdentifier.dropLast()))
    }
}
