import Foundation
import Observation

struct AppVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }

        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func bundledVersion(in bundle: Bundle = .main) -> AppVersion? {
        guard let value = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else { return nil }
        return AppVersion(value)
    }
}

struct AvailableUpdate: Equatable, Sendable {
    let version: AppVersion
    let tagName: String
    let releaseURL: URL
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let releaseURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case releaseURL = "html_url"
    }
}

protocol UpdateHTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionUpdateHTTP: UpdateHTTPPerforming {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

protocol LatestReleaseChecking: Sendable {
    func latestRelease() async throws -> GitHubRelease
}

struct GitHubLatestReleaseChecker: LatestReleaseChecking {
    static let endpoint = URL(
        string: "https://api.github.com/repos/rebelpaulo/notch-hud/releases/latest"
    )!

    let http: any UpdateHTTPPerforming

    init(http: any UpdateHTTPPerforming = URLSessionUpdateHTTP()) {
        self.http = http
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vibenotch update checker", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await http.perform(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw UpdateCheckError.unexpectedResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

enum UpdateCheckError: Error {
    case unexpectedResponse
}

@Observable
@MainActor
final class UpdateStore {
    static let refreshInterval: TimeInterval = 6 * 60 * 60

    let currentVersion: AppVersion?
    private(set) var availableUpdate: AvailableUpdate?
    private(set) var isChecking = false

    private let checker: any LatestReleaseChecking
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?

    init(
        currentVersion: AppVersion? = AppVersion.bundledVersion(),
        checker: any LatestReleaseChecking = GitHubLatestReleaseChecker()
    ) {
        self.currentVersion = currentVersion
        self.checker = checker
    }

    func start() {
        guard timer == nil else { return }

        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }

    func refresh() {
        guard let currentVersion, checkTask == nil else { return }

        isChecking = true
        checkTask = Task { [weak self, checker] in
            do {
                let release = try await checker.latestRelease()
                guard !Task.isCancelled else { return }
                self?.availableUpdate = Self.availableUpdate(
                    from: release,
                    newerThan: currentVersion
                )
            } catch {
                // A background update check should never turn a transient
                // network problem into UI noise. Keep any known update visible
                // and try again on the next slow cadence.
                NSLog("Vibenotch update check failed: %@", error.localizedDescription)
            }
            self?.finishCheck()
        }
    }

    private func finishCheck() {
        isChecking = false
        checkTask = nil
    }

    private static func availableUpdate(
        from release: GitHubRelease,
        newerThan currentVersion: AppVersion
    ) -> AvailableUpdate? {
        guard let releaseVersion = AppVersion(release.tagName),
              releaseVersion > currentVersion,
              release.tagName == "v\(releaseVersion)",
              release.releaseURL.scheme == "https",
              release.releaseURL.host == "github.com"
        else { return nil }

        return AvailableUpdate(
            version: releaseVersion,
            tagName: release.tagName,
            releaseURL: release.releaseURL
        )
    }
}
