import SwiftUI

/// Админ → «Диагностика»: what this phone has resolved, read-only.
///
/// ── Why it exists, and why in RELEASE ──
///
/// The owner measures flag propagation: flip a flag on agri-saas, bring the
/// app back to the foreground, see when the phone has it. The phone he does
/// that on runs the Release build, where there is no debugger, no console
/// and no `#if DEBUG` screen — and a flag whose surface has not shipped yet
/// has nothing visible to show it arrived. So the readout is in the build he
/// runs, behind Админ, which is already admin-only (`AdminView.access`).
///
/// ── What it shows, and what it never shows ──
///
///   · every key in `FeatureFlags.resolved`, «вкл.» exactly where `isOn` is
///     true — so a key sent as `false` reads «изкл.», the same as one never
///     sent, which is what the app does with both;
///   · `FeatureFlags.lastFreshAt` to the second (`BgDate.clockSeconds`), the
///     moment the last FRESH `/me` was adopted — the number the measurement
///     is about;
///   · the `X-Agrent-Client` value, so a counter on the server can be matched
///     to this phone's build;
///   · the `x-agrent-client-version` value, the contract this build declares
///     to the server's version gate (#169) — so a phone being told to update
///     can be matched to what it told the server. Both headers, because they
///     are the two this app puts on every request (`ClientHeader`).
///
/// NOT the user id, a token, a name, an email or anything else personal: a
/// screenshot of this goes into an issue thread. That is why it reads
/// `FeatureFlags` and `ClientHeader` and nothing from `CurrentUserStore`,
/// `SessionIdentity` or `TokenStore` — a source test holds it to that.
///
/// ── Live, and touches nothing ──
///
/// `FeatureFlags` is `@Observable`, so a foreground refresh that lands while
/// this page is open redraws it. Nothing here writes, and nothing here asks
/// the network: a «refresh» button would be a second `/me` path, which is
/// what `CurrentUserRefreshTests` counts against.
struct DiagnosticsView: View {
    @State private var flags = FeatureFlags.shared

    var body: some View {
        List {
            Section {
                if flags.resolved.isEmpty {
                    // Both "no fresh answer yet" and "the server sent none"
                    // land here, and both mean the same to the app: all off.
                    Text("Няма флагове — всички са изключени")
                        .foregroundStyle(Palette.secondaryText)
                } else {
                    ForEach(flags.resolved.keys.sorted(), id: \.self) { key in
                        flagRow(key)
                    }
                }
            } header: {
                SectionHeader("Флагове")
            }
            .pageRow()

            Section {
                fact("Последен свеж отговор",
                     value: flags.lastFreshAt.map(BgDate.clockSeconds) ?? "Няма в тази сесия")
                fact("X-Agrent-Client", value: ClientHeader.value ?? "Не се изпраща")
                fact(ClientHeader.contractVersionHeader, value: String(ClientHeader.contractVersion))
            } header: {
                SectionHeader("Сесия")
            } footer: {
                SectionFooter {
                    // What "fresh" means, once, because the measurement depends
                    // on it: a cached `/me` from disk never moves this time.
                    Text("Часът, в който приложението е приело флаговете от сървъра. Отговор от кеша не го променя.")
                }
            }
            .pageRow()
        }
        .inlineTitle("Диагностика")
        .pageBackground()
    }

    /// A key, and on/off. Monospaced because keys are identifiers the owner
    /// compares against the server's config letter by letter.
    private func flagRow(_ key: String) -> some View {
        let on = flags.isOn(key)
        return ValueRow {
            Text(on ? "вкл." : "изкл.")
                // Off is the quiet state; on is the news. `Palette.secondaryText`
                // is the measured 6.86:1, not `.secondary`.
                .foregroundStyle(on ? Color.primary : Palette.secondaryText)
                .fontWeight(on ? .semibold : .regular)
        } label: {
            Text(key).font(.body.monospaced())
        }
        // One stop, the state as a word: "social.dm, включен" rather than a
        // key stop and an abbreviation stop.
        .accessibleRow(spoken: "\(key), \(on ? "включен" : "изключен")", saying: [key])
    }

    private func fact(_ label: String, value: String) -> some View {
        ValueRow(label) {
            Text(value).monospacedDigit()
        }
        .accessibleRow(spoken: "\(label): \(value)", saying: [label])
    }
}
