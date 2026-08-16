import SwiftUI

enum UpdateNoticeFeedback: Equatable {
    case permissionDenied
    case helperMissing
    case launchFailed
}

struct UpdateNoticeView: View {
    let update: AvailableUpdate
    let currentVersion: AppVersion?
    let feedback: UpdateNoticeFeedback?
    let didStart: Bool
    let onSelect: () -> Void
    let onGrantAccess: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button(action: onSelect) {
                cardContent
            }
            .buttonStyle(.plain)
            .help(t("Install Vibenotch %@ in Terminal", update.version.description))

            if feedback == .permissionDenied {
                Button(action: onGrantAccess) {
                    Label(t("Grant Automation access"), systemImage: "gearshape")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DisplayStatus.needsMe.color)
                }
                .buttonStyle(.plain)
                .help(t("Open Automation privacy settings"))
            } else if feedback == .helperMissing {
                Text(t("Update helper missing — run ./scripts/install.sh once"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DisplayStatus.needsMe.color)
            } else if feedback == .launchFailed {
                Text(t("Could not open the updater in Terminal"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DisplayStatus.needsMe.color)
            }
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentSprite(status: .needsMe, size: 18, tint: DisplayStatus.working.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Vibenotch")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    + Text(t(" · Version %@ available", update.version.description))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))

                Text(
                    didStart
                        ? t("Update opened in Terminal")
                        : t("New version — click to update in Terminal")
                )
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    didStart ? DisplayStatus.done.color : DisplayStatus.needsMe.color
                )
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    chip(t("Update"), tint: DisplayStatus.working.color)
                    if let currentVersion {
                        chip("\(currentVersion) → \(update.version)")
                    }
                }

                Circle()
                    .fill(didStart ? DisplayStatus.done.color : DisplayStatus.needsMe.color)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(t("Update available"))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(isHovering ? 0.08 : 0.04))
        .clipShape(.rect(cornerRadius: 12))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
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
