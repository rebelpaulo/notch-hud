import Foundation

/// Seam over networking so usage-fetcher tests never touch the real internet.
/// Real implementations pass this straight to URLSession; fakes return
/// canned fixture bytes.
protocol UsageHTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionUsageHTTP: UsageHTTPPerforming {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Maps an HTTP response to the failure it represents, shared by both
/// fetchers so the 401 → credentialExpired mapping is decided once.
enum UsageHTTPStatus {
    /// 401 gets its own case instead of falling into `.network` because the
    /// fix is different: the user re-running the CLI login, not a retry.
    static func failure(for response: URLResponse) -> UsageUnavailable? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 {
            return .credentialExpired
        }
        if !(200...299).contains(http.statusCode) {
            return .network("HTTP \(http.statusCode)")
        }
        return nil
    }
}
