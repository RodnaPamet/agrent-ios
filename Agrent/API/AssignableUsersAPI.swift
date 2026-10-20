import Foundation
import Observation

/// Who the open farm can give work to (agrent-ios#371, #372): its ACTIVE
/// members, as `GET /api/t/{slug}/users/assignable` lists them
/// (agri-saas `listAssignableUsers`, readable by every role). The route is
/// on the undocumented baseline, so the shape is read from that function:
/// `[{id, name, email, image}]`, oldest membership first. An operator
/// (MECHANISATOR) is refused it by the operator lockdown; the forms that
/// read it aren't offered to that role, and a refusal leaves only "me".
///
/// ── Never on disk ──
///
/// Every row carries a colleague's email address. So this is read from the
/// network each time a form opens and kept in memory with the form, never
/// through `ResponseCache`, as the admin and messaging reads are.
enum AssignableUsersAPI {
    static var path: String { "\(FarmPath.root)/users/assignable" }

    struct Person: Decodable, Identifiable, Equatable, Hashable, Sendable {
        let id: String
        let name: String?
        let email: String?

        /// The name as the person spelled it, or the address when they set
        /// none: a picker row has to say who it is.
        var displayName: String {
            if let name = name?.recorded { return name }
            if let email = email?.recorded { return email }
            return "Член без име"
        }
    }

    /// A row that can't be read is left out rather than failing the list:
    /// one malformed member must not leave the form without anyone to pick.
    static func decode(from data: Data) throws -> [Person] {
        struct Lossy: Decodable {
            let person: Person?
            init(from decoder: any Decoder) throws { person = try? Person(from: decoder) }
        }
        return try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.person)
    }

    static func load() async throws -> [Person] {
        try decode(from: try await APIClient.shared.data(for: path))
    }
}

/// The list for one open form, read when the form opens.
@Observable
@MainActor
final class AssignableUsersStore {
    private(set) var state: LoadState<[AssignableUsersAPI.Person]> = .loading

    private let fetch: @MainActor () async throws -> [AssignableUsersAPI.Person]

    init(fetch: @escaping @MainActor () async throws -> [AssignableUsersAPI.Person] = {
        try await AssignableUsersAPI.load()
    }) {
        self.fetch = fetch
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await fetch(), .fresh)
        } catch {
            state = .failed(UserMessage.text(for: error))
        }
    }

    /// The people a picker offers, `me` first and named as such. `me` is
    /// added when the list doesn't have them (it failed, or hasn't come),
    /// so the form can always assign the person filling it.
    static func choices(_ people: [AssignableUsersAPI.Person]?, me: CurrentUser?) -> [Choice] {
        var rows: [Choice] = []
        if let me {
            let fromList = people?.first { $0.id == me.id }
            let name = fromList?.displayName ?? me.name?.recorded ?? me.email?.recorded ?? "Вие"
            rows.append(Choice(id: me.id, label: name == "Вие" ? name : "\(name) (Вие)"))
        }
        for person in people ?? [] where person.id != me?.id {
            rows.append(Choice(id: person.id, label: person.displayName))
        }
        return rows
    }

    struct Choice: Identifiable, Equatable, Hashable, Sendable {
        let id: String
        let label: String
    }
}
