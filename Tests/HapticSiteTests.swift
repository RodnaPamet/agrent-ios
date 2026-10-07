import SwiftUI
import XCTest
@testable import Agrent

/// The haptic vocabulary and where it is played (agri-saas#1193 P2.8).
///
/// Two halves. `WriteFeedback` itself is a value and is tested as one. Where
/// it fires is a property of the source — "this outcome is recorded inside
/// `send()` and inside nothing a poll runs" — and there is no runtime hook
/// that could observe a haptic, so that half reads the files, each probe with
/// a positive control so a moved file fails rather than passes.
final class WriteFeedbackTests: XCTestCase {

    func testNothingIsPlayedBeforeTheFirstOutcome() {
        XCTAssertNil(WriteFeedback().feedback)
    }

    func testTheVocabularyIsSuccessAndWarning() {
        var saved = WriteFeedback()
        saved.saved()
        XCTAssertEqual(saved.feedback, .success)

        var refused = WriteFeedback()
        refused.refused()
        XCTAssertEqual(refused.feedback, .warning)
    }

    /// `.sensoryFeedback` fires on a CHANGE of its trigger. Two saves in a
    /// row must compare unequal, or the second one is silent.
    func testASecondSaveIsAChange() {
        var feedback = WriteFeedback()
        feedback.saved()
        let first = feedback
        feedback.saved()
        XCTAssertNotEqual(first, feedback)
        XCTAssertEqual(feedback.feedback, .success)
    }

    func testARetryAfterARefusalIsAChange() {
        var feedback = WriteFeedback()
        feedback.refused()
        let first = feedback
        feedback.refused()
        XCTAssertNotEqual(first, feedback)
        feedback.saved()
        XCTAssertEqual(feedback.feedback, .success)
    }
}

/// The farm profile's success, run for real: `AdminStore` takes its network
/// as closures, so a save and a reload can be driven with nothing sent.
@MainActor
final class ProfileSaveFeedbackTests: XCTestCase {

    private func profile(version: Int) -> FarmProfile {
        FarmProfile(producerName: "Иван Петров", eik: nil, egn: nil,
                    address: nil, settlement: nil, municipality: nil,
                    registrationPlace: nil, registrationEkatte: nil,
                    odbhCity: nil, agricultureDirectorateCity: nil,
                    urn: nil, sizeHa: nil, grainProduced: [],
                    version: version)
    }

    private func update(over original: FarmProfile) throws -> (FarmProfileUpdate, FarmProfileDraft) {
        var draft = FarmProfileDraft(original)
        draft[.urn] = "1234567"
        return (try FarmProfileUpdate.build(original: original, draft: draft).get(), draft)
    }

    func testALandedSaveIsASuccess() async throws {
        let stored = profile(version: 2)
        let store = AdminStore(sendProfile: { _ in stored }, fetchProfile: { stored })
        let (body, draft) = try update(over: profile(version: 1))
        try await store.saveProfile(body, typed: draft)
        XCTAssertEqual(store.profileSaveFeedback.feedback, .success)
        XCTAssertEqual(store.profileSaveFeedback.count, 1)
    }

    /// A 409 is played by the editor, which stays open — not by the page
    /// under it, which would then say "saved" with a buzz.
    func testARefusedSavePlaysNothingOnThePage() async throws {
        let store = AdminStore(
            sendProfile: { _ in
                throw APIClient.APIError.conflict(currentVersion: 2, expectedVersion: 1)
            },
            fetchProfile: { throw URLError(.notConnectedToInternet) })
        let (body, draft) = try update(over: profile(version: 1))
        do {
            try await store.saveProfile(body, typed: draft)
            XCTFail("a 409 must throw to the sheet")
        } catch {}
        XCTAssertNil(store.profileSaveFeedback.feedback)
    }

    /// The reload after a 409 is the app reading, not the person writing.
    func testTheReloadPlaysNothing() async throws {
        let fresh = profile(version: 3)
        let store = AdminStore(sendProfile: { _ in fresh }, fetchProfile: { fresh })
        _ = try await store.reloadProfile()
        XCTAssertEqual(store.profileSaveFeedback, WriteFeedback())
    }
}

final class HapticSiteTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file in the app target, as (path relative to the repo, text).
    private func appSources() throws -> [(String, String)] {
        let app = Self.root.appendingPathComponent("Agrent")
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = String(url.standardizedFileURL.path
                .dropFirst(Self.root.standardizedFileURL.path.count + 1))
            out.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The declaration — `func name` or `var body` — that encloses `index`.
    /// Good enough for these files: the probes sit in methods and in `body`.
    private func enclosingDeclaration(of index: String.Index, in text: String) -> String? {
        let before = String(text[..<index])
        let regex = try! NSRegularExpression(pattern: #"(func \w+|var body)"#)
        let range = NSRange(before.startIndex..., in: before)
        guard let last = regex.matches(in: before, range: range).last,
              let found = Range(last.range, in: before) else { return nil }
        return String(before[found]).replacingOccurrences(of: "func ", with: "")
    }

    /// The body of every `func name(` in `text` — brace-matched from its
    /// first `{`. Every one, because a file can hold two stores with a
    /// `refresh` each, and both are read paths.
    private func bodies(of name: String, in text: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while let start = text.range(of: "func \(name)(", range: cursor..<text.endIndex),
              let open = text[start.upperBound...].firstIndex(of: "{") {
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            out.append(String(text[open...index]))
            cursor = text.index(after: index)
        }
        return out
    }

    // MARK: - One mechanism

    /// `.sensoryFeedback` is called in ONE place, behind the vocabulary, and
    /// no UIKit generator is created anywhere — a generator in a view is a
    /// haptic nobody listed.
    func testTheOnlySensoryFeedbackIsTheVocabulary() throws {
        let sources = try appSources()
        XCTAssertGreaterThan(sources.count, 100, "positive control: the app's sources were found")
        for (path, text) in sources {
            let expected = path == "Agrent/Design/Haptics.swift" ? 1 : 0
            XCTAssertEqual(count("sensoryFeedback(", in: text), expected,
                           "\(path) plays a haptic outside `writeFeedback`")
            for generator in ["UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator",
                              "UISelectionFeedbackGenerator", "UIFeedbackGenerator",
                              "AudioServicesPlaySystemSound"] {
                XCTAssertFalse(text.contains(generator), "\(path) uses \(generator)")
            }
        }
    }

    // MARK: - The exact sites

    /// Where the modifier is applied. A new site fails here until it is
    /// listed — with its reason in `WriteFeedback`'s doc comment.
    func testTheModifierSitsOnExactlyTheseScreens() throws {
        let expected: [String: Int] = [
            "Agrent/Locations/ParcelMapView.swift": 1,        // operation saved / kept
            "Agrent/Locations/ParcelOperationSheet.swift": 1, // operation refused
            "Agrent/Tasks/TaskDetailView.swift": 1,           // status changed / refused
            "Agrent/Exchange/ConversationView.swift": 1,      // message sent / refused
            "Agrent/Admin/FarmProfileView.swift": 2,          // page: saved; editor: refused
            "Agrent/Tasks/FieldOperationSection.swift": 1,    // parcel line marked / refused (#138)
        ]
        var found: [String: Int] = [:]
        for (path, text) in try appSources() {
            let n = count(".writeFeedback(", in: text)
            if n > 0 { found[path] = n }
        }
        XCTAssertEqual(found, expected)
    }

    /// Where an outcome is RECORDED, by the declaration around it. This is
    /// the list of user actions that can buzz: each is a tap's own code
    /// path, and `body` in `ParcelMapView` is the sheet's `onSaved`.
    func testOutcomesAreRecordedOnlyInTheseActions() throws {
        let expected: Set<String> = [
            "Agrent/Locations/ParcelMapView.swift var body saved",
            "Agrent/Locations/ParcelOperationSheet.swift save refused",
            "Agrent/Locations/ParcelOperationSheet.swift queueForLater refused",
            "Agrent/Tasks/TasksStore.swift setStatus saved",
            "Agrent/Tasks/TasksStore.swift setStatus refused",
            "Agrent/Exchange/MessagingStores.swift send saved",
            "Agrent/Exchange/MessagingStores.swift send refused",
            "Agrent/Admin/AdminStore.swift saveProfile saved",
            "Agrent/Admin/FarmProfileView.swift submit refused",
            // #138: a «Готово» that landed or was kept on the phone; a
            // refusal or a conflict on the tap. Never from the drain.
            "Agrent/Tasks/FieldOperationStore.swift mark saved",
            "Agrent/Tasks/FieldOperationStore.swift mark refused",
        ]
        let regex = try NSRegularExpression(pattern: #"\w+\.(saved|refused)\(\)"#)
        var found: Set<String> = []
        for (path, text) in try appSources() {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let whole = Range(match.range, in: text),
                      let kind = Range(match.range(at: 1), in: text) else { continue }
                let decl = enclosingDeclaration(of: whole.lowerBound, in: text) ?? "?"
                found.insert("\(path) \(decl) \(text[kind])")
            }
        }
        XCTAssertEqual(found, expected)
    }

    // MARK: - Never from the app's own work

    /// THE REGRESSION THIS FEATURE INVITES: a poll or a refresh that records
    /// an outcome buzzes a phone in a pocket. Each read path below — and the
    /// whole outbox, whose drain runs on reconnect — mentions no feedback.
    func testNoPollRefreshOrDrainRecordsAnOutcome() throws {
        let readPaths: [(String, [String])] = [
            ("Agrent/Exchange/MessagingStores.swift", ["run", "load", "refresh", "markRead", "loadOlder"]),
            ("Agrent/Tasks/TasksStore.swift", ["load"]),
            ("Agrent/Admin/AdminStore.swift", ["load", "loadMembers", "loadProfile", "reloadProfile"]),
            ("Agrent/Admin/FarmProfileView.swift", ["reloadAfterConflict"]),
            ("Agrent/Core/OutboxStore.swift", ["refresh", "enqueue", "flush", "drain", "post"]),
            // #138: the lines' reads, including the re-read the outbox
            // triggers when the drain sends or parks a mark — a phone that
            // buzzed for that would be buzzing for the app's own work.
            ("Agrent/Tasks/FieldOperationStore.swift",
             ["load", "loadAfterWrite", "adopt", "disownReads", "fetchCacheFirst"]),
        ]
        for (path, functions) in readPaths {
            let text = try source(path)
            for name in functions {
                let found = bodies(of: name, in: text)
                XCTAssertFalse(found.isEmpty, "\(path): func \(name) moved — this test no longer reads it")
                for body in found {
                    XCTAssertFalse(body.contains("Feedback"), "\(path): \(name) records a haptic outcome")
                }
            }
        }
        // Whole files that are only the app's own work, or the person's tap
        // on a batch whose result the banner states row by row.
        for path in ["Agrent/Core/OutboxStore.swift", "Agrent/Core/OutboxBanner.swift",
                     "Agrent/Core/PullToRefresh.swift", "Agrent/Core/CachedResource.swift",
                     "Agrent/Core/OfflinePrefetch.swift"] {
            XCTAssertFalse(try source(path).contains("Feedback"), "\(path) plays a haptic")
        }
    }

    /// Positive control for the extractor: it does see the feedback in the
    /// write paths, so the absences above are real absences.
    func testTheExtractorSeesTheWritePaths() throws {
        let messaging = try source("Agrent/Exchange/MessagingStores.swift")
        XCTAssertTrue(bodies(of: "send", in: messaging).contains { $0.contains("sendFeedback.saved()") })
        let tasks = try source("Agrent/Tasks/TasksStore.swift")
        XCTAssertTrue(bodies(of: "setStatus", in: tasks).contains { $0.contains("writeFeedback.refused()") })
        // Two `refresh`es in one file are both read: the inbox's and the
        // conversation's.
        XCTAssertEqual(bodies(of: "refresh", in: messaging).count, 2)
        let outbox = try source("Agrent/Core/OutboxStore.swift")
        XCTAssertEqual(bodies(of: "drain", in: outbox).count, 1)
    }
}
