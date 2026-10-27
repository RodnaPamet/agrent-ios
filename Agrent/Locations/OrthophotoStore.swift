import MapKit
import Observation

/// What the orthophoto map reads besides its tiles: the day the farm was
/// flown, for the footer, and the physical blocks (ФБ) in view.
///
/// Both are best effort. Neither failing costs the map: the footer then says
/// only whose photo it is, and the parcels stay without blocks under them.
@MainActor
@Observable
final class OrthophotoStore {
    private(set) var coverage: OrthoCoverage?
    private(set) var blocks: [OrthoBlock] = []
    /// The server stopped at its cap for the last area read.
    private(set) var truncated = false
    /// Out beyond `blocksSpan`, where no blocks are read: the footer says to
    /// zoom in for them.
    private(set) var tooFarOut = false

    /// Closer than this, the blocks read are the ones in view. About twelve
    /// kilometres.
    static let blocksSpan = 0.12
    /// Further out, the farm's OWN blocks (its bounds, `loadCoverage`), up
    /// to a holding this wide: the map opens a little wider than the farm,
    /// and a farm opened must show its blocks. Beyond both, none are read.
    static let farmSpan = 0.3

    @ObservationIgnored private var coverageFor: OrthophotoAPI.Box?
    /// The farm's bounds, for the blocks when the map is out past the farm.
    @ObservationIgnored private var farm: OrthophotoAPI.Box?
    @ObservationIgnored private var blocksFor: OrthophotoAPI.Box?
    @ObservationIgnored private var blocksTask: Task<Void, Never>?
    @ObservationIgnored private let readCoverage: @MainActor (OrthophotoAPI.Box) async throws -> OrthoCoverage
    @ObservationIgnored private let readBlocks: @MainActor (OrthophotoAPI.Box) async throws -> OrthoBlocks

    init(coverage: @escaping @MainActor (OrthophotoAPI.Box) async throws -> OrthoCoverage = OrthophotoAPI.coverage,
         blocks: @escaping @MainActor (OrthophotoAPI.Box) async throws -> OrthoBlocks = OrthophotoAPI.blocks) {
        readCoverage = coverage
        readBlocks = blocks
    }

    /// Once per farm: the newest photo of its bounds.
    func loadCoverage(_ box: OrthophotoAPI.Box) async {
        farm = box
        guard box != coverageFor else { return }
        coverageFor = box
        coverage = try? await readCoverage(box)
    }

    /// The blocks for what the map shows, after a pan or a zoom settles.
    /// The last area asked for wins: an earlier read still in flight is
    /// cancelled rather than allowed to land over a newer view.
    func showBlocks(in region: MKCoordinateRegion, farm known: OrthophotoAPI.Box? = nil) {
        if let known { farm = known }
        let visible = OrthophotoAPI.Box(region)
        let box: OrthophotoAPI.Box? = visible.span <= Self.blocksSpan
            ? visible
            : farm.flatMap { $0.span <= Self.farmSpan ? $0 : nil }
        tooFarOut = box == nil
        guard let box else {
            blocksTask?.cancel()
            blocksFor = nil
            blocks = []
            truncated = false
            return
        }
        guard box != blocksFor else { return }
        blocksFor = box
        blocksTask?.cancel()
        blocksTask = Task { [weak self, readBlocks] in
            guard let read = try? await readBlocks(box), !Task.isCancelled else { return }
            self?.blocks = read.blocks
            self?.truncated = read.truncated
        }
    }
}
