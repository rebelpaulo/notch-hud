import Foundation

/// USD-per-million-token rates for turning a token count into a notional cost.
///
/// "Notional" is load-bearing: everyone this scans is on a Claude or Codex
/// subscription, so no per-token money actually changes hands. This table
/// only answers "what would this have cost at API rates" — a proxy for
/// effort, not a bill. Presenting it as money spent would be a true number
/// telling a false story, so keep it out of anything labelled `cost`; every
/// call site should be reaching for `notionalCostUSD`.
///
/// Hand-maintained, last checked 2026-08-14 against each family's published
/// list price tier. `cachedInputPerMillion` is the cache-*read* rate. Claude's
/// `cache_creation_input_tokens` (a cache *write*) is folded into the plain
/// input rate below rather than given its own column — the real API bills
/// cache writes at a premium over plain input, so sessions that create a lot
/// of new cache slightly undercount.
/// ponytail: cache-write priced as plain input; add a fourth rate if that
/// undercount turns out to matter.
enum LocalUsagePricing {
    struct Rates: Sendable, Equatable {
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let outputPerMillion: Double
    }

    /// Keyed by the model id exactly as the CLI logs it — `message.model` for
    /// Claude, `turn_context.payload.model` for Codex. A model id missing from
    /// this table is expected, not a bug: new models ship on their own
    /// schedule, ahead of anyone updating this file. `LocalUsageScanner`
    /// contributes that model's tokens to the totals but zero cost, and adds
    /// them to `unpricedTokens` instead of guessing at a rate.
    static let rates: [String: Rates] = [
        "claude-opus-5": Rates(inputPerMillion: 15, cachedInputPerMillion: 1.5, outputPerMillion: 75),
        "claude-sonnet-5": Rates(inputPerMillion: 3, cachedInputPerMillion: 0.3, outputPerMillion: 15),
        "claude-fable-5": Rates(inputPerMillion: 3, cachedInputPerMillion: 0.3, outputPerMillion: 15),
        "claude-haiku-5": Rates(inputPerMillion: 0.8, cachedInputPerMillion: 0.08, outputPerMillion: 4),
        "gpt-5.6-terra": Rates(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10),
        "gpt-5-codex": Rates(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10)
    ]
}
