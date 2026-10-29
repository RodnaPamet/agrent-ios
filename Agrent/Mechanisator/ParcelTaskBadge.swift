import MapKit
import UIKit

/// How many of the mechanisator's current tasks are on a parcel, drawn on
/// the parcel (#465, owner 2026-10-29: «parcels have task numbers on them»).
final class ParcelTaskBadge: NSObject, MKAnnotation {
    let parcelName: String
    let count: Int
    let coordinate: CLLocationCoordinate2D

    init(parcelName: String, count: Int, coordinate: CLLocationCoordinate2D) {
        self.parcelName = parcelName
        self.count = count
        self.coordinate = coordinate
    }

    /// What VoiceOver reads on the map: the parcel and its count. The list
    /// under the map says the same, and is where a parcel is opened.
    var title: String? { A11y.sentence([parcelName, Plural.bg(count, "задача", "задачи")]) }
}

/// The number in a gold disc, with the ink the app writes on gold
/// (`Palette.onAccent`) and a halo that reads over any photo.
///
/// NOT INTERACTIVE. A tap on the number lands on the parcel under it, which
/// the map's own tap opens; a badge that took the touch would make the
/// middle of a field the one place it could not be opened from.
final class ParcelTaskBadgeView: MKAnnotationView {
    static let reuse = "parcelTaskBadge"
    private let label = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        canShowCallout = false
        collisionMode = .circle
        // Every count shows: hiding one where two parcels are close would
        // hide work.
        displayPriority = .required
        label.textAlignment = .center
        label.textColor = UIColor(Palette.onAccent)
        label.backgroundColor = UIColor(Palette.accent)
        label.layer.borderColor = UIColor(Palette.Map.labelHalo).cgColor
        label.layer.borderWidth = 2
        label.layer.masksToBounds = true
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ badge: ParcelTaskBadge) {
        // Scales with Dynamic Type, capped where a disc would cover the
        // field it counts; the list under the map is the unbounded channel.
        let base = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .bold)
        label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base, maximumPointSize: 24)
        label.text = "\(badge.count)"
        let fitted = label.sizeThatFits(CGSize(width: 80, height: 80))
        let side = max(fitted.height + 8, fitted.width + 12, 26)
        frame = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        label.frame = bounds
        label.layer.cornerRadius = side / 2
        centerOffset = .zero
        isAccessibilityElement = true
        accessibilityLabel = badge.title
    }
}
