import SwiftUI

struct ListingDetailView: View {
    let listing: ExchangeListing
    @State private var composing = false

    var body: some View {
        List {
            Section {
                LabeledContent("Култура") { Text(listing.commodity) }
                LabeledContent("Тип") { Text(listing.kind.label) }
                LabeledContent("Посока") { Text(listing.side.label) }
                if let quantity = listing.quantityTonnes {
                    LabeledContent("Количество") { Text("\(quantity) т") }
                }
                if let price = listing.pricePerTonne {
                    LabeledContent("Цена / т") {
                        Text("\(price) \(listing.priceCurrency ?? "")")
                    }
                }
                LabeledContent("Състояние") { Text(listing.status.label) }
            }

            if let region = listing.regionName {
                Section("Регион") {
                    LabeledContent(region) { Text(listing.regionCode ?? "") }
                }
            }

            // Public plaintext by design — sanitised server-side and
            // deliberately not encrypted, because cross-tenant readability is
            // what the marketplace is for. Absent when the seller wrote none.
            if let description = listing.description, !description.isEmpty {
                Section("Описание") { Text(description) }
            }
            if let seller = listing.sellerDisplayName, !seller.isEmpty {
                Section("Продавач") { Text(seller) }
            }

            Section {
                LabeledContent("Публикувана") {
                    Text(BgDate.full(listing.createdAt))
                }
                if let expires = listing.expiresAt {
                    LabeledContent("Валидна до") {
                        Text(BgDate.full(expires))
                    }
                }
            }

            if listing.isOwn {
                Section {
                    Text("Това е ваша обява.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if listing.isActive {
                Section {
                    Button("Изпрати запитване") { composing = true }
                }
            }
        }
        .navigationTitle(listing.commodity)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $composing) {
            InquiryComposeView(listing: listing)
        }
    }
}

/// Composing and sending an inquiry.
///
/// SHIPS FUNCTIONAL AND UNEXERCISED. Sending creates a production row and
/// emails the seller tenant's admins, so nothing in development or CI may tap
/// this: the owner's decision is that the first real operator send is the
/// first real test. The button works for them; it has never been pressed here.
struct InquiryComposeView: View {
    let listing: ExchangeListing

    @Environment(\.dismiss) private var dismiss
    @State private var composer = InquiryComposer()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(listing.commodity).font(.headline)
                    Text(summary(side: listing.side, kind: listing.kind,
                                 quantity: listing.quantityTonnes,
                                 price: listing.pricePerTonne,
                                 currency: listing.priceCurrency))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Съобщение") {
                    TextEditor(text: $composer.message)
                        .frame(minHeight: 120)
                        .disabled(composer.phase != .editing)
                }

                switch composer.phase {
                case .sent:
                    Section {
                        Label("Запитването е изпратено.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Продавачът ще види контактите ви само ако приеме запитването.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Section { Text(message).foregroundStyle(.red) }
                case .editing, .sending:
                    EmptyView()
                }
            }
            .navigationTitle("Ново запитване")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(composer.phase == .sending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(composer.phase == .sent ? "Готово" : "Отказ") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if composer.phase == .sending {
                        ProgressView()
                    } else if composer.phase != .sent {
                        Button("Изпрати") {
                            Task { await composer.send(listingID: listing.id) }
                        }
                        .disabled(!composer.canSend)
                    }
                }
            }
        }
    }
}
