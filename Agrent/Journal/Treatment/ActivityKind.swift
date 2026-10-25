import Foundation

/// Work on parcels that applies nothing (#439; agri-saas #2339, #2344;
/// owner 2026-10-25): recorded in «Нов запис» beside the treatments, so it
/// prints in the farm's diary (#436).
///
/// Not sowing: a sowing applies a seed product at a rate, so it isn't bare
/// work (owner with backend 1, 2026-10-25). The activities route takes these
/// three only, as the server's `BARE_ACTIVITY_KINDS` does.
enum ActivityKind: String, CaseIterable, Identifiable, Sendable {
    case prune = "PRUNE"
    case cultivate = "CULTIVATE"
    case harvest = "HARVEST"

    var id: String { rawValue }

    /// `ACTIVITY_LABELS_BG` (agri-saas `src/lib/operations/activity-labels.ts`),
    /// word for word, so the phone and the diary name the work alike.
    /// «Обработка на почвата» in full, never «Обработка»: in the БАБХ register
    /// that word alone is a chemical treatment.
    var label: String {
        switch self {
        case .prune: "Резитба"
        case .cultivate: "Обработка на почвата"
        case .harvest: "Прибиране на реколтата"
        }
    }
}

/// «Вид» on «Нов запис»: a treatment, or other work.
enum EntryKind: Hashable, Sendable, Identifiable {
    case treatment(TreatmentDraft.Kind)
    case activity(ActivityKind)

    static let all: [EntryKind] =
        TreatmentDraft.Kind.allCases.map(EntryKind.treatment) + ActivityKind.allCases.map(EntryKind.activity)

    var id: String {
        switch self {
        case .treatment(let kind): kind.rawValue
        case .activity(let kind): kind.rawValue
        }
    }

    var label: String {
        switch self {
        case .treatment(let kind): kind.label
        case .activity(let kind): kind.label
        }
    }
}
