import Testing
@testable import eMeishi

// MARK: - SpecialToken ID テスト

@MainActor
struct SpecialTokenTests {

    @Test func tokenIDsMatchQwenSpec() {
        #expect(Qwen25Tokenizer.SpecialToken.imStart == 151644)
        #expect(Qwen25Tokenizer.SpecialToken.imEnd   == 151645)
        #expect(Qwen25Tokenizer.SpecialToken.eot     == 151643)
    }
}
