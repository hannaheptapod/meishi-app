import Testing
@testable import eMeishi

struct AISearchEvidenceMatcherTests {
    @Test func matchesExplicitAreaAndSalesAcrossDifferentFields() {
        let fields = [
            "株式会社グローバルアロー",
            "営業企画部 営業",
            "東京都目黒区",
            "営業"
        ]

        #expect(AISearchEvidenceMatcher.matches(query: "目黒の会社の営業", fields: fields))
    }

    @Test func treatsCustomerConsultationAsSalesRelatedWork() {
        let fields = [
            "株式会社アエラス.FR アエラス目黒店",
            "お客様相談室"
        ]

        #expect(AISearchEvidenceMatcher.matches(query: "目黒の会社の営業", fields: fields))
    }

    @Test func rejectsCardMissingTheRequestedAreaAndRole() {
        let fields = [
            "NTTデータソフィア株式会社",
            "第二システム開発本部",
            "東京都江東区"
        ]

        #expect(!AISearchEvidenceMatcher.matches(query: "目黒の会社の営業", fields: fields))
    }
}
