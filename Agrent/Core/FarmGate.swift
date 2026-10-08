import SwiftUI

/// The tabs, once a farm is open — and what to say when none can be
/// (agrent-ios#179).
///
/// A returning farmer passes straight through: `FarmStore` restores their
/// farm before the first frame, with no request. Only a person with nothing
/// remembered on this phone ever sees the other states — or one whose last
/// farm, and only farm, the farm list has since closed — and each has a way
/// to Профил, the app's only Изход (#174), because none of them has the menu.
struct FarmGate: View {
    @State private var farms = FarmStore.shared
    @State private var me = CurrentUserStore.shared
    @State private var flags = FeatureFlags.shared

    /// A farm the person has just switched to, said aloud once the new tabs
    /// are up; see `announce`.
    @State private var opened: Farm?

    /// The lost-access alert, and its sentence as it was when it was asked
    /// for — so the text cannot change under the alert as it closes.
    @State private var tellingLostAccess = false
    @State private var lostAccessNote = ""

    var body: some View {
        Group {
            switch farms.state {
            case .active(let farm):
                // A NEW IDENTITY PER FARM. Every screen builds its own store
                // in `@State`, and SwiftUI keeps state for as long as a view
                // keeps its identity — so without this, a farm switch would
                // leave each tab showing the previous farm's records until
                // something reloaded it. Keyed on the slug: renaming a farm
                // is not a reason to rebuild everything.
                MainTabView().id(farm.slug)
            case .resolving:
                ProgressView("Зареждане на стопанството…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.Surface.page)
            case .none:
                OutsideAFarm {
                    // Creating one, when the server offers it to this person —
                    // `/me` has just been read, so the flags are this
                    // person's. Absent means off, and then only the way an
                    // existing farm can let them in.
                    if flags.isOn(FarmWizardText.flag) {
                        FarmWizardView(context: .onboarding) { farms.openCreated($0) }
                    } else {
                        EmptyState(
                            Self.noFarmTitle,
                            icon: "building.2",
                            message: Self.noFarmMessage
                        )
                    }
                }
            case .failed:
                OutsideAFarm {
                    ErrorState(message: Self.unavailable) {
                        await farms.resolve()
                        await farms.refreshFarms()
                    }
                }
            }
        }
        .task {
            await farms.resolve()
            // A gate that went away while `/me` was asked (an Изход) does not
            // start the next person's list under the old session's task.
            guard !Task.isCancelled else { return }
            // The list once a farm is settled — behind it, never in front: a
            // returning farmer is already looking at their farm. It names the
            // open farm, says this person's role there, and closes the farm
            // if it is no longer theirs.
            await farms.refreshFarms()
        }
        // The menu names the farm; `/me` can name the one seeded by slug.
        .onChange(of: me.user?.tenant) { _, tenant in farms.adoptName(from: tenant) }
        // ── A switch is SAID, not only seen ──
        //
        // Choosing a farm in Профил rebuilds every tab and takes the sheet
        // that held the row away. A sighted person sees the records change;
        // a VoiceOver user hears, at best, the first tab's title, and nothing
        // on it names the farm. So the switch is announced — a person's own
        // switch, or a farm they have just created, never the launch's first
        // farm (`old` is nil then) and never a farm closed under them, which
        // the alert below says instead.
        .onChange(of: farms.activeFarm?.slug) { old, new in
            guard old != nil, new != nil, old != new, farms.lostAccess == nil else { return }
            opened = farms.activeFarm
        }
        .task(id: opened?.slug) { await announce() }
        // Said once, over whatever opened instead: without it the app would
        // simply show another farm — or none — and the person would be left
        // to wonder where their records went.
        //
        // ASKED FOR A MOMENT LATER, not at once. The list that closes a farm
        // can answer while a sheet is open on the old one — Профил's own read
        // runs inside Админ's — and that sheet goes with the old tabs. An
        // alert asked for while a sheet is still being dismissed can be
        // refused by UIKit, and this one is the only sign anything happened.
        // Not seen to fail; not seen to succeed either, so not left to chance.
        .task(id: farms.lostAccess?.slug) {
            guard let lost = farms.lostAccess else { return }
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            lostAccessNote = Self.lostAccessMessage(lost, now: farms.activeFarm)
            tellingLostAccess = true
        }
        .onChange(of: tellingLostAccess) { _, shown in
            if !shown { farms.acknowledgeLostAccess() }
        }
        .alert(Self.lostAccessTitle, isPresented: $tellingLostAccess) {
            Button("Добре", role: .cancel) {}
        } message: {
            Text(lostAccessNote)
        }
    }

    /// Once the old tabs — and any sheet open over them — have gone. High
    /// priority, as `OutboxBanner`'s is: the focus move that follows a
    /// screen being replaced is exactly what cuts a default one short.
    private func announce() async {
        guard let farm = opened else { return }
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled else { return }
        var line = AttributedString(Self.openedLine(farm))
        line.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(line).post()
        opened = nil
    }

    /// Longer than a sheet takes to go.
    private static let settle = Duration.milliseconds(600)

    static let noFarmTitle = "Нямате стопанство"
    /// Only while creating a farm is switched off for this person — with it
    /// on, the wizard is this screen.
    static let noFarmMessage = "Профилът Ви все още не е свързан със стопанство. "
        + "Помолете собственика на стопанството да Ви покани."
    static let unavailable = "Стопанството не може да бъде заредено. Проверете връзката и опитайте пак."

    static let lostAccessTitle = "Стопанството вече не е достъпно"

    /// Which farm went, and which is open now. The farm seeded by slug alone
    /// may never have been named; a farm from the list always has been.
    static func lostAccessMessage(_ lost: Farm?, now open: Farm?) -> String {
        let gone = lost?.name.map { "«\($0)» вече не е сред стопанствата Ви." }
            ?? "Стопанството, което беше отворено, вече не е сред стопанствата Ви."
        guard let open, open.name != nil else { return gone }
        return gone + " " + openedLine(open)
    }

    /// The farm that is open now, in the words the alert uses too.
    static func openedLine(_ farm: Farm) -> String {
        "Отворено е стопанство «\(farm.name ?? farm.slug)»."
    }
}

/// A state with no farm in it: the page, and Профил in the corner — the way
/// to Изход when the tabs and their menu are not there.
private struct OutsideAFarm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .pageBackground()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ProfileView()
                        } label: {
                            Label("Профил", systemImage: "person.crop.circle")
                        }
                        .accessibilityInputLabels(A11y.Spoken.profile)
                    }
                }
        }
    }
}
