import XCTest
@testable import Agrent

/// Who a farm's work can be given to (#371): the server's list, read
/// leniently, and the picker's rows. Synthetic people throughout.
@MainActor
final class AssignableUsersTests: XCTestCase {
    private func me(_ id: String = "u-me", name: String? = "Тестов Стопанин") throws -> CurrentUser {
        CurrentUser(id: id, name: name, email: "me@example.invalid", role: "OWNER")
    }

    private let people = [
        AssignableUsersAPI.Person(id: "u-me", name: "Тестов Стопанин", email: "me@example.invalid"),
        AssignableUsersAPI.Person(id: "u-op", name: "Оператор Едно", email: "op@example.invalid"),
        AssignableUsersAPI.Person(id: "u-nameless", name: "  ", email: "nameless@example.invalid"),
    ]

    /// `listAssignableUsers`'s shape. One row that can't be read is left
    /// out, never the whole list.
    func testTheListIsReadLeniently() throws {
        let data = Data(#"""
            [{"id":"u-1","name":"Оператор Едно","email":"op@example.invalid","image":null},
             {"name":"no id"},
             {"id":"u-2","name":null,"email":null}]
            """#.utf8)
        let read = try AssignableUsersAPI.decode(from: data)
        XCTAssertEqual(read.map(\.id), ["u-1", "u-2"])
        XCTAssertEqual(AssignableUsersAPI.path, "\(FarmPath.root)/users/assignable")
    }

    /// A row says who it is: the name, the address when there's none.
    func testAPersonIsNamedOrAddressed() {
        XCTAssertEqual(people[1].displayName, "Оператор Едно")
        XCTAssertEqual(people[2].displayName, "nameless@example.invalid", "a blank name is no name")
        XCTAssertEqual(AssignableUsersAPI.Person(id: "x", name: nil, email: nil).displayName, "Член без име")
    }

    /// The person filling the form first, named as such, and only once;
    /// the rest in the server's order.
    func testThePickerPutsMeFirstOnce() throws {
        let rows = AssignableUsersStore.choices(people, me: try me())
        XCTAssertEqual(rows.map(\.id), ["u-me", "u-op", "u-nameless"])
        XCTAssertEqual(rows[0].label, "Тестов Стопанин (Вие)")
    }

    /// The list failed or hasn't come: the form can still assign the
    /// person filling it, which is what it did before the row existed.
    func testWithNoListThePickerStillHasMe() throws {
        XCTAssertEqual(AssignableUsersStore.choices(nil, me: try me()).map(\.id), ["u-me"])
        XCTAssertEqual(AssignableUsersStore.choices(nil, me: try me(name: nil)).first?.label,
                       "me@example.invalid (Вие)")
        XCTAssertEqual(AssignableUsersStore.choices(people, me: nil).map(\.id), ["u-me", "u-op", "u-nameless"],
                       "without /me, nobody is marked")
    }

    func testAFailedReadIsAFailureTheFormSurvives() async {
        let store = AssignableUsersStore { throw URLError(.notConnectedToInternet) }
        await store.load()
        guard case .failed = store.state else { return XCTFail("\(store.state)") }
        XCTAssertNil(store.state.value)
    }
}
