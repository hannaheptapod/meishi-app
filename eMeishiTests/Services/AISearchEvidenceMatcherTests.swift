import Testing
@testable import eMeishi

struct AISearchEvidenceMatcherTests {
    @Test func matchesExplicitAreaAndSalesAcrossDifferentFields() {
        let fields = [
            "例示販売株式会社",
            "営業企画部 営業",
            "東京都例示区",
            "営業"
        ]

        #expect(AISearchEvidenceMatcher.matches(query: "例示区の会社の営業", fields: fields))
    }

    @Test func treatsCustomerConsultationAsSalesRelatedWork() {
        let fields = [
            "架空相談株式会社 例示区店",
            "お客様相談室"
        ]

        #expect(AISearchEvidenceMatcher.matches(query: "例示区の会社の営業", fields: fields))
    }

    @Test func rejectsCardMissingTheRequestedAreaAndRole() {
        let fields = [
            "サンプル開発株式会社",
            "第二システム開発本部",
            "東京都架空区"
        ]

        #expect(!AISearchEvidenceMatcher.matches(query: "例示区の会社の営業", fields: fields))
    }
}
