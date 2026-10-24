import XCTest

/// No read hangs on a view that can be nothing (#428).
///
/// `Group { if loaded { … } }.task { load() }` never loads. Before the
/// read the `Group` holds no view, and a modifier on no view never runs.
/// `UnfinishedTreatmentSection` (#326) had exactly this shape and never
/// showed; «Корекции» (#392) was written the same way and was caught under
/// the fixture seam. A source-reading test, as there is no runtime hook to
/// ask whether a `.task` ever started.
final class EmptyGroupTaskTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    /// A `Group {` whose whole content is one `if` with no `else`, followed
    /// by a `.task` or `.onAppear`. Line-based, for this repo's formatting:
    /// the brace that closes the Group sits at the Group's own indent.
    static func offenders(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var found: [String] = []
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "Group {" {
            let indent = line.prefix { $0 == " " }
            guard let close = lines[(i + 1)...].firstIndex(where: { $0 == indent + "}" }) else { continue }
            let body = lines[(i + 1)..<close]
            guard body.first?.trimmingCharacters(in: .whitespaces).hasPrefix("if ") == true,
                  !body.contains(where: { $0.hasPrefix(indent + "    } else") }),
                  // One `if` and nothing beside it: its own closing brace is
                  // the body's last line.
                  body.last == indent + "    }" else { continue }
            let modifiers = lines[(close + 1)...].prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".") }
            if modifiers.contains(where: { $0.contains(".task") || $0.contains(".onAppear") }) {
                found.append(body.first!.trimmingCharacters(in: .whitespaces))
            }
        }
        return found
    }

    func testNoReadHangsOnAGroupThatCanBeEmpty() throws {
        let app = Self.root.appendingPathComponent("Agrent")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(Self.offenders(in: text), [], url.lastPathComponent)
        }
        XCTAssertGreaterThan(files, 100, "positive control: the app's sources were found")
    }

    /// Positive control: #326's own shape is found, and a Group with an
    /// `else`, or with more beside the `if`, is not.
    func testTheCheckSeesTheShape() {
        let broken = """
                Group {
                    if let progress, !progress.complete {
                        unfinished(progress)
                    }
                }
                .task(id: handle) { await read() }
        """
        XCTAssertEqual(Self.offenders(in: broken), ["if let progress, !progress.complete {"])

        let withElse = """
                Group {
                    if let value {
                        Text(value)
                    } else {
                        ProgressView()
                    }
                }
                .task { await load() }
        """
        XCTAssertEqual(Self.offenders(in: withElse), [])
    }
}
