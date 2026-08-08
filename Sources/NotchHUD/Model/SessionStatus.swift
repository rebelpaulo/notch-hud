import SwiftUI

enum SessionStatus: String, Codable, Sendable {
    case starting, working, needs_me, done, unknown
}

enum DisplayStatus: Hashable, Sendable {
    case working
    case needsMe
    case done
    case idle

    var color: Color {
        switch self {
        case .working:
            Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
        case .needsMe:
            Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
        case .done:
            Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
        case .idle:
            Color(red: 72 / 255, green: 72 / 255, blue: 74 / 255)
        }
    }

    var label: String {
        switch self {
        case .working:
            t("Working")
        case .needsMe:
            t("Needs me")
        case .done:
            t("Done")
        case .idle:
            t("Idle")
        }
    }
}

extension SessionStatus {
    var displayStatus: DisplayStatus {
        switch self {
        case .starting, .working:
            .working
        case .needs_me:
            .needsMe
        case .done:
            .done
        case .unknown:
            .idle
        }
    }
}

enum SessionChipStyle {
    static func agentLabel(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude", "claude-code":
            "Claude"
        case "codex", "openai-codex":
            "Codex"
        default:
            agent.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    static func agentTint(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "claude", "claude-code":
            Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case "codex", "openai-codex":
            .white
        default:
            Color(white: 0.62)
        }
    }

    /// Sprite identity color: orange for Claude, blue for Codex.
    static func spriteTint(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "claude", "claude-code":
            Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case "codex", "openai-codex":
            Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
        default:
            Color(white: 0.62)
        }
    }

    static func modelLabel(_ model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.hasPrefix("gpt-") {
            return "GPT-" + String(model.dropFirst(4))
        }

        return model
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                let value = String(part)
                return value.first.map { $0.uppercased() + String(value.dropFirst()) } ?? value
            }
            .joined(separator: " ")
    }

    static func terminalLabel(_ termProgram: String) -> String {
        switch termProgram {
        case "Apple_Terminal":
            "Terminal"
        case "iTerm.app", "iTerm2":
            "iTerm2"
        default:
            termProgram
        }
    }

    static func sourceLabel(_ source: String) -> String? {
        switch source {
        case "claude-desktop", "codex-desktop":
            "Desktop"
        default:
            nil
        }
    }
}
