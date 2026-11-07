import MapKit
import SwiftUI

/// «Вятър и налягане»: the wind and the pressure systems over Bulgaria for
/// the next 48 hours, moving (owner, 2026-11-06: "the winds and the
/// cyclones dynamics", from Open-Meteo).
///
/// ── What is on the map ──
///
/// - An arrow per grid place, every half degree, pointing where the wind
///   blows, coloured by its strength (the legend says the bands).
/// - The isobars every 2 hPa: close together is strong wind, rings are a
///   pressure system.
/// - «Н» at a low (a cyclone) and «В» at a high, with their pressure.
/// - The block the map was opened from, as a dot, so the farmer sees what
///   is coming at their own field.
///
/// The hour moves with the slider, or by itself with ▶, an hour every half
/// second: a low crossing the country in a few seconds is the "dynamics".
struct WindMapView: View {
    /// The block it was opened from, for the dot.
    let place: String
    let latitude: Double
    let longitude: Double
    var source: any WindFieldSource = WindFieldSources.current

    init(place: String, latitude: Double, longitude: Double,
         source: any WindFieldSource = WindFieldSources.current) {
        self.place = place
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
        _region = State(initialValue: Self.opening(latitude: latitude, longitude: longitude))
    }

    /// Where it opens (owner, 2026-11-07: "needs to open a bit more zoomed
    /// in"): on the block, about a degree across, the reach of a farm's own
    /// weather (the Danube to the Balkan from a block near Pleven). The
    /// whole country is a pinch away.
    nonisolated static func opening(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                           span: MKCoordinateSpan(latitudeDelta: 1.1, longitudeDelta: 1.0))
    }

    @State private var state: LoadState<WindField> = .loading
    @State private var hour = 0
    @State private var playing = false
    /// What the map shows, for the streaks' projection.
    @State private var region: MKCoordinateRegion
    @State private var particles = WindParticles()
    @Environment(\.dismiss) private var dismiss
    /// Reduce Motion on: still arrows instead of moving streaks.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content
                .inlineTitle("Вятър и налягане")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Затвори") { dismiss() }
                            .accessibilityInputLabels(A11y.Spoken.close)
                    }
                }
                .task { await load() }
                .task(id: playing) { await play() }
        }
    }

    private func load() async {
        do {
            let field = try await source.field()
            particles.reset(latitudes: field.latitudes, longitudes: field.longitudes)
            state = .loaded(field, .fresh)
        } catch {
            state = .failed("Картата на вятъра не може да се зареди в момента.")
        }
    }

    /// ▶: an hour every half second, from wherever the slider is, to the
    /// end, then it stops.
    private func play() async {
        guard playing, let field = state.value else { return }
        if hour >= field.hours.count - 1 { hour = 0 }
        while playing, hour < field.hours.count - 1 {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, playing else { return }
            hour += 1
        }
        playing = false
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Зареждане…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await load() }
        case .loaded(let field, _):
            map(field)
                .safeAreaInset(edge: .bottom, spacing: 0) { controls(field) }
        }
    }

    // MARK: - The map

    private func map(_ field: WindField) -> some View {
        let shown = min(hour, max(field.hours.count - 1, 0))
        let grid = field.pressure.indices.contains(shown) ? field.pressure[shown] : []
        let isobars = grid.isEmpty ? [] : PressureAnalysis.isobars(grid, latitudes: field.latitudes,
                                                                  longitudes: field.longitudes)
        let centres = grid.isEmpty ? [] : PressureAnalysis.centres(grid, latitudes: field.latitudes,
                                                                   longitudes: field.longitudes)
        return Map(initialPosition: .region(Self.opening(latitude: latitude, longitude: longitude)),
                   interactionModes: [.pan, .zoom]) {
            ForEach(isobars) { isobar in
                MapPolyline(coordinates: isobar.path.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(Palette.secondaryText.opacity(0.8), lineWidth: 1)
            }
            // Still arrows only under Reduce Motion; the streaks over the
            // map are the wind otherwise.
            if reduceMotion {
                ForEach(field.points(at: shown)) { point in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                        WindArrow(windMS: point.windMS, from: point.windFrom)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(centres) { centre in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude)) {
                    CentreMark(centre: centre)
                }
                .annotationTitles(.hidden)
            }
            Annotation(place, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Palette.Surface.page, lineWidth: 2))
                    .accessibilityLabel("\(place) на картата")
            }
        }
        // Muted, so the moving wind is what the eye follows.
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .continuous) { context in region = context.region }
        .overlay {
            // Clouds and rain under the wind (owner, 2026-11-07).
            ZStack {
                CloudLayer(field: field, hour: shown, region: { region })
                if !reduceMotion {
                    WindFlowLayer(wind: WindVectors(field, hour: shown), region: { region }, particles: particles)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary(field, at: shown, centres: centres))
    }

    /// Bulgaria with its margin, as the grid covers it.
    nonisolated static let bulgaria = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.75, longitude: 25.5),
        span: MKCoordinateSpan(latitudeDelta: 4.8, longitudeDelta: 8.4))

    /// What the map says to VoiceOver, which cannot see arrows: the hour,
    /// the strongest wind and where, and each centre.
    private func summary(_ field: WindField, at hour: Int, centres: [PressureAnalysis.Centre]) -> String {
        let points = field.points(at: hour)
        let strongest = points.max { $0.windMS < $1.windMS }
        return A11y.sentence([
            field.hours.indices.contains(hour) ? WindMapWords.hourText(field.hours[hour]) : nil,
            strongest.map { "най-силен вятър \(WeatherWords.speed($0.windMS))" },
        ] + centres.map { WindMapWords.centreSpoken($0) })
    }

    // MARK: - The hour

    private func controls(_ field: WindField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(playing ? "Пауза" : "Пусни")
                .accessibilityInputLabels(playing ? A11y.spokenNames("Пауза", "Pause") : A11y.spokenNames("Пусни", "Play"))
                VStack(alignment: .leading, spacing: 2) {
                    if field.hours.indices.contains(hour) {
                        Text(WindMapWords.hourText(field.hours[hour]))
                            .font(.subheadline.weight(.semibold))
                    }
                    Slider(value: Binding(get: { Double(hour) }, set: { hour = Int($0.rounded()) }),
                           in: 0...Double(max(field.hours.count - 1, 1)), step: 1)
                        .tint(Palette.accent)
                        .accessibilityLabel("Час")
                        .accessibilityValue(field.hours.indices.contains(hour)
                                            ? WindMapWords.hourText(field.hours[hour]) : "")
                }
            }
            WindLegend()
            Link("Данни: Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com")!)
                .font(.caption2)
                .accessibilityInputLabels(A11y.spokenNames("Open-Meteo"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .solidBar(hairline: .top)
    }
}

/// An arrow where the wind blows TO, longer and stronger in colour as it
/// rises. Hidden from VoiceOver: the map's summary says it in words.
private struct WindArrow: View {
    let windMS: Double
    let from: Double

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 10 + min(windMS, 20) * 0.7, weight: .bold))
            .foregroundStyle(WindMapWords.color(windMS))
            .rotationEffect(.degrees(from + 180))
            .accessibilityHidden(true)
    }
}

/// «Н» at a low, «В» at a high, with the pressure under it.
private struct CentreMark: View {
    let centre: PressureAnalysis.Centre

    var body: some View {
        VStack(spacing: 0) {
            Text(centre.kind == .low ? "Н" : "В")
                .font(.title2.weight(.heavy))
                .foregroundStyle(centre.kind == .low ? Palette.error : Palette.accent)
            Text(WeatherWords.number(centre.hPa, places: 0))
                .font(.caption2.weight(.semibold))
        }
        .padding(4)
        .background(Palette.Surface.page.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

/// The bands the arrows are coloured in.
private struct WindLegend: View {
    var body: some View {
        // Two rows: on one, «облаци» broke as «облац / и» (measured).
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ForEach(WindMapWords.bands, id: \.label) { band in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up").foregroundStyle(band.color)
                        Text(band.label)
                    }
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Palette.Weather.cloud).frame(width: 10, height: 10)
                    Text("облаци")
                }
                HStack(spacing: 4) {
                    Circle().fill(Palette.Weather.rain).frame(width: 10, height: 10)
                    Text("дъжд")
                }
                Text("Н ниско, В високо налягане")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .font(.caption2)
        .foregroundStyle(Palette.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Цветът на стрелката е силата на вятъра. Сивото е облачност, тъмното е дъжд. Н е ниско налягане, циклон. В е високо налягане.")
    }
}

/// The map's words and colours. Pure, so tests pin them.
enum WindMapWords {
    /// «сб, 7 ноември, 14 ч».
    static func hourText(_ date: Date) -> String {
        "\(BgDate.weekdayDay(date)), \(BgDate.hourMark(date))"
    }

    /// «Ниско налягане 1002 hPa», for VoiceOver.
    static func centreSpoken(_ centre: PressureAnalysis.Centre) -> String {
        "\(centre.kind == .low ? "Ниско налягане, циклон" : "Високо налягане") \(WeatherWords.pressure(centre.hPa))"
    }

    struct Band { let label: String; let color: Color; let upTo: Double }

    /// Calm enough to spray, a breeze, strong, and a gale.
    static let bands: [Band] = [
        Band(label: "до 4 м/с", color: Palette.ChartSeries.colors[0], upTo: 4),
        Band(label: "4–8", color: Palette.ChartSeries.colors[2], upTo: 8),
        Band(label: "8–12", color: Palette.warning, upTo: 12),
        Band(label: "над 12", color: Palette.error, upTo: .infinity),
    ]

    static func color(_ windMS: Double) -> Color {
        bands.first { windMS < $0.upTo }?.color ?? Palette.error
    }
}
