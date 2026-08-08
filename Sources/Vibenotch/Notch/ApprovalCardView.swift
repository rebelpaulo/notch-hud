import Foundation
import SwiftUI

struct ApprovalCardView: View {
    let approval: PendingApproval
    let decisionWriter: ApprovalDecisionWriter
    let onDismiss: @MainActor (String) -> Void

    private let amber = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    private let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            approvalBody
            buttons
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045))
        .clipShape(cardShape)
        .overlay {
            cardShape.stroke(.white.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("⚠")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(amber)

            Text(approval.tool)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(amber)

            if let headerSummary {
                Text(headerSummary)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(approval.projectName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var approvalBody: some View {
        switch approval.tool {
        case "Edit", "NotebookEdit":
            editBody
        case "Write":
            writeBody
        case "Bash":
            bashBody
        default:
            Text(approval.summary ?? approval.tool)
                .approvalCodeStyle()
        }
    }

    private var editBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(approval.edit?.file)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { line in
                        HStack(alignment: .top, spacing: 7) {
                            Text(line.kind.prefix)
                                .frame(width: 10, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.kind.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(line.kind.background)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .background(Color.black.opacity(0.22))
        .clipShape(.rect(cornerRadius: 9))
    }

    private var writeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(approval.write?.file)
            ScrollView(.vertical) {
                Text(approval.write?.content ?? "")
                    .approvalCodeStyle()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 155)
        }
        .background(Color.black.opacity(0.22))
        .clipShape(.rect(cornerRadius: 9))
    }

    private var bashBody: some View {
        ScrollView(.vertical) {
            Text(approval.bash?.command ?? "")
                .approvalCodeStyle()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 155)
        .background(Color.black.opacity(0.28))
        .clipShape(.rect(cornerRadius: 9))
    }

    private func fileHeader(_ file: String?) -> some View {
        Text(file.flatMap { $0.isEmpty ? nil : $0 } ?? t("Unknown file"))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.67))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            approvalButton(t("Deny"), background: .white.opacity(0.10), foreground: .white) {
                decide(.deny, scope: .once)
            }
            approvalButton(t("Allow Once"), background: .white.opacity(0.94), foreground: .black) {
                decide(.allow, scope: .once)
            }
            approvalButton(
                t("Bypass"),
                background: Color(red: 0.78, green: 0.10, blue: 0.20),
                foreground: .white
            ) {
                bypass()
            }
        }
    }

    private func approvalButton(
        _ title: String,
        background: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(background)
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func decide(_ decision: ApprovalDecision.Decision, scope: ApprovalDecision.Scope) {
        do {
            try decisionWriter.write(
                ApprovalDecision(decision: decision, scope: scope),
                for: approval.sessionId
            )
            onDismiss(approval.sessionId)
        } catch {
            NSLog("Vibenotch could not write approval decision: %@", error.localizedDescription)
        }
    }

    private func bypass() {
        do {
            try decisionWriter.write(
                ApprovalDecision(decision: .allow, scope: .session),
                for: approval.sessionId
            )
            do {
                try decisionWriter.writeSessionAllowance(for: approval)
            } catch {
                // The hook also persists this allowance after consuming the decision.
                NSLog(
                    "Vibenotch could not prewrite the session allowance: %@",
                    error.localizedDescription
                )
            }
            onDismiss(approval.sessionId)
        } catch {
            NSLog("Vibenotch could not write bypass decision: %@", error.localizedDescription)
        }
    }

    private var headerSummary: String? {
        guard let summary = approval.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              summary != approval.tool
        else {
            return nil
        }

        let duplicatedPrefix = approval.tool + " "
        if summary.hasPrefix(duplicatedPrefix) {
            return String(summary.dropFirst(duplicatedPrefix.count))
        }
        return summary
    }

    private var diffLines: [ApprovalDiffLine] {
        let oldLines = (approval.edit?.old ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let newLines = (approval.edit?.new ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        return oldLines.enumerated().map { index, line in
            ApprovalDiffLine(id: "old-\(index)", kind: .removed, text: line)
        } + newLines.enumerated().map { index, line in
            ApprovalDiffLine(id: "new-\(index)", kind: .added, text: line)
        }
    }
}

private struct ApprovalDiffLine: Identifiable {
    enum Kind {
        case removed
        case added

        var prefix: String {
            switch self {
            case .removed: "-"
            case .added: "+"
            }
        }

        var foreground: Color {
            switch self {
            case .removed: Color(red: 1, green: 107 / 255, blue: 107 / 255)
            case .added: Color(red: 126 / 255, green: 231 / 255, blue: 135 / 255)
            }
        }

        var background: Color {
            switch self {
            case .removed: Color(red: 58 / 255, green: 29 / 255, blue: 34 / 255)
            case .added: Color(red: 30 / 255, green: 51 / 255, blue: 37 / 255)
            }
        }
    }

    let id: String
    let kind: Kind
    let text: String
}

private extension View {
    func approvalCodeStyle() -> some View {
        font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.84))
            .textSelection(.enabled)
    }
}
