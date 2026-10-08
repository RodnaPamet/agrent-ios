import SwiftUI

/// «Парцели» on a task that is not a field operation (agrent-ios#177): the
/// task's parcels on a map, and by name under it.
///
/// Owner, 2026-10-07: an opened task «does not list the parcel it relates
/// to — it needs to include the map with the parcels which are connected to
/// the task (can be more than 1)». A field operation's section does both
/// already, with each parcel's state; this is the same map for every other
/// task, where an outline means only «this task's», so it has no legend.
///
/// ── Nothing while loading, nothing for a task without parcels ──
///
/// Most tasks have none. A heading with a spinner that then vanishes would
/// jump the page under the reader's thumb on every one of them, so the
/// section appears only with something in it. A FAILURE is said, under the
/// heading, with a retry: parcels that could not be read are not a task
/// without parcels.
struct TaskParcelsSection: View {
    let store: TaskParcelsStore

    var body: some View {
        switch store.state {
        case .loading:
            EmptyView()

        case .failed(let message):
            section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Опитай пак") { Task { await store.load() } }
                        .buttonStyle(MarkButtonStyle(prominent: false))
                }
            }

        case .loaded(let parcels, _) where parcels.isEmpty:
            EmptyView()

        case .loaded(let parcels, _):
            section {
                // No map at all when none of them has an outline — a map of
                // nothing in particular says the task is about nowhere.
                if let map = TaskParcelMapContent.linked(parcels) {
                    TaskParcelMap(content: map, showsLegend: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(parcels) { parcel in
                        ParcelNameRow(parcel: parcel)
                    }
                }
            }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The field operation's heading, so the two sections read alike.
            Text("Парцели")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of the task's parcels, by name — and, when it has no outline, saying
/// so beside it, because the note under the map gives a count and not WHICH
/// parcel is missing from it.
private struct ParcelNameRow: View {
    let parcel: Parcel

    var body: some View {
        MetaRow {
            Text(parcel.name)
            if !parcel.isDrawable {
                MetaSeparator()
                Text("без очертания").foregroundStyle(Palette.secondaryText)
            }
        }
        .font(.body)
        // One stop, from the values — never the rendered `·`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence([parcel.name, parcel.isDrawable ? nil : "без очертания"]))
    }
}
