import SwiftUI

/// A parcel's risk reading: vegetation and moisture, their averages, and
/// when the satellite looked. One view for Риск's rows and for the parcel's
/// own screen (owner, 2026-10-29: the risk reachable from Блокове → a
/// parcel), so the two can't say different things about one field.
struct ParcelRiskReadings: View {
    let risk: ParcelRisk
    let freshness: Freshness?

    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two chips, stacked rather than side by side: at accessibility
            // sizes two labelled chips on one line reflow independently and
            // fight, which is the failure JournalDetailView documents.
            reading("Зеленина", risk.vegetation, value: risk.ndvi, index: "NDVI")
            reading("Влага", risk.moisture, value: risk.ndmi, index: "NDMI")

            if let reason = risk.absenceReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            acquisitionLine
        }
    }

    private func reading(
        _ title: String, _ level: RiskLevel, value: Double?, index: String
    ) -> some View {
        // A COLUMN WHILE IT FITS, STACKED WHEN IT CANNOT.
        //
        // `Text(title).frame(width: 72)` boxed «Зеленина» at a hard 72pt. At
        // `.footnote` that is comfortable by default and ruinous at the five
        // accessibility sizes, where the word wants roughly 290pt: with no
        // `fixedSize` the column breaks it into two- and three-letter
        // fragments and the tail is simply cut. On the one screen whose job is
        // telling a farmer WHICH reading is bad — and the chip beside it says
        // only the level, while the trailing text is an index code.
        //
        // The 72 is worth keeping below that threshold: it aligns «Зеленина»
        // and «Влага» so the two chips form a column you can compare down.
        // Above it the alignment is the thing that has to go, because there
        // are only two readings and losing the column costs less than losing
        // the words. `NewsView` already switches axis on the same threshold.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: typeSize.isAccessibilitySize ? nil : 72,
                       alignment: .leading)

            CategoryChip(
                text: level.label,
                foreground: level.colors.foreground,
                background: level.colors.background
            )

            if let value {
                // Labelled as an average, deliberately. The map overlay is
                // per-pixel over the whole location; this is one number
                // over this parcel's boundary. A farmer comparing a bright
                // patch there against this will find them different, and
                // both are correct.
                Text("\(index) \(Num.text(value)) ср.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var acquisitionLine: some View {
        if let line = FarmRiskView.acquisition(risk, freshness) {
            Label(line.shown, systemImage: "camera.badge.clock")
                .font(.caption)
                // NEVER `.secondary`, which is what this was. The parcel map
                // says it in its own comment: this line is the caveat on
                // every number above it, and it must not read as a footnote.
                .foregroundStyle(line.isStale ? Palette.warning : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // THE `else` THE PARCEL MAP ALREADY HAD.
            //
            // Without it the whole line vanished and the row showed two
            // coloured chips and two index numbers with no date and no
            // caveat — an undated reading wearing the clothes of a current
            // one. `acquiredDate` is optional on the wire, and the parcel
            // map records for the SAME satellite data that the server may
            // omit it; `BgDate.parseISODay` also returns nil for a full
            // instant, which is the other shape this codebase has met.
            Label("Датата на заснемане е неизвестна.", systemImage: "camera.badge.clock")
                .font(.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the readings say, as clauses for a spoken sentence: the chips'
    /// MEANING, and the acquisition line with its `·` read as a pause.
    static func spoken(_ risk: ParcelRisk, _ freshness: Freshness?) -> [String?] {
        [
            spokenReading("зеленина", risk.vegetation, risk.ndvi, "NDVI"),
            spokenReading("влага", risk.moisture, risk.ndmi, "NDMI"),
            risk.absenceReason,
            FarmRiskView.acquisition(risk, freshness)?.spoken ?? "датата на заснемане е неизвестна",
        ]
    }

    /// «зеленина добро, NDVI 0,62 средно» — the chip's MEANING rather than
    /// its rendered fragment, and «ср.» spelled out, which is an
    /// abbreviation on screen and a word in the ear.
    private static func spokenReading(
        _ title: String, _ level: RiskLevel, _ value: Double?, _ index: String
    ) -> String {
        var text = "\(title) \(level.label.lowercased())"
        if let value { text += ", \(index) \(Num.text(value)) средно" }
        return text
    }
}
