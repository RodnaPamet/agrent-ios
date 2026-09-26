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
                    ForEach(Array(chosen.enumerated()), id: \.element.id) { index, surface in
                        row(surface, inBar: true)
                            // NAMED ACTIONS, because `.onMove` is a DRAG.
                            //
                            // Order is the point of this screen — which five
                            // surfaces are in the bar AND in what sequence —
                            // and a drag is the one gesture no focus ring can
                            // perform. A Switch Control user could add and
                            // remove but never reorder, and Full Keyboard
                            // Access had no route at all.
                            //
                            // Named actions appear in the Switch Control menu,
                            // under Tab+Z for Full Keyboard, and in VoiceOver's
                            // actions rotor — the reference's own answer to an
                            // action hidden behind a gesture. The drag still
                            // works; this is an alternative, not a replacement.
                            .accessibilityActions {
                                if index > 0 {
                                    Button("Премести нагоре") {
                                        chosen.move(fromOffsets: [index], toOffset: index - 1)
                                    }
                                }
                                if index < chosen.count - 1 {
                                    Button("Премести надолу") {
                                        chosen.move(fromOffsets: [index], toOffset: index + 2)
                                    }
                                }
                            }
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
            .inlineTitle("Раздели")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отказ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запази") {
                        Task {
                            // ONLY on success.
                            //
                            // This dismissed unconditionally. A refused
                            // write rolls the bar back — so the farmer
                            // watched their arrangement snap to what it
                            // was, with the sheet closing over the one
                            // place the reason is printed. The overlay
                            // below could never be seen.
                            //
                            // Found while the route still 404'd, which is
                            // the window where the failure path was the
                            // ONLY path. A week later it would have been
                            // unreachable code that stays wrong.
                            if await store.save(chosen) { dismiss() }
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
            // The GLYPH is the second channel: minus against plus, not red
            // against green alone. Red and green are the classic pair that
            // deuteranopia collapses, and the two buttons sit in the same
            // position on rows that otherwise look identical.
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
                    // 44pt. A body-size SF Symbol in a `.plain` button with no
                    // padding is about 22pt of hit area — half the minimum,
                    // for the control that adds and removes tabs, sitting at
                    // the trailing edge where a thumb is least accurate.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
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
