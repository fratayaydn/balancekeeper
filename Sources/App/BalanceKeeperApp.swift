// BalanceKeeper.app: settings window for the balancekeeperd background agent.
// Runs only while the window is open; the agent does the actual work.
import AudioToolbox
import CoreAudio
import ServiceManagement
import SwiftUI

let prefsDomain = "io.github.fratayaydn.balancekeeper"
let agentPlistName = "io.github.fratayaydn.balancekeeper.agent.plist"
let updaterPlistName = "io.github.fratayaydn.balancekeeper.updater.plist"
let settingsChangedNotification = Notification.Name("io.github.fratayaydn.balancekeeper.SettingsChanged")
let statusChangedNotification = Notification.Name("io.github.fratayaydn.balancekeeper.StatusChanged")
let lockPointKey = "LockPoint"
let correctionCountKey = "CorrectionCount"
let lastCorrectionKey = "LastCorrection"
let registeredBuildKey = "RegisteredBuildID"
let reregistrationPendingKey = "ReregistrationPending"
let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
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

enum ReregistrationAction {
    case none, storeBuildID, reregister
}

func reregistrationAction(storedBuildID: String?, currentBuildID: String, pending: Bool,
                          agentStatus: SMAppService.Status, updaterStatus: SMAppService.Status) -> ReregistrationAction {
    if pending { return .reregister }
    guard storedBuildID != currentBuildID || updaterStatus == .notRegistered || updaterStatus == .notFound else {
        return .none
    }
    return agentStatus == .enabled || agentStatus == .requiresApproval ? .reregister : .storeBuildID
}

final class Model: ObservableObject {
    @Published var lockPoint = 0.5
    @Published var outputName = ""
    @Published var outputBalance: Double?
    @Published var correctionCount = 0
    @Published var lastCorrection: Date?
    @Published var agentStatus = SMAppService.Status.notRegistered
    @Published var errorMessage: String?
    @Published var latestVersion: String?
    @Published var automaticUpdates = true
    @Published var lastUpdateCheck: Date?
    @Published var installedVersion = currentVersion
    @Published var updateStatus: String?
    @Published var updateInProgress = false

    private var updateProcess: Process?
    private var reregistering = false

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
        if !reregistering { agentStatus = agent.status }
        defaults.synchronize()
        correctionCount = defaults.integer(forKey: correctionCountKey)
        lastCorrection = defaults.object(forKey: lastCorrectionKey) as? Date
        automaticUpdates = defaults.object(forKey: "AutomaticallyInstallUpdates") == nil
            || defaults.bool(forKey: "AutomaticallyInstallUpdates")
        lastUpdateCheck = defaults.object(forKey: "LastUpdateCheck") as? Date
        let data = try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            as? [String: Any]
        installedVersion = info?["CFBundleShortVersionString"] as? String ?? currentVersion
        latestVersion = availableUpdate(defaults.object(forKey: "LatestVersion"), current: installedVersion)
    }

    /// launchd only starts the agent build that was registered when the app is signed locally (its code signature
    /// is part of the launch constraint), so after an update the agent is registered again, if it was enabled.
    private func reregisterAfterUpdate() {
        switch reregistrationAction(storedBuildID: defaults.string(forKey: registeredBuildKey),
                                    currentBuildID: currentBuildID,
                                    pending: defaults.bool(forKey: reregistrationPendingKey),
                                    agentStatus: agent.status,
                                    updaterStatus: SMAppService.agent(plistName: updaterPlistName).status) {
        case .none: return
        case .storeBuildID:
            defaults.set(currentBuildID, forKey: registeredBuildKey)
            return
        case .reregister: break
        }
        defaults.set(true, forKey: reregistrationPendingKey)
        defaults.synchronize()
        agentStatus = agent.status  // shown until the sequence ends
        reregistering = true
        DispatchQueue.global().async { [weak self, defaults] in
            var result = reregisterAgent()
            if result != .skipped && !agentIsRunning() { result = reregisterAgent() }  // right after an update the first pass may not take
            if result != .failed {
                defaults.set(currentBuildID, forKey: registeredBuildKey)
                if result == .registered { defaults.removeObject(forKey: reregistrationPendingKey) }
                defaults.synchronize()
            }
            DispatchQueue.main.async {
                self?.reregistering = false
                if result == .failed {
                    self?.errorMessage = "Could not enable BalanceKeeper after the update. Close and reopen BalanceKeeper to try again."
                }
                self?.readAgentState()
            }
        }
    }

    func runUpdate(install: Bool) {
        guard !updateInProgress else { return }
        updateInProgress = true
        updateStatus = install ? "Downloading and installing update..." : "Checking for updates..."
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/balancekeeper-update")
        process.arguments = [install ? "--install" : "--check"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateProcess = nil
                self.readAgentState()
                guard finished.terminationReason == .exit && finished.terminationStatus == 0 else {
                    self.updateInProgress = false
                    self.updateStatus = install ? "Could not install the update. Try again." : "Could not check for updates. Try again."
                    return
                }
                if install && self.installedVersion != currentVersion {
                    self.updateStatus = "Restarting BalanceKeeper..."
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                        DispatchQueue.main.async {
                            if error == nil {
                                NSApp.terminate(nil)
                            } else {
                                self.updateInProgress = false
                                self.updateStatus = "Updated. Quit and reopen BalanceKeeper."
                            }
                        }
                    }
                } else {
                    self.updateInProgress = false
                    self.updateStatus = self.latestVersion == nil ? "BalanceKeeper is up to date" : nil
                }
            }
        }
        updateProcess = process
        do {
            try process.run()
        } catch {
            updateProcess = nil
            updateInProgress = false
            updateStatus = "Could not start the updater. Try again."
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

    var lastCheckedText: String {
        guard let lastUpdateCheck else { return "last checked never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "last checked \(formatter.localizedString(for: lastUpdateCheck, relativeTo: Date()))"
    }

    func setAutomaticUpdates(_ on: Bool) {
        defaults.set(on, forKey: "AutomaticallyInstallUpdates")
        defaults.synchronize()
        automaticUpdates = on
    }

    func setAgentEnabled(_ on: Bool) {
        reregistering = false  // the user's choice is shown at once
        defaults.removeObject(forKey: reregistrationPendingKey)
        defaults.synchronize()
        do {
            try setLoginItemsEnabled(on)
        } catch {
            errorMessage = "Could not \(on ? "enable" : "disable") BalanceKeeper: \(error.localizedDescription)"
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
            Section("Updates") {
                Toggle(isOn: Binding(get: { model.automaticUpdates }, set: { model.setAutomaticUpdates($0) })) {
                    Text("Install updates automatically")
                    Text("Only updates signed by the developer and notarized by Apple.")
                }
                HStack {
                    Text("Version \(model.installedVersion), \(model.lastCheckedText)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates") { model.runUpdate(install: false) }
                        .disabled(model.updateInProgress)
                }
                if let status = model.updateStatus ?? model.latestVersion.map({ "Version \($0) is available" }) {
                    HStack {
                        Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if model.latestVersion != nil {
                            Button("Update") { model.runUpdate(install: true) }
                                .disabled(model.updateInProgress)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.readAgentState() }
        .alert("BalanceKeeper", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
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

// MARK: - Login items

let agentJob = "gui/\(getuid())/io.github.fratayaydn.balancekeeper.agent"
let updaterJob = "gui/\(getuid())/io.github.fratayaydn.balancekeeper.updater"

// Remove the updater first, since removing the agent can terminate the background process.
func setLoginItemsEnabled(_ enabled: Bool) throws {
    let names = enabled ? [agentPlistName, updaterPlistName] : [updaterPlistName, agentPlistName]
    var firstError: Error?
    for name in names {
        let service = SMAppService.agent(plistName: name)
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            if firstError == nil { firstError = error }
        }
    }
    if let firstError { throw firstError }
}

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

enum ReregistrationResult {
    case registered, skipped, failed
}

/// Unregister, wait until launchd has dropped the job, register and start once: the sequence that refreshes
/// the agent's launch constraint after an update (see scripts/install.sh).
func reregisterAgent() -> ReregistrationResult {
    try? setLoginItemsEnabled(false)
    for job in [updaterJob, agentJob] {
        for _ in 0..<70 {
            if launchctl(["print", job]).isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
    Thread.sleep(forTimeInterval: 1)
    guard UserDefaults.standard.bool(forKey: reregistrationPendingKey) else { return .skipped }
    try? setLoginItemsEnabled(true)
    let agent = SMAppService.agent(plistName: agentPlistName)
    let success = agent.status == .enabled || agent.status == .requiresApproval
    startAgentOnce()
    Thread.sleep(forTimeInterval: 2)
    return success ? .registered : .failed
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `BalanceKeeper --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? setLoginItemsEnabled(false)
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            do {
                try setLoginItemsEnabled(true)
                startAgentOnce()
                // This build is registered now; the window must not re-register it again (see reregisterAfterUpdate).
                UserDefaults.standard.set(currentBuildID, forKey: registeredBuildKey)
                UserDefaults.standard.removeObject(forKey: reregistrationPendingKey)
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
