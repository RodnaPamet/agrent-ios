import SwiftUI

/// Apple Weather's mark and the link to its sources — required by the service
/// beside anything shown from it. Shared by the weather sheet and Табло's
/// weather card (#671), so the two cannot drift.
struct WeatherAttribution: View {
    let attribution: WeatherReport.Attribution?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let attribution {
            VStack(alignment: .leading, spacing: 6) {
                if let mark = scheme == .dark ? attribution.markDarkURL : attribution.markLightURL {
                    AsyncImage(url: mark) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(attribution.serviceName).font(.footnote)
                    }
                    .frame(height: 14)
                    .accessibilityLabel(attribution.serviceName)
                }
                if let legal = attribution.legalPageURL {
                    Link("Източници на данните", destination: legal)
                        .font(.footnote)
                        .accessibilityInputLabels(A11y.spokenNames("Източници на данните", "Data sources"))
                }
            }
        }
    }
}
