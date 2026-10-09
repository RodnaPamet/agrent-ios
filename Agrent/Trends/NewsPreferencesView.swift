import SwiftUI

/// «Предпочитания» (#231): the topics a farmer follows, switched on and off.
///
/// Owner, 2026-10-08: a button on Новини opens it; the choices are the
/// person's, kept on the server, so the web and every phone agree. The
/// topics and their names are the server's catalogue — this screen lists
/// whatever it holds, grouped as it groups them (Култури, Теми).
///
/// A switch saves as it moves (`NewsStore.toggle`, coalesced). «Готово»
/// only closes; the feed under the sheet reloads for the new topics then.
struct NewsPreferencesView: View {
    let store: NewsStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let catalogue = store.catalogue {
                    topics(catalogue)
                } else if let message = store.catalogueError {
                    // Nothing to switch without the catalogue, so the sheet
                    // says why and offers the read again.
                    ErrorState(message: message) { await store.loadCatalogue() }
                        .background(Palette.Surface.formPage)
                } else {
                    ProgressView("Зареждане…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.Surface.formPage)
                }
            }
            .inlineTitle("Предпочитания")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .accessibilityInputLabels(A11y.Spoken.done)
                }
            }
            .task {
                if store.catalogue == nil { await store.loadCatalogue() }
                // Opened before Новини finished reading them, or after that
                // read failed: the switches wait for this one.
                if !store.preferencesRead { await store.loadPreferences() }
            }
        }
    }

    private func topics(_ catalogue: NewsTagCatalogue) -> some View {
        PageForm {
            Section {
                Text("Новините показват само избраните теми, а „Всички“ над тях — всичко. Без избрани теми се показват всички новини.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.preferencesRead, let message = store.preferencesReadError {
                Section {
                    Text(message)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Опитай пак") { Task { await store.loadPreferences() } }
                }
            }

            if let error = store.preferencesError {
                Section {
                    Text(error)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Опитай пак") { store.retrySave() }
                }
            }

            ForEach(catalogue.groups) { group in
                Section(titled: group.label) {
                    ForEach(group.tags) { tag in
                        TopicSwitch(tag: tag, isOn: store.isChosen(tag.key)) {
                            store.toggle(tag.key)
                        }
                        // Until the person's topics are read, an «off» here
                        // is not their choice — see `NewsStore.preferencesRead`.
                        .disabled(!store.preferencesRead)
                    }
                }
            }
        }
    }
}

/// One topic's switch. The store owns the choice; the switch shows it and
/// asks for the change, so a save that fails leaves the switch where the
/// person put it while the sheet says it was not saved.
private struct TopicSwitch: View {
    let tag: NewsTagCatalogue.Tag
    let isOn: Bool
    let flip: () -> Void

    var body: some View {
        // Flipped only on a real change: a set that repeats the value it
        // already shows (a second activation before the redraw) would
        // otherwise undo the first.
        Toggle(tag.label, isOn: Binding(get: { isOn }, set: { if $0 != isOn { flip() } }))
            // Bulgarian first, then the catalogue's English for a phone whose
            // Voice Control listens in English (asked of agri-saas for this).
            .accessibilityInputLabels(A11y.spokenNames(tag.label, tag.labelEn))
    }
}
