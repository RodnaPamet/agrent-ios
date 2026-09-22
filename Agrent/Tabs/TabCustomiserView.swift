import SwiftUI

/// Choose which screens sit in the bottom row, and in what order.
struct TabCustomiserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = BottomTabsStore.shared
    @State private var chosen: [AppSurface] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chosen) { surface in
                        row(surface, inBar: true)
                    }
                    .onMove { from, to in chosen.move(fromOffsets: from, toOffset: to) }
                } header: {
                    Text("В долната лента · \(chosen.count) от \(AppSurface.capacity)")
                } footer: {
                    // Says the constraint rather than letting a farmer
                    // discover it by having a tap do nothing.
                    Text("iOS показва най-много \(AppSurface.capacity) раздела. "
                       + "Всичко останало е в менюто горе вляво и остава достъпно.")
                }

                // `permitted`, not `allCases` — the editor must not offer a
                // tab whose every screen would 403. An operator choosing
                // Борса would get a bar that errors, and would reasonably
                // conclude the app is broken rather than that they lack
                // the role.
                let rest = AppSurface.allCases.filter { surface in
                    store.permitted.contains(surface)
                        && !chosen.contains { $0.id == surface.id }
                }
                if !rest.isEmpty {
                    Section("В менюто") {
                        ForEach(rest) { surface in
                            row(surface, inBar: false)
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Раздели")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") {
                        Task {
                            await store.save(chosen)
                            dismiss()
                        }
                    }
                    .disabled(chosen.isEmpty || store.isSaving)
                }
            }
            .task { if chosen.isEmpty { chosen = store.bottomTabs } }
            .overlay(alignment: .bottom) {
                if let failure = store.saveFailure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.red)
                }
            }
        }
    }

    private func row(_ surface: AppSurface, inBar: Bool) -> some View {
        // Full at five. The plus must LOOK unavailable, not merely be
        // unavailable: `.disabled` dims a button's own style, and an
        // explicit `.foregroundStyle(.green)` overrides that dimming — so
        // the first version showed a bright green plus that did nothing,
        // which is the exact failure the footer text was added to prevent.
        // Caught by screenshotting the sheet at 5 of 5.
        let canAdd = chosen.count < AppSurface.capacity
        let enabled = inBar || canAdd
        return HStack {
            Label(surface.label, systemImage: surface.icon)
            Spacer()
            Button {
                if inBar {
                    chosen.removeAll { $0.id == surface.id }
                } else if canAdd {
                    chosen.append(surface)
                }
            } label: {
                Image(systemName: inBar ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(enabled
                        ? (inBar ? Color.red : Color.green)
                        : Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(inBar
                ? "Премахни \(surface.label) от долната лента"
                : "Добави \(surface.label) в долната лента")
            // Silence is not an explanation. VoiceOver says why.
            .accessibilityHint(enabled ? "" : "Долната лента е пълна")
        }
    }
}
