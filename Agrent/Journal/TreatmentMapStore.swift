import Foundation
import MapKit
import Observation

/// A recorded treatment's parcels, for «Виж на картата» (#399).
///
/// The journal's row says how many parcels and which blocks, but not which
/// parcels: its list read carries no ids. The owner asked to see them, and
/// where (2026-10-22). They come from reads that already exist:
/// - `GET /journal/treatments/{handle}` has the treatment's `taskIds`, one
///   field-operation task per block (agri-saas #1740);
/// - each task's `GET /field-operations/{taskId}` has its block, its lines
///   (the treated parcels) and that block's parcels with their outlines.
///
/// Cache first, like every read here, so a treatment opened once can be shown
/// with no signal. The saved screen already holds the parcels, so it builds
/// this with them and makes no read.
@Observable
@MainActor
final class TreatmentMapStore {
    private(set) var state: LoadState<[TreatmentPlace.Field]>
    private(set) var outlines: [String: [MKPolygon]] = [:]

    private let handle: String?

    typealias LoadTasks = @MainActor (String) async -> LoadState<[String]>
    typealias LoadDetail = @MainActor (String) async -> LoadState<FieldOperationDetail>
    private let loadTasks: LoadTasks
    private let loadDetail: LoadDetail

    init(
        handle: String,
        loadTasks: @escaping LoadTasks = { handle in
            await CachedResource.load(TreatmentAPI.treatmentPath(handle)) { try TreatmentAPI.taskIDs(from: $0) }
        },
        loadDetail: @escaping LoadDetail = { id in
            await CachedResource.load(FieldOperationAPI.detailPath(id)) { try await FieldOperationAPI.decodeDetail(from: $0) }
        }
    ) {
        self.handle = handle
        self.state = .loading
        self.loadTasks = loadTasks
        self.loadDetail = loadDetail
    }

    /// The saved screen's parcels, already in hand: nothing to read.
    init(fields: [TreatmentPlace.Field]) {
        self.handle = nil
        self.state = .loaded(fields, .fresh)
        self.loadTasks = { _ in .loading }
        self.loadDetail = { _ in .loading }
        self.outlines = TreatmentPlace.outlines(fields)
    }

    func load() async {
        guard let handle else { return }
        if state.value == nil { state = .loading }
        let tasks = await loadTasks(handle)
        guard !Task.isCancelled else { return }
        guard case .loaded(let ids, _) = tasks else {
            if case .failed(let message) = tasks, state.value == nil { state = .failed(message) }
            return
        }
        var details: [FieldOperationDetail] = []
        var oldest: Date?
        for id in ids {
            switch await loadDetail(id) {
            case .loaded(let detail, let freshness):
                details.append(detail)
                if case .stale(let since) = freshness { oldest = min(oldest ?? since, since) }
            case .failed(let message):
                // One block missing would show the treatment as smaller than
                // it was, so a failure is the whole answer, not a partial map.
                if state.value == nil { state = .failed(message) }
                return
            case .loading:
                return
            }
        }
        guard !Task.isCancelled else { return }
        let fields = Self.fields(from: details)
        outlines = TreatmentPlace.outlines(fields)
        state = .loaded(fields, oldest.map { .stale(since: $0) } ?? .fresh)
    }

    /// The treated parcels, by block, each named in its block. A line names
    /// its parcel; the outline comes from the block's parcel list when the
    /// parcel has one there. A parcel with several product lines is listed
    /// once.
    nonisolated static func fields(from details: [FieldOperationDetail]) -> [TreatmentPlace.Field] {
        var result: [TreatmentPlace.Field] = []
        var seen = Set<String>()
        for detail in details {
            let blockID = detail.location?.id ?? ""
            let blockName = detail.location?.name ?? "—"
            let shaped = Dictionary(detail.parcels.map { ($0.id, $0) }) { first, _ in first }
            var block: [TreatmentPlace.Field] = []
            for line in detail.lines where seen.insert(line.parcel.id).inserted {
                let parcel = shaped[line.parcel.id] ?? Parcel(
                    id: line.parcel.id, name: line.parcel.name, cropType: nil,
                    areaHa: line.parcel.areaHa.map { NSDecimalNumber(decimal: $0.value).doubleValue },
                    geometry: nil, soilType: nil, cadastralId: nil, ekatte: nil,
                    hasActiveLease: nil, absentFromImportAt: nil)
                block.append(TreatmentPlace.Field(parcel: parcel, blockID: blockID, blockName: blockName))
            }
            result += block.sorted { $0.parcel.name.localizedStandardCompare($1.parcel.name) == .orderedAscending }
        }
        return result
    }
}
