import XCTest
@testable import Agrent

/// ChatKit is the conversation engine every chat surface shares
/// (agrent-ios#196, P4.7) — a FOLDER, by the owner's choice, not a framework
/// (2026-10-08). So the boundary is this test rather than the compiler:
/// nothing in ChatKit names Борса's own types or rules. A surface reaches
/// ChatKit; ChatKit never reaches a surface.
///
/// Source-reading, comments stripped — history may name Борса, code may not.
@MainActor
final class ChatKitBoundaryTests: XCTestCase {

    /// Борса's names: its models, its stores, its policy, its listing words.
    private let surfaceNames = ["Exchange", "MessagingPolicy", "ConversationAvailability",
                                "ConversationStore", "ListingThreadOpener", "CommodityName"]

    private func files(in folder: String) throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .map { ($0, SignOutHygieneTests.code(try String(contentsOf: root.appendingPathComponent($0),
                                                                encoding: .utf8))) }
    }

    func testChatKitNamesNothingOfTheExchange() throws {
        let chatKit = try files(in: "Agrent/ChatKit")
        XCTAssertGreaterThanOrEqual(chatKit.count, 10, "positive control: ChatKit's files were not found")
        var offenders: [String] = []
        for (name, code) in chatKit {
            for surface in surfaceNames where code.contains(surface) {
                offenders.append("\(name) names \(surface)")
            }
        }
        XCTAssertEqual(offenders, [], "ChatKit reaches into a surface")
    }

    /// Positive control: the probe does see Борса's names where they belong.
    func testTheProbeSeesTheExchangeInTheExchange() throws {
        let exchange = try files(in: "Agrent/Exchange")
        let seen = Set(exchange.flatMap { _, code in surfaceNames.filter { code.contains($0) } })
        XCTAssertTrue(seen.contains("Exchange"))
        XCTAssertTrue(seen.contains("MessagingPolicy"))
    }
}
