import Foundation

/// An area, shown in DECARES because that is what a Bulgarian farm works in.
///
/// ── The app was mixing units on one screen ──
///
/// The server sends parcel areas as hectares — the field is literally
/// `areaHa`, and `YieldRecord.areaHa` is `Decimal(12,4)`. But its dose
/// units are already decares («г/дка, кг/дка, л/дка, мл/дка», see
/// `OperationModels`) and so are the calculator's own figures (`areaDca`,
/// `standingValuePerDca`, `marginPerDca`). So Локации showed a field size
/// in hectares directly under a spray sheet quoting a dose per decare, and
/// a farmer checking whether a tank mix was right had to carry a ×10
/// between two numbers on the same screen. That is the arithmetic a wrong
/// spray rate is made of.
///
/// This completes a convention the rest of the app already had rather than
/// inventing one.
///
/// ── Why a type and not a formatter ──
///
/// The hectares are PRIVATE and there is no `hectares` property. A second
/// `× 10` is therefore unreachable: 324 дка and 3 240 дка would be obvious,
/// but 32,4 against 324 on a screen with no other area is not, and that is
/// the mistake this shape makes impossible rather than merely unlikely.
///
/// It also means the unit cannot be lost in transit. `(Parcel, Double?)`
/// crossing a closure carries no unit and the compiler has nothing to say;
/// `(Parcel, Area?)` means a half-finished conversion stops compiling and
/// walks you to every file that needs changing.
///
/// ── The wire stays hectares ──
///
/// Nothing is converted at decode. `Parcel.areaHa` keeps its honest name
/// and its honest unit, because a property called `areaHa` holding decares
/// is exactly the trap the next reader falls into. Values leave through
/// `wireHectares`, which is named so that sending the wrong thing has to be
/// typed out in full.
struct Area: Equatable, Sendable {
    /// 1 hectare = 10 decares = 10 000 m². Exact, not a rounding.
    private static let decaresPerHectare: Double = 10

    private let hectares: Double

    /// The one way in from a decoded model.
    init(hectares: Double) { self.hectares = hectares }

    /// The one way out to the wire.
    var wireHectares: Double { hectares }

    var decares: Double { hectares * Self.decaresPerHectare }

    /// «324 дка» — what a row shows.
    var text: String { "\(number) дка" }

    /// The number alone, for a field that carries its own unit label.
    var number: String { Num.text(decares) }

    /// «324 декара» — SPOKEN, and the reason this is a separate string.
    ///
    /// VoiceOver reads «дка» as three letters. The visible abbreviation and
    /// the spoken word are different renderings of one fact, which is the
    /// rule this app already follows for the middle dot that used to be
    /// read aloud as "middle dot".
    ///
    /// Rounded to whole decares for speech: someone hearing a field size
    /// wants «324 декара», not «324 цяло и 57 стотни декара».
    var spoken: String {
        Plural.bg(Int(decares.rounded()), "декар", "декара")
    }

    /// Reads DECARES, and accepts a comma as well as a full stop.
    ///
    /// The decimal pad on a Bulgarian keyboard gives a comma, and this app
    /// PRINTS commas — `number` renders «324,57», which is what prefills an
    /// input. Parsing only a full stop would reject the app's own output
    /// the moment anyone edited it.
    static func parse(decares text: String) -> Area? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0, value.isFinite
        else { return nil }
        return Area(hectares: value / decaresPerHectare)
    }

    /// Below this, two figures are the same field rather than a correction.
    ///
    /// STATED ONCE, because as a bare literal it is the quiet trap: `0.005`
    /// is 50 m² read as hectares and 5 m² read as decares, and nothing at
    /// the call site says which was meant. It was already two different
    /// numbers in two files.
    static let registerTolerance = Area(hectares: 0.005)

    func differs(from other: Area, byMoreThan tolerance: Area = .registerTolerance) -> Bool {
        abs(hectares - other.hectares) > tolerance.hectares
    }
}
