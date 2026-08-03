import SwiftUI

enum SessionRowFeedback: Equatable {
    case permissionDenied
    case notFound
}

struct SessionRowView: View {
    let session: Session
    let now: Date
    let feedback: SessionRowFeedback?
    let onSelect: (Session) -> Void
    let onGrantAccess: () -> Void

    @State private var isHovering = false

    private var canFocus: Bool {
        session.terminal?.tty != nil || session.source == "claude-desktop"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button {
                onSelect(session)
            } label: {
                cardContent
            }
            .buttonStyle(.plain)
            .disabled(!canFocus)
            .help(canFocus ? "Raise this session's terminal" : "Background session")

            if feedback == .permissionDenied {
                Button(action: onGrantAccess) {
                    Label("Grant Automation access", systemImage: "gearshape")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DisplayStatus.needsMe.color)
                }
                .buttonStyle(.plain)
                .help("Open Automation privacy settings")
            } else if feedback == .notFound {
                Text("Terminal window not found")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .opacity(canFocus ? 1 : 0.55)
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentSprite(status: session.displayStatus, size: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                titleLine
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let prompt = session.prompt,
                   !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("You: \(prompt)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                activityLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingMetadata
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(isHovering && canFocus ? 0.08 : 0.04))
        .clipShape(.rect(cornerRadius: 12))
        .contentShape(.rect)
        .onHover { hovering in
            isHovering = canFocus && hovering
        }
    }

    private var titleLine: Text {
        let project = Text(session.project)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(.white)

        guard let task = session.task, !task.isEmpty else {
            return project
        }

        return project
            + Text(" · ")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white.opacity(0.28))
            + Text(task)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white.opacity(0.58))
    }

    @ViewBuilder
    private var activityLine: some View {
        if session.displayStatus == .working,
           let toolLine = session.toolLine,
           !toolLine.isEmpty {
            highlightedToolLine(toolLine)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if session.displayStatus == .done {
            Text("Done — click to jump")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DisplayStatus.done.color)
                .lineLimit(1)
        }
    }

    private func highlightedToolLine(_ line: String) -> Text {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let tool = parts.first.map(String.init) ?? line
        let detail = parts.count > 1 ? " " + String(parts[1]) : ""

        return Text(tool)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(Color(red: 110 / 255, green: 180 / 255, blue: 255 / 255))
            + Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
    }

    private var trailingMetadata: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 4) {
                chip(
                    SessionChipStyle.agentLabel(session.agent),
                    tint: SessionChipStyle.agentTint(session.agent)
                )

                if let model = session.model, !model.isEmpty {
                    chip(SessionChipStyle.modelLabel(model))
                }

                if let source = session.source,
                   let sourceLabel = SessionChipStyle.sourceLabel(source) {
                    chip(sourceLabel)
                } else if let terminal = session.terminal?.termProgram, !terminal.isEmpty {
                    chip(SessionChipStyle.terminalLabel(terminal))
                }

                chip(session.elapsed(at: now))
            }

            Circle()
                .fill(session.displayStatus.color)
                .frame(width: 6, height: 6)
                .accessibilityLabel(Text(session.displayStatus.label))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func chip(_ label: String, tint: Color = .white.opacity(0.56)) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.white.opacity(0.06))
            .clipShape(.capsule)
    }
}
