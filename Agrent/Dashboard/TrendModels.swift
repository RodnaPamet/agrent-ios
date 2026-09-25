import Foundation

// MARK: - GET /dashboard/trends

/// Metric history, with the range the server could actually answer for.
///
/// ── `daysAvailable` can be SMALLER than `daysRequested` ──
///
/// A young tenant has fewer days of history than the screen asked for, and the
/// server says what to do about it: *"Plot the range you were given, not the
/// one you requested: a chart that pads the difference with zeroes shows a
/// collapse that never happened."*
///
/// So nothing here pads, and `isPartial` exists so a view can SAY the range is
/// short rather than drawing it as if it were not. A farm three weeks old
/// asking for ninety days would otherwise get a chart that looks like sixty-
/// nine days of nothing followed by a farm — which is the same defect as a
/// capped list that looks like a complete one.
struct TrendPayload: Decodable, Equatable, Sendable {
    let dataPoints: [TrendDataPoint]
    let daysRequested: Int
    let daysAvailable: Int

    /// No `format` declared on either, so parsed rather than decoded.
    let rangeStartRaw: String
    let rangeEndRaw: String

    var rangeStart: Date? { BgDate.parseInstantOrDay(rangeStartRaw) }
    var rangeEnd: Date? { BgDate.parseInstantOrDay(rangeEndRaw) }

    enum CodingKeys: String, CodingKey {
        case dataPoints, daysRequested, daysAvailable
        case rangeStartRaw = "rangeStart"
        case rangeEndRaw = "rangeEnd"
    }

    /// The server had less history than was asked for. Not an error, and not
    /// something to hide: it is the difference between "nothing happened" and
    /// "we were not here yet".
    var isPartial: Bool { daysAvailable < daysRequested }
}

/// One day of counts.
///
/// TEN required integers and not one of them nullable, which is unusual in
/// this API and is the reason this type has no leniency in it: a missing
/// counter here would be a genuine server defect rather than an absent
/// relation, and swallowing it would draw a zero that is a lie about the day.
struct TrendDataPoint: Decodable, Equatable, Identifiable, Sendable {
    let dateRaw: String

    let evidenceOverdue: Int
    let evidenceDueSoon7d: Int
    let evidenceCurrent: Int
    let tasksOpen: Int
    let tasksOverdue: Int
    let assetsTotal: Int
    let assetsActive: Int
    let assetsHighCriticality: Int
    let assetsRetired: Int

    var date: Date? { BgDate.parseInstantOrDay(dateRaw) }

    /// The raw string, which is stable and unique per point, so a chart's
    /// `ForEach` does not depend on a parse succeeding.
    var id: String { dateRaw }

    enum CodingKeys: String, CodingKey {
        case dateRaw = "date"
        case evidenceOverdue, evidenceDueSoon7d, evidenceCurrent
        case tasksOpen, tasksOverdue
        case assetsTotal, assetsActive, assetsHighCriticality, assetsRetired
    }
}

// MARK: - GET /dashboard/task-trend

/// A DIFFERENT ENVELOPE FROM ITS SIBLING, and deliberately not unified.
///
/// `/dashboard/trends` answers with `TrendPayload` — data points plus range
/// metadata. `/dashboard/task-trend` answers with a bare `{ trend: [...] }`:
/// no range, no `daysAvailable`, no `daysRequested`. Two sibling endpoints
/// under one prefix, two shapes.
///
/// Documented rather than discovered, which is the whole difference. A client
/// that assumed the sibling's envelope would have decoded nothing and had no
/// idea why. Wrapping both in one generic to make them look alike would put
/// the surprise back — the asymmetry is the fact worth keeping visible.
struct FarmTaskTrend: Decodable, Equatable, Sendable {
    let trend: [FarmTaskTrendPoint]
}

struct FarmTaskTrendPoint: Decodable, Equatable, Identifiable, Sendable {
    let dateRaw: String
    let created: Int
    let completed: Int

    var date: Date? { BgDate.parseInstantOrDay(dateRaw) }
    var id: String { dateRaw }

    enum CodingKeys: String, CodingKey {
        case dateRaw = "date"
        case created, completed
    }
}

// MARK: - GET /reports/field-briefing

/// The briefing, and — when there is none — WHY there is none.
///
/// ── Three booleans, three different sentences ──
///
/// `briefing: null` alone says nothing a farmer can act on. The server carries
/// three flags precisely so a client can name the cause instead of drawing an
/// empty card:
///
///     aiConfigured        false → this deployment has no model
///     satelliteConfigured false → no Earth Engine credentials
///     satelliteAvailable  false → configured, but the imagery call did not return
///
/// The first two are somebody else's job to fix and the third may fix itself,
/// which is the difference that matters to the person holding the phone. So
/// `absence` resolves them in that order and a view must not collapse them
/// into one empty state.
struct FieldBriefingPayload: Decodable, Equatable, Sendable {
    let aiConfigured: Bool
    let satelliteConfigured: Bool
    let satelliteAvailable: Bool
    let fieldCount: Int

    /// OPTIONAL. `FieldBriefing` is `{type: ["object","null"]}` in its own
    /// schema, so a `$ref` to it admits null even though `briefing` is in
    /// `required` — see `DashboardModels`, where I got this wrong once.
    let briefing: FieldBriefing?

    let generatedAtRaw: String
    let dateRaw: String

    var generatedAt: Date? { BgDate.parseInstantOrDay(generatedAtRaw) }
    var date: Date? { BgDate.parseInstantOrDay(dateRaw) }

    enum CodingKeys: String, CodingKey {
        case aiConfigured, satelliteConfigured, satelliteAvailable, fieldCount, briefing
        case generatedAtRaw = "generatedAt"
        case dateRaw = "date"
    }

    /// Why there is no briefing, or nil because there is one.
    ///
    /// Resolved in the order a farmer can act on: the two configuration
    /// causes are permanent until somebody changes the deployment, the
    /// imagery one is transient and worth retrying.
    enum Absence: Equatable, Sendable {
        case noModel
        case noSatelliteCredentials
        case imageryUnavailable
        /// Configured, available, and still nothing — nothing in the three
        /// flags explains it, and saying so is better than blaming a cause
        /// that is not there.
        case unexplained
    }

    var absence: Absence? {
        guard briefing == nil else { return nil }
        if !aiConfigured { return .noModel }
        if !satelliteConfigured { return .noSatelliteCredentials }
        if !satelliteAvailable { return .imageryUnavailable }
        return .unexplained
    }
}

struct FieldBriefing: Decodable, Equatable, Sendable {
    let headline: String
    let summary: String
    let actions: [BriefingAction]
}

/// One thing the briefing suggests doing.
///
/// `field` is NULL for an action that applies to the whole farm — the server
/// says so, and that is a meaning rather than a gap. A row must not print a
/// placeholder for it; "no field" IS the scope.
struct BriefingAction: Decodable, Equatable, Identifiable, Sendable {
    /// Nil means the whole farm. Also `.recorded`, because a field name read
    /// off an optional relation is the collapse that has caught this repo
    /// three times, and `null` and `""` would mean the same thing here.
    var field: String? { fieldRaw?.recorded }
    private let fieldRaw: String?

    let action: String
    let priority: Priority

    /// Actions have no id on the wire. The text is what distinguishes them on
    /// screen, so it is what `ForEach` keys on — and two identical actions on
    /// the same field would be the same row anyway.
    var id: String { "\(fieldRaw ?? "")|\(action)" }

    enum CodingKeys: String, CodingKey {
        case fieldRaw = "field"
        case action, priority
    }

    /// PINNED by the spec as three lowercase values. Lenient anyway, because
    /// an unknown priority must not fail a briefing — an action a farmer can
    /// read without a severity beats no briefing at all.
    enum Priority: String, LenientDecodable, Sendable {
        case high, medium, low
        case unknown = "UNKNOWN"

        static var unknownCase: Self { .unknown }

        /// Ordered so a sort puts what matters first. `unknown` sorts LAST
        /// rather than first: an unrecognised value is not evidence of
        /// urgency, and putting it at the top would let a future value shout.
        var rank: Int {
            switch self {
            case .high: 0
            case .medium: 1
            case .low: 2
            case .unknown: 3
            }
        }

        var label: String {
            switch self {
            case .high: "Спешно"
            case .medium: "Средно"
            case .low: "Ниско"
            case .unknown: "—"
            }
        }
    }
}
