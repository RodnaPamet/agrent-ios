import Foundation

/// What «Машини» says about a machine, pure so tests pin it.
enum MachineWords {
    /// «Движи се», «Спряна, с включен двигател», «Спряна»; the moving flag is
    /// the server's, so the phone and the web agree.
    static func state(_ position: Machine.Position) -> String {
        if position.moving == true { return "Движи се" }
        if position.ignition == true { return "Спряна, с включен двигател" }
        return "Спряна"
    }

    /// «Движи се, 14:31» or «Спряна, 3 ноември»: the state and when it was
    /// last heard from. A machine never heard from says so.
    static func status(_ position: Machine.Position?, source: PositionSource? = nil, hasSourceField: Bool = false,
                       now: Date = Date()) -> String {
        guard let position else { return silence(source, known: hasSourceField) }
        guard let at = position.recordedAt else { return state(position) }
        return "\(state(position)), \(BgDate.messageTime(at, now: now))"
    }

    /// A machine with no position yet: no source at all, or one that has not
    /// reported, which want different things done about them.
    static func silence(_ source: PositionSource?, known: Bool) -> String {
        guard let source else {
            return known ? "Няма източник на местоположение" : "Още няма сигнал"
        }
        switch source.kind {
        case "TRACKER": return "Тракерът още не е подал сигнал"
        case "SIMULATED": return "Демо данни: още няма движение"
        default: return "Още няма данни от \(source.label)"
        }
    }

    /// The row's line: kind, source and state.
    static func row(_ machine: Machine, now: Date = Date()) -> String {
        [MachineKind.label(machine.type), machine.positionSource?.label,
         status(machine.lastPosition, source: machine.positionSource, hasSourceField: true, now: now)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Said over the whole screen when any machine is the simulator's, so a
    /// demo is never read as a real fleet.
    static let demoNotice = "Демо данни: машините и маршрутите тук са симулирани и не се записват в дневника."

    /// «45 мин», «2 ч 05 мин».
    static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(max(minutes, 0)) мин" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(String(format: "%02d", rest)) мин"
    }

    /// A worked parcel's line: «45 мин, 32 дка», and «вероятно» for a weak
    /// match, which is offered as a suggestion rather than a fact.
    static func worked(_ parcel: WorkedDay.Parcel) -> String {
        var parts = [duration(minutes: parcel.minutesWorked)]
        if let area = parcel.areaHa { parts.append(Area(hectares: area).text) }
        if let confidence = parcel.confidence, confidence < weakMatch { parts.append("вероятно") }
        return parts.joined(separator: ", ")
    }

    /// Below this the server's match is a guess worth naming as one.
    static let weakMatch = 0.5

    /// Why a day shows no route, or a note on the one it shows.
    static func trackNote(_ track: MachineTrack) -> String? {
        if !track.retained {
            return "Маршрутът за този ден вече не се пази: маршрутите се пазят 30 дни. Обработените парцели остават."
        }
        if track.points.isEmpty { return "Машината не е подавала сигнал този ден." }
        if track.truncated { return "Показана е само част от маршрута за деня." }
        return nil
    }

    /// The worked parcels are worked out each night. The server says
    /// whether that has run (`derived`); from before it said, today is taken
    /// as not yet.
    static func workedNote(_ worked: WorkedDay, isToday: Bool) -> String? {
        guard worked.parcels.isEmpty else { return nil }
        let pending = worked.derived.map { !$0 } ?? isToday
        return pending ? "Обработените парцели за този ден се изчисляват през нощта." : "Няма обработени парцели за този ден."
    }

    /// The mechanisator's notice (owner): which machines are tracked and who
    /// sees them, from the server's own list.
    static func notice(_ tracked: TrackedMachines) -> String {
        guard !tracked.machines.isEmpty else {
            return "Няма машини с GPS тракер в стопанството."
        }
        let names = tracked.machines.map(\.name).joined(separator: ", ")
        let who = tracked.visibleTo.compactMap(roleWord).joined(separator: " и ")
        let seen = who.isEmpty ? "" : " Местоположението им виждат \(who)."
        return "С GPS тракер са: \(names).\(seen) Вашият телефон не се проследява."
    }

    private static func roleWord(_ role: String) -> String? {
        switch role {
        case "OWNER": "собствениците"
        case "ADMIN": "администраторите"
        case "EDITOR": "редакторите"
        case "MECHANISATOR": "механизаторите"
        default: nil
        }
    }
}
