import XCTest
@testable import CevicheCore

final class LocalizationTests: XCTestCase {
    private func language(_ identifier: String) throws -> Bundle {
        let url = try XCTUnwrap(L10n.bundle.url(forResource: identifier, withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    func testEverySupportedLanguageShipsCompleteTablesAndNativeLabels() throws {
        let englishURL = try XCTUnwrap(try language("en").url(forResource: "Localizable", withExtension: "strings"))
        let english = try XCTUnwrap(NSDictionary(contentsOf: englishURL) as? [String: String])
        XCTAssertGreaterThan(english.count, 1500)
        for identifier in L10n.supportedLanguages {
            let bundle = try language(identifier)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(NSDictionary(contentsOf: tableURL) as? [String: String])
            XCTAssertEqual(Set(table.keys), Set(english.keys), identifier)
            XCTAssertTrue(table.values.allSatisfy { !$0.isEmpty }, identifier)
            if identifier != "en" {
                for key in ["Import Photos…", "Exposure", "Remove from Library…", "Appearance", "Couldn’t Open the Photo"] {
                    XCTAssertNotEqual(L10n.key(key, bundle: bundle), key, "\(identifier): \(key)")
                }
            }
        }
    }

    func testRegionalLanguagePreferencesResolveToExpectedScripts() {
        for (preference, expected) in [("en-US", "en"), ("zh-CN", "zh-Hans"),
                                       ("zh-TW", "zh-Hant"), ("zh-Hant-HK", "zh-Hant"),
                                       ("it-IT", "it"), ("es-ES", "es"), ("es-AR", "es")] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: L10n.supportedLanguages,
                                                         forPreferences: [preference]).first, expected, preference)
        }
    }

    func testInterpolationDoesNotTranslateUserTextOrInterpretItsPercentSigns() throws {
        let name = "Exposure 50% %@ 中文.jpg"
        let message: L10n.Message = "Downloading \(name)"
        XCTAssertEqual(message.key, "Downloading %1$@")
        for identifier in L10n.supportedLanguages {
            let result = L10n.tr(message, bundle: try language(identifier))
            XCTAssertTrue(result.contains(name), result)
            XCTAssertFalse(result.contains("%1$@"), result)
        }
        let percentage: L10n.Message = "\(name) - 100%"
        XCTAssertEqual(L10n.tr(percentage, bundle: try language("en")), name + " - 100%")
        XCTAssertEqual(L10n.tr("100%", bundle: try language("en")), "100%")
    }

    func testOneEnglishWordInTwoContextsTranslatesEachWay() throws {
        let chinese = try language("zh-Hans"), english = try language("en")
        XCTAssertEqual(L10n.tr("Landscape", context: "orientation", bundle: chinese), "横向")
        XCTAssertEqual(L10n.tr("Landscape", context: "exposure program", bundle: chinese), "风景")
        XCTAssertEqual(L10n.tr("Landscape", context: "orientation", bundle: english), "Landscape")
        XCTAssertEqual(L10n.tr("A future word", context: "anything", bundle: chinese), "A future word", "Untranslated reads as the English")
    }

    func testDatesFollowTheInAppLanguageWithoutRelaunch() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: LanguageChoice.key), defaults.object(forKey: "AppleLanguages"))
        defer {
            defaults.set(saved.0, forKey: LanguageChoice.key); defaults.set(saved.1, forKey: "AppleLanguages")
            L10n.updateActiveBundle()
        }
        // 9 November 2026, midday UTC, so the day is the same in every time zone.
        let date = Date(timeIntervalSince1970: 1_794_225_600)
        let month: [LanguageChoice: String] = [.en: "Nov", .es: "nov", .it: "nov", .zhHans: "11月", .zhHant: "11月"]
        var seen = Set<String>()
        for (choice, expected) in month {
            LanguageChoice.current = choice
            let text = date.localized(date: .abbreviated, time: .omitted)
            XCTAssertTrue(text.contains(expected), "\(choice): \(text)")
            XCTAssertTrue(L10n.tr("Archived \(date, format: .dateTime.day().month().year())").contains(expected), "\(choice)")
            seen.insert(text)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 3, "English, the Romance languages and Chinese differ; es and it, zh-Hans and zh-Hant may match")
    }

    func testUnknownKeysFallBackToEnglishWithoutDroppingValues() throws {
        let unknown: L10n.Message = "A future message for \("photo.jpg")"
        for identifier in L10n.supportedLanguages {
            XCTAssertEqual(L10n.tr(unknown, bundle: try language(identifier)), "A future message for photo.jpg")
        }
    }

    func testPluralMessagesAreWholeSentencesAndRetainCounts() throws {
        let singular: L10n.Message = "\(1) photo"
        let plural: L10n.Message = "\(2) photos"
        XCTAssertEqual(L10n.tr(singular, bundle: try language("en")), "1 photo")
        XCTAssertEqual(L10n.tr(plural, bundle: try language("en")), "2 photos")
        for identifier in L10n.supportedLanguages {
            XCTAssertTrue(L10n.tr(singular, bundle: try language(identifier)).contains("1"))
            XCTAssertTrue(L10n.tr(plural, bundle: try language(identifier)).contains("2"))
        }
    }


    func testTranslationNeverChangesSerializedEnumsOrXMPColorNames() throws {
        XCTAssertEqual(MaskKind.subject.rawValue, "Subject")
        XCTAssertEqual(UprightMode.guided.rawValue, "Guided")
        XCTAssertEqual(EditTransferItem.whiteBalance.rawValue, "White balance")
        XCTAssertEqual(SelectiveColor.names, ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"])
        var settings = Adjustments()
        settings.selectiveColors[0].hue = 12
        let xmp = try XMPCodec.encode(adjustments: settings)
        let text = try XCTUnwrap(String(data: xmp, encoding: .utf8))
        XCTAssertTrue(text.contains("HueAdjustmentRed"))
        XCTAssertFalse(text.contains("L10n"))
        let decoded = try JSONDecoder().decode(MaskKind.self, from: JSONEncoder().encode(MaskKind.subject))
        XCTAssertEqual(decoded, .subject)
    }
}
