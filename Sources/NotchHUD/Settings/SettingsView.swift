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
    @State private var remoteStatus = "A verificar…"
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
                settingsSection("All-Nighter", systemImage: "bolt.fill") {
                    allNighterSection
                }
                settingsSection("Sessões", systemImage: "rectangle.stack") {
                    sessionsSection
                }
                settingsSection("Remoto (telemóvel)", systemImage: "iphone") {
                    remoteSection
                }
                settingsSection("Sobre", systemImage: "info.circle") {
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
            settingsRow("Modo predefinido") {
                Picker("", selection: defaultModeBinding) {
                    ForEach(DefaultModeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 225)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("INÍCIO RÁPIDO")
                    .settingsCaption()
                HStack(spacing: 8) {
                    timerButton("30 min", seconds: 30 * 60)
                    timerButton("1 h", seconds: 60 * 60)
                    timerButton("2 h", seconds: 2 * 60 * 60)
                }
            }

            Divider().overlay(.white.opacity(0.08))
            settingsToggle("Permitir que o ecrã durma", isOn: keepAwakeEngine.configBinding(\.allowDisplaySleep))
            settingsToggle(
                "Manter acordado com a tampa fechada",
                isOn: keepAwakeEngine.configBinding(\.closedLidMode)
            )
            .disabled(!closedLidModeAvailable)
            if !closedLidModeAvailable {
                Text("Instala primeiro: sudo scripts/install-all-nighter.sh")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.85))
            }
            settingsToggle(
                "Só com alimentação ligada quando a tampa está fechada",
                isOn: keepAwakeEngine.configBinding(\.acPowerOnlyForClosedLid)
            )
            .disabled(!closedLidModeAvailable || !keepAwakeEngine.config.closedLidMode)
            settingsToggle("Desligar ao desbloquear", isOn: keepAwakeEngine.configBinding(\.autoOffOnUnlock))

            stepperRow(
                "Limite mínimo da bateria",
                value: batteryFloorBinding,
                range: 10...50,
                suffix: "%"
            )
            stepperRow(
                "Período de tolerância",
                value: graceMinutesBinding,
                range: 0...60,
                suffix: " min"
            )

            VStack(alignment: .leading, spacing: 8) {
                settingsToggle("Lembrar quando estiver inativo", isOn: reminderEnabledBinding)
                if keepAwakeEngine.config.reminderAfterIdleSeconds > 0 {
                    stepperRow(
                        "Lembrar após",
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
                    .accessibilityLabel(keepAwakeEngine.isActive ? "Desligar All-Nighter" : "Ligar All-Nighter")

                    Text(statusText(at: context.date))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(keepAwakeEngine.isActive ? .white.opacity(0.78) : .white.opacity(0.42))
                }
            }
        }
    }

    private var watchedAppsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPS VIGIADAS")
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
                    .accessibilityLabel("Remover \(bundleID)")
                }
            }
            HStack(spacing: 8) {
                TextField("com.exemplo.app", text: $watchedBundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(addWatchedBundleID)
                Button("Adicionar", action: addWatchedBundleID)
                    .disabled(watchedBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fixedInfoRow(
                "Sem atualização",
                value: "\(Int(workingStaleSeconds)) s → estado desconhecido"
            )
            fixedInfoRow("Remoção", value: "\(Int(dropSeconds / 60)) min")
            Text("Valores fixos. Clicar numa sessão concluída abre-a e remove o respetivo cartão; os chips Desktop identificam sessões de apps de secretária.")
                .settingsExplanation()
        }
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remotePairing {
                fixedInfoRow("URL", value: remotePairing.url)
                fixedInfoRow("Segredo", value: "••••")
            } else {
                Text("Ainda não emparelhado. Cria ~/.notch-hud/remote.json e consulta a documentação de configuração remota no projeto.")
                    .settingsExplanation()
            }
            fixedInfoRow("Interruptor remoto", value: remoteStatus)
            HStack(spacing: 10) {
                Button("Enviar push de teste") {
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
            fixedInfoRow("Versão", value: "NotchHUD dev")
            fixedInfoRow("Diretório de sessões", value: spoolURL.path)
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
        guard keepAwakeEngine.isActive else { return "All-Nighter desligado" }
        let elapsed = max(0, date.timeIntervalSince(keepAwakeEngine.activeSince ?? date))
        var result = "Ativo há \(compactDuration(elapsed)) · \(modeName(keepAwakeEngine.mode))"
        if let remaining = keepAwakeEngine.remainingTime(at: date) {
            result += " · faltam \(compactDuration(remaining))"
        }
        return result
    }

    private func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes >= 60 ? "\(minutes / 60)h\(minutes % 60)m" : "\(minutes)m"
    }

    private func modeName(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: "desligado"
        case .manual: "indefinido"
        case .timer: "temporizador"
        case .whileAgentsWork: "enquanto os agentes trabalham"
        case .whileAppsRunning: "enquanto as apps estão abertas"
        }
    }

    private func refreshRemoteStatus() async {
        remotePairing = RemotePairing.load(from: remoteConfigURL)
        guard remotePairing != nil else {
            remoteStatus = "não configurado"
            return
        }
        let result = await commandRunner.run(arguments: ["--state"])
        guard result.exitCode == 0,
              let enabled = RemoteKillSwitchState.decode(result.stdout)
        else {
            remoteStatus = "indisponível"
            return
        }
        remoteStatus = enabled ? "ligado" : "desligado"
    }

    private func sendTestPush() {
        isSendingTestPush = true
        pushResult = nil
        Task {
            let result = await commandRunner.run(arguments: ["NotchHUD", "Teste"])
            pushResult = RemoteActionResult(
                succeeded: result.exitCode == 0,
                message: result.exitCode == 0 ? "Enviado ✓" : "Falhou (\(result.exitCode))"
            )
            isSendingTestPush = false
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
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
        fatalError("init(coder:) não é suportado")
    }

    func show() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private enum DefaultModeChoice: String, CaseIterable, Identifiable {
    case agents
    case apps
    case indefinite

    var id: Self { self }
    var title: String {
        switch self {
        case .agents: "Enquanto os agentes trabalham"
        case .apps: "Enquanto as apps estão abertas"
        case .indefinite: "Indefinido"
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
