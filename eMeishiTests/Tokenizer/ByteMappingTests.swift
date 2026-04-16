import Testing
@testable import eMeishi

// MARK: - Qwen25Tokenizer バイトマッピング テスト

struct ByteMappingTests {

    // GPT-2方式の bytes_to_unicode が全256バイトを網羅するか
    @Test func coverageAllBytes() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc.count == 256, "全256バイトがエンコード対応している必要がある")
        #expect(dec.count == 256, "全256バイトがデコード対応している必要がある")
    }

    // スペース (0x20) が U+0120 (Ġ) にマップされること
    @Test func spaceEncodedAsGhostChar() {
        let (enc, _) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc[0x20] == "Ġ", "スペースは Ġ (U+0120) にエンコードされる必要がある")
    }

    // 改行 (0x0A) が Ċ (U+010A) にマップされること
    @Test func newlineEncoded() {
        let (enc, _) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc[0x0A] == "Ċ", "改行は Ċ (U+010A) にエンコードされる必要がある")
    }

    // 印字可能 ASCII (例: 'A' = 0x41) はそのままマップされること
    @Test func printableAsciiIdentity() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc[0x41] == "A", "印字可能 ASCII は自分自身にエンコードされる")
        #expect(dec["A"] == 0x41, "印字可能 ASCII は自分自身からデコードされる")
    }

    // エンコードとデコードが逆写像になっているか
    @Test func roundTrip() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        for b: UInt8 in 0...255 {
            if let ch = enc[b], let decoded = dec[ch] {
                #expect(decoded == b, "byte \(b) のラウンドトリップが失敗")
            }
        }
    }
}
