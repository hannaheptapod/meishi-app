import Testing
import CoreML
@testable import Meishi

// MARK: - Qwen25Tokenizer テスト

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
        let spaceChar = enc[0x20]
        #expect(spaceChar == "Ġ", "スペースは Ġ (U+0120) にエンコードされる必要がある")
    }

    // 改行 (0x0A) が Ċ (U+010A) にマップされること
    @Test func newlineEncoded() {
        let (enc, _) = Qwen25Tokenizer.buildByteMapping()
        let nlChar = enc[0x0A]
        #expect(nlChar == "Ċ", "改行は Ċ (U+010A) にエンコードされる必要がある")
    }

    // 印字可能 ASCII (例: 'A' = 0x41) はそのままマップされること
    @Test func printableAsciiIdentity() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        let charA = enc[0x41]
        #expect(charA == "A", "印字可能 ASCII は自分自身にエンコードされる")
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

// MARK: - BPEPair テスト

@MainActor
struct BPEPairTests {

    @Test func hashEquality() {
        let p1 = BPEPair("hello", "world")
        let p2 = BPEPair("hello", "world")
        let p3 = BPEPair("world", "hello")
        #expect(p1 == p2)
        #expect(p1 != p3)
        var set = Set<BPEPair>()
        set.insert(p1)
        set.insert(p2)
        #expect(set.count == 1, "同じペアは重複なく格納される")
    }
}

// MARK: - LocalLLMService テスト（モデル不要）

struct CausalMaskTests {

    let service = LocalLLMService.shared

    // 4D プリフィルマスク: 下三角が 1 (int32)
    @Test func prefillMask4DInt32() throws {
        let mask = try service.buildCausalMask(queryLen: 3, keyLen: 3)
        #expect(mask.shape == [1, 1, 3, 3])
        // [0,0,0,0]=1 [0,0,0,1]=0 [0,0,0,2]=0
        // [0,0,1,0]=1 [0,0,1,1]=1 [0,0,1,2]=0
        // [0,0,2,0]=1 [0,0,2,1]=1 [0,0,2,2]=1
        #expect(mask[0].intValue == 1)
        #expect(mask[1].intValue == 0)
        #expect(mask[2].intValue == 0)
        #expect(mask[3].intValue == 1)
        #expect(mask[4].intValue == 1)
        #expect(mask[5].intValue == 0)
        #expect(mask[6].intValue == 1)
        #expect(mask[7].intValue == 1)
        #expect(mask[8].intValue == 1)
    }

    // 4D デコードマスク: queryLen=1 のとき全て 1 (can attend all)
    @Test func decodeMask4DAllOnes() throws {
        let mask = try service.buildCausalMask(queryLen: 1, keyLen: 5)
        #expect(mask.shape == [1, 1, 1, 5])
        for i in 0..<5 {
            #expect(mask[i].intValue == 1, "デコードマスクは全て 1 である必要がある")
        }
    }
}

// MARK: - ChatML プロンプト テスト

struct ChatMLPromptTests {

    let service = LocalLLMService.shared

    @Test func promptContainsSpecialTokens() {
        let prompt = service.buildChatMLPrompt(lines: ["山田 太郎", "株式会社テスト"])
        #expect(prompt.contains("<|im_start|>"), "ChatML 開始トークンが必要")
        #expect(prompt.contains("<|im_end|>"), "ChatML 終了トークンが必要")
        #expect(prompt.contains("system"), "system ロールが必要")
        #expect(prompt.contains("user"), "user ロールが必要")
        #expect(prompt.contains("assistant"), "assistant プレフィクスが必要")
    }

    @Test func promptContainsInputLines() {
        let lines = ["山田 太郎", "株式会社テスト", "test@example.com"]
        let prompt = service.buildChatMLPrompt(lines: lines)
        for line in lines {
            #expect(prompt.contains(line), "入力行 '\(line)' がプロンプトに含まれる必要がある")
        }
    }

    @Test func promptEndsWithAssistantPrefix() {
        let prompt = service.buildChatMLPrompt(lines: ["テスト"])
        #expect(prompt.hasSuffix("<|im_start|>assistant"),
             "プロンプトは assistant プレフィクスで終わる必要がある")
    }
}

// MARK: - JSON パース テスト

struct JSONParseTests {

    let service = LocalLLMService.shared

    @Test func parsesFullJSON() {
        let json = """
        {"lastName":"山田","firstName":"太郎","company":"テスト株式会社","title":"部長",\
        "phone":"090-1234-5678","email":"yamada@test.co.jp","address":"東京都","website":"https://test.co.jp"}
        """
        let result = service.parseJSON(json)
        #expect(result != nil)
        #expect(result?.lastName  == "山田")
        #expect(result?.firstName == "太郎")
        #expect(result?.company   == "テスト株式会社")
        #expect(result?.title     == "部長")
        #expect(result?.phones.first == "090-1234-5678")
        #expect(result?.email     == "yamada@test.co.jp")
        #expect(result?.address   == "東京都")
        #expect(result?.website   == "https://test.co.jp")
    }

    @Test func parsesJSONWithMarkdownFence() {
        let text = """
        ```json
        {"lastName":"田中","firstName":"花子","company":"","title":"","phone":"","email":"","address":"","website":""}
        ```
        """
        let result = service.parseJSON(text)
        #expect(result != nil, "```json フェンスを除去してパースできる必要がある")
        #expect(result?.lastName == "田中")
        #expect(result?.firstName == "花子")
    }

    @Test func parsesJSONWithLeadingText() {
        let text = "以下がJSONです：\n{\"lastName\":\"佐藤\",\"firstName\":\"一郎\",\"company\":\"\",\"title\":\"\",\"phone\":\"\",\"email\":\"\",\"address\":\"\",\"website\":\"\"}"
        let result = service.parseJSON(text)
        #expect(result != nil, "前置きテキストがあってもパースできる必要がある")
        #expect(result?.lastName == "佐藤")
    }

    @Test func returnsNilForInvalidJSON() {
        #expect(service.parseJSON("") == nil)
        #expect(service.parseJSON("これはJSONではありません") == nil)
        #expect(service.parseJSON("{ 不正なJSON }") == nil)
    }

    @Test func parsesPartialJSON() {
        // 必須フィールドが一部欠けていても処理できる
        let json = "{\"lastName\":\"木村\",\"firstName\":\"次郎\"}"
        let result = service.parseJSON(json)
        // 欠けたフィールドは空文字列になる
        #expect(result?.lastName == "木村")
        #expect(result?.company  == "")
    }
}

// MARK: - SpecialToken ID テスト

struct SpecialTokenTests {

    @Test func tokenIDsMatchQwenSpec() {
        // Qwen2.5 の仕様に合わせた特殊トークン ID の確認
        #expect(Qwen25Tokenizer.SpecialToken.imStart == 151644)
        #expect(Qwen25Tokenizer.SpecialToken.imEnd   == 151645)
        #expect(Qwen25Tokenizer.SpecialToken.eot     == 151643)
    }
}
