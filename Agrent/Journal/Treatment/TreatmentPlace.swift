import MapKit

/// «Ново мероприятие», step two: where it was done (agrent-ios#293).
///
/// The crop is chosen first, and then every parcel of that crop on the farm
/// is offered — across blocks, because a crop is not confined to one, and a
/// spray of the wheat is a spray of all the wheat that was treated.
///
/// Pure, so the grouping, the total and the map's tap are read by tests.
enum TreatmentPlace {

    /// One parcel, with the block it is in: two blocks may each number a
    /// field «1», and the block is what tells them apart.
    struct Field: Identifiable, Hashable, Sendable {
        let parcel: Parcel
        let blockID: String
        let blockName: String
        var id: String { parcel.id }
    }

    /// One crop and its parcels.
    struct Crop: Identifiable, Hashable, Sendable {
        /// The Bulgarian name, folded — what groups the parcels.
        let key: String
        /// In Bulgarian, as everywhere a parcel's crop is shown.
        let label: String
        let fields: [Field]
        var id: String { key }
    }

    /// The farm's crops from its parcels, in Bulgarian alphabetical order,
    /// each with its parcels by block and then by name.
    ///
    /// A parcel with no crop is not offered: the entry is about a crop, and
    /// the ДНЕВНИК prints the crop above each field it lists.
    ///
    /// Grouped on the BULGARIAN name, case-blind — not on the stored value.
    /// The farm's crops come in more than one spelling: «Canola» and
    /// «Rapeseed» are both «Рапица», and «Wheat» and an imported «Пшеница»
    /// both «Пшеница». Grouped on the stored value, each pair was two
    /// identical menu entries, each holding part of the crop — and a spray of
    /// the wheat is a spray of all of it.
    static func crops(_ blocks: [(Location, [Parcel])]) -> [Crop] {
        var byKey: [String: (label: String, fields: [Field])] = [:]
        for (block, parcels) in blocks {
            for parcel in parcels {
                guard let raw = parcel.cropType?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { continue }
                let label = CommodityName.freeText(raw) ?? raw
                let key = label.lowercased()
                byKey[key, default: (label, [])].fields
                    .append(Field(parcel: parcel, blockID: block.id, blockName: block.name))
            }
        }
        return byKey
            .map { key, value in
                Crop(key: key, label: value.label, fields: value.fields.sorted(by: fieldOrder))
            }
            .sorted { $0.label.compare($1.label, locale: Locale(identifier: "bg_BG")) == .orderedAscending }
    }

    private static func fieldOrder(_ a: Field, _ b: Field) -> Bool {
        let bg = Locale(identifier: "bg_BG")
        let blocks = a.blockName.compare(b.blockName, options: [.numeric], locale: bg)
        if blocks != .orderedSame { return blocks == .orderedAscending }
        return a.parcel.name.compare(b.parcel.name, options: [.numeric], locale: bg) == .orderedAscending
    }

    /// The treated area: the chosen parcels' areas added up. A parcel with no
    /// area is counted as such, so the total is never presented as complete
    /// when it is not.
    struct Total: Equatable, Sendable {
        let area: Area
        let parcels: Int
        let withoutArea: Int
    }

    static func total(_ fields: [Field]) -> Total {
        let known = fields.compactMap(\.parcel.areaHa)
        return Total(area: Area(hectares: known.reduce(0, +)),
                     parcels: fields.count,
                     withoutArea: fields.count - known.count)
    }

    /// Every parcel's outlines, built ONCE per load: `mapPolygons` builds new
    /// `MKPolygon`s each time, and the map is redrawn on every toggle and
    /// every pan.
    static func outlines(_ crops: [Crop]) -> [String: [MKPolygon]] {
        var byID: [String: [MKPolygon]] = [:]
        for field in crops.flatMap(\.fields) where byID[field.id] == nil {
            byID[field.id] = field.parcel.geometry?.mapPolygons ?? []
        }
        return byID
    }

    /// The parcels under a tap on the map, smallest first — where two
    /// outlines overlap, the smaller is the one inside the other and the one
    /// most likely meant.
    static func fields(at coordinate: CLLocationCoordinate2D, in fields: [Field],
                       outlines: [String: [MKPolygon]]) -> [Field] {
        let point = MKMapPoint(coordinate)
        return fields
            .filter { field in (outlines[field.id] ?? []).contains { contains($0, point) } }
            .sorted { ($0.parcel.areaHa ?? .infinity) < ($1.parcel.areaHa ?? .infinity) }
    }

    /// Inside the outer ring and outside every hole, by ray casting in map
    /// points — planar there, which is what the outlines are drawn in.
    static func contains(_ polygon: MKPolygon, _ point: MKMapPoint) -> Bool {
        guard ringContains(polygon, point) else { return false }
        return !(polygon.interiorPolygons ?? []).contains { ringContains($0, point) }
    }

    private static func ringContains(_ ring: MKPolygon, _ point: MKMapPoint) -> Bool {
        let count = ring.pointCount
        guard count >= 3 else { return false }
        let points = ring.points()
        var inside = false
        var j = count - 1
        for i in 0..<count {
            let a = points[i], b = points[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
