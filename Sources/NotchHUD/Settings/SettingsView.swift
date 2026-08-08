import AppKit
import Observation
import SwiftUI

struct SettingsView: View {
    @Bindable var keepAwakeEngine: KeepAwakeEngine
    let closedLidModeAvailable: Bool
    let spoolURL: URL
    let workingStaleSeconds: TimeInterval
    let dropSeconds: TimeInterval
    let remoteConfigURL: URL
    let commandRunner: any CommandRunning

    @State private var watchedBundleID = ""
    @State private var remotePairing: RemotePairing?
    @State private var remoteStatus = t("checking…")
    @State private var pushResult: RemoteActionResult?
    @State private var isSendingTestPush = false

    init(
        keepAwakeEngine: KeepAwakeEngine,
        closedLidModeAvailable: Bool,
        spoolURL: URL,
        workingStaleSeconds: TimeInterval = 90,
        dropSeconds: TimeInterval = 15 * 60,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        commandRunner: (any CommandRunning)? = nil
    ) {
        self.keepAwakeEngine = keepAwakeEngine
        self.closedLidModeAvailable = closedLidModeAvailable
        self.spoolURL = spoolURL
        self.workingStaleSeconds = workingStaleSeconds
        self.dropSeconds = dropSeconds
        remoteConfigURL = homeURL.appendingPathComponent(".notch-hud/remote.json")
        self.commandRunner = commandRunner ?? RemoteScriptCommandRunner(homeURL: homeURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection(t("Gotta go!"), systemImage: "bolt.fill") {
                    allNighterSection
                }
                settingsSection(t("Sessions"), systemImage: "rectangle.stack") {
                    sessionsSection
                }
                settingsSection(t("Remote (phone)"), systemImage: "iphone") {
                    remoteSection
                }
                settingsSection(t("About"), systemImage: "info.circle") {
                    aboutSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 520)
        .background(Color.notchBackground)
        .preferredColorScheme(.dark)
        .task {
            await refreshRemoteStatus()
        }
    }

    private var allNighterSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            settingsRow(t("Default mode")) {
                Picker("", selection: defaultModeBinding) {
                    ForEach(DefaultModeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 225)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(t("QUICK START"))
                    .settingsCaption()
                HStack(spacing: 8) {
                    timerButton("30 min", seconds: 30 * 60)
                    timerButton("1 h", seconds: 60 * 60)
                    timerButton("2 h", seconds: 2 * 60 * 60)
                }
            }

            Divider().overlay(.white.opacity(0.08))
            settingsToggle(t("Let the display sleep"), isOn: keepAwakeEngine.configBinding(\.allowDisplaySleep))
            settingsToggle(
                t("Stay awake with the lid closed"),
                isOn: keepAwakeEngine.configBinding(\.closedLidMode)
            )
            .disabled(!closedLidModeAvailable)
            if !closedLidModeAvailable {
                Text(t("Install first: sudo scripts/install-all-nighter.sh"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.85))
            }
            settingsToggle(
                t("Only on AC power when the lid is closed"),
                isOn: keepAwakeEngine.configBinding(\.acPowerOnlyForClosedLid)
            )
            .disabled(!closedLidModeAvailable || !keepAwakeEngine.config.closedLidMode)
            settingsToggle(t("Turn off on unlock"), isOn: keepAwakeEngine.configBinding(\.autoOffOnUnlock))

            stepperRow(
                t("Battery floor"),
                value: batteryFloorBinding,
                range: 10...50,
                suffix: "%"
            )
            stepperRow(
                t("Grace period"),
                value: graceMinutesBinding,
                range: 0...60,
                suffix: " min"
            )

            VStack(alignment: .leading, spacing: 8) {
                settingsToggle(t("Remind me while idle"), isOn: reminderEnabledBinding)
                if keepAwakeEngine.config.reminderAfterIdleSeconds > 0 {
                    stepperRow(
                        t("Remind after"),
                        value: reminderHoursBinding,
                        range: 1...24,
                        suffix: " h"
                    )
                }
            }

            watchedAppsEditor

            Divider().overlay(.white.opacity(0.08))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    Button {
                        toggleAllNighter()
                    } label: {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(keepAwakeEngine.isActive ? Color.red : .white.opacity(0.45))
                            .frame(width: 28, height: 24)
                            .background(.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(keepAwakeEngine.isActive ? t("Turn off Gotta go!") : t("Turn on Gotta go!"))

                    Text(statusText(at: context.date))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(keepAwakeEngine.isActive ? .white.opacity(0.78) : .white.opacity(0.42))
                }
            }
        }
    }

    private var watchedAppsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("WATCHED APPS"))
                .settingsCaption()
            ForEach(keepAwakeEngine.config.watchedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Button {
                        keepAwakeEngine.config.watchedBundleIDs = KeepAwakeSettingsLogic
                            .removingWatchedBundleID(bundleID, from: keepAwakeEngine.config.watchedBundleIDs)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.42))
                    .accessibilityLabel(t("Remove %@", bundleID))
                }
            }
            HStack(spacing: 8) {
                TextField("com.example.app", text: $watchedBundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(addWatchedBundleID)
                Button(t("Add"), action: addWatchedBundleID)
                    .disabled(watchedBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fixedInfoRow(
                t("No update for"),
                value: t("%d s → unknown state", Int(workingStaleSeconds))
            )
            fixedInfoRow(t("Card removal"), value: "\(Int(dropSeconds / 60)) min")
            Text(t("Fixed values. Clicking a finished session opens it and removes its card; Desktop chips mark sessions from desktop apps."))
                .settingsExplanation()
        }
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remotePairing {
                fixedInfoRow("URL", value: remotePairing.url)
                fixedInfoRow(t("Secret"), value: "••••")
            } else {
                Text(t("Not paired yet. Create ~/.notch-hud/remote.json and see the remote setup docs in the project."))
                    .settingsExplanation()
            }
            fixedInfoRow(t("Remote state"), value: remoteStatus)
            HStack(spacing: 10) {
                Button(t("Send test push")) {
                    sendTestPush()
                }
                .disabled(remotePairing == nil || isSendingTestPush)
                if let pushResult {
                    Text(pushResult.message)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(pushResult.succeeded ? .green : .red)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fixedInfoRow(t("Version"), value: "NotchHUD dev")
            fixedInfoRow(t("Sessions directory"), value: spoolURL.path)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
            content()
        }
        .padding(14)
        .background(.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).settingsLabel()
            Spacer()
            content()
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).settingsLabel()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        settingsRow(title) {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)\(suffix)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    private func fixedInfoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).settingsLabel()
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func timerButton(_ title: String, seconds: TimeInterval) -> some View {
        Button(title) {
            keepAwakeEngine.setMode(.timer(until: Date().addingTimeInterval(seconds)))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var defaultModeBinding: Binding<DefaultModeChoice> {
        Binding(
            get: { DefaultModeChoice(keepAwakeEngine.config.defaultMode) },
            set: { keepAwakeEngine.config.defaultMode = $0.mode }
        )
    }

    private var batteryFloorBinding: Binding<Int> {
        Binding(
            get: { KeepAwakeSettingsLogic.clampedBatteryFloor(keepAwakeEngine.config.batteryFloorPercent) },
            set: { keepAwakeEngine.config.batteryFloorPercent = KeepAwakeSettingsLogic.clampedBatteryFloor($0) }
        )
    }

    private var graceMinutesBinding: Binding<Int> {
        Binding(
            get: { KeepAwakeSettingsLogic.graceMinutes(from: keepAwakeEngine.config.graceSeconds) },
            set: { keepAwakeEngine.config.graceSeconds = KeepAwakeSettingsLogic.graceSeconds(from: $0) }
        )
    }

    private var reminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { keepAwakeEngine.config.reminderAfterIdleSeconds > 0 },
            set: { keepAwakeEngine.config.reminderAfterIdleSeconds = $0 ? 3_600 : 0 }
        )
    }

    private var reminderHoursBinding: Binding<Int> {
        Binding(
            get: { max(1, min(24, Int(keepAwakeEngine.config.reminderAfterIdleSeconds / 3_600))) },
            set: { keepAwakeEngine.config.reminderAfterIdleSeconds = TimeInterval(max(1, min(24, $0)) * 3_600) }
        )
    }

    private func addWatchedBundleID() {
        keepAwakeEngine.config.watchedBundleIDs = KeepAwakeSettingsLogic.addingWatchedBundleID(
            watchedBundleID,
            to: keepAwakeEngine.config.watchedBundleIDs
        )
        watchedBundleID = ""
    }

    private func toggleAllNighter() {
        keepAwakeEngine.setMode(keepAwakeEngine.isActive ? .off : safeDefaultMode)
    }

    private var safeDefaultMode: KeepAwakeMode {
        switch keepAwakeEngine.config.defaultMode {
        case .off, .timer: .whileAgentsWork
        case let mode: mode
        }
    }

    private func statusText(at date: Date) -> String {
        guard keepAwakeEngine.isActive else { return t("Gotta go! is off") }
        let elapsed = max(0, date.timeIntervalSince(keepAwakeEngine.activeSince ?? date))
        var result = t("On for %@ · %@", compactDuration(elapsed), modeName(keepAwakeEngine.mode))
        if let remaining = keepAwakeEngine.remainingTime(at: date) {
            result += t(" · %@ left", compactDuration(remaining))
        }
        return result
    }

    private func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes >= 60 ? "\(minutes / 60)h\(minutes % 60)m" : "\(minutes)m"
    }

    private func modeName(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: t("off")
        case .manual: t("indefinite")
        case .timer: t("timer")
        case .whileAgentsWork: t("while agents are working")
        case .whileAppsRunning: t("while the apps are open")
        }
    }

    private func refreshRemoteStatus() async {
        remotePairing = RemotePairing.load(from: remoteConfigURL)
        guard remotePairing != nil else {
            remoteStatus = t("not configured")
            return
        }
        let result = await commandRunner.run(arguments: ["--state"])
        guard result.exitCode == 0,
              let enabled = RemoteKillSwitchState.decode(result.stdout)
        else {
            remoteStatus = t("unavailable")
            return
        }
        remoteStatus = enabled ? t("on") : t("off")
    }

    private func sendTestPush() {
        isSendingTestPush = true
        pushResult = nil
        Task {
            let result = await commandRunner.run(arguments: ["NotchHUD", t("Test")])
            pushResult = RemoteActionResult(
                succeeded: result.exitCode == 0,
                message: result.exitCode == 0 ? t("Sent ✓") : t("Failed (%d)", result.exitCode)
            )
            isSendingTestPush = false
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    init(
        keepAwakeEngine: KeepAwakeEngine,
        closedLidModeAvailable: Bool,
        spoolURL: URL,
        workingStaleSeconds: TimeInterval,
        dropSeconds: TimeInterval
    ) {
        let settingsView = SettingsView(
            keepAwakeEngine: keepAwakeEngine,
            closedLidModeAvailable: closedLidModeAvailable,
            spoolURL: spoolURL,
            workingStaleSeconds: workingStaleSeconds,
            dropSeconds: dropSeconds
        )
        let hostingView = NSHostingView(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchHUD"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 480, height: 480)
        window.contentMaxSize = NSSize(width: 480, height: 10_000)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        if previousActivationPolicy == nil {
            previousActivationPolicy = NSApp.activationPolicy()
        }
        let policyChanged = NSApp.activationPolicy() == .regular
            || NSApp.setActivationPolicy(.regular)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()
        NSLog(
            "NotchHUD Settings show policyRegular=%d visible=%d key=%d frame=%@",
            policyChanged,
            window.isVisible,
            window.isKeyWindow,
            NSStringFromRect(window.frame)
        )
    }

    func closeSettings() {
        window?.orderOut(nil)
        restoreActivationPolicy()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        restoreActivationPolicy()
        return false
    }

    private func restoreActivationPolicy() {
        guard let previousActivationPolicy else { return }
        self.previousActivationPolicy = nil
        if NSApp.activationPolicy() != previousActivationPolicy {
            NSApp.setActivationPolicy(previousActivationPolicy)
        }
    }
}

private enum DefaultModeChoice: String, CaseIterable, Identifiable {
    case agents
    case apps
    case indefinite

    var id: Self { self }
    var title: String {
        switch self {
        case .agents: t("While agents are working")
        case .apps: t("While the apps are open")
        case .indefinite: t("Indefinitely")
        }
    }
    var mode: KeepAwakeMode {
        switch self {
        case .agents: .whileAgentsWork
        case .apps: .whileAppsRunning
        case .indefinite: .manual
        }
    }

    init(_ mode: KeepAwakeMode) {
        switch mode {
        case .whileAppsRunning: self = .apps
        case .manual: self = .indefinite
        default: self = .agents
        }
    }
}

private struct RemotePairing {
    let url: String

    static func load(from url: URL) -> RemotePairing? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remoteURL = object["url"] as? String,
              let secret = object["secret"] as? String,
              !remoteURL.isEmpty,
              !secret.isEmpty
        else { return nil }
        return RemotePairing(url: remoteURL)
    }
}

private enum RemoteKillSwitchState {
    static func decode(_ output: String) -> Bool? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["keep_awake_enabled"] as? Bool
    }
}

private struct RemoteActionResult {
    let succeeded: Bool
    let message: String
}

private extension View {
    func settingsLabel() -> some View {
        font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
    }

    func settingsCaption() -> some View {
        font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.38))
    }

    func settingsExplanation() -> some View {
        font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
            .fixedSize(horizontal: false, vertical: true)
    }
}
