import MapKit
import UIKit

/// A name on the orthophoto: a parcel's, or a physical block's number
/// (#458). Text only, as a ДФЗ map prints them, never a pin.
final class OrthoMapLabel: NSObject, MKAnnotation {
    enum Kind { case parcel, block }

    let kind: Kind
    let text: String
    let coordinate: CLLocationCoordinate2D

    init(kind: Kind, text: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.text = text
        self.coordinate = coordinate
    }

    // The parcel's name is what VoiceOver reads; a block number is the
    // Ministry's reference, read as such.
    var title: String? { kind == .parcel ? text : "Физически блок \(text)" }
}

/// The label itself: white text on a dark halo, which reads over any photo.
///
/// COLLISIONS ARE MAPKIT'S. Every label declares a rectangle collision and a
/// priority: a parcel's name outranks a block's number, so where two would
/// overlap MapKit hides the block's first, and a block's numbers come back
/// as the map is zoomed in and they have room.
final class OrthoMapLabelView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle
        canShowCallout = false
        label.textColor = UIColor(Palette.Map.label)
        label.backgroundColor = UIColor(Palette.Map.labelHalo).withAlphaComponent(0.7)
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ annotation: OrthoMapLabel) {
        let parcel = annotation.kind == .parcel
        // Scales with Dynamic Type, capped where a label would cover the
        // field it names; the list under the map is the unbounded channel.
        let style: UIFont.TextStyle = parcel ? .footnote : .caption2
        let base = UIFont.preferredFont(forTextStyle: style)
        let font = parcel ? UIFont.systemFont(ofSize: base.pointSize, weight: .semibold) : base
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: parcel ? 26 : 20)
        label.text = annotation.text
        displayPriority = parcel ? .defaultHigh : .defaultLow
        let fitted = label.sizeThatFits(CGSize(width: 220, height: 200))
        let size = CGSize(width: min(fitted.width + 8, 228), height: fitted.height + 4)
        frame = CGRect(origin: .zero, size: size)
        label.frame = bounds
        centerOffset = .zero
        isAccessibilityElement = true
        accessibilityLabel = annotation.title
    }
}
