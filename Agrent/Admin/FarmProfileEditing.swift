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
//   ABSENT IS LEFT ALONE NOW (agri-saas#1176, fixed by #1181). It used to
//   clear: the usecase mapped every field through `norm(input[k])` and
//   `norm(undefined)` was null, so a body that left out `egn` erased the
//   farm's ЕГН. The body below STILL carries every key it may send (twelve,
//   see the next paragraph) with explicit nulls — correct under both
//   semantics, so it does not matter which server build answers, and it is
//   the read-modify-write the web page does too. Swift's synthesised
//   `Encodable` omits nil optionals, which under the old semantics would have
//   been the same erase by another route; it stays replaced. An explicit null
//   still clears, and that is the one way to.
//
//   ЕИК IS NEVER SENT (agri-saas#1352, enforced by P3.9). The PUT REJECTS a
//   body whose `eik` DIFFERS from the stored one — null included, which would
//   clear it — with 400 FARM_PROFILE_EIK_NOT_EDITABLE. (As merged in #1355 an
//   unchanged echo is accepted as a no-op; #1352's plan refused the key
//   outright, and this client was built to that stricter reading. Leaving
//   the key out is correct under both.) ЕИК is written only
//   by Agrent staff verifying the farm's identity claim (P3.4/P3.9), because
//   it reaches the ДНЕВНИК PDF and the БАБХ register export and a free-edit
//   field let any ADMIN put an unchecked number there. So the body carries
//   exactly TWELVE keys, `eik` absent. Absent is "left alone" under #1181's
//   merge semantics, verified in `upsertFarmProfile` (`Object.hasOwn`), so
//   leaving it out preserves the stored ЕИК rather than clearing it. The
//   field stays READABLE: it is in the GET response and shown read-only.
//
//   THE REQUEST IS DOCUMENTED (#1178): `UpdateFarmProfileRequest` lists
//   thirteen properties, none required, and the limits below match its
//   `maxLength`s. The twelve sent are `FarmProfileText.writable` plus
//   `sizeHa` and `grainProduced`.
//
//   A NEGATIVE SIZE IS A 400, not a stored null. The usecase does refuse a
//   negative as null, but zod's `.nonnegative()` in the route rejects it
//   first, so that branch is unreachable over HTTP. The client refuses it
//   before sending; the response diff still reports a size the server
//   dropped, in case the two ever drift.
//
//   OPTIMISTIC LOCK (agri-saas#1184). GET reports `version`; the save sends
//   it back as `If-Match` (a bare integer) and a stale one is a 409
//   STALE_DATA with `currentVersion` / `expectedVersion` under
//   `error.details`. The editor then STOPS: no overwrite, no silent retry —
//   it says someone else saved, and «Презареди» re-reads the profile and
//   re-applies the farmer's edits over it (`FarmProfileRebase`), naming any
//   field both people changed. Before #1184 this was last-write-wins on the
//   whole record and two admins lost an edit silently.
//
//   SAFE TO RETRY, with one new answer. A PUT of the whole object is
//   idempotent by construction, so a timeout offers «Запази» again rather
//   than the unknown-outcome warning the member writes need. What changed
//   with the lock: if the timed-out save DID land, the retry carries the
//   old version and is a 409 — the conflict screen, not a lost write, and a
//   reload shows the farmer their own save.

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

    /// May the farm's own admin write this field through the PUT?
    ///
    /// Every field but ЕИК (agri-saas#1352): the server refuses a body that
    /// carries `eik` at all, so it is shown in the editor but never typed
    /// into and never sent. See the file header.
    var isWritable: Bool { self != .eik }

    /// The text fields the PUT body carries, in the web's order. Every loop
    /// that BUILDS, ENCODES, REBASES or REPORTS on a save walks this, not
    /// `allCases` — one list, so the ЕИК cannot leak back in through any one
    /// of them.
    static let writable: [FarmProfileText] = allCases.filter(\.isWritable)

    /// Under the read-only ЕИК in the editor. No web wording exists for it
    /// (agri-saas `messages/bg.json` has none for P3.4/P3.9, #1355 included),
    /// so it is written here. The verification status beside it is
    /// `EikStatus`.
    static let eikReadOnlyNote = "ЕИК се променя само след проверка от екипа на Agrent."

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

/// The PUT body: all TWELVE writable keys, ALWAYS, nulls explicit — and
/// never `eik` (agri-saas#1352).
///
/// See the file header — an omitted key used to be erased server-side, so
/// the synthesised `Encodable` (which omits nils) is replaced rather than
/// trusted. The ЕИК is the one deliberate omission: the server refuses a body
/// that carries it, and absent leaves the stored one alone.
struct FarmProfileUpdate: Encodable, Equatable, Sendable {
    var text: [FarmProfileText: String?]
    var sizeHa: Double?
    var grainProduced: [String]

    /// The version of the profile this body was BUILT OVER — the `If-Match`.
    /// NOT ENCODED: it is a header, and the body schema has no `version`.
    ///
    /// Carried here rather than read from the store at send time, because
    /// the store's copy can move under an open sheet (pull-to-refresh behind
    /// it). Sending the newer version with edits made over the older one
    /// would pass the lock and overwrite a change the farmer never saw —
    /// precisely the lost update the lock exists for.
    var expectedVersion: Int? = nil

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        // `writable`, NOT `allCases`: even a `text[.eik]` some caller set is
        // never encoded: a value differing from the stored ЕИК is a 400
        // (agri-saas#1352), and absent is always safe.
        for field in FarmProfileText.writable {
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

        // The ЕИК is not built at all: it is not the farmer's to send.
        for field in FarmProfileText.writable {
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
        return .success(FarmProfileUpdate(text: text, sizeHa: sizeHa, grainProduced: crops,
                                          expectedVersion: original.version))
    }
}

/// After a 409: the farmer's edits, re-applied over the profile as it is NOW.
///
/// The cheap way to keep unsaved edits through a reload, and it falls out of
/// how `build` already works. An edit is "this field differs from what I was
/// shown" — so it is judged against the OLD profile and carried across, while
/// every field the farmer did not touch takes the NEW stored value. The
/// other person's changes to fields this farmer left alone therefore survive
/// the next save, instead of being written back over with stale values.
///
/// SAME-FIELD COLLISIONS ARE NAMED, NOT RESOLVED. Where both people changed
/// one field, the farmer's value is kept in the box (it is what they typed)
/// and a note says what the other person stored, so pressing «Запази» again
/// is an informed overwrite rather than the silent one the lock prevents.
/// Where both typed the SAME value there is nothing to say.
struct FarmProfileRebase: Equatable {
    let draft: FarmProfileDraft
    let collisions: [String]

    static func rebase(_ draft: FarmProfileDraft, from old: FarmProfile,
                       onto fresh: FarmProfile) -> FarmProfileRebase {
        let before = FarmProfileDraft(old)
        let now = FarmProfileDraft(fresh)
        var out = now
        var collisions: [String] = []

        /// Both sides moved the same value, to different places.
        func collided<V: Equatable>(_ mine: V, _ was: V, _ theirs: V) -> Bool {
            mine != was && theirs != was && theirs != mine
        }

        // `writable`: the ЕИК always takes the FRESH stored value (it is in
        // `now`), never a carried-over edit — staff verification may be the
        // very write that caused the 409, and it must not be written back.
        for field in FarmProfileText.writable where draft[field] != before[field] {
            out[field] = draft[field]
            guard collided(draft[field], before[field], now[field]) else { continue }
            if field == .egn {
                // NEVER the value — the same rule as `FarmProfileSaveReport`:
                // this is plain text on screen and in the accessibility tree.
                collisions.append("«ЕГН» е променено и от друг потребител — проверете го.")
            } else {
                let theirs = now[field].isEmpty ? "празно" : "«\(now[field])»"
                collisions.append("«\(field.label)»: друг потребител е записал \(theirs).")
            }
        }
        if draft.sizeHa != before.sizeHa {
            out.sizeHa = draft.sizeHa
            if collided(draft.sizeHa, before.sizeHa, now.sizeHa) {
                let theirs = now.sizeHa.isEmpty ? "празно" : "\(now.sizeHa) ха"
                collisions.append("Размер: друг потребител е записал \(theirs).")
            }
        }
        if draft.crops != before.crops {
            out.crops = draft.crops
            if collided(draft.crops, before.crops, now.crops) {
                let theirs = now.crops.isEmpty ? "празно" : now.crops.joined(separator: ", ")
                collisions.append("Култури: друг потребител е записал \(theirs).")
            }
        }
        return FarmProfileRebase(draft: out, collisions: collisions)
    }
}

/// The words for a 409 on the farm-profile save.
///
/// THERE IS NO CONFLICT SCREEN ELSEWHERE IN THIS APP TO COPY. The journal is
/// read-and-create on iOS, and the one `.conflict` catch (opening a Борса
/// thread) retries because there it is a duplicate, not a lost update. The
/// wording starts from `APIError.conflict`'s own sentence — «Записът е
/// променен на сървъра, докато го редактирахте.» — said about THIS record.
enum FarmProfileConflict {
    static let message = "Профилът е променен от друг потребител, докато го "
        + "редактирахте. Промените ви не са записани."
    static let advice = "«Презареди» показва записаното сега и запазва "
        + "вашите промени в полетата, които сте редактирали."
    static let reload = "Презареди"
    /// After the reload, before the next save.
    static let reloaded = "Профилът е презареден. Прегледайте и запазете отново."
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

        // Not the ЕИК: it was not sent, so whatever the server holds is not
        // something it "changed" from what the farmer typed.
        for field in FarmProfileText.writable {
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
