// BalanceKeeper.app: settings window for the balancekeeperd background agent.
// Runs only while the window is open; the agent does the actual work.
import AudioToolbox
import CoreAudio
import ServiceManagement
import SwiftUI

let prefsDomain = "io.github.fratayaydn.balancekeeper"
let agentPlistName = "io.github.fratayaydn.balancekeeper.agent.plist"
let settingsChangedNotification = Notification.Name("io.github.fratayaydn.balancekeeper.SettingsChanged")
let statusChangedNotification = Notification.Name("io.github.fratayaydn.balancekeeper.StatusChanged")
let lockPointKey = "LockPoint"
let correctionCountKey = "CorrectionCount"
let lastCorrectionKey = "LastCorrection"
let registeredBuildKey = "RegisteredBuildID"
let currentBuildID = Bundle.main.object(forInfoDictionaryKey: "BKBuildID") as? String ?? ""

// MARK: - Audio output

/// The default output device and its balance, read through the same CoreAudio properties the agent uses.
enum AudioOutput {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static let defaultDevice = address(kAudioHardwarePropertyDefaultOutputDevice)
    static let pan = address(kAudioDevicePropertyStereoPan, kAudioDevicePropertyScopeOutput)
    static let virtualBalance = address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioDevicePropertyScopeOutput)

    static func device() -> AudioDeviceID {
        var address = defaultDevice
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func name(_ device: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "Unknown" }
        return name.takeRetainedValue() as String
    }

    /// The balance as System Settings shows it (0 = left, 0.5 = center, 1 = right), or nil without a balance control.
    static func balance(_ device: AudioDeviceID) -> Double? {
        for var address in [pan, virtualBalance] where AudioObjectHasProperty(device, &address) {
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return Double(value) }
        }
        return nil
    }
}

/// "just now" under a minute, then the largest whole unit: "3 minutes ago", "1 hour ago", "2 days ago", "1 month ago".
func timeAgo(_ date: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    let units: [(seconds: Double, name: String)] = [
        (365 * 86400, "year"), (30 * 86400, "month"), (86400, "day"), (3600, "hour"), (60, "minute"),
    ]
    guard let unit = units.first(where: { seconds >= $0.seconds }) else { return "just now" }
    let count = Int(seconds / unit.seconds)
    return "\(count) \(unit.name)\(count == 1 ? "" : "s") ago"
}

func balanceText(_ value: Double) -> String {
    let percent = Int((abs(value - 0.5) * 200).rounded())
    if percent == 0 { return "Center" }
    return "\(percent)% \(value < 0.5 ? "left" : "right")"
}

// MARK: - Model

final class Model: ObservableObject {
    @Published var lockPoint = 0.5
    @Published var outputName = ""
    @Published var outputBalance: Double?
    @Published var correctionCount = 0
    @Published var lastCorrection: Date?
    @Published var agentStatus = SMAppService.Status.notRegistered

    // The app's bundle identifier is prefsDomain, so its standard defaults are the domain the agent reads.
    private let defaults = UserDefaults.standard
    private let agent = SMAppService.agent(plistName: agentPlistName)
    private var watchedDevice = AudioDeviceID(kAudioObjectUnknown)
    private lazy var outputChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.readOutput() }

    init() {
        reregisterAfterUpdate()
        if let stored = defaults.object(forKey: lockPointKey) as? Double { lockPoint = min(max(stored, 0), 1) }
        readAgentState()
        readOutput()
        // Event-driven like the agent: CoreAudio reports output device and balance changes while the window is open.
        var address = AudioOutput.defaultDevice
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputChanged)
        DistributedNotificationCenter.default().addObserver(forName: statusChangedNotification, object: nil, queue: .main) {
            [weak self] _ in self?.readAgentState()
        }
    }

    func readOutput() {
        let device = AudioOutput.device()
        if device != watchedDevice {
            for var address in [AudioOutput.pan, AudioOutput.virtualBalance] {
                if watchedDevice != kAudioObjectUnknown {
                    AudioObjectRemovePropertyListenerBlock(watchedDevice, &address, .main, outputChanged)
                }
                if AudioObjectHasProperty(device, &address) {
                    AudioObjectAddPropertyListenerBlock(device, &address, .main, outputChanged)
                }
            }
            watchedDevice = device
        }
        outputName = AudioOutput.name(device)
        outputBalance = AudioOutput.balance(device)
    }

    func readAgentState() {
        agentStatus = agent.status
        defaults.synchronize()
        correctionCount = defaults.integer(forKey: correctionCountKey)
        lastCorrection = defaults.object(forKey: lastCorrectionKey) as? Date
    }

    /// launchd only starts the agent build that was registered when the app is signed locally (its code signature
    /// is part of the launch constraint), so after an update the agent is registered again, if it was enabled.
    private func reregisterAfterUpdate() {
        guard defaults.string(forKey: registeredBuildKey) != currentBuildID else { return }
        defaults.set(currentBuildID, forKey: registeredBuildKey)
        guard agent.status == .enabled else { return }
        DispatchQueue.global().async { [weak self] in
            reregisterAgent()
            if !agentIsRunning() { reregisterAgent() }  // right after an update the first pass may not take
            DispatchQueue.main.async { self?.readAgentState() }
        }
    }

    func setLockPoint(_ value: Double) {
        // Snap to center near the middle, like a detent: center is what almost everyone wants.
        let value = abs(value - 0.5) < 0.02 ? 0.5 : min(max(value, 0), 1)
        lockPoint = value
        defaults.set(value, forKey: lockPointKey)
        defaults.synchronize()
        // The agent moves the macOS balance (System Settings shows it live). Setting it here as well would race
        // with this notification: the agent would see the change before the new lock point, undo it and count it.
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, deliverImmediately: true)
    }

    var isEnabled: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setAgentEnabled(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            NSLog("BalanceKeeper: could not \(on ? "register" : "unregister") the agent: \(error)")
        }
        readAgentState()
    }
}

// MARK: - Window

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        Form {
            Section {
                // Two texts in a Form row label: macOS shows the second one as the row's grey description.
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setAgentEnabled($0) })) {
                    Text("Enable BalanceKeeper")
                    Text("Keeps the left/right audio balance where you set it. macOS sometimes shifts it on its own, often after the volume keys are pressed while the Mac is busy.")
                }
                statusRow
            }

            Section("Balance") {
                LabeledContent {
                    HStack {
                        Slider(value: Binding(get: { model.lockPoint }, set: { model.setLockPoint($0) }), in: 0...1) {
                            Text("Keep balance at")
                        } minimumValueLabel: {
                            Text("L").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("R").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        Text(balanceText(model.lockPoint)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                } label: {
                    Text("Keep balance at")
                }
                if model.lockPoint != 0.5 {
                    LabeledContent("") {
                        Button("Center") { model.setLockPoint(0.5) }
                    }
                }
            }
            .disabled(!model.isEnabled)
            .opacity(model.isEnabled ? 1 : 0.45)

            Section("Now") {
                LabeledContent("Output", value: model.outputName)
                LabeledContent("Balance", value: model.outputBalance.map(balanceText) ?? "No balance control")
                LabeledContent("Corrected") {
                    // Computed when the window opens and then once a minute, not on every redraw.
                    TimelineView(.everyMinute) { context in
                        Text(correctionText(now: context.date)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func correctionText(now: Date) -> String {
        guard model.correctionCount > 0 else { return "Not yet" }
        let times = model.correctionCount == 1 ? "Once" : "\(model.correctionCount) times"
        guard let last = model.lastCorrection else { return times }
        return "\(times), last \(timeAgo(last, now: now))"
    }

    @ViewBuilder private var statusRow: some View {
        switch model.agentStatus {
        case .enabled:
            StatusRow(symbol: "checkmark.circle.fill", color: .green, title: "BalanceKeeper Is On",
                      detail: model.lockPoint == 0.5
                          ? "The balance stays centered on every output, including headphones."
                          : "The balance stays at \(balanceText(model.lockPoint).lowercased()) on every output, including headphones.")
        case .requiresApproval:
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                      title: "Approval Required",
                      detail: "Allow BalanceKeeper under \u{201C}Allow in the Background\u{201D} so it can run without this window.",
                      action: ("Open Login Items\u{2026}", { SMAppService.openSystemSettingsLoginItems() }))
        default:
            StatusRow(symbol: "circle", color: .secondary, title: "BalanceKeeper Is Off",
                      detail: "macOS controls the audio balance as usual.")
        }
    }
}

/// A status line in the style of System Settings: symbol, title, explanation and an optional button.
struct StatusRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.label, action: action.run).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Login item

let agentJob = "gui/\(getuid())/io.github.fratayaydn.balancekeeper.agent"

@discardableResult
func launchctl(_ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Starts the agent once through launchd. After an update this makes launchd pin the agent to the new build;
/// without it the job can stay stuck with "needs LWCR update" (see scripts/install.sh).
func startAgentOnce() { launchctl(["kickstart", agentJob]) }

func agentIsRunning() -> Bool { launchctl(["print", agentJob]).contains("state = running") }

/// Unregister, wait until launchd has dropped the job, register and start once: the sequence that refreshes
/// the agent's launch constraint after an update (see scripts/install.sh).
func reregisterAgent() {
    let agent = SMAppService.agent(plistName: agentPlistName)
    try? agent.unregister()
    for _ in 0..<70 where !launchctl(["print", agentJob]).isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    Thread.sleep(forTimeInterval: 1)
    try? agent.register()
    startAgentOnce()
    Thread.sleep(forTimeInterval: 2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `BalanceKeeper --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? SMAppService.agent(plistName: agentPlistName).unregister()
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            do {
                try SMAppService.agent(plistName: agentPlistName).register()
                startAgentOnce()
                // This build is registered now; the window must not re-register it again (see reregisterAfterUpdate).
                UserDefaults.standard.set(currentBuildID, forKey: registeredBuildKey)
                UserDefaults.standard.synchronize()  // exit() would otherwise drop the unsaved value
                exit(0)
            } catch {
                FileHandle.standardError.write("BalanceKeeper: could not register the background agent: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BalanceKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("BalanceKeeper", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
