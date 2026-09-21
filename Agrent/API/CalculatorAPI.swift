import Foundation

enum CalculatorAPI {
    /// No query parameters. `getGrainNetWorth` takes `seasonId` optionally and
    /// both the API route and the web page pass none, so the native client
    /// passing one would diverge from the web for the same farm. It also keeps
    /// the request clear of the unified log: CFNetwork writes full request
    /// URLs, query included, and the app cannot suppress that.
    static var path: String { "/api/t/\(Config.tenantSlug)/grain/calculator" }

    static func decode(from data: Data) async throws -> CalculatorPayload {
        try await APIClient.shared.decode(data, as: CalculatorPayload.self)
    }
}
