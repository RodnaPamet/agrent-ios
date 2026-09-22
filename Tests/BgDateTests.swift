import XCTest
@testable import Agrent

/// The phone this app is tested on reports `AppleLocale = en_BG` — English
/// language, Bulgarian region, an entirely ordinary thing for a person to
/// have set. On that device `Date.formatted` produced "11 September 2026"
/// while SwiftUI's `Text(date, format:)` two tabs away produced
/// "21 септември". Same app, same format style, two idioms, two languages.
final class BgDateTests: XCTestCase {

    private var september11: Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "Europe/Sofia"),
            year: 2026, month: 9, day: 11, hour: 12
        ).date!
    }

    /// The assertion that matters: Bulgarian regardless of what the process
    /// locale happens to be. Running under en_US on CI and bg_BG locally
    /// must give the same answer, which is the whole point of declaring it.
    func testMonthsAreBulgarianWhateverTheProcessLocaleIs() {
        XCTAssertTrue(BgDate.full(september11).contains("септември"),
                      BgDate.full(september11))
        XCTAssertTrue(BgDate.dayMonth(september11).contains("септември"),
                      BgDate.dayMonth(september11))
    }

    /// And specifically NOT the English the device would otherwise give.
    func testTheEnglishFormIsNotProduced() {
        for text in [BgDate.full(september11), BgDate.dayMonth(september11)] {
            XCTAssertFalse(text.contains("September"), text)
            XCTAssertFalse(text.contains("Sep"), text)
        }
    }

    /// `full` carries the year, `dayMonth` does not — rows do not need it
    /// and it costs width the chip beside them wants.
    func testOnlyTheFullFormCarriesTheYear() {
        XCTAssertTrue(BgDate.full(september11).contains("2026"))
        XCTAssertFalse(BgDate.dayMonth(september11).contains("2026"))
    }

    /// The defect this class exists for, stated as a comparison: the raw
    /// idiom and the declared one must not disagree. On a device set to
    /// en_BG the first of these is English.
    func testTheDeclaredFormDiffersFromTheDeviceDefaultUnderEnglishLocales() {
        let deviceStyle = september11.formatted(
            .dateTime.day().month(.wide).year().locale(Locale(identifier: "en_BG")))
        XCTAssertNotEqual(deviceStyle, BgDate.full(september11),
                          "if these are equal the test is no longer testing anything")
        XCTAssertTrue(deviceStyle.contains("September"))
    }
}

/// The task detail route returned a `createdBy.name` of
/// `v1:FTDt/A1v/6KngIxn762VOuI9kQdrKrz69Se6XnFAUBVSb0L/Nm8r` — an encryption
/// envelope, not a name. The screen rendered it under "Създадена от".
final class CipherEnvelopeTests: XCTestCase {
    typealias Assignee = WorkItemSummary.Assignee

    func testTheMeasuredCiphertextIsNotShown() {
        let a = Assignee(
            id: "u1",
            name: "v1:FTDt/A1v/6KngIxn762VOuI9kQdrKrz69Se6XnFAUBVSb0L/Nm8r",
            email: nil
        )
        XCTAssertNil(a.displayName, "54 characters of base64 reached the screen")
    }

    /// It falls through to the email rather than giving up, because an
    /// address is a worse name and still a real one.
    func testACiphertextNameFallsBackToTheEmail() {
        let a = Assignee(id: "u1", name: "v1:AAAA/BBBB", email: "ivan@example.invalid")
        XCTAssertEqual(a.displayName, "ivan@example.invalid")
    }

    /// Matched on the versioned envelope tag, not on "looks like base64" —
    /// a looser rule would eventually eat a real value.
    func testRealNamesAreNotMistakenForCiphertext() {
        for name in [
            "Иван Петров", "Svetoslav Radolovski", "v", "v1", "vera",
            "Vasil", ":", "x:y", "1v:abc", "V1:abc".lowercased() == "v1:abc" ? "Вера" : "Вера",
        ] {
            XCTAssertEqual(
                Assignee(id: "u", name: name, email: nil).displayName, name,
                "\(name) was rejected as ciphertext"
            )
        }
    }

    func testEnvelopeDetection() {
        XCTAssertTrue(Assignee.isCipherEnvelope("v1:abc"))
        XCTAssertTrue(Assignee.isCipherEnvelope("v2:abc"))
        XCTAssertTrue(Assignee.isCipherEnvelope("v10:abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope("v:abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope("va1:abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope(":abc"))
        XCTAssertFalse(Assignee.isCipherEnvelope("Иван Петров"))
    }
}
