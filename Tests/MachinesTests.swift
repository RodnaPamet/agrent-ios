import XCTest
@testable import Agrent

/// «Машини» (#574): what the screens say, and what they read, against
/// agri-saas #2948's contract. IMEIs here are synthetic, made to pass the
/// check digit; nothing here calls the server.
final class MachinesTests: XCTestCase {

    // MARK: - IMEI

    func testAnIMEIIsFifteenDigitsWithItsCheckDigit() {
        XCTAssertTrue(IMEI.isValid("350000000000006"))
        XCTAssertTrue(IMEI.isValid("86 0000 0000 00017"), "spaces as a label prints them")
        XCTAssertTrue(IMEI.isValid("860000-000000017"))
        XCTAssertFalse(IMEI.isValid("350000000000007"), "a typo in one digit")
        XCTAssertFalse(IMEI.isValid("35000000000006"), "fourteen digits")
        XCTAssertFalse(IMEI.isValid("3500000000000060"), "sixteen digits")
        XCTAssertFalse(IMEI.isValid("35000000000000a"))
        XCTAssertFalse(IMEI.isValid("３５0000000000006"), "only ASCII digits")
        XCTAssertEqual(IMEI.normalised("86 0000-0000 00017"), "860000000000017")
    }

    // MARK: - Words

    private func position(moving: Bool?, ignition: Bool?, at: String? = "2026-11-09T14:31:00+02:00") -> Machine.Position {
        .init(lat: 42.5, lon: 25.1, recordedAt: at.flatMap(BgDate.parseInstant), speedKph: nil,
              ignition: ignition, moving: moving)
    }

    func testTheStateIsTheServersMovingFlag() {
        XCTAssertEqual(MachineWords.state(position(moving: true, ignition: true)), "Движи се")
        XCTAssertEqual(MachineWords.state(position(moving: false, ignition: true)), "Спряна, с включен двигател")
        XCTAssertEqual(MachineWords.state(position(moving: false, ignition: false)), "Спряна")
        XCTAssertEqual(MachineWords.status(nil), "Още няма сигнал", "no source field: says nothing it doesn't know")
        XCTAssertEqual(MachineWords.status(position(moving: false, ignition: nil, at: nil)), "Спряна")
    }

    /// Where a position comes from, and why a machine is dark: no source at
    /// all is not a source gone quiet (owner, 2026-11-10).
    func testThePositionSourceIsNamed() {
        XCTAssertEqual(PositionSource(kind: "TELEMATICS", provider: "JOHN_DEERE").label, "John Deere (JDLink)")
        XCTAssertEqual(PositionSource(kind: "TELEMATICS", provider: "CNH").label, "Case IH / New Holland (AFS Connect)")
        XCTAssertEqual(PositionSource(kind: "TELEMATICS", provider: "CLAAS").label, "CLAAS (CLAAS connect)")
        XCTAssertEqual(PositionSource(kind: "TELEMATICS", provider: "AGCO").label, "Fendt / Massey Ferguson (AGCO Connect)")
        XCTAssertEqual(PositionSource(kind: "TELEMATICS", provider: "NEW").label, "Телематика на производителя")
        XCTAssertEqual(PositionSource(kind: "TRACKER", provider: nil).label, "GPS тракер")
        XCTAssertEqual(PositionSource(kind: "SIMULATED", provider: nil).label, "Демо данни")
        XCTAssertEqual(MachineWords.silence(nil, known: true), "Няма източник на местоположение")
        XCTAssertEqual(MachineWords.silence(.init(kind: "TRACKER", provider: nil), known: true), "Тракерът още не е подал сигнал")
        XCTAssertEqual(MachineWords.silence(.init(kind: "TELEMATICS", provider: "CLAAS"), known: true),
                       "Още няма данни от CLAAS (CLAAS connect)")
        let deere = Machine(assetId: "a1", name: "T", type: "TRACTOR",
                            lastPosition: position(moving: true, ignition: true, at: nil),
                            positionSource: .init(kind: "TELEMATICS", provider: "JOHN_DEERE"))
        XCTAssertEqual(MachineWords.row(deere), "Трактор, John Deere (JDLink), Движи се")
    }

    func testDurationsAndWorkedLines() {
        XCTAssertEqual(MachineWords.duration(minutes: 45), "45 мин")
        XCTAssertEqual(MachineWords.duration(minutes: 125), "2 ч 05 мин")
        XCTAssertEqual(MachineWords.duration(minutes: 120), "2 ч")
        let sure = WorkedDay.Parcel(parcelId: "p1", name: "SYNTH-1", minutesWorked: 45, areaHa: 3.2, confidence: 0.9)
        XCTAssertEqual(MachineWords.worked(sure), "45 мин, \(Area(hectares: 3.2).text)")
        let weak = WorkedDay.Parcel(parcelId: "p2", name: "SYNTH-2", minutesWorked: 8, areaHa: nil, confidence: 0.3)
        XCTAssertEqual(MachineWords.worked(weak), "8 мин, вероятно", "a weak match is a suggestion")
    }

    /// «Нов запис от тези парцели» ticks the confident matches only; a weak
    /// one (a road along the edge) is left for the person (backend 1,
    /// 2026-11-13). No area is ever computed: the server sends none.
    func testTheDraftTicksOnlyConfidentParcels() {
        let sure = WorkedDay.Parcel(parcelId: "p1", name: "SYNTH-1", minutesWorked: 45, areaHa: nil, confidence: 0.9)
        let edge = WorkedDay.Parcel(parcelId: "p2", name: "SYNTH-2", minutesWorked: 8, areaHa: nil, confidence: 0.3)
        let atBar = WorkedDay.Parcel(parcelId: "p3", name: "SYNTH-3", minutesWorked: 20, areaHa: nil, confidence: 0.5)
        let day = WorkedDay(date: "2026-11-13", parcels: [sure, edge, atBar], derived: true)
        XCTAssertEqual(MachineWords.preselected(day), ["p1", "p3"])
        XCTAssertEqual(MachineWords.worked(sure), "45 мин", "no area when the server sends none")
    }

    /// Past 30 days the route is gone, which is not "did not move".
    func testTheRoutesThreeSilences() {
        XCTAssertEqual(MachineWords.trackNote(MachineTrack(date: "2026-09-01", points: [], retained: false)),
                       "Маршрутът за този ден вече не се пази: маршрутите се пазят 30 дни. Обработените парцели остават.")
        XCTAssertEqual(MachineWords.trackNote(MachineTrack(date: "2026-11-08", points: [])),
                       "Машината не е подавала сигнал този ден.")
        let one = MachineTrack.Point(lat: 42.5, lon: 25.1, recordedAt: nil, speedKph: 9, ignition: true)
        XCTAssertEqual(MachineWords.trackNote(MachineTrack(date: "2026-11-08", points: [one], truncated: true)),
                       "Показана е само част от маршрута за деня.")
        XCTAssertNil(MachineWords.trackNote(MachineTrack(date: "2026-11-08", points: [one])))
    }

    func testTodaysWorkedParcelsWaitForTheNight() {
        let none = WorkedDay(date: "2026-11-09", parcels: [])
        XCTAssertEqual(MachineWords.workedNote(none, isToday: true), "Обработените парцели за този ден се изчисляват през нощта.")
        // The server's `derivedAt` decides when it says: not run yet, or ran
        // and found nothing, whatever the day.
        XCTAssertEqual(MachineWords.workedNote(WorkedDay(date: "2026-11-08", parcels: [], derived: false), isToday: false),
                       "Обработените парцели за този ден се изчисляват през нощта.")
        XCTAssertEqual(MachineWords.workedNote(WorkedDay(date: "2026-11-09", parcels: [], derived: true), isToday: true),
                       "Няма обработени парцели за този ден.")
        XCTAssertEqual(MachineWords.workedNote(none, isToday: false), "Няма обработени парцели за този ден.")
        let some = WorkedDay(date: "2026-11-09", parcels: [.init(parcelId: "p", name: "P", minutesWorked: 5, areaHa: nil, confidence: nil)])
        XCTAssertNil(MachineWords.workedNote(some, isToday: true))
    }

    /// A task with several tracked machines says so, and names the one shown.
    func testATasksMachineSaysWhichAndHowManyMore() {
        let moving = position(moving: true, ignition: true, at: nil)
        XCTAssertEqual(MachineWords.taskMachine(.init(name: "Трактор 1", lastPosition: moving, locatableCount: 1), moving),
                       "Трактор 1: Движи се")
        XCTAssertEqual(MachineWords.taskMachine(.init(name: "Трактор 1", lastPosition: moving, locatableCount: 2), moving),
                       "Трактор 1: Движи се. Задачата има още една проследявана машина.")
        XCTAssertEqual(MachineWords.taskMachine(.init(name: nil, lastPosition: moving, locatableCount: 3), moving),
                       "Движи се. Задачата има още 2 проследявани машини.")
    }

    /// The mechanisator's notice names the machines and who sees them, from
    /// the server's `visibleTo`, and says their phone is not tracked.
    func testTheNoticeSaysWhatIsTrackedAndWhoSees() {
        let tracked = TrackedMachines(machines: [.init(name: "Трактор 1", type: "TRACTOR"),
                                                 .init(name: "Комбайн", type: "HARVESTER")],
                                      visibleTo: ["OWNER", "ADMIN"])
        XCTAssertEqual(MachineWords.notice(tracked),
                       "Проследяват се (GPS тракер или телематика на производителя): Трактор 1, Комбайн. Местоположението им виждат собствениците и администраторите. Вашият телефон не се проследява.")
        XCTAssertEqual(MachineWords.notice(TrackedMachines(machines: [], visibleTo: ["OWNER"])),
                       "Няма проследявани машини в стопанството.")
    }

    func testTheDeviceSetupComesFromTheServer() {
        XCTAssertEqual(AddTrackerSheet.setup(.init(host: "gps.example.test", port: 5027, protocolName: "codec8")),
                       "В конфигуратора на тракера задайте сървър gps.example.test, порт 5027, протокол TCP (Codec 8).")
        XCTAssertTrue(AddTrackerSheet.setup(nil).hasPrefix("Сървърът за GPS тракери още не е настроен."),
                      "unset ingest is said, never a blank")
    }

    func testOnlyMachinesCarryATracker() {
        XCTAssertTrue(MachineAsset(id: "a1", name: "T", type: "TRACTOR").isMachine)
        XCTAssertFalse(MachineAsset(id: "a2", name: "Склад", type: "STORAGE").isMachine)
        XCTAssertFalse(MachineAsset(id: "a3", name: "?", type: nil).isMachine)
        XCTAssertEqual(MachineKind.label("HARVESTER"), "Комбайн")
        XCTAssertNil(MachineKind.label("BUILDING"))
        XCTAssertEqual(MachineKind.label("IRRIGATION"), "Напоителна система")
        XCTAssertFalse(MachineAsset(id: "a4", name: "Пивот", type: "IRRIGATION").isMachine,
                       "named in the fleet, not offered for a tracker")
    }

    // MARK: - Decoding (agri-saas #2948's shapes)

    private func decode<T: Decodable & Sendable>(_ json: String, as type: T.Type) async throws -> T {
        try await APIClient.shared.decode(Data(json.utf8), as: type)
    }

    func testTheListReadsLenientlyWithOffsetTimes() async throws {
        let list = try await decode("""
        {"machines":[
          {"assetId":"a1","name":"Трактор 1","type":"TRACTOR",
           "lastPosition":{"lat":42.5,"lon":25.1,"recordedAt":"2026-11-09T14:31:02+02:00","speedKph":9.5,"ignition":true,"moving":true}},
          {"assetId":"a2","name":"Комбайн","type":"HARVESTER","lastPosition":null},
          {"name":"no id"}
        ]}
        """, as: MachinesListProbe.self)
        XCTAssertEqual(list.machines.map(\.assetId), ["a1", "a2"], "one bad row drops alone")
        XCTAssertEqual(list.machines[0].lastPosition?.moving, true)
        XCTAssertNotNil(list.machines[0].lastPosition?.recordedAt, "an offset time decodes")
        XCTAssertNil(list.machines[1].lastPosition)
    }

    /// A tracker replays what it buffered out of signal, so points can come
    /// out of order; the route is drawn by the device's own times.
    func testTheRouteIsDrawnInRecordedOrder() async throws {
        let track = try await decode("""
        {"date":"2026-11-09","points":[
          {"lat":1,"lon":1,"recordedAt":"2026-11-09T10:00:00+02:00"},
          {"lat":3,"lon":3,"recordedAt":"2026-11-09T12:00:00+02:00"},
          {"lat":2,"lon":2,"recordedAt":"2026-11-09T11:00:00+02:00"}]}
        """, as: MachineTrack.self)
        XCTAssertEqual(track.points.map(\.lat), [1, 2, 3])
    }

    /// Coordinates arrive as decimal strings (agri-saas #2948 stage 3), so a
    /// number-only decoder would drop every machine from the map.
    func testCoordinatesReadAsStringsOrNumbers() async throws {
        let list = try await decode("""
        {"machines":[{"assetId":"a1","name":"T","type":"TRACTOR","positionSource":null,
          "lastPosition":{"lat":"43.4120000","lon":"24.6050000","recordedAt":"2026-11-12T10:00:00+02:00","speedKph":0.4,"ignition":true,"moving":false}}]}
        """, as: MachinesListProbe.self)
        XCTAssertEqual(list.machines.first?.lastPosition?.lat ?? 0, 43.412, accuracy: 1e-9)
        let track = try await decode(#"{"date":"2026-11-12","points":[{"lat":"43.4","lon":24.6},{"lat":"x","lon":"1"}]}"#,
                                     as: MachineTrack.self)
        XCTAssertEqual(track.points.count, 1, "an unreadable coordinate drops its point, not the route")
        XCTAssertEqual(track.points.first?.lon ?? 0, 24.6, accuracy: 1e-9)
    }

    /// The register ships after the reads: a 404 hides it and «Нов тракер»
    /// rather than showing an error and a form that cannot save.
    func testAnAbsentRegisterIsNotAnError() {
        XCTAssertTrue(MachinesStore.isAbsent(APIClient.APIError.http(status: 404, code: nil, message: nil)))
        XCTAssertFalse(MachinesStore.isAbsent(APIClient.APIError.http(status: 500, code: nil, message: nil)))
        XCTAssertFalse(MachinesStore.isAbsent(URLError(.notConnectedToInternet)))
    }

    func testTheTrackAndRegisterRead() async throws {
        let pending = try await decode(#"{"date":"2026-11-09","parcels":[],"derivedAt":null}"#, as: WorkedDay.self)
        XCTAssertEqual(pending.derived, false)
        let ran = try await decode(#"{"date":"2026-11-08","parcels":[],"derivedAt":"2026-11-09T02:00:00+02:00"}"#, as: WorkedDay.self)
        XCTAssertEqual(ran.derived, true)
        let before = try await decode(#"{"date":"2026-11-08","parcels":[]}"#, as: WorkedDay.self)
        XCTAssertNil(before.derived)
        let old = try await decode(#"{"date":"2026-09-01","points":[],"truncated":false,"retained":false}"#, as: MachineTrack.self)
        XCTAssertFalse(old.retained)
        let register = try await decode("""
        {"ingest":null,"trackers":[{"id":"t1","assetId":"a1","assetName":"Трактор 1","assetType":"TRACTOR",
          "imei":"350000000000006","label":null,"installedAt":"2026-11-09T08:00:00+02:00",
          "driversInformedAt":"2026-11-09T07:55:00+02:00","driversInformedByName":"Синтетичен Администратор","lastSeenAt":null}]}
        """, as: TrackerRegister.self)
        XCTAssertNil(register.ingest, "unset on the server")
        XCTAssertEqual(register.trackers.first?.imei, "350000000000006")
        let assets = try await MachinesAPI.decodeAssets(Data(#"[{"id":"a1","name":"Т","type":"TRACTOR"},{"x":1}]"#.utf8))
        XCTAssertEqual(assets.map(\.id), ["a1"])
        let wrapped = try await MachinesAPI.decodeAssets(Data(#"{"assets":[{"id":"a1","name":"Т","type":"TRACTOR"}]}"#.utf8))
        XCTAssertEqual(wrapped.map(\.id), ["a1"])
        // A task names its machines by `assetId`, the register by `id`.
        let onTask = try await MachinesAPI.decodeAssets(Data(#"{"machines":[{"assetId":"a2","assetName":"К","assetType":"HARVESTER"}]}"#.utf8))
        XCTAssertEqual(onTask.map(\.id), ["a2"])
        XCTAssertEqual(onTask.first?.type, "HARVESTER")
        let enveloped = try await MachinesAPI.decodeAssets(Data(#"{"assets":[{"assetId":"a3","name":"Т","type":"TRACTOR","positionSource":null},{"assetId":"a4","name":"К","type":"HARVESTER","positionSource":{"kind":"TELEMATICS","provider":"CLAAS"}}]}"#.utf8))
        XCTAssertNil(enveloped.first?.positionSource)
        XCTAssertEqual(enveloped.first?.sourceKnown, true, "null said: no source")
        XCTAssertEqual(enveloped.last?.positionSource?.provider, "CLAAS")
    }
}

/// The list's private wrapper, mirrored to read it here.
private struct MachinesListProbe: Decodable, Sendable {
    let machines: [Machine]
    private enum CodingKeys: String, CodingKey { case machines }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = ((try? c.decode([Lossy<Machine>].self, forKey: .machines)) ?? []).compactMap(\.value)
    }
}
