import Foundation
import XCTest
@testable import MilaNativeUI

/// Every catalog bundled into the package resolves, and a non-English locale
/// renders its own catalog rather than the English fallback.
/// Evidence for the `mila-apple-bundled-catalogs` contract.
final class MilaLocalizationTests: XCTestCase {
    /// Messages whose catalog form carries a placeholder, with the bindings
    /// their call sites supply.
    private let templated: [MilaMessage: [String: String]] = [
        .confirmDelete: ["name": "build-01"],
        .signInConnectingHost: ["host": "overalls.example"],
    ]

    func testEverySupportedLocaleShipsANonEmptyCatalog() throws {
        for tag in MilaStrings.supportedLocales {
            let catalog = try XCTUnwrap(MilaStrings.catalog(tag), "\(tag) is not bundled")
            XCTAssertGreaterThan(catalog.count, 100, "\(tag) catalog is empty")
        }
    }

    func testEveryMessageResolvesThroughASharedCatalogIdentity() throws {
        let english = try XCTUnwrap(MilaStrings.catalog("en"))
        for message in MilaMessage.allCases {
            let id = try XCTUnwrap(MilaStrings.catalogID(message), "\(message) has no catalog id")
            XCTAssertNotNil(english[id], "\(message) maps to \(id), which is not in the shared catalog")
        }
    }

    func testEveryLocaleTranslatesEveryMessageWithoutEnglishFallback() throws {
        for tag in MilaStrings.supportedLocales {
            let catalog = try XCTUnwrap(MilaStrings.catalog(tag))
            let locale = Locale(identifier: tag)
            for message in MilaMessage.allCases {
                let id = try XCTUnwrap(MilaStrings.catalogID(message))
                let form = try XCTUnwrap(catalog[id], "\(tag) lacks \(id)")
                if let bindings = templated[message] {
                    let expected = bindings.reduce(form) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
                    XCTAssertEqual(MilaStrings.text(message, bindings, locale: locale), expected, "\(tag) \(id)")
                } else {
                    XCTAssertFalse(MilaStrings.hasPlaceholder(form), "\(id) needs bindings at its call site")
                    XCTAssertEqual(MilaStrings.text(message, locale: locale), form, "\(tag) \(id)")
                }
            }
        }
    }

    func testNonEnglishLocalesRenderTheirOwnCatalog() {
        XCTAssertEqual(MilaStrings.text(.machines, locale: Locale(identifier: "de_DE")), "Maschinen")
        XCTAssertEqual(MilaStrings.text(.actionStart, locale: Locale(identifier: "ja_JP")), "起動")
        XCTAssertEqual(MilaStrings.text(.machines, locale: Locale(identifier: "ar")), "الأجهزة")
        XCTAssertEqual(
            MilaStrings.text(.signInConnectingHost, ["host": "overalls.example"], locale: Locale(identifier: "de")),
            "Verbindung zu overalls.example wird hergestellt…"
        )
        XCTAssertNotEqual(MilaStrings.text(.machines, locale: Locale(identifier: "de")), MilaStrings.fallback(.machines))
    }

    func testDeviceLocalesExpandToBundledCatalogs() {
        XCTAssertEqual(MilaStrings.bundledLocale(for: Locale(identifier: "zh_CN")), "zh-Hans")
        XCTAssertEqual(MilaStrings.bundledLocale(for: Locale(identifier: "zh-Hans_CN")), "zh-Hans")
        XCTAssertEqual(MilaStrings.bundledLocale(for: Locale(identifier: "pt")), "pt-BR")
        XCTAssertEqual(MilaStrings.bundledLocale(for: Locale(identifier: "pt_PT")), "pt-PT")
        XCTAssertEqual(MilaStrings.bundledLocale(for: Locale(identifier: "de_AT")), "de")
        XCTAssertEqual(MilaStrings.bundledLocale(for: Locale(identifier: "en_GB")), "en")
        XCTAssertNil(MilaStrings.bundledLocale(for: Locale(identifier: "he_IL")))
        XCTAssertNil(MilaStrings.bundledLocale(for: Locale(identifier: "zh_TW")))
        XCTAssertEqual(MilaStrings.text(.machines, locale: Locale(identifier: "zh_CN")), "机器")
        XCTAssertEqual(MilaStrings.text(.machines, locale: Locale(identifier: "he_IL")), "Machines")
    }

    func testOverrideThenDeviceLanguageThenEnglish() {
        XCTAssertEqual(MilaStrings.activeLocale(override: "fr", preferredLanguages: ["de-DE"]), "fr")
        XCTAssertEqual(MilaStrings.activeLocale(override: "en", preferredLanguages: ["de-DE"]), "en")
        XCTAssertEqual(MilaStrings.activeLocale(override: "", preferredLanguages: ["he-IL", "de-DE"]), "de")
        XCTAssertEqual(MilaStrings.activeLocale(override: nil, preferredLanguages: ["ja-JP"]), "ja")
        // A malformed or unsupported stored override follows the device.
        XCTAssertEqual(MilaStrings.activeLocale(override: "xx-YY", preferredLanguages: ["ko-KR"]), "ko")
        XCTAssertEqual(MilaStrings.activeLocale(override: String(repeating: "x", count: 65), preferredLanguages: []), "en")
        XCTAssertEqual(MilaStrings.activeLocale(override: nil, preferredLanguages: ["he-IL"]), "en")
    }

    func testStoredOverrideDrivesDefaultResolution() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mila-localization-\(UUID().uuidString)"))
        defaults.set("sv", forKey: MilaStrings.localeOverrideKey)
        XCTAssertEqual(MilaStrings.activeLocale(defaults: defaults), "sv")
        defaults.removeObject(forKey: MilaStrings.localeOverrideKey)
        XCTAssertEqual(
            MilaStrings.activeLocale(defaults: defaults),
            MilaStrings.activeLocale(override: nil, preferredLanguages: Locale.preferredLanguages)
        )
    }

    func testRightToLeftCatalogsFollowTheRustDirectionPolicy() {
        XCTAssertTrue(MilaStrings.isRightToLeft("ar"))
        XCTAssertTrue(MilaStrings.isRightToLeft("arz"))
        XCTAssertTrue(MilaStrings.isRightToLeft("ur"))
        XCTAssertFalse(MilaStrings.isRightToLeft("de"))
        XCTAssertFalse(MilaStrings.isRightToLeft("he"))
    }
}
