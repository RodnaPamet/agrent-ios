import MapKit
import SwiftUI

/// The isobars and the centres of low and high pressure, on a block's own
/// map (owner, 2026-11-07: "bring the slider and the other removed elements
/// to the Apple map when the button is clicked"): every 2 hPa, «Н» at a low
/// (a cyclone) and «В» at a high, with their pressure, for the hour the
/// slider is on.
///
/// Worked out once per hour (`PressureAnalysis`), drawn every frame from the
/// map's own region as the streaks are, so they stay on the land while the
/// map pans. Light lines with a dark edge, as the satellite photograph can
/// be any colour.
struct PressureLayer: View {
    let isobars: [PressureAnalysis.Isobar]
    let centres: [PressureAnalysis.Centre]
    let region: () -> MKCoordinateRegion

    init(field: WindField, hour: Int, region: @escaping () -> MKCoordinateRegion) {
        let grid = field.pressure.indices.contains(hour) ? field.pressure[hour] : []
        isobars = grid.isEmpty ? [] : PressureAnalysis.isobars(grid, latitudes: field.latitudes,
                                                               longitudes: field.longitudes)
        centres = grid.isEmpty ? [] : PressureAnalysis.centres(grid, latitudes: field.latitudes,
                                                               longitudes: field.longitudes)
        self.region = region
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                let projection = WindProjection(region: region(), size: size)
                var lines = Path()
                for isobar in isobars {
                    let points = isobar.path.map { projection.point(latitude: $0.latitude, longitude: $0.longitude) }
                    lines.addLines(points)
                }
                context.stroke(lines, with: .color(Palette.Map.labelHalo.opacity(0.5)), lineWidth: 2.6)
                context.stroke(lines, with: .color(Palette.Map.label.opacity(0.75)), lineWidth: 1.1)
                for centre in centres {
                    let at = projection.point(latitude: centre.latitude, longitude: centre.longitude)
                    guard at.x > -40, at.y > -40, at.x < size.width + 40, at.y < size.height + 40 else { continue }
                    let letter = Text(centre.kind == .low ? "Н" : "В")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(centre.kind == .low ? Palette.error : Palette.accent)
                    let value = Text(WeatherWords.number(centre.hPa, places: 0))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.Map.label)
                    context.fill(Path(roundedRect: CGRect(x: at.x - 22, y: at.y - 22, width: 44, height: 46),
                                      cornerRadius: 8),
                                 with: .color(Palette.Map.labelHalo.opacity(0.55)))
                    context.draw(letter, at: CGPoint(x: at.x, y: at.y - 6))
                    context.draw(value, at: CGPoint(x: at.x, y: at.y + 14))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The block map's wind words: the hour, and the centres said aloud.
enum WindMapWords {
    /// «сб, 7 ноември, 14 ч».
    static func hourText(_ date: Date) -> String {
        "\(BgDate.weekdayDay(date)), \(BgDate.hourMark(date))"
    }

    /// «Ниско налягане, циклон 1002 hPa», for VoiceOver.
    static func centreSpoken(_ centre: PressureAnalysis.Centre) -> String {
        "\(centre.kind == .low ? "Ниско налягане, циклон" : "Високо налягане") \(WeatherWords.pressure(centre.hPa))"
    }
}

/// The streaks' strength, the clouds, rain and the pressure centres, on two
/// rows: on one, «облаци» broke as «облац / и» (measured).
struct WindLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ForEach(WindBands.bands, id: \.label) { band in
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
        .accessibilityLabel("Цветът на чертите е силата на вятъра. Сивото е облачност, тъмното е дъжд. Линиите са изобари. Н е ниско налягане, циклон. В е високо налягане.")
    }
}
