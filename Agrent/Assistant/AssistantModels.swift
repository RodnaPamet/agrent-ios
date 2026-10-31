import Foundation

/// The assistant's wire (#483, agri-saas #2578, phase 1: answers only).
///
/// ── One question, one turn ──
///
/// `POST /assistant/stream` takes `{ question, pageContext? }` and answers
/// with server-sent events. Nothing of an earlier turn is sent back: history
/// would be one more customer-written field reaching the prompt, and spend on
/// every turn (backend 2, 2026-10-31). The sheet keeps the session's turns on
/// screen only.
struct AssistantRequest: Encodable, Sendable {
    let question: String
    let pageContext: AssistantPageContext?
}

/// What the person is looking at, as IDENTIFIERS only: the web PAGE
/// TEMPLATE the screen corresponds to, brackets intact
/// (`/t/[tenantSlug]/journal`), never a concrete URL — so no slug and no
/// record id ride in it (agri-saas #2591 checks it against a generated set
/// of page templates). Never a title, a label, or anything typed, a search
/// term included — the server reads this into the prompt, so it is an
/// injection surface, and it answers 400 to a field it does not know.
struct AssistantPageContext: Encodable, Equatable, Sendable {
    let route: String
    var selectedIds: [String]? = nil

    /// A bar or menu surface: its web page's template.
    static func surface(_ surface: AppSurface) -> AssistantPageContext {
        AssistantPageContext(route: template(surface))
    }

    /// `AppSurface` is the web page without its farm; the template puts the
    /// farm back as the template's own placeholder.
    static func template(_ surface: AppSurface) -> String {
        "/t/[tenantSlug]\(surface.rawValue)"
    }
}

/// One event of a turn. The payload's own `type` names it; there is no
/// `event:` field to subscribe to, so a type this build does not know
/// decodes as `.unknown` and is ignored — an older phone keeps working
/// against a newer server.
///
/// There is no `error` event, by design: every end is `refusal`, `halt` or
/// `done`. A connection that closes without one of those is a transport
/// failure and nothing else.
enum AssistantEvent: Decodable, Equatable, Sendable {
    case thinking
    case toolCall(name: String)
    case toolResult(name: String, ok: Bool, truncated: Bool)
    case answer(text: String, links: [AssistantLink], proposal: AssistantProposal?)
    /// Refused by a guard after the stream opened: the reason is a CODE.
    case refusal(reason: String)
    /// A bound was reached: what came before is real but incomplete.
    case halt(outcome: String, counts: [String: Int])
    case done(truncatedAny: Bool)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, name, ok, truncated, text, links, proposal, reason, outcome, truncatedAny
        case toolCalls, limit, elapsedMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "thinking":
            self = .thinking
        case "tool_call":
            self = .toolCall(name: (try? c.decode(String.self, forKey: .name)) ?? "")
        case "tool_result":
            self = .toolResult(name: (try? c.decode(String.self, forKey: .name)) ?? "",
                               ok: (try? c.decode(Bool.self, forKey: .ok)) ?? false,
                               truncated: (try? c.decode(Bool.self, forKey: .truncated)) ?? false)
        case "answer":
            self = .answer(text: try c.decode(String.self, forKey: .text),
                           links: (try? c.decodeIfPresent([AssistantLink].self, forKey: .links)) ?? [],
                           proposal: try? c.decodeIfPresent(AssistantProposal.self, forKey: .proposal))
        case "refusal":
            self = .refusal(reason: (try? c.decode(String.self, forKey: .reason)) ?? "")
        case "halt":
            var counts: [String: Int] = [:]
            for key in [CodingKeys.toolCalls, .limit, .elapsedMs] {
                if let value = try? c.decode(Int.self, forKey: key) { counts[key.stringValue] = value }
            }
            self = .halt(outcome: (try? c.decode(String.self, forKey: .outcome)) ?? "", counts: counts)
        case "done":
            self = .done(truncatedAny: (try? c.decode(Bool.self, forKey: .truncatedAny)) ?? false)
        default:
            self = .unknown(type: type)
        }
    }

    /// Whether the turn is over once this arrives.
    var ends: Bool {
        switch self {
        case .refusal, .halt, .done: true
        default: false
        }
    }
}

/// A screen the answer points at: a web page route the server checked
/// against its page table before sending (a link to nothing is dropped
/// there), and the Bulgarian words for it. Links are a field, never Markdown
/// in the answer's text (agri-saas #2578).
struct AssistantLink: Decodable, Equatable, Sendable, Hashable {
    let route: String
    let label: String

    /// The route without a leading `/t/<farm>`, which a link may or may not
    /// carry: the farm is the one open either way.
    var page: String {
        let parts = route.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "t" else { return route }
        return "/" + parts.dropFirst(3).joined(separator: "/")
    }

    /// The bar tab the route is, when it is one.
    var surface: AppSurface? { AppSurface(rawValue: page) }

    /// The one thing the route names — `/farm-tasks/{id}`, `/locations/{id}`,
    /// with the REAL id, which the server sends only for a record the turn
    /// read — as a notification's link names it (`PushLink`), in the farm
    /// the person has open.
    func screen(inFarm farm: String?) -> AppRoute? {
        guard let farm, !farm.isEmpty else { return nil }
        return PushLink.parse("/t/\(URLEscape.segment(farm))\(page)").map(AppRoute.init)
    }
}

/// Phase 2's prepared change (owner, 2026-10-31: the usual form opens
/// filled and the person taps «Запиши»). Decoded so a phase-2 server does
/// not fail a phase-1 phone; nothing here acts on it yet.
struct AssistantProposal: Decodable, Equatable, Sendable {
    let kind: String
    let status: String?
}
