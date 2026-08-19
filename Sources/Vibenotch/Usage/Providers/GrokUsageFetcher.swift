import Foundation

/// Reads Grok CLI usage from the same backend the CLI itself calls.
///
/// Two endpoints, not one: `/v1/billing` carries the quota, `/v1/settings`
/// carries the plan name. They are independent on purpose — a broken plan
/// lookup must never cost the user their gauge, so its failure is absorbed
/// here rather than thrown. See `fetchPlan`.
struct GrokUsageFetcher: UsageFetching {
    let kind: UsageProviderKind = .grok

    private static let billingEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let settingsEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    private let credentials: GrokCredentialReading
    private let http: UsageHTTPPerforming

    init(
        credentials: GrokCredentialReading = FileGrokCredentialReader(),
        http: UsageHTTPPerforming = URLSessionUsageHTTP()
    ) {
        self.credentials = credentials
        self.http = http
    }

    func fetch(now: Date) async throws -> UsageSnapshot {
        let creds = try credentials.read()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await http.perform(Self.request(for: Self.billingEndpoint, key: creds.key))
        } catch let error as UsageUnavailable {
            throw error
        } catch {
            throw UsageUnavailable.network(error.localizedDescription)
        }

        if let failure = UsageHTTPStatus.failure(for: response) {
            throw failure
        }

        guard let payload = try? JSONDecoder().decode(GrokBillingResponse.self, from: data) else {
            throw UsageUnavailable.unexpectedResponse("grok billing payload did not match the expected shape")
        }

        // Best-effort only: a failed plan lookup must never cost the user
        // their gauge, so nothing here is allowed to throw past this point.
        let plan = await Self.fetchPlan(key: creds.key, http: http)

        return UsageSnapshot(
            provider: .grok,
            account: creds.email,
            plan: plan,
            billing: .plan(plan),
            windows: Self.windows(from: payload),
            capturedAt: now
        )
    }

    private static func fetchPlan(key: String, http: UsageHTTPPerforming) async -> String? {
        guard let (data, response) = try? await http.perform(request(for: settingsEndpoint, key: key)) else {
            return nil
        }
        guard UsageHTTPStatus.failure(for: response) == nil else { return nil }
        return (try? JSONDecoder().decode(GrokSettingsResponse.self, from: data))?.subscriptionTierDisplay
    }

    private static func request(for url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func windows(from payload: GrokBillingResponse) -> [UsageWindow] {
        guard let config = payload.config else { return [] }
        let start = parseISO8601(config.currentPeriod?.start)
        let end = parseISO8601(config.currentPeriod?.end)
        // Derived from the payload, never hardcoded: a weekly period is the
        // one observed so far, but nothing here assumes 604800 seconds.
        let length: TimeInterval? = {
            guard let start, let end else { return nil }
            let seconds = end.timeIntervalSince(start)
            return seconds > 0 ? seconds : nil
        }()

        var windows: [UsageWindow] = []

        // THE INVERTED RULE THIS FILE EXISTS TO GET RIGHT: this payload is
        // protobuf underneath, and proto3 omits a field entirely when its
        // value equals the type's zero value. For `creditUsagePercent` that
        // means "absent" IS "0%", not "unknown" — captured live: the field
        // was missing at 0% usage and appeared the instant usage hit 1%.
        //
        // That is the OPPOSITE of ClaudeUsageFetcher and CodexUsageFetcher,
        // where a missing percentage must drop the window because those are
        // ordinary JSON APIs with no such omission rule, and a synthesized
        // zero there would be a lie. Applying THEIR "missing = drop the
        // window" guard here would blank the Grok card at exactly 0% usage —
        // the one moment an empty bar is both the honest answer and the most
        // reassuring thing on screen. Do not copy that guard down into this
        // file; it inverts the meaning.
        let accountPercent = config.creditUsagePercent ?? 0
        if let accountWindow = UsageWindow.validated(
            kind: .weekly,
            percentUsed: accountPercent,
            resetsAt: end,
            windowLength: length,
            scopeLabel: nil,
            // Grok reports no severity of its own, same as Codex.
            severity: .derived(fromPercentUsed: accountPercent)
        ) {
            windows.append(accountWindow)
        }

        for product in config.productUsage ?? [] {
            // Same proto3 rule, one level down: GrokBuild in the captured
            // payload carries no `usagePercent` key at all, and that means
            // 0%, not "no data" — it must NOT be dropped like Codex would
            // drop a scoped limit with a missing percent.
            let percent = product.usagePercent ?? 0
            if let scoped = UsageWindow.validated(
                kind: .weekly,
                percentUsed: percent,
                resetsAt: end,
                windowLength: length,
                scopeLabel: scopeLabel(fromProduct: product.product),
                severity: .derived(fromPercentUsed: percent)
            ) {
                windows.append(scoped)
            }
        }

        return windows
    }

    /// "GrokImagine" -> "Imagine", "GrokBuild" -> "Build". A product name
    /// that doesn't start with "Grok" (or is missing) still needs a non-nil
    /// label — a scoped window with `scopeLabel == nil` would read as
    /// account-wide and could win `UsageSnapshot.window(_:)` over the real
    /// one. See `UsageWindow.unspecifiedScopeLabel`.
    private static func scopeLabel(fromProduct product: String?) -> String {
        guard let product, !product.isEmpty else { return UsageWindow.unspecifiedScopeLabel }
        guard product.hasPrefix("Grok") else { return product }
        let stripped = product.dropFirst("Grok".count)
        return stripped.isEmpty ? product : String(stripped)
    }

    /// Two formatters because fractional seconds are not guaranteed even
    /// though every captured timestamp so far has them. Mirrors
    /// `ClaudeUsageFetcher.parseISO8601`, which is `fileprivate` to that file
    /// and so cannot be shared from here.
    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

/// Decoding target for `GET /v1/billing?format=credits`. Every field is
/// optional: an undocumented endpoint can rename or drop one without
/// crashing the app. Unlike Claude's and Codex's endpoints, these keys are
/// already camelCase on the wire, so no `CodingKeys` are needed here.
struct GrokBillingResponse: Decodable {
    struct Period: Decodable {
        let start: String?
        let end: String?
    }

    struct ProductUsage: Decodable {
        let product: String?
        let usagePercent: Double?
    }

    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let productUsage: [ProductUsage]?
    }

    let config: Config?
}

/// Decoding target for `GET /v1/settings`. Snake_case here, unlike the
/// billing endpoint above — apparently a different service behind the same
/// host. Only the one field this app uses is modeled.
struct GrokSettingsResponse: Decodable {
    let subscriptionTierDisplay: String?

    enum CodingKeys: String, CodingKey {
        case subscriptionTierDisplay = "subscription_tier_display"
    }
}
