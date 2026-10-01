import Foundation

// The farm profile's WRITE path, as pure values so every rule in it is a unit
// test rather than a screenshot.
//
// ── PORTED, NOT DESIGNED ──
//
// The plan is agri-saas's: #1141 built the web editor
// (`src/app/t/[tenantSlug]/(app)/admin/farm-profile/page.tsx`) and the
// usecase (`src/app-layer/usecases/farm-profile.ts`), and #1145 documented the
// route (`PUT /admin/farm-profile`, `updateFarmProfile` in openapi.json) with
// the three things a client gets wrong: a blank CLEARS, send the whole object,
// and the response can legitimately differ from the request. Labels, hints,
// field order, the comma-accepting size input and the save message are the
// web's, verbatim. What is iOS-only is named where it happens.
//
// ── WHAT THE SERVER REALLY DOES, read from the code, not the summary ──
//
//   OMITTED CLEARS TOO (agri-saas#1176, open). The schema says "every field
//   is optional", which reads like PATCH. It is not: the usecase maps EVERY
//   field through `norm(input[k])`, `norm(undefined)` is null, and an absent
//   `grainProduced` becomes `[]`. A body that left out `egn` would erase the
//   farm's ЕГН. So the body below always carries all thirteen keys, with
//   explicit nulls — Swift's synthesised `Encodable` OMITS nil optionals,
//   which would have been the same erase by another route. Never a per-field
//   PUT.
//
//   THE REQUEST IS MODELLED FROM THE ROUTE'S ZOD SCHEMA: on agri-saas main
//   `components.schemas.UpdateFarmProfileRequest` is a stub with zero
//   properties (also #1176). The limits below are `UpdateFarmProfileSchema`
//   in `admin/farm-profile/route.ts`. agri-saas#1178 (unmerged at the time
//   of writing) documents it: THIRTEEN properties, NONE required — and its
//   own description says "absent is not leave alone". Checked 2026-10-01
//   against #1178's head: its thirteen are exactly `FarmProfileText`'s
//   eleven plus `sizeHa` and `grainProduced`. "None required" does NOT
//   permit a subset.
//
//   A NEGATIVE SIZE IS A 400, not a stored null. The usecase does refuse a
//   negative as null, but zod's `.nonnegative()` in the route rejects it
//   first, so that branch is unreachable over HTTP. The client refuses it
//   before sending; the response diff still reports a size the server
//   dropped, in case the two ever drift.
//
//   NO VERSION, NO ETag, NO If-Match, no `updatedAt` on the wire. Last
//   writer wins on the WHOLE record: two admins editing at once lose one
//   edit silently. A known limit, recorded on #1176 — not papered over with
//   a client-side lock, which would only narrow the window and read as
//   protection that is not there.
//
//   SAFE TO RETRY. A PUT of the whole object is idempotent by construction —
//   a replay stores the same row (and writes one more audit line). So a
//   timeout offers «Запази» again rather than the unknown-outcome warning
//   the member writes need.

/// The eleven text fields, in the WEB's order (`TEXT_FIELDS` in the page).
///
/// One table drives the draft, the body, the validation and the diff, which
/// is the same single-source shape the usecase uses (`PROFILE_FIELDS`) — a
/// twelfth field added in one place and forgotten in another is exactly how a
/// body ends up omitting a key, and an omitted key is an erased one.
enum FarmProfileText: String, CaseIterable, Sendable {
    case producerName, egn, eik, urn, address, municipality, settlement,
         agricultureDirectorateCity, registrationPlace, registrationEkatte, odbhCity

    /// `admin.farmProfile.fields.*`, verbatim from agri-saas `messages/bg.json`.
    var label: String {
        switch self {
        case .producerName: "Земеделски производител (име/фирма)"
        case .egn: "ЕГН"
        case .eik: "ЕИК"
        case .urn: "УРН (регистрационен номер на стопанина)"
        case .address: "Адрес по регистрация / на управление"
        case .municipality: "Община"
        case .settlement: "Населено място"
        case .agricultureDirectorateCity: "ОД „Земеделие“ гр."
        case .registrationPlace: "Място на регистриране (местоположение на стопанството)"
        case .registrationEkatte: "ЕКАТТЕ"
        case .odbhCity: "ОДБХ гр."
        }
    }

    /// The web's description line: `encryptedNote` on the three encrypted
    /// fields, `fieldHints.*` where one exists, nothing otherwise.
    var hint: String? {
        switch self {
        case .egn, .eik:
            "Съхранява се криптирано."
        case .urn:
            // The web shows the encrypted note INSTEAD of this hint (its
            // ternary checks `encrypted` first), so its own УРН hint never
            // renders. Both are shown here: the hint is the one sentence that
            // stops a farmer typing their ЕИК into the УРН box.
            "Съхранява се криптирано. Номерът на стопанството в регистъра на "
                + "земеделските стопани — различен от ЕИК и ЕГН."
        case .registrationPlace:
            "Където е регистрирано стопанството. Обикновено това е и складът за "
                + "растителна продукция — самият склад се записва за всеки парцел поотделно."
        default:
            nil
        }
    }

    /// `UpdateFarmProfileSchema`'s `.max(n)`, per field.
    var maxLength: Int {
        switch self {
        case .producerName: 300
        case .address: 500
        case .egn, .eik, .registrationEkatte: 20
        case .urn: 40
        case .municipality, .settlement, .agricultureDirectorateCity,
             .registrationPlace, .odbhCity: 200
        }
    }

    var wire: KeyPath<FarmProfile, String?> {
        switch self {
        case .producerName: \.producerName
        case .egn: \.egn
        case .eik: \.eik
        case .urn: \.urn
        case .address: \.address
        case .municipality: \.municipality
        case .settlement: \.settlement
        case .agricultureDirectorateCity: \.agricultureDirectorateCity
        case .registrationPlace: \.registrationPlace
        case .registrationEkatte: \.registrationEkatte
        case .odbhCity: \.odbhCity
        }
    }
}

/// Server bounds that are not per-text-field. From the route's zod schema.
enum FarmProfileLimits {
    static let maxHectares: Double = 1_000_000
    static let maxCrops = 50
    static let maxCropLength = 120
}

/// What the form holds: STRINGS, because that is what an input holds.
///
/// The web says it best — "a half-typed «12.» is a valid thing to be looking
/// at and not a number" — so the typed values are built at the boundary
/// (`FarmProfileUpdate.build`) rather than carried through the form.
struct FarmProfileDraft: Equatable, Sendable {
    var text: [FarmProfileText: String]
    /// HECTARES, as the web's field is («Размер на стопанството (ха)»). See
    /// `FarmProfileEditView` for why this one input breaks the app's decare
    /// convention and how it is bridged.
    var sizeHa: String
    var crops: [String]

    init(_ profile: FarmProfile) {
        text = Dictionary(uniqueKeysWithValues: FarmProfileText.allCases.map {
            ($0, profile[keyPath: $0.wire] ?? "")
        })
        sizeHa = profile.sizeHa.map(Self.hectaresText) ?? ""
        crops = profile.grainProduced
    }

    subscript(_ field: FarmProfileText) -> String {
        get { text[field] ?? "" }
        set { text[field] = newValue }
    }

    /// The prefill, and the comparison `build` uses to tell "untouched" from
    /// "edited". Bulgarian comma, no grouping (a grouping space would be
    /// re-typed by nobody and parsed by `parseHectares` only because it
    /// strips spaces), and up to the column's three decimals so a stored
    /// 39,758 is shown as stored.
    static func hectaresText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3))
            .grouping(.never).locale(BgDate.locale))
    }

    enum SizeInput: Equatable {
        case blank
        case value(Double)
        case notANumber
        case negative
        case tooLarge
    }

    /// The web's parse (`trim().replace(',', '.')`), made strict.
    ///
    /// THE ONE PLACE THIS DELIBERATELY DIFFERS FROM THE WEB. The web sends an
    /// unparseable size as NULL — and null clears. So «41,2,5» or «около 40»
    /// silently erases a declared size on the web. Here it is refused with a
    /// message: a typo must not be able to delete a figure that reaches a
    /// state form, which is the same reason the server refuses a negative.
    static func parseHectares(_ raw: String) -> SizeInput {
        let cleaned = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return .blank }
        // ONE separator, either kind. `Double("1,5")` is nil, and a string
        // with both («1.234,5») is a grouping guess this field has no need to
        // make: nobody declares a thousand hectares to the dot.
        let separators = cleaned.filter { $0 == "," || $0 == "." }.count
        guard separators <= 1 else { return .notANumber }
        guard let value = Double(cleaned.replacingOccurrences(of: ",", with: ".")),
              value.isFinite
        else { return .notANumber }
        if value < 0 { return .negative }
        if value > FarmProfileLimits.maxHectares { return .tooLarge }
        return .value(value)
    }

    /// What the farmer typed, as entries: the WEB's parse.
    ///
    /// The web holds the crops in one box and sends
    /// `split(',').map(trim).filter(nonBlank)`, so a comma always separated
    /// two crops there. Rows here can hold a comma too, and splitting it the
    /// same way keeps one rule for one field across both clients — a profile
    /// saved from the phone and opened on the web round-trips unchanged.
    static func typedCrops(_ rows: [String]) -> [String] {
        rows.flatMap { $0.split(separator: ",", omittingEmptySubsequences: true) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The web's parse, then the usecase's grain normalisation, run BEFORE
    /// sending.
    ///
    /// De-duplicate case-insensitively while KEEPING THE FIRST spelling, and
    /// preserve order — `seen` / `toLocaleLowerCase('bg')` in
    /// `upsertFarmProfile`. Nothing sorts: it is a declaration, and the
    /// server itself refuses to reorder it. Done here as well because zod
    /// checks `.max(50)` on the RAW array, before the server de-duplicates: a
    /// list of 50 crops plus one accidental duplicate would be a 400 the
    /// farmer cannot read, where normalising first sends 50.
    static func normaliseCrops(_ rows: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for crop in typedCrops(rows) {
            let key = crop.lowercased(with: BgDate.locale)
            guard seen.insert(key).inserted else { continue }
            out.append(crop)
        }
        return out
    }
}

/// The PUT body: all thirteen keys, ALWAYS, nulls explicit.
///
/// See the file header — an omitted key is erased server-side, so the
/// synthesised `Encodable` (which omits nils) is replaced rather than trusted.
struct FarmProfileUpdate: Encodable, Equatable, Sendable {
    var text: [FarmProfileText: String?]
    var sizeHa: Double?
    var grainProduced: [String]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for field in FarmProfileText.allCases {
            // `?? nil` flattens the dictionary's own optional: a missing key
            // is sent as null rather than skipped. The table is total today;
            // this keeps the body total if that ever stops being true.
            if let value = text[field] ?? nil {
                try c.encode(value, forKey: Key(field.rawValue))
            } else {
                try c.encodeNil(forKey: Key(field.rawValue))
            }
        }
        if let sizeHa {
            try c.encode(sizeHa, forKey: Key("sizeHa"))
        } else {
            try c.encodeNil(forKey: Key("sizeHa"))
        }
        try c.encode(grainProduced, forKey: Key("grainProduced"))
    }

    struct Problem: Equatable, Sendable {
        /// nil for the size and the crop list, which are not text fields.
        let field: FarmProfileText?
        let message: String
    }

    /// READ-MODIFY-WRITE of the whole object.
    ///
    /// An UNTOUCHED field goes back exactly as it was loaded — not re-trimmed,
    /// not re-formatted — so opening the editor and saving changes nothing the
    /// farmer did not change. An EDITED field is trimmed, and a blank one is
    /// sent as null, which clears it: that is the one way to clear, and it is
    /// what the farmer did.
    ///
    /// Untouched is judged against the PREFILL, not against the wire value,
    /// because the prefill is what the farmer was looking at. A stored size
    /// of 39.758 prefills «39,758»; leaving that alone resends 39.758 itself
    /// rather than a re-parse of its rendering.
    /// Everything that stopped a save, together — one round of fixes rather
    /// than one refusal per tap.
    struct Refusal: Error, Equatable, Sendable {
        let problems: [Problem]
    }

    static func build(original: FarmProfile, draft: FarmProfileDraft)
        -> Result<FarmProfileUpdate, Refusal>
    {
        let before = FarmProfileDraft(original)
        var problems: [Problem] = []
        var text: [FarmProfileText: String?] = [:]

        for field in FarmProfileText.allCases {
            if draft[field] == before[field] {
                text[field] = original[keyPath: field.wire]
                continue
            }
            let trimmed = draft[field].trimmingCharacters(in: .whitespacesAndNewlines)
            // UTF-16, because zod's `.max` is a JavaScript string length.
            // A Cyrillic letter is one unit either way; this matters for an
            // emoji someone pasted, which is two.
            if trimmed.utf16.count > field.maxLength {
                problems.append(Problem(
                    field: field,
                    message: "«\(field.label)» е твърде дълго — до \(field.maxLength) знака."))
            }
            text[field] = trimmed.isEmpty ? nil : trimmed
        }

        var sizeHa = original.sizeHa
        if draft.sizeHa != before.sizeHa {
            switch FarmProfileDraft.parseHectares(draft.sizeHa) {
            case .blank: sizeHa = nil
            case .value(let v): sizeHa = v
            case .notANumber:
                problems.append(Problem(field: nil, message:
                    "Размерът трябва да е число в хектари, напр. 41,25."))
            case .negative:
                problems.append(Problem(field: nil, message:
                    "Размерът не може да е отрицателен."))
            case .tooLarge:
                problems.append(Problem(field: nil, message:
                    "Размерът е над 1 000 000 ха — проверете дали не е въведен в декари или кв. м."))
            }
        }

        var crops = original.grainProduced
        if draft.crops != before.crops {
            crops = FarmProfileDraft.normaliseCrops(draft.crops)
            if crops.count > FarmProfileLimits.maxCrops {
                problems.append(Problem(field: nil, message:
                    "Културите са твърде много — до \(FarmProfileLimits.maxCrops)."))
            }
            if let long = crops.first(where: { $0.utf16.count > FarmProfileLimits.maxCropLength }) {
                problems.append(Problem(field: nil, message:
                    "«\(long.prefix(30))…» е твърде дълго за култура — до "
                        + "\(FarmProfileLimits.maxCropLength) знака."))
            }
        }

        if !problems.isEmpty { return .failure(Refusal(problems: problems)) }
        return .success(FarmProfileUpdate(text: text, sizeHa: sizeHa, grainProduced: crops))
    }
}

/// What to tell the farmer after a save, from what the SERVER RETURNED.
///
/// The web re-reads the response into the form and says only «записан», so a
/// dropped duplicate simply vanishes from the box. Here it is said, because
/// the edit sheet closes on success and a crop disappearing from a list one
/// screen away is easy not to notice.
///
/// Compared against what the farmer TYPED (trimmed), not against the body —
/// so a duplicate the client folded before sending is reported the same way
/// as anything the server folded. Trimming alone is never reported: nobody
/// needs telling that a trailing space went.
enum FarmProfileSaveReport {
    static let saved = "Профилът на стопанството е записан."

    static func notes(draft: FarmProfileDraft, saved profile: FarmProfile) -> [String] {
        var notes: [String] = []

        for field in FarmProfileText.allCases {
            let typed = draft[field].trimmingCharacters(in: .whitespacesAndNewlines)
            let stored = profile[keyPath: field.wire] ?? ""
            guard typed != stored else { continue }
            if stored.isEmpty {
                notes.append("«\(field.label)» не беше приет и е празен.")
            } else if field == .egn {
                // NEVER the value. This note is plain text on screen and in the
                // accessibility tree, and the ЕГН's whole treatment is that it
                // appears only behind an explicit reveal.
                notes.append("«ЕГН» беше коригирано от сървъра — проверете го.")
            } else {
                notes.append("«\(field.label)» е записано като «\(stored)».")
            }
        }

        switch FarmProfileDraft.parseHectares(draft.sizeHa) {
        case .value(let typed):
            if let stored = profile.sizeHa {
                // The column is Decimal(12, 3), so a fourth decimal is rounded
                // by Postgres and that IS worth saying. Float noise is not: the
                // tolerance sits far below the column's 0.001 and far above
                // a double's error at a million hectares.
                if abs(typed - stored) > 1e-7 {
                    notes.append("Размерът е записан като "
                                 + "\(FarmProfileDraft.hectaresText(stored)) ха.")
                }
            } else {
                notes.append("Размерът не беше приет и е празен.")
            }
        default:
            break
        }

        let typedCrops = FarmProfileDraft.typedCrops(draft.crops)
        if typedCrops != profile.grainProduced {
            let kept = Set(profile.grainProduced)
            let keptFolded = Set(profile.grainProduced.map { $0.lowercased(with: BgDate.locale) })
            var dropped: [String] = []
            for crop in typedCrops where !kept.contains(crop) && !dropped.contains(crop) {
                dropped.append(crop)
            }
            // «повторение» only when it IS one — every dropped entry matches a
            // kept one case-insensitively. A crop the sanitiser rewrote is not
            // a duplicate, and calling it one would be a false statement about
            // what the server did; that case gets the plain list instead.
            if !dropped.isEmpty,
               dropped.allSatisfy({ keptFolded.contains($0.lowercased(with: BgDate.locale)) }) {
                notes.append("Премахнати като повторение: "
                             + dropped.map { "«\($0)»" }.joined(separator: ", ") + ".")
            } else {
                notes.append("Списъкът с култури е записан като: "
                             + profile.grainProduced.joined(separator: ", ") + ".")
            }
        }
        return notes
    }
}
