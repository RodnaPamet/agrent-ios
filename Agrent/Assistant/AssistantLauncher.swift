import Observation
import SwiftUI

/// The assistant's button, lower right on every screen of a stack (#483,
/// owner 2026-10-31: «lower right, as on the web»), above the tab bar and
/// above a screen's own bottom bar — «Нов разход», «Ново мероприятие», the
/// five seconds of «Отмени». Shown only while the server offers it
/// (`AssistantAPI.flag`), which the phone re-reads on every return to the
/// foreground, so it can go between one use and the next.
struct AssistantLauncher: View {
    /// The bar tab this stack belongs to: the page the assistant is told
    /// the person is on. nil in a sheet's stack, which sends no page.
    let surface: AppSurface?

    @State private var open = false
    @State private var store = AssistantStore()
    @State private var flags = FeatureFlags.shared

    var body: some View {
        if flags.isOn(AssistantAPI.flag) {
            Button {
                open = true
            } label: {
                Label(AssistantText.title, systemImage: "sparkles")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 52, height: 52)
                    .background(Palette.accent, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AssistantText.title)
            .accessibilityInputLabels(A11y.spokenNames("Асистент", "Assistant"))
            .accessibilityShowsLargeContentViewer {
                Label(AssistantText.title, systemImage: "sparkles")
            }
            .sheet(isPresented: $open) {
                AssistantSheet(store: store, context: surface.flatMap(AssistantPageContext.surface))
            }
        }
    }
}

/// How much of a stack's bottom its screens' bars take, so the assistant's
/// button sits above them rather than on them.
///
/// Each bottom bar (`solidBar(hairline: .top)`) reports its height while it
/// is on screen and withdraws it when it goes. A stack's screens below the
/// top one are off screen, and so is another tab's, so what is summed is
/// what is drawn: a screen's gold button and, while it shows, the «Отмени»
/// bar above it.
@MainActor
@Observable
final class BottomChrome {
    private var heights: [UUID: CGFloat] = [:]

    var height: CGFloat { heights.values.reduce(0, +) }

    func report(_ id: UUID, _ height: CGFloat) {
        if heights[id] != height { heights[id] = height }
    }

    func withdraw(_ id: UUID) {
        heights[id] = nil
    }
}

extension View {
    /// A stack's assistant button, lower right, above its screens' bottom
    /// bars (`BottomChrome`), and staying put while the keyboard is up.
    func assistantLauncher(surface: AppSurface?, chrome: BottomChrome) -> some View {
        environment(chrome)
            .overlay(alignment: .bottomTrailing) {
                AssistantLauncher(surface: surface)
                    .padding(.trailing, 16)
                    .padding(.bottom, chrome.height + 12)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
    }
}
