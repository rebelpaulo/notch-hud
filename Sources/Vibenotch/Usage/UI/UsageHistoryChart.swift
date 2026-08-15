import Charts
import SwiftUI

/// Tokens per day for one provider, and the two rollups worth a number.
///
/// Deliberately a bar per calendar day rather than a smoothed line: usage is
/// not continuous, it happens in sittings, and a line would invent a slope
/// across a day nobody worked. The gap where you took a weekend is information.
struct UsageHistoryChart: View {
    let provider: UsageProviderKind
    let points: [LocalUsageDayPoint]
    let today: Int
    let trailing: Int
    /// nil while the first cold scan is still walking gigabytes of logs.
    let isCounting: Bool

    private var mine: [LocalUsageDayPoint] {
        points.filter { $0.provider == provider }.sorted { $0.day < $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                stat(t("Today"), value: today)
                Spacer()
                stat(t("Last 31 days"), value: trailing, alignment: .trailing)
            }

            if isCounting {
                // Not an empty chart: a flat baseline would say "you used
                // nothing", and the honest answer while the scan runs is that
                // we do not know yet.
                Text(t("Counting the local logs…"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 44, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else if mine.isEmpty {
                Text(t("No local usage recorded"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 44, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                chart
            }

            if let top = mine.max(by: { $0.totalTokens < $1.totalTokens })?.topModel {
                Text(t("Top model: %@", top))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var chart: some View {
        Chart(mine) { point in
            BarMark(
                x: .value(t("Day"), point.day, unit: .day),
                y: .value(t("Tokens"), point.totalTokens)
            )
            .foregroundStyle(provider.tint)
            .cornerRadius(1)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            // Two labels only. This is 6pt type in a notch drawer; a full date
            // axis would be unreadable and would still tell you nothing you
            // could act on.
            AxisMarks(values: .stride(by: .day, count: 10)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.narrow))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(height: 44)
    }

    private func stat(
        _ label: String,
        value: Int,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            Text(UsageFormatting.tokenCount(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
