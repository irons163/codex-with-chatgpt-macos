import XCTest
@testable import C2CCore

final class AppLocalizationTests: XCTestCase {
    func testCodexLanguageIdentifiersUseSupportedLanguageOrEnglishFallback() {
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("en-US"), .english)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("zh-TW"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("zh-Hant-HK"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("zh_CN"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("fr-CA"), .french)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("es-419"), .spanish)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("ja-JP"), .japanese)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("ko-KR"), .korean)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier("de-DE"), .english)
        XCTAssertEqual(AppLanguage.matchingCodexIdentifier(nil), .english)
    }

    func testEverySupportedLanguageHasEveryAppString() throws {
        for language in AppLanguage.allCases {
            XCTAssertTrue(AppLocalization.hasCompleteCatalog(for: language), language.rawValue)
        }

        let data = try XCTUnwrap(AppLocalization.javascriptCatalog.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        XCTAssertEqual(Set(object.keys), Set(AppLanguage.allCases.map(\.rawValue)))
        for language in AppLanguage.allCases {
            XCTAssertEqual(
                Set(object[language.rawValue]?.keys.map { $0 } ?? []),
                Set(AppTextKey.allCases.map(\.rawValue)),
                language.rawValue
            )
        }
    }

    func testReplacementAndFallbackText() {
        XCTAssertEqual(
            AppLocalization.text(
                .attachNextBatch,
                language: .english,
                replacements: ["count": "12"]
            ),
            "Attach next batch after sending (12 remaining)"
        )
        XCTAssertEqual(
            AppLocalization.text(.checkUpdates, language: .japanese),
            "アップデートを確認…"
        )
    }
}
