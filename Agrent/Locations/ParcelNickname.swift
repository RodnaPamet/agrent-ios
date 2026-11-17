import Foundation

/// The farmer's own name for a parcel, and the number it stands beside
/// (owner, 2026-11-17, #667: "rename the parcels with a swipe so that he can
/// easily relate to their names in the assistant").
///
/// A NICKNAME, not a rename of the record: the ДНЕВНИК keeps printing the
/// field number and the cadastral number. So every place that names a parcel
/// asks for its `title`, and shows the `number` beside it when the two
/// differ — the paperwork stays recognisable from the screen.
enum ParcelNickname {
    /// A nickname worth showing: trimmed, and nil when blank or when it only
    /// repeats the number.
    static func shown(_ displayName: String?, number: String) -> String? {
        guard let nick = displayName?.recorded, nick != number.recorded else { return nil }
        return nick
    }

    /// The longest nickname the server takes.
    static let maxLength = 120
}

extension Parcel {
    /// The farmer's nickname, or nil.
    var nickname: String? { ParcelNickname.shown(displayName, number: name) }
    /// What to call it: the nickname, else the field number.
    var title: String { nickname ?? name }
}

extension ParcelHistory.ParcelRef {
    var nickname: String? { ParcelNickname.shown(displayName, number: name) }
}
