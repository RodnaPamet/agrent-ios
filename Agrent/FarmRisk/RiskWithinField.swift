import Foundation

/// How even the parcel is, in words (#562 stage 2; the owner chose words
/// first, 2026-11-07): how much of the visible part is under the stress
/// line, and whether a small very weak part is pulling the average down.
/// Pure, so `RiskWithinFieldTests` pins it.
///
/// Every figure is over the part the satellite could see
/// (`ParcelRisk.WithinField`), so the share says «от видимата част».
enum RiskWithinField {
    /// The mean this far below the median means a minority of very poor
    /// pixels drags it down: a patch to find, not a uniformly weak crop.
    static let draggedDown = 0.05
    /// From this spread between the weakest and the strongest tenth, the
    /// field is uneven enough to say so.
    static let uneven = 0.3
    /// Below this coverage the visible part is small enough to say how
    /// small (agreed with backend 1, in the spec's description). Near-full
    /// coverage is the normal case and stays quiet.
    ///
    /// The rest is said as «no clear view», never as cloud: the server masks
    /// snow and ice exactly as it masks cloud, and since its cloud rule
    /// keeps a pass by its own clear share, part of a parcel can simply
    /// have had no pass over it. A field under snow called «под облак» in
    /// January would discredit the number beside it.
    static let quietCoverage = 0.9

    static func sentences(_ field: ParcelRisk.WithinField, mean: Double?) -> [String] {
        var sentences: [String] = []
        let line = RiskTrendWords.index(field.threshold)
        if let share = field.belowThresholdShare {
            if share <= 0 {
                sentences.append("Нищо от видимата част на парцела не е под прага на стрес (NDVI \(line)).")
            } else {
                sentences.append("\(percent(share).capitalizedFirst) от видимата част на парцела е под прага на стрес (NDVI \(line)).")
            }
        }
        if let coverage = field.coverage, coverage < quietCoverage {
            sentences.append("Сателитът е видял само \(percent(coverage)) от парцела през периода; за останалото няма ясен изглед.")
        }
        if let mean, let median = field.ndviP50, median - mean >= draggedDown {
            sentences.append("Средната стойност е свалена от малка, много слаба част: огледайте полето за петна.")
        } else if let low = field.ndviP10, let high = field.ndviP90, high - low >= uneven {
            sentences.append("Полето е неравномерно: най-слабата десета част е под \(RiskTrendWords.index(low)), най-силната над \(RiskTrendWords.index(high)).")
        }
        return sentences
    }

    /// «Най-слаба е северозападната част на парцела (NDVI 0,39, с 0,14 под
    /// медианата).» Nil for an unknown zone code.
    static func weakest(_ weakest: ParcelRisk.Weakest) -> String? {
        let part: String
        switch weakest.zone {
        case "NW": part = "северозападната част"
        case "N": part = "северната част"
        case "NE": part = "североизточната част"
        case "W": part = "западната част"
        case "C": part = "средата"
        case "E": part = "източната част"
        case "SW": part = "югозападната част"
        case "S": part = "южната част"
        case "SE": part = "югоизточната част"
        default: return nil
        }
        let below = RiskTrendWords.index(abs(weakest.delta))
        return "Най-слаба е \(part) на парцела (NDVI \(RiskTrendWords.index(weakest.ndvi)), с \(below) под медианата)."
    }

    /// For the assistant: the figures themselves, said as over the visible part.
    static func facts(_ field: ParcelRisk.WithinField) -> String? {
        var parts: [String] = []
        if let p10 = field.ndviP10, let p50 = field.ndviP50, let p90 = field.ndviP90 {
            parts.append("P10 \(RiskTrendWords.index(p10)), медиана \(RiskTrendWords.index(p50)), P90 \(RiskTrendWords.index(p90))")
        }
        if let share = field.belowThresholdShare {
            parts.append("под прага \(RiskTrendWords.index(field.threshold)): \(percent(share))")
        }
        if let coverage = field.coverage {
            parts.append("видими \(percent(coverage)) от парцела")
        }
        guard !parts.isEmpty else { return nil }
        return "NDVI по видимата част на парцела: " + parts.joined(separator: "; ") + "."
    }

    /// «7 %», «под 1 %» for a trace, with a no-break space before «%».
    static func percent(_ share: Double) -> String {
        let nbsp = "\u{00A0}"
        if share > 0, share < 0.01 { return "под 1\(nbsp)%" }
        return "\(WeatherWords.number(min(share, 1) * 100, places: 0))\(nbsp)%"
    }
}
