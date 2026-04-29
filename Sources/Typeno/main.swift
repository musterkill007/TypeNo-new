import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import Combine
import Foundation
import QuartzCore
import SwiftUI
import TypeNoCore

// MARK: - Localization Helper

/// Returns `zh` when the system's first preferred language is Chinese, otherwise `en`.
func L(_ en: String, _ zh: String) -> String {
    Locale.preferredLanguages.first.map { $0.hasPrefix("zh") } == true ? zh : en
}

// MARK: - Hotkey Configuration

enum HotkeyModifier: String, Codable, CaseIterable {
    case leftControl  = "LeftControl"
    case rightControl = "RightControl"
    case leftOption   = "LeftOption"
    case rightOption  = "RightOption"
    case leftCommand  = "LeftCommand"
    case rightCommand = "RightCommand"
    case leftShift    = "LeftShift"
    case rightShift   = "RightShift"

    var symbol: String {
        switch self {
        case .leftControl,  .rightControl: "⌃"
        case .leftOption,   .rightOption:  "⌥"
        case .leftCommand,  .rightCommand: "⌘"
        case .leftShift,    .rightShift:   "⇧"
        }
    }

    var label: String {
        switch self {
        case .leftControl:  L("⌃ Left Control",  "⌃ 左 Control")
        case .rightControl: L("⌃ Right Control", "⌃ 右 Control")
        case .leftOption:   L("⌥ Left Option",   "⌥ 左 Option")
        case .rightOption:  L("⌥ Right Option",  "⌥ 右 Option")
        case .leftCommand:  L("⌘ Left Command",  "⌘ 左 Command")
        case .rightCommand: L("⌘ Right Command", "⌘ 右 Command")
        case .leftShift:    L("⇧ Left Shift",    "⇧ 左 Shift")
        case .rightShift:   L("⇧ Right Shift",   "⇧ 右 Shift")
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftControl,  .rightControl: .control
        case .leftOption,   .rightOption:  .option
        case .leftCommand,  .rightCommand: .command
        case .leftShift,    .rightShift:   .shift
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftControl:  59
        case .rightControl: 62
        case .leftOption:   58
        case .rightOption:  61
        case .leftCommand:  55
        case .rightCommand: 54
        case .leftShift:    56
        case .rightShift:   60
        }
    }
}

enum TriggerMode: String, Codable, CaseIterable {
    case singleTap = "SingleTap"
    case doubleTap = "DoubleTap"

    var label: String {
        switch self {
        case .singleTap: L("1× Single Tap", "1× 单击")
        case .doubleTap: L("2× Double Tap", "2× 双击")
        }
    }
}

enum MicrophoneSelection: Equatable {
    case automatic
    case specific(String)

    init(storedValue: String?) {
        if let storedValue, !storedValue.isEmpty {
            self = .specific(storedValue)
        } else {
            self = .automatic
        }
    }

    var uniqueID: String? {
        switch self {
        case .automatic: nil
        case .specific(let uniqueID): uniqueID
        }
    }
}

struct MicrophoneOption: Equatable {
    let uniqueID: String
    let localizedName: String
}

extension UserDefaults {
    private static let modifierKey   = "ai.marswave.typeno.hotkeyModifier"
    private static let triggerKey    = "ai.marswave.typeno.triggerMode"
    private static let microphoneKey = "ai.marswave.typeno.microphone"

    var hotkeyModifier: HotkeyModifier {
        get {
            guard let raw = string(forKey: Self.modifierKey),
                  let v = HotkeyModifier(rawValue: raw) else { return .leftControl }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.modifierKey) }
    }

    var triggerMode: TriggerMode {
        get {
            guard let raw = string(forKey: Self.triggerKey),
                  let v = TriggerMode(rawValue: raw) else { return .singleTap }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.triggerKey) }
    }

    var microphoneSelection: MicrophoneSelection {
        get { MicrophoneSelection(storedValue: string(forKey: Self.microphoneKey)) }
        set {
            if let storedValue = newValue.uniqueID {
                set(storedValue, forKey: Self.microphoneKey)
            } else {
                removeObject(forKey: Self.microphoneKey)
            }
        }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("ai.marswave.typeno.hotkeyConfigChanged")
}

extension NSScreen {
    static var typenoNotchPreferred: NSScreen? {
        screens.first { $0.typenoIsBuiltInDisplay } ?? main
    }

    private var typenoIsBuiltInDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }

        return CGDisplayIsBuiltin(screenNumber) != 0
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: StatusItemController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var overlayController: OverlayPanelController?
    private var permissionsGranted = false
    private var pollTimer: Timer?
    private let updateService = UpdateService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = OverlayPanelController(appState: appState)
        statusItemController = StatusItemController(appState: appState)
        hotkeyMonitor = HotkeyMonitor(
            modifier: UserDefaults.standard.hotkeyModifier,
            triggerMode: UserDefaults.standard.triggerMode,
            onToggle: { [weak self] in self?.handleToggle() }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restartHotkeyMonitor),
            name: .hotkeyConfigChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceContextDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceContextDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        appState.onToggleRequest = { [weak self] in
            self?.handleToggle()
        }

        appState.onOverlayRequest = { [weak self] visible in
            if visible {
                self?.overlayController?.show()
            } else {
                self?.overlayController?.hide()
            }
        }

        appState.onRecordingIslandHoverRegionCheck = { [weak self] in
            self?.overlayController?.isMouseInsideRecordingIslandRegion() ?? false
        }

        appState.onPermissionOpen = { [weak self] kind in
            self?.openPermissionSettings(for: kind)
        }

        appState.onCancel = { [weak self] in
            self?.cancelFlow()
        }

        appState.onConfirm = { [weak self] in
            self?.appState.confirmInsert()
        }

        appState.onUpdateRequest = { [weak self] in
            self?.performUpdate()
        }

        // Auto-poll permissions and coli install status
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFullscreenIdleIslandSuppression()
                self?.pollStatus()
            }
        }

        hotkeyMonitor?.start()
        refreshFullscreenIdleIslandSuppression()

        seedDebugHistoryIfNeeded()
        startDebugAutoRecordingIfNeeded()
        showDependencyGuideIfNeeded()

        // Silent update check on launch
        Task {
            if let release = await updateService.checkForUpdate() {
                statusItemController?.setUpdateAvailable(release.version)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func seedDebugHistoryIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        if let previewText = environment["TYPENO_DEBUG_PREVIEW_TEXT"] {
            appState.phase = .recording
            appState.previewTranscript = previewText
            appState.islandHovering = environment["TYPENO_DEBUG_PREVIEW_COLLAPSED"] != "1"
            appState.onOverlayRequest?(true)
            return
        }

        guard environment["TYPENO_DEBUG_SEED_HISTORY"] == "1" else {
            return
        }

        let historyTexts: [String]
        if let historyItems = environment["TYPENO_DEBUG_HISTORY_ITEMS"] {
            historyTexts = historyItems
                .components(separatedBy: "||")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            historyTexts = [
                environment["TYPENO_DEBUG_HISTORY_TEXT"]
                    ?? "Debug history item for notch placement verification."
            ]
        }
        for text in historyTexts.reversed() {
            appState.transcriptHistory.record(text)
        }
        let suppressIdleIsland = environment["TYPENO_DEBUG_FULLSCREEN_SUPPRESSED"] == "1"
        appState.setIdleIslandSuppressedForFullscreen(suppressIdleIsland)
        appState.historyOpen = !suppressIdleIsland && environment["TYPENO_DEBUG_OPEN_HISTORY"] == "1"
        appState.onOverlayRequest?(appState.shouldShowIdleIsland)
    }

    private func startDebugAutoRecordingIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TYPENO_DEBUG_AUTO_RECORD"] == "1" else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            do {
                try self.appState.startRecording()
                if environment["TYPENO_DEBUG_AUTO_RECORD_EXPANDED"] == "1" {
                    self.appState.setIslandHovering(true)
                }
            } catch {
                self.appState.showError(error.localizedDescription)
            }
        }
    }

    private func showDependencyGuideIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let hasDebugOverlay = environment["TYPENO_DEBUG_PREVIEW_TEXT"] != nil
            || environment["TYPENO_DEBUG_SEED_HISTORY"] == "1"
            || environment["TYPENO_DEBUG_AUTO_RECORD"] == "1"
        guard !hasDebugOverlay else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.appState.showDependencyGuideIfNeeded()
        }
    }

    @objc private func workspaceContextDidChange(_ notification: Notification) {
        refreshFullscreenIdleIslandSuppression()
    }

    private func refreshFullscreenIdleIslandSuppression() {
        if ProcessInfo.processInfo.environment["TYPENO_DEBUG_FULLSCREEN_SUPPRESSED"] == "1" {
            appState.setIdleIslandSuppressedForFullscreen(true)
            return
        }

        guard let frontmostAppIsFullscreen = ActiveAppFullscreenDetector.frontmostExternalApplicationIsFullscreen() else {
            return
        }
        appState.setIdleIslandSuppressedForFullscreen(frontmostAppIsFullscreen)
    }

    private func pollStatus() {
        switch appState.phase {
        case .permissions:
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: false)
            if missing.isEmpty {
                permissionsGranted = true
                appState.hidePermissions()
            } else {
                appState.showPermissions(missing)
            }
        case .missingColi:
            let dependencyStatus = appState.refreshDependencyStatus()
            if dependencyStatus.isReady {
                appState.hideColiGuidance()
            } else if dependencyStatus.canAutoInstallFFmpeg && !appState.autoInstallBlocked(for: .ffmpeg) {
                appState.autoInstallFFmpeg()
            } else if dependencyStatus.canAutoInstallColi && !appState.autoInstallBlocked(for: .coli) {
                appState.autoInstallColi()
            }
        default:
            break
        }
    }

    private func handleToggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .done:
            appState.confirmInsert()
        case .transcribing, .error:
            appState.cancel()
        case .permissions, .missingColi, .installingColi, .updating:
            break
        }
    }

    @objc private func restartHotkeyMonitor() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = HotkeyMonitor(
            modifier: UserDefaults.standard.hotkeyModifier,
            triggerMode: UserDefaults.standard.triggerMode,
            onToggle: { [weak self] in self?.handleToggle() }
        )
        hotkeyMonitor?.start()
    }

    private func startRecording() {
        // Only check permissions if not previously granted this session
        if !permissionsGranted {
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: true, requestAccessibilityIfNeeded: true)
            if !missing.isEmpty {
                appState.showPermissions(missing)
                return
            }
            permissionsGranted = true
        }

        guard appState.refreshDependencyStatus().isReady else {
            appState.showMissingColi()
            return
        }

        do {
            try appState.startRecording()
        } catch {
            appState.showError(error.localizedDescription)
        }
    }

    private func stopRecording() {
        Task { @MainActor in
            do {
                try await appState.stopRecording()
                await appState.transcribeAndInsert()
            } catch is CancellationError {
                // User canceled; keep app in reset state
            } catch {
                appState.showError(error.localizedDescription)
            }
        }
    }

    private func cancelFlow() {
        appState.cancel()
    }

    private func openPermissionSettings(for kind: PermissionKind) {
        PermissionManager.openPrivacySettings(for: [kind])
    }

    private func performUpdate() {
        Task {
            appState.phase = .updating(L("Checking for updates...", "检查更新..."))
            appState.onOverlayRequest?(true)

            switch await updateService.checkForUpdateDetailed() {
            case .upToDate:
                appState.phase = .updating(L("Already up to date", "已是最新版本"))
                try? await Task.sleep(for: .seconds(2))
                appState.phase = .idle
                appState.onOverlayRequest?(false)

            case .rateLimited:
                appState.showError(L("GitHub rate limit — try again later", "GitHub 请求限制，请稍后重试"))

            case .failed:
                appState.showError(L("Could not check for updates", "无法检查更新"))

            case .updateAvailable(let release):
                appState.phase = .updating(L("v\(release.version) available", "v\(release.version) 可更新"))
                appState.onOverlayRequest?(true)
                try? await Task.sleep(for: .seconds(1.5))
                appState.phase = .idle
                appState.onOverlayRequest?(false)
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateService.repoOwner)/\(UpdateService.repoName)/releases/latest")!)
            }
        }
    }
}

enum ActiveAppFullscreenDetector {
    private static let fullScreenAttribute = "AXFullScreen"

    static func frontmostExternalApplicationIsFullscreen() -> Bool? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        if application.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }

        return applicationIsFullscreen(application)
    }

    private static func applicationIsFullscreen(_ application: NSRunningApplication) -> Bool {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        if windowAttributeIsFullscreen(kAXFocusedWindowAttribute, in: applicationElement) {
            return true
        }
        if windowAttributeIsFullscreen(kAXMainWindowAttribute, in: applicationElement) {
            return true
        }

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success else {
            return false
        }

        guard let windows = windowsValue as? [AXUIElement] else {
            return false
        }

        return windows.contains { windowIsFullscreen($0) }
    }

    private static func windowAttributeIsFullscreen(_ attribute: String, in applicationElement: AXUIElement) -> Bool {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            attribute as CFString,
            &windowValue
        ) == .success,
            let window = windowValue,
            CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return false
        }

        return windowIsFullscreen(window as! AXUIElement)
    }

    private static func windowIsFullscreen(_ window: AXUIElement) -> Bool {
        var fullscreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            fullScreenAttribute as CFString,
            &fullscreenValue
        ) == .success,
            let fullscreenValue,
            CFGetTypeID(fullscreenValue) == CFBooleanGetTypeID() else {
            return false
        }

        return CFBooleanGetValue((fullscreenValue as! CFBoolean))
    }
}

// MARK: - Model

enum PermissionKind: CaseIterable, Hashable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone: L("Microphone", "麦克风")
        case .accessibility: L("Accessibility", "辅助功能")
        }
    }

    var explanation: String {
        switch self {
        case .microphone: L("Required to capture your voice", "用于捕获语音")
        case .accessibility: L("Required to type text into apps", "用于向应用输入文字")
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic.fill"
        case .accessibility: "hand.raised.fill"
        }
    }
}

enum AppPhase: Equatable {
    case idle
    case recording
    case transcribing(String? = nil)
    case done(String)        // transcription result, waiting for user confirm
    case permissions(Set<PermissionKind>)
    case missingColi
    case installingColi(String) // progress message
    case updating(String)    // progress message
    case error(String)

    var subtitle: String {
        switch self {
        case .idle:
            return L("Press Fn to start", "按 Fn 开始")
        case .recording:
            return L("Listening...", "录音中...")
        case .transcribing(let message):
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? L("Transcribing...", "转录中...") : trimmed
        case .done(let text):
            return text
        case .permissions, .missingColi, .installingColi:
            return ""
        case .updating(let message):
            return message
        case .error(let message):
            return message
        }
    }
}

enum DependencyID: CaseIterable, Hashable, Identifiable {
    case node
    case ffmpeg
    case coli

    var id: Self { self }

    var title: String {
        switch self {
        case .node: "Node.js / npm"
        case .ffmpeg: "ffmpeg"
        case .coli: "coli"
        }
    }

    var icon: String {
        switch self {
        case .node: "hexagon"
        case .ffmpeg: "waveform"
        case .coli: "brain.head.profile"
        }
    }
}

struct DependencyStatus: Equatable {
    var nodePath: String?
    var npmPath: String?
    var ffmpegPath: String?
    var brewPath: String?
    var coliPath: String?

    static func detect() -> DependencyStatus {
        DependencyStatus(
            nodePath: ColiASRService.findNodePath(),
            npmPath: ColiASRService.findNpmPath(),
            ffmpegPath: ColiASRService.findFFmpegPath(),
            brewPath: ColiASRService.findBrewPath(),
            coliPath: ColiASRService.findPreviewCapableColiPath()
        )
    }

    var isReady: Bool {
        npmPath != nil && ffmpegPath != nil && coliPath != nil
    }

    var missingDependencies: [DependencyID] {
        DependencyID.allCases.filter { !isReady($0) }
    }

    var canAutoInstallFFmpeg: Bool {
        ffmpegPath == nil && brewPath != nil
    }

    var canAutoInstallColi: Bool {
        npmPath != nil && ffmpegPath != nil && coliPath == nil
    }

    func isReady(_ dependency: DependencyID) -> Bool {
        switch dependency {
        case .node: npmPath != nil
        case .ffmpeg: ffmpegPath != nil
        case .coli: coliPath != nil
        }
    }

    func detail(for dependency: DependencyID) -> String {
        switch dependency {
        case .node:
            if let npmPath {
                return L("Found npm at \(npmPath)", "已找到 npm：\(npmPath)")
            }
            return L("Install Node.js first so TypeNo can use npm.", "请先安装 Node.js，TypeNo 才能使用 npm。")
        case .ffmpeg:
            if let ffmpegPath {
                return L("Found ffmpeg at \(ffmpegPath)", "已找到 ffmpeg：\(ffmpegPath)")
            }
            if brewPath != nil {
                return L("TypeNo can install ffmpeg with Homebrew.", "TypeNo 可以通过 Homebrew 安装 ffmpeg。")
            }
            return L("Install Homebrew, then run brew install ffmpeg.", "请先安装 Homebrew，然后执行 brew install ffmpeg。")
        case .coli:
            if let coliPath {
                return L("Found coli at \(coliPath)", "已找到 coli：\(coliPath)")
            }
            if npmPath != nil && ffmpegPath != nil {
                return L("TypeNo can install coli automatically with npm.", "TypeNo 可以通过 npm 自动安装 coli。")
            }
            return L("coli will be installed after Node.js and ffmpeg are ready.", "Node.js 和 ffmpeg 准备好后会安装 coli。")
        }
    }

    var setupCommands: [String] {
        var commands: [String] = []
        if npmPath == nil {
            commands.append("# Install Node.js from https://nodejs.org")
        }
        if ffmpegPath == nil {
            if brewPath == nil {
                commands.append("# Install Homebrew from https://brew.sh")
            }
            commands.append("brew install ffmpeg")
        }
        if coliPath == nil {
            commands.append("npm install -g @marswave/coli")
        }
        return commands
    }
}

struct PreviewStreamPayload: Sendable {
    let data: Data
    let isFinal: Bool
}

private final class PreviewAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }

    func isEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    var transcript = ""
    @Published var previewTranscript = ""
    @Published var islandHovering = false
    @Published var islandPinnedOpen = false
    @Published var historyOpen = false
    @Published var suppressIdleIslandForFullscreenApp = false
    @Published var transcriptHistory = TranscriptHistory()
    @Published var islandWidth = CompactIslandMetrics.width
    @Published var collapsedRecordingRailWidth = CompactIslandMetrics.collapsedRecordingWidth
    @Published var historyPanelWidth = CompactIslandMetrics.historyPanelMinimumWidth
    @Published var previewPanelWidth = CompactIslandMetrics.previewPanelMinimumWidth
    @Published var collapsedRecordingSpacerWidth = CompactIslandMetrics.collapsedRecordingSpacerWidth(
        for: ScreenGeometry(frame: .zero, visibleFrame: .zero, safeAreaTop: 0)
    )
    @Published var notchAttachmentHeight: CGFloat = 0
    @Published var usesTopOverlayHost = false
    @Published var overlayHostWidth: CGFloat = CompactIslandMetrics.width
    @Published var overlayHostHeight: CGFloat = 420
    @Published var overlayContentX: CGFloat = 0
    @Published var overlayContentY: CGFloat = 0
    @Published var overlayContentWidth: CGFloat = CompactIslandMetrics.width
    @Published var overlayContentHeight: CGFloat = CompactIslandMetrics.minimumHeight
    @Published var overlayPreviewTextViewportHeight: CGFloat = 18
    @Published var overlayHistoryRowsViewportHeight: CGFloat = 26
    @Published var overlayLayoutPlan: OverlayLayoutPlan?
    @Published var dependencyStatus = DependencyStatus.detect()
    @Published var dependencyErrorMessage: String?

    var onOverlayRequest: ((Bool) -> Void)?
    var onPermissionOpen: ((PermissionKind) -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onToggleRequest: (() -> Void)?
    var onUpdateRequest: (() -> Void)?
    var onRecordingIslandHoverRegionCheck: (() -> Bool)?

    private let recorder = AudioRecorder()
    private let asrService = ColiASRService()
    private var currentRecordingURL: URL?
    private var previousApp: NSRunningApplication?
    private var recordingTimer: Timer?
    private var hoverCollapseWorkItem: DispatchWorkItem?
    private var previewOverlayRefreshWorkItem: DispatchWorkItem?
    private var previewStreamShutdownWorkItem: DispatchWorkItem?
    private var lastPreviewOverlayRefreshAt: CFTimeInterval = 0
    private let previewOverlayRefreshInterval: CFTimeInterval = 0.12
    private let previewStreamIdleShutdownDelay: TimeInterval = 3.0
    private var previewActive = false
    private var previewStreamActive = false
    private let previewAudioGate = PreviewAudioGate()
    private var measuredPreviewTextSize: CGSize = CGSize(width: 0, height: 18)
    private var measuredHistoryRowSizes: [UUID: CGSize] = [:]
    private var blockedAutoInstallDependencies = Set<DependencyID>()
    @Published var recordingElapsedSeconds: Int = 0

    var recordingElapsedStr: String {
        let m = recordingElapsedSeconds / 60
        let s = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    func startRecording() throws {
        transcript = ""
        previewTranscript = ""
        measuredPreviewTextSize = CGSize(width: 0, height: 18)
        overlayPreviewTextViewportHeight = 18
        islandPinnedOpen = false
        historyOpen = false
        islandHovering = false
        cancelRecordingHoverCollapse()
        cancelPreviewOverlayRefresh()
        cancelPreviewStreamShutdown()
        lastPreviewOverlayRefreshAt = 0
        previewActive = true
        previewStreamActive = false
        previewAudioGate.setEnabled(false)
        previousApp = NSWorkspace.shared.frontmostApplication
        let previewASRService = asrService
        let previewAudioGate = previewAudioGate
        let microphone = try MicrophoneManager.resolvedDevice(for: UserDefaults.standard.microphoneSelection)
        currentRecordingURL = try recorder.start(
            using: microphone,
            shouldStreamPreviewAudio: {
                previewAudioGate.isEnabled()
            },
            streamHandler: { payload in
                previewASRService.sendPreviewAudio(payload.data, isFinal: payload.isFinal)
            }
        )
        recordingElapsedSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingElapsedSeconds += 1 }
        }
        phase = .recording
        onOverlayRequest?(true)
    }

    func stopRecording() async throws {
        recordingTimer?.invalidate()
        recordingTimer = nil
        transcript = ""
        previewActive = false
        cancelPreviewOverlayRefresh()
        phase = .transcribing(nil)
        onOverlayRequest?(true)

        defer {
            finishPreviewAudioStreamIfNeeded()
        }
        let url = try await recorder.stop()
        currentRecordingURL = url
    }

    func cancel() {
        if case .idle = phase, historyOpen {
            closeHistory()
            return
        }

        let targetApp = previousApp
        recordingTimer?.invalidate()
        recordingTimer = nil
        previewActive = false
        previewStreamActive = false
        previewAudioGate.setEnabled(false)
        previewTranscript = ""
        measuredPreviewTextSize = CGSize(width: 0, height: 18)
        overlayPreviewTextViewportHeight = 18
        islandPinnedOpen = false
        islandHovering = false
        historyOpen = false
        cancelRecordingHoverCollapse()
        cancelPreviewOverlayRefresh()
        cancelPreviewStreamShutdown()
        recorder.cancel()
        asrService.cancelCurrentProcess()
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        transcript = ""
        previousApp = nil
        phase = .idle
        onOverlayRequest?(shouldShowIdleIsland)
        if let targetApp {
            targetApp.activate()
        }
    }

    func showPermissions(_ missing: Set<PermissionKind>) {
        phase = .permissions(missing)
        onOverlayRequest?(true)
    }

    func hidePermissions() {
        phase = .idle
        onOverlayRequest?(shouldShowIdleIsland)
    }

    @discardableResult
    func refreshDependencyStatus() -> DependencyStatus {
        let nextStatus = DependencyStatus.detect()
        dependencyStatus = nextStatus
        for dependency in DependencyID.allCases where nextStatus.isReady(dependency) {
            blockedAutoInstallDependencies.remove(dependency)
        }
        if nextStatus.isReady {
            dependencyErrorMessage = nil
        }
        return nextStatus
    }

    func autoInstallBlocked(for dependency: DependencyID) -> Bool {
        blockedAutoInstallDependencies.contains(dependency)
    }

    func showDependencyGuideIfNeeded() {
        guard case .idle = phase else { return }
        let status = refreshDependencyStatus()
        guard !status.isReady else { return }
        phase = .missingColi
        onOverlayRequest?(true)
    }

    func showMissingColi(allowAutoInstall: Bool = true) {
        let status = refreshDependencyStatus()
        guard !status.isReady else {
            phase = .idle
            onOverlayRequest?(shouldShowIdleIsland)
            return
        }

        if allowAutoInstall,
           status.canAutoInstallFFmpeg,
           !blockedAutoInstallDependencies.contains(.ffmpeg) {
            autoInstallFFmpeg()
        } else if allowAutoInstall,
                  status.canAutoInstallColi,
                  !blockedAutoInstallDependencies.contains(.coli) {
            autoInstallColi()
        } else {
            phase = .missingColi
            onOverlayRequest?(true)
        }
    }

    func autoInstallColi() {
        dependencyErrorMessage = nil
        phase = .installingColi(L("Installing coli with npm...", "正在通过 npm 安装 coli..."))
        onOverlayRequest?(true)

        Task {
            do {
                try await ColiASRService.installColi { [weak self] message in
                    self?.phase = .installingColi(message)
                }
                // Verify installation
                let status = refreshDependencyStatus()
                if status.isReady {
                    phase = .idle
                    onOverlayRequest?(shouldShowIdleIsland)
                } else {
                    showMissingColi(allowAutoInstall: false)
                }
            } catch {
                blockedAutoInstallDependencies.insert(.coli)
                dependencyErrorMessage = L(
                    "Could not install coli automatically: \(error.localizedDescription)",
                    "无法自动安装 coli：\(error.localizedDescription)"
                )
                showMissingColi(allowAutoInstall: false)
            }
        }
    }

    func autoInstallFFmpeg() {
        dependencyErrorMessage = nil
        phase = .installingColi(L("Installing ffmpeg with Homebrew...", "正在通过 Homebrew 安装 ffmpeg..."))
        onOverlayRequest?(true)

        Task {
            do {
                try await ColiASRService.installFFmpeg { [weak self] message in
                    self?.phase = .installingColi(message)
                }
                showMissingColi()
            } catch {
                blockedAutoInstallDependencies.insert(.ffmpeg)
                dependencyErrorMessage = L(
                    "Could not install ffmpeg automatically: \(error.localizedDescription)",
                    "无法自动安装 ffmpeg：\(error.localizedDescription)"
                )
                showMissingColi(allowAutoInstall: false)
            }
        }
    }

    func copyDependencySetupCommands() {
        let commands = dependencyStatus.setupCommands.joined(separator: "\n")
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    func hideColiGuidance() {
        if case .missingColi = phase {
            phase = .idle
            onOverlayRequest?(shouldShowIdleIsland)
        }
    }

    func showError(_ message: String) {
        phase = .error(message)
        onOverlayRequest?(true)
    }

    func transcribeAndInsert() async {
        guard let url = currentRecordingURL else {
            showError("No recording")
            return
        }

        transcript = ""
        previewActive = false
        phase = .transcribing(nil)

        do {
            let text = try await asrService.transcribe(fileURL: url)
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            // Show result briefly, then auto-insert
            phase = .done(transcript)
            recordHistory(transcript)
            onOverlayRequest?(true)
            confirmInsert()
        } catch is CancellationError {
            // User canceled the current transcription with Esc.
        } catch TypeNoError.coliNotInstalled {
            showMissingColi()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func confirmInsert() {
        guard !transcript.isEmpty else {
            cancel()
            return
        }

        let text = transcript
        let targetApp = previousApp

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Hide overlay
        onOverlayRequest?(false)

        // Activate previous app, then Cmd+V
        if let targetApp {
            targetApp.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let source = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)

            self?.resetState()
        }
    }

    private func resetState() {
        previewActive = false
        previewStreamActive = false
        previewAudioGate.setEnabled(false)
        previewTranscript = ""
        measuredPreviewTextSize = CGSize(width: 0, height: 18)
        overlayPreviewTextViewportHeight = 18
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        previousApp = nil
        transcript = ""
        islandPinnedOpen = false
        islandHovering = false
        historyOpen = false
        cancelRecordingHoverCollapse()
        cancelPreviewOverlayRefresh()
        cancelPreviewStreamShutdown()
        phase = .idle
        onOverlayRequest?(shouldShowIdleIsland)
    }

    private func handlePreviewTranscript(_ text: String) {
        guard previewActive else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        guard normalized != previewTranscript else { return }
        measuredPreviewTextSize = CGSize(width: 0, height: 18)
        previewTranscript = normalized
        if case .recording = phase {
            schedulePreviewOverlayRefresh()
        }
    }

    func transcribeFile(_ url: URL) async {
        previousApp = NSWorkspace.shared.frontmostApplication
        transcript = ""
        previewTranscript = ""
        previewActive = false
        phase = .transcribing(nil)
        onOverlayRequest?(true)

        do {
            let text = try await asrService.transcribe(fileURL: url)
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            phase = .done(transcript)
            recordHistory(transcript)
            onOverlayRequest?(true)
            // Copy to clipboard (don't paste into another app)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            try? await Task.sleep(for: .seconds(2))
            cancel()
        } catch is CancellationError {
            // User canceled the current transcription with Esc.
        } catch TypeNoError.coliNotInstalled {
            showMissingColi()
        } catch {
            showError(error.localizedDescription)
        }
    }

    var shouldShowIdleIsland: Bool {
        !transcriptHistory.items.isEmpty && !suppressIdleIslandForFullscreenApp
    }

    var isRecordingIslandExpanded: Bool {
        islandHovering || islandPinnedOpen
    }

    var isCollapsedHistoryEntry: Bool {
        if case .idle = phase {
            return shouldShowIdleIsland && !historyOpen
        }
        return false
    }

    @discardableResult
    func updateIslandLayout(for screen: ScreenGeometry) -> OverlayLayoutPlan? {
        if let request = overlayLayoutRequest(for: screen) {
            let plan = OverlayLayoutPlanner.makePlan(request)
            applyOverlayLayoutPlan(plan)
            return plan
        }

        let nextIslandWidth = CompactIslandMetrics.width(for: screen)
        let nextCollapsedRailWidth = CompactIslandMetrics.collapsedRecordingWidth(for: screen)
        let nextCollapsedSpacerWidth = CompactIslandMetrics.collapsedRecordingSpacerWidth(for: screen)
        let nextNotchAttachmentHeight = OverlayGeometry.notchAttachmentHeight(for: screen)
        let nextHistoryPanelWidth = CompactIslandMetrics.historyPanelWidth(
            forTextLengths: transcriptHistory.items.map { $0.text.count },
            screen: screen
        )
        let previewText = previewTranscript.isEmpty ? phase.subtitle : previewTranscript
        let nextPreviewPanelWidth = CompactIslandMetrics.previewPanelWidth(
            forTextLength: previewText.count,
            screen: screen
        )

        if islandWidth != nextIslandWidth {
            islandWidth = nextIslandWidth
        }
        if collapsedRecordingRailWidth != nextCollapsedRailWidth {
            collapsedRecordingRailWidth = nextCollapsedRailWidth
        }
        if collapsedRecordingSpacerWidth != nextCollapsedSpacerWidth {
            collapsedRecordingSpacerWidth = nextCollapsedSpacerWidth
        }
        if historyPanelWidth != nextHistoryPanelWidth {
            historyPanelWidth = nextHistoryPanelWidth
        }
        if previewPanelWidth != nextPreviewPanelWidth {
            previewPanelWidth = nextPreviewPanelWidth
        }
        if notchAttachmentHeight != nextNotchAttachmentHeight {
            notchAttachmentHeight = nextNotchAttachmentHeight
        }
        overlayLayoutPlan = nil
        return nil
    }

    private func overlayLayoutRequest(for screen: ScreenGeometry) -> OverlayLayoutRequest? {
        let measurements = OverlayMeasurements(
            previewTextSize: measuredPreviewTextSize.height > 18.5 ? measuredPreviewTextSize : nil,
            historyRowSizes: transcriptHistory.items.map { item in
                measuredHistoryRowSizes[item.id] ?? .zero
            }
        )

        if case .recording = phase {
            return OverlayLayoutRequest(
                screen: screen,
                scene: .recording(
                    RecordingOverlayScene(
                        isExpanded: isRecordingIslandExpanded,
                        previewText: previewTranscript,
                        elapsedText: recordingElapsedStr
                    )
                ),
                measurements: measurements,
                previousPlan: overlayLayoutPlan
            )
        }

        if case .idle = phase, shouldShowIdleIsland {
            return OverlayLayoutRequest(
                screen: screen,
                scene: .history(
                    HistoryOverlayScene(
                        isExpanded: historyOpen,
                        items: transcriptHistory.items
                    )
                ),
                measurements: measurements,
                previousPlan: overlayLayoutPlan
            )
        }

        return nil
    }

    private func applyOverlayLayoutPlan(_ plan: OverlayLayoutPlan) {
        if islandWidth != plan.islandWidth {
            islandWidth = plan.islandWidth
        }
        if collapsedRecordingRailWidth != plan.collapsedRailWidth {
            collapsedRecordingRailWidth = plan.collapsedRailWidth
        }
        if collapsedRecordingSpacerWidth != plan.collapsedSpacerWidth {
            collapsedRecordingSpacerWidth = plan.collapsedSpacerWidth
        }
        if notchAttachmentHeight != plan.attachmentHeight {
            notchAttachmentHeight = plan.attachmentHeight
        }

        switch plan.variant {
        case .recordingPreview:
            if previewPanelWidth != plan.panelFrame.width {
                previewPanelWidth = plan.panelFrame.width
            }
            if let viewportHeight = plan.viewportHeight,
               overlayPreviewTextViewportHeight != viewportHeight {
                overlayPreviewTextViewportHeight = viewportHeight
            }
        case .singleHistory, .historyList:
            if historyPanelWidth != plan.panelFrame.width {
                historyPanelWidth = plan.panelFrame.width
            }
            if let viewportHeight = plan.viewportHeight,
               overlayHistoryRowsViewportHeight != viewportHeight {
                overlayHistoryRowsViewportHeight = viewportHeight
            }
        case .recordingRail, .historyEntry:
            break
        }

        overlayLayoutPlan = plan
    }

    func updateMeasuredPreviewTextSize(_ size: CGSize) {
        let normalized = CGSize(
            width: max(0, size.width.rounded(.up)),
            height: max(18, size.height.rounded(.up))
        )
        guard abs(measuredPreviewTextSize.width - normalized.width) > 0.5
            || abs(measuredPreviewTextSize.height - normalized.height) > 0.5 else {
            return
        }

        measuredPreviewTextSize = normalized
        if case .recording = phase, isRecordingIslandExpanded {
            schedulePreviewOverlayRefresh()
        }
    }

    func updateMeasuredHistoryRowSizes(_ sizes: [UUID: CGSize]) {
        guard !sizes.isEmpty else { return }

        var nextSizes = measuredHistoryRowSizes
        for (id, size) in sizes {
            nextSizes[id] = CGSize(
                width: max(0, size.width.rounded(.up)),
                height: max(22, size.height.rounded(.up))
            )
        }
        guard nextSizes != measuredHistoryRowSizes else { return }

        measuredHistoryRowSizes = nextSizes
        if case .idle = phase, historyOpen {
            onOverlayRequest?(true)
        }
    }

    func updateTopOverlayHost(
        active: Bool,
        hostWidth: CGFloat = 0,
        hostHeight: CGFloat = 0,
        contentFrame: CGRect = .zero
    ) {
        guard active else {
            if usesTopOverlayHost {
                usesTopOverlayHost = false
            }
            overlayLayoutPlan = nil
            return
        }

        if overlayHostWidth != hostWidth {
            overlayHostWidth = hostWidth
        }
        if overlayHostHeight != hostHeight {
            overlayHostHeight = hostHeight
        }
        if overlayContentX != contentFrame.minX {
            overlayContentX = contentFrame.minX
        }
        if overlayContentY != contentFrame.minY {
            overlayContentY = contentFrame.minY
        }
        if overlayContentWidth != contentFrame.width {
            overlayContentWidth = contentFrame.width
        }
        if overlayContentHeight != contentFrame.height {
            overlayContentHeight = contentFrame.height
        }
        if usesTopOverlayHost != true {
            usesTopOverlayHost = true
        }
    }

    func setIslandHovering(_ hovering: Bool) {
        guard case .recording = phase else { return }

        if hovering {
            cancelRecordingHoverCollapse()
            guard !islandHovering else { return }
            islandHovering = true
            enablePreviewAudioStreamIfNeeded()
            onOverlayRequest?(true)
            return
        }

        scheduleRecordingHoverCollapse()
    }

    private func scheduleRecordingHoverCollapse() {
        cancelRecordingHoverCollapse()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.collapseRecordingHoverIfNeeded()
            }
        }
        hoverCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func collapseRecordingHoverIfNeeded() {
        if case .recording = phase {
            guard islandHovering, !islandPinnedOpen else { return }
            if onRecordingIslandHoverRegionCheck?() == true {
                scheduleRecordingHoverCollapse()
                return
            }

            islandHovering = false
            schedulePreviewAudioStreamPauseIfNeeded()
            onOverlayRequest?(true)
        }
    }

    private func cancelRecordingHoverCollapse() {
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil
    }

    func toggleRecordingIsland() {
        guard case .recording = phase else { return }
        cancelRecordingHoverCollapse()
        islandPinnedOpen.toggle()
        if isRecordingIslandExpanded {
            enablePreviewAudioStreamIfNeeded()
        } else {
            schedulePreviewAudioStreamPauseIfNeeded()
        }
        onOverlayRequest?(true)
    }

    private func enablePreviewAudioStreamIfNeeded() {
        guard previewActive else { return }
        cancelPreviewStreamShutdown()

        if !previewStreamActive {
            let didStart = asrService.startPreviewStream { [weak self] text in
                Task { @MainActor in
                    self?.handlePreviewTranscript(text)
                }
            }
            previewStreamActive = didStart
        }

        if previewStreamActive {
            recorder.setPreviewStreamingEnabled(true)
            previewAudioGate.setEnabled(true)
        }
    }

    private func schedulePreviewAudioStreamPauseIfNeeded() {
        guard previewStreamActive, !isRecordingIslandExpanded else { return }
        cancelPreviewStreamShutdown()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishPreviewAudioStreamIfNeeded()
            }
        }
        previewStreamShutdownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + previewStreamIdleShutdownDelay, execute: workItem)
    }

    private func finishPreviewAudioStreamIfNeeded() {
        cancelPreviewStreamShutdown()
        previewAudioGate.setEnabled(false)
        recorder.setPreviewStreamingEnabled(false)
        guard previewStreamActive else { return }
        previewStreamActive = false
        asrService.finishPreviewStream()
    }

    private func cancelPreviewStreamShutdown() {
        previewStreamShutdownWorkItem?.cancel()
        previewStreamShutdownWorkItem = nil
    }

    func setIdleIslandSuppressedForFullscreen(_ suppressed: Bool) {
        guard suppressIdleIslandForFullscreenApp != suppressed else { return }

        suppressIdleIslandForFullscreenApp = suppressed
        guard case .idle = phase else { return }

        if suppressed {
            historyOpen = false
            onOverlayRequest?(false)
        } else {
            onOverlayRequest?(shouldShowIdleIsland)
        }
    }

    func openHistory() {
        guard shouldShowIdleIsland, !historyOpen else { return }
        historyOpen = true
        onOverlayRequest?(true)
    }

    func closeHistory() {
        guard historyOpen else { return }
        historyOpen = false
        onOverlayRequest?(shouldShowIdleIsland)
    }

    func copyHistoryItem(_ item: TranscriptHistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    private func recordHistory(_ text: String) {
        transcriptHistory.record(text)
    }

    private func schedulePreviewOverlayRefresh() {
        guard case .recording = phase else { return }

        let now = CACurrentMediaTime()
        let remainingDelay = previewOverlayRefreshInterval - (now - lastPreviewOverlayRefreshAt)
        previewOverlayRefreshWorkItem?.cancel()

        guard remainingDelay > 0 else {
            performPreviewOverlayRefresh()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performPreviewOverlayRefresh()
            }
        }
        previewOverlayRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay, execute: workItem)
    }

    private func performPreviewOverlayRefresh() {
        guard case .recording = phase else {
            cancelPreviewOverlayRefresh()
            return
        }

        previewOverlayRefreshWorkItem = nil
        lastPreviewOverlayRefreshAt = CACurrentMediaTime()
        onOverlayRequest?(true)
    }

    private func cancelPreviewOverlayRefresh() {
        previewOverlayRefreshWorkItem?.cancel()
        previewOverlayRefreshWorkItem = nil
    }
}

// MARK: - Errors

enum TypeNoError: LocalizedError {
    case noRecording
    case emptyTranscript
    case coliNotInstalled
    case npmNotFound
    case coliInstallFailed(String)
    case dependencyInstallFailed(String)
    case transcriptionFailed(String)
    case noMicrophoneAvailable
    case selectedMicrophoneUnavailable
    case couldNotUseMicrophone(String)
    case couldNotStartRecording

    var errorDescription: String? {
        switch self {
        case .noRecording: "No recording"
        case .emptyTranscript: "No speech detected"
        case .coliNotInstalled: "TypeNo needs the local Coli engine. Install it with: npm install -g @marswave/coli"
        case .npmNotFound: "Node.js is required. Install it from https://nodejs.org"
        case .coliInstallFailed(let message): "Coli install failed: \(message)"
        case .dependencyInstallFailed(let message): message
        case .transcriptionFailed(let message): message
        case .noMicrophoneAvailable: L("No microphone available", "没有可用的麦克风")
        case .selectedMicrophoneUnavailable: L("The selected microphone is unavailable", "所选麦克风当前不可用")
        case .couldNotUseMicrophone(let name): L("Could not use microphone: \(name)", "无法使用麦克风：\(name)")
        case .couldNotStartRecording: L("Could not start recording", "无法开始录音")
        }
    }
}

// MARK: - Permission Manager

enum PermissionManager {
    static func missingPermissions(requestMicrophoneIfNeeded: Bool, requestAccessibilityIfNeeded: Bool = false) -> Set<PermissionKind> {
        var missing = Set<PermissionKind>()

        switch microphoneStatus(requestIfNeeded: requestMicrophoneIfNeeded) {
        case .authorized:
            break
        default:
            missing.insert(.microphone)
        }

        if !accessibilityStatus(requestIfNeeded: requestAccessibilityIfNeeded) {
            missing.insert(.accessibility)
        }

        return missing
    }

    static func microphoneStatus(requestIfNeeded: Bool) -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined, requestIfNeeded {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        return status
    }

    static func accessibilityStatus(requestIfNeeded: Bool) -> Bool {
        guard requestIfNeeded else {
            return AXIsProcessTrusted()
        }
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings(for permissions: Set<PermissionKind>) {
        let urlString: String
        if permissions.contains(.accessibility) {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        } else if permissions.contains(.microphone) {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Microphone Manager

enum MicrophoneManager {
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [.microphone, .external]

    static func availableMicrophones() -> [MicrophoneOption] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        var seen = Set<String>()
        return session.devices
            .filter { seen.insert($0.uniqueID).inserted }
            .sorted { lhs, rhs in
                lhs.localizedName.localizedStandardCompare(rhs.localizedName) == .orderedAscending
            }
            .map { device in
                MicrophoneOption(uniqueID: device.uniqueID, localizedName: device.localizedName)
            }
    }

    static func resolvedDevice(for selection: MicrophoneSelection) throws -> AVCaptureDevice {
        switch selection {
        case .automatic:
            if let device = AVCaptureDevice.default(for: .audio) {
                return device
            }
            guard let fallback = availableMicrophones().first.flatMap({ AVCaptureDevice(uniqueID: $0.uniqueID) }) else {
                throw TypeNoError.noMicrophoneAvailable
            }
            return fallback

        case .specific(let uniqueID):
            guard let device = AVCaptureDevice(uniqueID: uniqueID) else {
                throw TypeNoError.selectedMicrophoneUnavailable
            }
            return device
        }
    }
}

// MARK: - Audio Recorder

@MainActor
final class AudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private final class RecordingContext: @unchecked Sendable {
        let session: AVCaptureSession
        let output: AVCaptureAudioFileOutput
        let dataOutput: AVCaptureAudioDataOutput
        let recordingURL: URL
        let shouldStreamPreviewAudio: @Sendable () -> Bool
        let streamHandler: @Sendable (PreviewStreamPayload) -> Void
        let audioDataQueue = DispatchQueue(label: "ai.marswave.typeno.recorder.audio-data")
        var stopContinuation: CheckedContinuation<URL, Error>?
        var discardRecordingOnFinish = false
        var converter: AVAudioConverter?
        var sourceBuffer: AVAudioPCMBuffer?
        var previewPCMBuffer = Data()
        var previewBufferedFrameCount = 0
        var previewStreamClosed = false
        var previewOutputAttached = false
        let previewFlushFrameThreshold = 1_600

        init(
            session: AVCaptureSession,
            output: AVCaptureAudioFileOutput,
            dataOutput: AVCaptureAudioDataOutput,
            recordingURL: URL,
            shouldStreamPreviewAudio: @escaping @Sendable () -> Bool,
            streamHandler: @escaping @Sendable (PreviewStreamPayload) -> Void
        ) {
            self.session = session
            self.output = output
            self.dataOutput = dataOutput
            self.recordingURL = recordingURL
            self.shouldStreamPreviewAudio = shouldStreamPreviewAudio
            self.streamHandler = streamHandler
        }
    }

    private var activeContexts: [ObjectIdentifier: RecordingContext] = [:]
    private var currentRecordingID: ObjectIdentifier?
    /// Lock-protected map for audio data delegate callbacks (called on background queue).
    private let audioContextLock = NSLock()
    private nonisolated(unsafe) var audioDataContexts: [ObjectIdentifier: RecordingContext] = [:]

    func start(
        using microphone: AVCaptureDevice,
        shouldStreamPreviewAudio: @escaping @Sendable () -> Bool,
        streamHandler: @escaping @Sendable (PreviewStreamPayload) -> Void
    ) throws -> URL {
        guard currentRecordingID == nil else {
            throw TypeNoError.couldNotStartRecording
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()
        let dataOutput = AVCaptureAudioDataOutput()

        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            let input = try AVCaptureDeviceInput(device: microphone)
            guard session.canAddInput(input) else {
                throw TypeNoError.couldNotUseMicrophone(microphone.localizedName)
            }
            session.addInput(input)

            guard session.canAddOutput(output) else {
                throw TypeNoError.couldNotStartRecording
            }
            session.addOutput(output)

            // Keep the preview audio output wired into the session from the start.
            // Dynamically adding/removing outputs while AVCaptureAudioFileOutput is recording
            // is unreliable on some machines, but leaving the delegate nil keeps it cold.
            guard session.canAddOutput(dataOutput) else {
                throw TypeNoError.couldNotStartRecording
            }
            session.addOutput(dataOutput)
        }

        let context = RecordingContext(
            session: session,
            output: output,
            dataOutput: dataOutput,
            recordingURL: url,
            shouldStreamPreviewAudio: shouldStreamPreviewAudio,
            streamHandler: streamHandler
        )
        dataOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let contextID = ObjectIdentifier(output)
        activeContexts[contextID] = context
        currentRecordingID = contextID

        session.startRunning()
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        return url
    }

    func setPreviewStreamingEnabled(_ enabled: Bool) {
        guard let contextID = currentRecordingID,
              let context = activeContexts[contextID] else {
            return
        }

        if enabled {
            attachPreviewOutput(to: context)
        } else {
            detachPreviewOutput(from: context, flushPendingAudio: true)
        }
    }

    func stop() async throws -> URL {
        guard let contextID = currentRecordingID,
              let context = activeContexts[contextID] else {
            throw TypeNoError.noRecording
        }
        guard context.output.isRecording else {
            tearDownCapturePipeline(for: context)
            activeContexts.removeValue(forKey: contextID)
            currentRecordingID = nil
            return context.recordingURL
        }

        context.audioDataQueue.sync {
            Self.flushPreviewPCMBuffer(for: context, isFinal: true)
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.stopContinuation = continuation
            context.output.stopRecording()
        }
    }

    func cancel() {
        guard let contextID = currentRecordingID,
              let context = activeContexts[contextID] else {
            return
        }

        currentRecordingID = nil
        finishStop(for: contextID, with: .failure(CancellationError()))

        let wasRecording = context.output.isRecording
        context.discardRecordingOnFinish = true
        context.audioDataQueue.sync {
            Self.flushPreviewPCMBuffer(for: context, isFinal: true)
        }
        context.output.stopRecording()
        if !wasRecording {
            tearDownCapturePipeline(for: context)
            try? FileManager.default.removeItem(at: context.recordingURL)
            activeContexts.removeValue(forKey: contextID)
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {}

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        let contextID = ObjectIdentifier(output)
        Task { @MainActor in
            guard let context = activeContexts[contextID] else { return }

            defer {
                if context.discardRecordingOnFinish, let outputURL = outputFileURL as URL? {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                tearDownCapturePipeline(for: context)
                activeContexts.removeValue(forKey: contextID)
                if currentRecordingID == contextID {
                    currentRecordingID = nil
                }
            }

            if let error {
                finishStop(for: contextID, with: .failure(error))
            } else {
                finishStop(for: contextID, with: .success(context.recordingURL))
            }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        audioContextLock.lock()
        let context = audioDataContexts[ObjectIdentifier(output)]
        audioContextLock.unlock()
        if context == nil {
            return
        }
        guard let context else { return }
        guard context.shouldStreamPreviewAudio() else { return }
        guard let data = Self.makePreviewPCMData(from: sampleBuffer, context: context) else { return }
        Self.appendPreviewPCMData(data, to: context)
    }

    private func tearDownCapturePipeline(for context: RecordingContext) {
        detachPreviewOutput(from: context, flushPendingAudio: false)
        context.audioDataQueue.sync {
            Self.flushPreviewPCMBuffer(for: context, isFinal: false)
        }
        context.dataOutput.setSampleBufferDelegate(nil, queue: nil)
        if context.session.outputs.contains(where: { $0 === context.dataOutput }) {
            context.session.removeOutput(context.dataOutput)
        }
        if context.session.outputs.contains(where: { $0 === context.output }) {
            context.session.removeOutput(context.output)
        }
        context.session.inputs.forEach { context.session.removeInput($0) }
        if context.session.isRunning {
            context.session.stopRunning()
        }
    }

    private func attachPreviewOutput(to context: RecordingContext) {
        guard !context.previewOutputAttached,
              !context.previewStreamClosed else {
            return
        }

        context.dataOutput.setSampleBufferDelegate(self, queue: context.audioDataQueue)
        let dataOutputID = ObjectIdentifier(context.dataOutput)
        audioContextLock.lock()
        audioDataContexts[dataOutputID] = context
        audioContextLock.unlock()
        context.previewOutputAttached = true
    }

    private func detachPreviewOutput(from context: RecordingContext, flushPendingAudio: Bool) {
        guard context.previewOutputAttached else { return }

        if flushPendingAudio {
            context.audioDataQueue.sync {
                Self.flushPreviewPCMBuffer(for: context, isFinal: false)
            }
        }

        let dataOutputID = ObjectIdentifier(context.dataOutput)
        audioContextLock.lock()
        audioDataContexts.removeValue(forKey: dataOutputID)
        audioContextLock.unlock()
        context.dataOutput.setSampleBufferDelegate(nil, queue: nil)
        context.previewOutputAttached = false
    }

    private func finishStop(for contextID: ObjectIdentifier, with result: Result<URL, Error>) {
        guard let context = activeContexts[contextID],
              let stopContinuation = context.stopContinuation else { return }
        context.stopContinuation = nil
        switch result {
        case .success(let url): stopContinuation.resume(returning: url)
        case .failure(let err): stopContinuation.resume(throwing: err)
        }
    }

    private nonisolated static func makePreviewPCMData(from sampleBuffer: CMSampleBuffer, context: RecordingContext) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let inputFormat = AVAudioFormat(streamDescription: asbdPointer)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        guard let inputFormat, let outputFormat else { return nil }

        if context.converter == nil || context.converter?.inputFormat != inputFormat {
            context.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            context.sourceBuffer = nil
        }
        guard let converter = context.converter else { return nil }

        let frameCapacity = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        pcmBuffer.frameLength = frameCapacity
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: pcmBuffer.mutableAudioBufferList.pointee.mBuffers.mData!)
        guard status == kCMBlockBufferNoErr else { return nil }

        let estimatedRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = max(1, AVAudioFrameCount(Double(frameCapacity) * estimatedRatio) + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        context.sourceBuffer = pcmBuffer
        let inputBlock: AVAudioConverterInputBlock = { [weak context] _, outStatus in
            guard let context, let buffer = context.sourceBuffer else {
                outStatus.pointee = .noDataNow
                return nil
            }
            context.sourceBuffer = nil
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let convertStatus = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard error == nil else { return nil }
        guard convertStatus == .haveData || outputBuffer.frameLength > 0 else { return nil }

        let bytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0, let audioData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        return Data(bytes: audioData, count: byteCount)
    }

    private nonisolated static func appendPreviewPCMData(_ data: Data, to context: RecordingContext) {
        guard !context.previewStreamClosed else { return }
        context.previewPCMBuffer.append(data)
        context.previewBufferedFrameCount += data.count / 2

        if context.previewBufferedFrameCount >= context.previewFlushFrameThreshold {
            flushPreviewPCMBuffer(for: context, isFinal: false)
        }
    }

    private nonisolated static func flushPreviewPCMBuffer(for context: RecordingContext, isFinal: Bool) {
        guard !context.previewStreamClosed else { return }

        if !context.previewPCMBuffer.isEmpty {
            let payload = context.previewPCMBuffer
            context.previewPCMBuffer.removeAll(keepingCapacity: true)
            context.previewBufferedFrameCount = 0
            context.streamHandler(PreviewStreamPayload(data: payload, isFinal: false))
        }

        if isFinal {
            context.previewStreamClosed = true
            context.streamHandler(PreviewStreamPayload(data: Data(), isFinal: true))
        }
    }
}

// MARK: - ASR Service

/// Thread-safe mutable data buffer for pipe reading.
private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class ColiASRService: @unchecked Sendable {
    private static let previewCapabilityLock = NSLock()
    nonisolated(unsafe) private static var previewCapabilityCache: (path: String, supported: Bool)?

    static var isInstalled: Bool {
        findPreviewCapableColiPath() != nil
    }

    static var isNpmAvailable: Bool {
        findNpmPath() != nil
    }

    static var dependenciesAreReady: Bool {
        DependencyStatus.detect().isReady
    }

    private struct PreviewState {
        var process: Process
        var stdin: FileHandle
        var lineBuffer = ""
        var wasCancelled = false
    }

    /// Auto-install coli via npm. Reports progress via callback.
    static func installColi(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let npmPath = findNpmPath() else {
            throw TypeNoError.npmNotFound
        }

        await onProgress("Installing coli...")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: npmPath)
                    process.arguments = ["install", "-g", "@marswave/coli"]

                    // Set up PATH so npm can find node
                    let npmDir = (npmPath as NSString).deletingLastPathComponent
                    let env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        npmDir,
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/current/bin",
                        home + "/.volta/bin",
                        home + "/.local/share/fnm/aliases/default/bin"
                    ]
                    var processEnv = env
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    processEnv["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                    process.environment = processEnv

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Read pipe data asynchronously to avoid deadlock
                    let stderrBuf = LockedData()
                    let stderrHandle = stderr.fileHandleForReading

                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    try process.run()

                    // 120-second timeout for install
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    stderrHandle.readabilityHandler = nil

                    guard process.terminationStatus == 0 else {
                        let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TypeNoError.coliInstallFailed(msg.isEmpty ? "npm install failed" : msg)
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func installFFmpeg(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let brewPath = findBrewPath() else {
            throw TypeNoError.dependencyInstallFailed("Homebrew is required to install ffmpeg automatically.")
        }

        await onProgress(L("Installing ffmpeg with Homebrew...", "正在通过 Homebrew 安装 ffmpeg..."))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: brewPath)
                    process.arguments = ["install", "ffmpeg"]

                    var processEnv = ProcessInfo.processInfo.environment
                    let brewDir = (brewPath as NSString).deletingLastPathComponent
                    let existingPath = processEnv["PATH"] ?? "/usr/bin:/bin"
                    processEnv["PATH"] = [
                        brewDir,
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        existingPath
                    ].joined(separator: ":")
                    process.environment = processEnv

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    let stdoutBuf = LockedData()
                    let stderrBuf = LockedData()
                    let stdoutHandle = stdout.fileHandleForReading
                    let stderrHandle = stderr.fileHandleForReading

                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stdoutBuf.append(data) }
                    }
                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    try process.run()

                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 900, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil

                    guard process.terminationStatus == 0 else {
                        let output = [
                            String(data: stdoutBuf.read(), encoding: .utf8),
                            String(data: stderrBuf.read(), encoding: .utf8)
                        ]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        throw TypeNoError.dependencyInstallFailed(output.isEmpty ? "brew install ffmpeg failed" : output)
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private var currentProcess: Process?
    private let processLock = NSLock()
    private let previewWriteQueue = DispatchQueue(label: "ai.marswave.typeno.asr.preview-write", qos: .utility)
    private var currentProcessWasCancelled = false
    private var previewState: PreviewState?

    func cancelCurrentProcess() {
        processLock.lock()
        let proc = currentProcess
        let previewProcess = previewState?.process
        if proc != nil {
            currentProcessWasCancelled = true
        }
        if previewState != nil {
            previewState?.wasCancelled = true
        }
        currentProcess = nil
        previewState = nil
        processLock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
        if let previewProcess, previewProcess.isRunning {
            previewProcess.terminate()
        }
    }

    @discardableResult
    func startPreviewStream(onPreviewText: @MainActor @escaping @Sendable (String) -> Void) -> Bool {
        previewWriteQueue.sync {}

        processLock.lock()
        guard previewState == nil else {
            processLock.unlock()
            return true
        }
        guard let coliPath = Self.findPreviewCapableColiPath() else {
            processLock.unlock()
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: coliPath)
        process.arguments = [
            "asr-stream",
            "--json",
            "--asr-interval-ms",
            "\(Self.previewASRIntervalMilliseconds())"
        ]
        process.environment = Self.makeColiEnvironment(coliPath: coliPath)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else { return }
            self?.handlePreviewStdoutData(data, onPreviewText: onPreviewText)
        }

        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
            previewState = PreviewState(process: process, stdin: stdin.fileHandleForWriting)
            processLock.unlock()
            return true
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            processLock.unlock()
            return false
        }
    }

    func sendPreviewAudio(_ data: Data, isFinal: Bool) {
        guard isFinal || data.isEmpty == false else { return }

        previewWriteQueue.async { [weak self] in
            self?.writePreviewAudio(data, isFinal: isFinal)
        }
    }

    private func writePreviewAudio(_ data: Data, isFinal: Bool) {
        processLock.lock()
        guard let state = previewState else {
            processLock.unlock()
            return
        }
        let stdin = state.stdin
        processLock.unlock()

        if isFinal {
            try? stdin.close()
            return
        }

        guard data.isEmpty == false else { return }
        try? stdin.write(contentsOf: data)
    }

    func finishPreviewStream() {
        previewWriteQueue.async { [weak self] in
            self?.closePreviewStreamAfterQueuedWrites()
        }
    }

    private func closePreviewStreamAfterQueuedWrites() {
        processLock.lock()
        guard let state = previewState else {
            processLock.unlock()
            return
        }
        previewState = nil
        processLock.unlock()
        try? state.stdin.close()
        // Wait briefly then terminate if still running
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if state.process.isRunning {
                state.process.terminate()
            }
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let coliPath = Self.findColiPath() else {
            throw TypeNoError.coliNotInstalled
        }
        if let modelIssue = Self.detectIncompleteModelDownload() {
            throw TypeNoError.transcriptionFailed(modelIssue)
        }

        // Retry once on failure (handles transient issues like ffmpeg not found)
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                return try await runTranscription(fileURL: fileURL, coliPath: coliPath)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt == 0 {
                    // Brief delay before retry
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        throw lastError!
    }

    private func runTranscription(fileURL: URL, coliPath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: coliPath)
                    process.arguments = ["asr", fileURL.path]

                    // Inherit a proper PATH so node/bun can be found
                    let env = Self.makeColiEnvironment(coliPath: coliPath)

                    process.environment = env

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Read pipe data asynchronously to avoid deadlock when buffer fills up
                    let stdoutBuf = LockedData()
                    let stderrBuf = LockedData()
                    let stdoutHandle = stdout.fileHandleForReading
                    let stderrHandle = stderr.fileHandleForReading

                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard data.isEmpty == false else { return }
                        stdoutBuf.append(data)
                    }
                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    self?.processLock.lock()
                    self?.currentProcessWasCancelled = false
                    self?.currentProcess = process
                    self?.processLock.unlock()

                    try process.run()

                    // Dynamic timeout: 2x audio duration, minimum 120s (covers model download on first run)
                    var audioTimeout: TimeInterval = 120
                    if let audioFile = try? AVAudioFile(forReading: fileURL) {
                        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                        audioTimeout = max(120, durationSeconds * 2.0)
                    }
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + audioTimeout, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    // Stop reading handlers
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil

                    self?.processLock.lock()
                    let wasCancelled = self?.currentProcessWasCancelled ?? false
                    self?.currentProcessWasCancelled = false
                    self?.currentProcess = nil
                    self?.processLock.unlock()

                    guard process.terminationReason != .uncaughtSignal else {
                        if wasCancelled {
                            throw CancellationError()
                        }
                        let diagnostics = Self.timeoutDiagnostics(
                            stdout: String(data: stdoutBuf.read(), encoding: .utf8) ?? "",
                            stderr: String(data: stderrBuf.read(), encoding: .utf8) ?? ""
                        )
                        throw TypeNoError.transcriptionFailed(diagnostics)
                    }

                    let output = String(data: stdoutBuf.read(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TypeNoError.transcriptionFailed(Self.diagnoseColiError(msg))
                    }

                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns the macOS system HTTPS proxy as an "http://host:port" string, or nil if none is set.
    static func systemHTTPSProxyURL() -> String? {
        guard let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        // Check HTTPS proxy first, fall back to HTTP proxy
        if let httpsEnabled = proxySettings[kCFNetworkProxiesHTTPSEnable as String] as? Int, httpsEnabled == 1,
           let host = proxySettings[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = proxySettings[kCFNetworkProxiesHTTPSPort as String] as? Int, !host.isEmpty {
            return "http://\(host):\(port)"
        }
        if let httpEnabled = proxySettings[kCFNetworkProxiesHTTPEnable as String] as? Int, httpEnabled == 1,
           let host = proxySettings[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = proxySettings[kCFNetworkProxiesHTTPPort as String] as? Int, !host.isEmpty {
            return "http://\(host):\(port)"
        }
        return nil
    }

    private func handlePreviewStdoutData(_ data: Data, onPreviewText: @MainActor @escaping @Sendable (String) -> Void) {
        guard let chunk = String(data: data, encoding: .utf8), chunk.isEmpty == false else { return }

        processLock.lock()
        guard var state = previewState else {
            processLock.unlock()
            return
        }
        state.lineBuffer += chunk

        while let newlineRange = state.lineBuffer.range(of: "\n") {
            let line = String(state.lineBuffer[..<newlineRange.lowerBound])
            state.lineBuffer.removeSubrange(..<newlineRange.upperBound)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if let previewText = Self.extractPreviewText(from: trimmed) {
                Task { @MainActor in
                    onPreviewText(previewText)
                }
            }
        }

        previewState = state
        processLock.unlock()
    }

    private static func extractPreviewText(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return extractPreviewText(fromJSONObject: json) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractPreviewText(fromJSONObject json: Any) -> String? {
        if let string = json as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let array = json as? [Any] {
            for item in array.reversed() {
                if let text = extractPreviewText(fromJSONObject: item) {
                    return text
                }
            }
            return nil
        }

        guard let dict = json as? [String: Any] else { return nil }

        let candidateKeys = ["text", "result", "sentence", "transcript", "partial", "output"]
        for key in candidateKeys {
            if let value = dict[key], let text = extractPreviewText(fromJSONObject: value) {
                return text
            }
        }

        if let segments = dict["segments"] as? [Any] {
            let joined = segments.compactMap { extractPreviewText(fromJSONObject: $0) }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        for value in dict.values {
            if let text = extractPreviewText(fromJSONObject: value) {
                return text
            }
        }

        return nil
    }

    private static func makeColiEnvironment(coliPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""
        let coliDir = (coliPath as NSString).deletingLastPathComponent
        let extraPaths = [
            coliDir,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.nvm/versions/node/",
            home + "/.bun/bin",
            home + "/.npm-global/bin",
            "/opt/homebrew/opt/node/bin"
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        env["NO_UPDATE_NOTIFIER"] = "1"
        env["npm_config_update_notifier"] = "false"

        if env["HTTP_PROXY"] == nil && env["HTTPS_PROXY"] == nil && env["http_proxy"] == nil {
            if let proxyURL = systemHTTPSProxyURL() {
                env["HTTPS_PROXY"] = proxyURL
                env["HTTP_PROXY"] = proxyURL
                env["https_proxy"] = proxyURL
                env["http_proxy"] = proxyURL
            }
        }

        return env
    }

    private static func previewASRIntervalMilliseconds() -> Int {
        let value = ProcessInfo.processInfo.environment["TYPENO_PREVIEW_ASR_INTERVAL_MS"]
            .flatMap(Int.init) ?? 2_000
        return min(max(value, 1_000), 5_000)
    }

    private static func detectIncompleteModelDownload() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let modelsDir = home.appendingPathComponent(".coli/models", isDirectory: true)
        let senseVoiceDir = modelsDir.appendingPathComponent(
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
            isDirectory: true
        )
        let senseVoiceCheckFile = senseVoiceDir.appendingPathComponent("model.int8.onnx")
        let senseVoiceArchive = modelsDir.appendingPathComponent(
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"
        )

        let fm = FileManager.default
        if !fm.fileExists(atPath: senseVoiceCheckFile.path) && fm.fileExists(atPath: senseVoiceArchive.path) {
            return "Coli model download looks incomplete. Delete \(senseVoiceArchive.path) and try again."
        }

        return nil
    }

    /// Returns a user-friendly error message for common coli failure modes.
    private static func diagnoseColiError(_ stderr: String) -> String {
        if stderr.isEmpty { return "coli failed" }
        let lower = stderr.lowercased()
        if lower.contains("env: node") || lower.contains("env:node") || (lower.contains("no such file") && lower.contains("node")) {
            return "Node.js not found. Make sure Node.js is installed (nodejs.org) and restart TypeNo."
        }
        if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("no such file") || lower.contains("command not found")) {
            return "ffmpeg is required but not installed. Run: brew install ffmpeg"
        }
        if lower.contains("sherpa-onnx-node") || lower.contains("could not find sherpa") {
            return "Node.js version incompatibility with native addon. Try: npm install -g @marswave/coli --build-from-source"
        }
        return stderr
    }

    private static func timeoutDiagnostics(stdout: String, stderr: String) -> String {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if combined.isEmpty {
            return "Transcription timed out. Coli may still be downloading its first model, or the network/proxy may be blocking GitHub."
        }

        let lower = combined.lowercased()
        if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("no such file") || lower.contains("command not found")) {
            return "Transcription failed: ffmpeg is required but not installed. Run: brew install ffmpeg"
        }

        let condensed = combined
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(6)
            .joined(separator: " | ")

        return "Transcription timed out. Coli output: \(condensed)"
    }

    static func findNpmPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        if let pathInEnv = executableInPath(named: "npm", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            home + "/.nvm/current/bin/npm",
            home + "/.volta/bin/npm",
            home + "/.local/share/fnm/aliases/default/bin/npm",
            home + "/.bun/bin/npm"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("npm")
    }

    static func findNodePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        if let pathInEnv = executableInPath(named: "node", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            home + "/.nvm/current/bin/node",
            home + "/.volta/bin/node",
            home + "/.local/share/fnm/aliases/default/bin/node",
            home + "/.bun/bin/node",
            "/opt/homebrew/opt/node/bin/node"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("node")
    }

    static func findFFmpegPath() -> String? {
        let env = ProcessInfo.processInfo.environment

        if let pathInEnv = executableInPath(named: "ffmpeg", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
            "/usr/local/opt/ffmpeg/bin/ffmpeg"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("ffmpeg")
    }

    static func findBrewPath() -> String? {
        let env = ProcessInfo.processInfo.environment

        if let pathInEnv = executableInPath(named: "brew", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("brew")
    }

    static func findColiPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        // Check current environment PATH first
        if let pathInEnv = executableInPath(named: "coli", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            home + "/.local/bin/coli",
            "/opt/homebrew/bin/coli",
            "/usr/local/bin/coli",
            home + "/.npm-global/bin/coli",
            home + "/.bun/bin/coli",
            home + "/.volta/bin/coli",
            home + "/.nvm/current/bin/coli",
            "/opt/homebrew/opt/node/bin/coli"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Check fnm/nvm managed Node installs
        let managedRoots: [(root: String, rel: String)] = [
            (home + "/.local/share/fnm/node-versions", "installation/bin/coli"),
            (home + "/.nvm/versions/node", "bin/coli")
        ]
        for managed in managedRoots {
            if let path = newestManagedBinary(under: managed.root, relativePath: managed.rel) {
                return path
            }
        }

        // Use npm to find global bin directory (works even when coli is in a custom prefix)
        if let npmGlobalBin = resolveNpmGlobalBin(), !npmGlobalBin.isEmpty {
            let coliViaNpm = npmGlobalBin + "/coli"
            if FileManager.default.isExecutableFile(atPath: coliViaNpm) {
                return coliViaNpm
            }
        }

        // GUI apps don't inherit terminal PATH, so spawn a login shell to resolve coli
        return resolveViaShell("coli")
    }

    static func findPreviewCapableColiPath() -> String? {
        guard let coliPath = findColiPath() else {
            return nil
        }

        previewCapabilityLock.lock()
        if let cache = previewCapabilityCache, cache.path == coliPath {
            previewCapabilityLock.unlock()
            return cache.supported ? coliPath : nil
        }
        previewCapabilityLock.unlock()

        let supported = supportsPreviewStream(coliPath: coliPath)

        previewCapabilityLock.lock()
        previewCapabilityCache = (path: coliPath, supported: supported)
        previewCapabilityLock.unlock()

        guard supported else { return nil }
        return coliPath
    }

    private static func supportsPreviewStream(coliPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: coliPath)
        process.arguments = ["asr-stream", "--help"]
        process.environment = makeColiEnvironment(coliPath: coliPath)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()

            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeoutItem)

            process.waitUntilExit()
            timeoutItem.cancel()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = [
                String(data: outputData, encoding: .utf8),
                String(data: errorData, encoding: .utf8)
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
                .lowercased()

            return process.terminationStatus == 0 && output.contains("asr-stream")
        } catch {
            return false
        }
    }

    private static func executableInPath(named name: String, path: String?) -> String? {
        guard let path else { return nil }
        for dir in path.split(separator: ":") {
            let full = String(dir) + "/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    private static func newestManagedBinary(under rootPath: String, relativePath: String) -> String? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sorted = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 != d2 ? d1 > d2 : $0.lastPathComponent > $1.lastPathComponent
            }

        for dir in sorted {
            let path = dir.path + "/" + relativePath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func resolveViaShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Use -i (interactive) so nvm/fnm/volta init scripts in .zshrc are loaded
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let path, !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    /// Resolve the npm global bin directory by asking npm itself via a login shell.
    private static func resolveNpmGlobalBin() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "npm bin -g 2>/dev/null || npm prefix -g 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // npm bin -g returns the bin path directly
            // npm prefix -g returns the prefix, bin is prefix/bin
            if output.hasSuffix("/bin") {
                return output
            } else if !output.isEmpty {
                return output + "/bin"
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - Hotkey Monitor

@MainActor
final class HotkeyMonitor {
    private let modifier: HotkeyModifier
    private let triggerMode: TriggerMode
    private let onToggle: () -> Void
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyDownAt: Date?
    private var firstTapAt: Date?
    private var otherKeyPressed = false

    init(modifier: HotkeyModifier = .leftControl, triggerMode: TriggerMode = .singleTap, onToggle: @escaping () -> Void) {
        self.modifier = modifier
        self.triggerMode = triggerMode
        self.onToggle = onToggle
    }

    func stop() {
        [flagsMonitor, keyMonitor, localFlagsMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        flagsMonitor = nil; keyMonitor = nil
        localFlagsMonitor = nil; localKeyMonitor = nil
    }

    func start() {
        // Track key presses while modifier is held (both global and local)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.otherKeyPressed = true
            return event
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
            return event
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    private func handle(event: NSEvent) {
        var others: NSEvent.ModifierFlags = [.shift, .option, .command, .control, .function]
        others.remove(modifier.flag)
        let hasOtherModifier = !event.modifierFlags.intersection(others).isEmpty

        if event.keyCode == modifier.keyCode {
            if keyDownAt == nil {
                // Key press — modifier flag becomes set
                if event.modifierFlags.contains(modifier.flag) && !hasOtherModifier {
                    keyDownAt = Date()
                    otherKeyPressed = false
                }
            } else if let downAt = keyDownAt {
                // Key release — modifier flag clears
                let elapsed = Date().timeIntervalSince(downAt)
                let isQuickRelease = elapsed < 0.3 && !otherKeyPressed && !hasOtherModifier
                if isQuickRelease {
                    switch triggerMode {
                    case .singleTap:
                        onToggle()
                    case .doubleTap:
                        if let firstTap = firstTapAt {
                            if Date().timeIntervalSince(firstTap) < 0.5 {
                                onToggle()
                                firstTapAt = nil
                            } else {
                                firstTapAt = Date()
                            }
                        } else {
                            firstTapAt = Date()
                        }
                    }
                }
                keyDownAt = nil
                otherKeyPressed = false
            }
        } else if keyDownAt != nil && Self.modifierKeyCodes.contains(event.keyCode) {
            // Another modifier pressed while ours is held — mark as chord, don't trigger
            otherKeyPressed = true
        }
    }
}

// MARK: - Status Item

@MainActor
final class StatusItemController: NSObject {
    private enum MenuTag {
        static let record = 100
        static let update = 200
        static let microphone = 250
        static let hotkeyBase = 300
        static let triggerBase = 400
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private var cancellable: AnyCancellable?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureMenu()
        configureDragDrop()
        updateTitle(for: appState.phase)
        cancellable = appState.$phase.sink { [weak self] phase in
            self?.updateTitle(for: phase)
            self?.updateRecordMenuItem(for: phase)
        }
    }

    private func configureDragDrop() {
        guard let button = statusItem.button else { return }
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let aboutItem = NSMenuItem(title: "TypeNo  v\(version)", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let mod = UserDefaults.standard.hotkeyModifier
        let recordItem = NSMenuItem(title: L("Record  \(mod.symbol)", "录音  \(mod.symbol)"), action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.tag = MenuTag.record
        menu.addItem(recordItem)

        let transcribeItem = NSMenuItem(title: L("Transcribe File to Clipboard...", "转录文件到剪贴板..."), action: #selector(transcribeFile), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())

        // Microphone sub-menu
        let microphoneItem = NSMenuItem(title: L("Microphone", "麦克风"), action: nil, keyEquivalent: "")
        microphoneItem.tag = MenuTag.microphone
        menu.setSubmenu(makeMicrophoneSubmenu(), for: microphoneItem)
        menu.addItem(microphoneItem)

        // Hotkey sub-menu
        let hotkeyItem = NSMenuItem(title: L("Hotkey", "快捷键"), action: nil, keyEquivalent: "")
        let hotkeySub = NSMenu()
        for (i, m) in HotkeyModifier.allCases.enumerated() {
            let item = NSMenuItem(title: m.label, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = MenuTag.hotkeyBase + i
            item.state = m == mod ? .on : .off
            hotkeySub.addItem(item)
        }
        menu.setSubmenu(hotkeySub, for: hotkeyItem)
        menu.addItem(hotkeyItem)

        // Trigger Mode sub-menu
        let triggerItem = NSMenuItem(title: L("Trigger Mode", "触发方式"), action: nil, keyEquivalent: "")
        let triggerSub = NSMenu()
        let curTrigger = UserDefaults.standard.triggerMode
        for (i, t) in TriggerMode.allCases.enumerated() {
            let item = NSMenuItem(title: t.label, action: #selector(changeTriggerMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = MenuTag.triggerBase + i
            item.state = t == curTrigger ? .on : .off
            triggerSub.addItem(item)
        }
        menu.setSubmenu(triggerSub, for: triggerItem)
        menu.addItem(triggerItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: L("Check for Updates...", "检查更新..."), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = MenuTag.update
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem(title: L("Open Privacy Settings", "打开隐私设置"), action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Quit TypeNo", "退出 TypeNo"), action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func makeMicrophoneSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let selection = UserDefaults.standard.microphoneSelection

        let automaticItem = NSMenuItem(title: L("Automatic", "自动"), action: #selector(changeMicrophone(_:)), keyEquivalent: "")
        automaticItem.target = self
        automaticItem.state = selection == .automatic ? .on : .off
        submenu.addItem(automaticItem)

        let microphones = MicrophoneManager.availableMicrophones()
        if microphones.isEmpty {
            submenu.addItem(NSMenuItem.separator())
            let unavailableItem = NSMenuItem(title: L("No microphones found", "未找到麦克风"), action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            submenu.addItem(unavailableItem)
            return submenu
        }

        submenu.addItem(NSMenuItem.separator())

        for microphone in microphones {
            let item = NSMenuItem(title: microphone.localizedName, action: #selector(changeMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = microphone.uniqueID
            item.state = selection.uniqueID == microphone.uniqueID ? .on : .off
            submenu.addItem(item)
        }

        if case .specific(let selectedID) = selection,
           microphones.contains(where: { $0.uniqueID == selectedID }) == false {
            submenu.addItem(NSMenuItem.separator())
            let unavailableItem = NSMenuItem(title: L("Selected microphone unavailable", "已选麦克风不可用"), action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            unavailableItem.state = .on
            submenu.addItem(unavailableItem)
        }

        return submenu
    }

    private func refreshMicrophoneSubmenu() {
        guard let menu = statusItem.menu,
              let microphoneItem = menu.item(withTag: MenuTag.microphone) else { return }
        menu.setSubmenu(makeMicrophoneSubmenu(), for: microphoneItem)
    }

    private func updateRecordMenuItem(for phase: AppPhase) {
        guard let item = statusItem.menu?.item(withTag: MenuTag.record) else { return }
        let sym = UserDefaults.standard.hotkeyModifier.symbol
        switch phase {
        case .recording:
            item.title = L("Stop Recording", "停止录音")
        default:
            item.title = L("Record  \(sym)", "录音  \(sym)")
        }
    }

    private func makeStatusBarImage(systemName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: "TypeNo")
        image?.isTemplate = true
        return image
    }

    private func updateTitle(for phase: AppPhase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            button.image = makeStatusBarImage(systemName: "record.circle.fill")
            button.imagePosition = .imageOnly
            button.title = ""
        default:
            button.image = nil
            button.imagePosition = .noImage
            button.title = switch phase {
            case .recording: "Rec"
            case .transcribing: "..."
            case .done: "✓"
            case .updating: "↓"
            default: "!"
            }
        }
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        let idx = sender.tag - MenuTag.hotkeyBase
        guard let mod = HotkeyModifier.allCases[safe: idx] else { return }
        UserDefaults.standard.hotkeyModifier = mod
        // Update checkmarks
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        // Refresh title + record item
        if let phase = appState?.phase {
            updateTitle(for: phase)
            updateRecordMenuItem(for: phase)
        }
        NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
    }

    @objc private func changeMicrophone(_ sender: NSMenuItem) {
        if let uniqueID = sender.representedObject as? String {
            UserDefaults.standard.microphoneSelection = .specific(uniqueID)
        } else {
            UserDefaults.standard.microphoneSelection = .automatic
        }
        refreshMicrophoneSubmenu()
    }

    @objc private func changeTriggerMode(_ sender: NSMenuItem) {
        let idx = sender.tag - MenuTag.triggerBase
        guard let mode = TriggerMode.allCases[safe: idx] else { return }
        UserDefaults.standard.triggerMode = mode
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
    }

    @objc private func openPrivacySettings() {
        PermissionManager.openPrivacySettings(for: [])
    }

    @objc private func toggleRecording() {
        appState?.onToggleRequest?()
    }

    @objc private func checkForUpdates() {
        appState?.onUpdateRequest?()
    }

    func setUpdateAvailable(_ version: String) {
        guard let item = statusItem.menu?.item(withTag: MenuTag.update) else { return }
        item.title = L("Update Available (v\(version))", "有新版本 (v\(version))")
    }

    @objc private func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "aac")!
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file — result will be copied to clipboard"

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await appState?.transcribeFile(url)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSWindowDelegate, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshMicrophoneSubmenu()
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first,
              ["m4a", "mp3", "wav", "aac"].contains(url.pathExtension.lowercased()) else {
            return []
        }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first else {
            return false
        }

        Task { @MainActor in
            await appState?.transcribeFile(url)
        }
        return true
    }
}

// MARK: - Overlay Panel

@MainActor
final class EscapeAwarePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {  // Return or Enter
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class OverlayHitTestView: NSView {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let appState, appState.usesTopOverlayHost else {
            return super.hitTest(point)
        }

        let baseHitRegions = appState.overlayLayoutPlan?.hitRegions ?? [
            CGRect(
                x: appState.overlayContentX,
                y: appState.overlayContentY,
                width: appState.overlayContentWidth,
                height: appState.overlayContentHeight
            ).insetBy(dx: -8, dy: -8)
        ]
        let hitRegions: [CGRect]
        if appState.isCollapsedHistoryEntry {
            hitRegions = baseHitRegions.map { $0.insetBy(dx: -18, dy: -10) }
        } else {
            hitRegions = baseHitRegions
        }
        let containsPoint = hitRegions.contains { region in
            let activeRect = NSRect(
                x: region.minX,
                y: bounds.height - region.minY - region.height,
                width: region.width,
                height: region.height
            )
            return activeRect.contains(point)
        }

        guard containsPoint else { return nil }
        if appState.isCollapsedHistoryEntry {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let appState, appState.isCollapsedHistoryEntry else {
            super.mouseDown(with: event)
            return
        }

        appState.openHistory()
    }

    private func minimumInteractiveHeight(for appState: AppState) -> CGFloat {
        guard appState.historyOpen else { return 0 }

        let textLengths = appState.transcriptHistory.items.map { $0.text.count }
        let estimatedRowsHeight = CompactIslandMetrics.historyRowsViewportHeight(
            forTextLengths: textLengths,
            panelWidth: appState.historyPanelWidth
        )
        if textLengths.count == 1 {
            return appState.notchAttachmentHeight + 16 + max(30, estimatedRowsHeight)
        }

        return appState.notchAttachmentHeight + 20 + 18 + 6 + estimatedRowsHeight
    }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class OverlayPanelController {
    private let hudPanel: NSPanel
    private let capturePanel: EscapeAwarePanel
    private let hudHostingView: NSHostingView<OverlayView>
    private let captureHostingView: NSHostingView<OverlayView>
    private let measuringHostingView: NSHostingView<OverlayView>
    private let hudHitTestView: OverlayHitTestView
    private let captureHitTestView: OverlayHitTestView
    private let appState: AppState
    private let islandFrameAnimationDuration: TimeInterval = 0.24
    private let recordingHoverMouseCheckInterval: CFTimeInterval = 1.0 / 60.0
    private var globalMouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var globalHistoryClickMonitor: Any?
    private var localHistoryClickMonitor: Any?
    private var lastRecordingHoverMouseCheckAt: CFTimeInterval = 0

    init(appState: AppState) {
        self.appState = appState
        hudHostingView = FirstMouseHostingView(rootView: OverlayView(appState: appState))
        captureHostingView = FirstMouseHostingView(rootView: OverlayView(appState: appState))
        measuringHostingView = FirstMouseHostingView(rootView: OverlayView(appState: appState, forceContentOnly: true))
        hudHitTestView = OverlayHitTestView(appState: appState)
        captureHitTestView = OverlayHitTestView(appState: appState)

        hudPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        capturePanel = EscapeAwarePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configure(panel: hudPanel, contentView: hudHitTestView)
        configure(panel: capturePanel, contentView: captureHitTestView)
        install(hostingView: hudHostingView, in: hudHitTestView)
        install(hostingView: captureHostingView, in: captureHitTestView)
        capturePanel.onEscape = { [weak appState] in
            appState?.onCancel?()
        }
        capturePanel.onReturn = { [weak appState] in
            appState?.onConfirm?()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            removeMouseTrackingMonitors()
            removeHistoryClickMonitors()
        }
    }

    private func install(hostingView: NSView, in containerView: NSView) {
        containerView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
    }

    private func installMouseTrackingMonitors() {
        guard globalMouseMoveMonitor == nil, localMouseMoveMonitor == nil else { return }

        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRecordingHoverFromMouseLocation()
            }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateRecordingHoverFromMouseLocation()
            }
            return event
        }
    }

    private func removeMouseTrackingMonitors() {
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
            self.globalMouseMoveMonitor = nil
        }
        if let localMouseMoveMonitor {
            NSEvent.removeMonitor(localMouseMoveMonitor)
            self.localMouseMoveMonitor = nil
        }
        lastRecordingHoverMouseCheckAt = 0
    }

    private func installHistoryClickMonitors() {
        guard globalHistoryClickMonitor == nil, localHistoryClickMonitor == nil else { return }

        globalHistoryClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openHistoryIfMouseIsInsideCollapsedEntry()
            }
        }
        localHistoryClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.openHistoryIfMouseIsInsideCollapsedEntry()
            }
            return event
        }
    }

    private func removeHistoryClickMonitors() {
        if let globalHistoryClickMonitor {
            NSEvent.removeMonitor(globalHistoryClickMonitor)
            self.globalHistoryClickMonitor = nil
        }
        if let localHistoryClickMonitor {
            NSEvent.removeMonitor(localHistoryClickMonitor)
            self.localHistoryClickMonitor = nil
        }
    }

    private func openHistoryIfMouseIsInsideCollapsedEntry() {
        guard appState.isCollapsedHistoryEntry,
              isMouseInsideCollapsedHistoryEntry() else {
            return
        }

        appState.openHistory()
    }

    private func updateRecordingHoverFromMouseLocation() {
        guard case .recording = appState.phase else { return }

        let now = CACurrentMediaTime()
        guard now - lastRecordingHoverMouseCheckAt >= recordingHoverMouseCheckInterval else { return }
        lastRecordingHoverMouseCheckAt = now

        if isMouseInsideRecordingIslandRegion() {
            if !appState.islandHovering {
                appState.setIslandHovering(true)
            }
        } else if appState.islandHovering {
            appState.setIslandHovering(false)
        }
    }

    func show() {
        if case .recording = appState.phase {
            installMouseTrackingMonitors()
        } else {
            removeMouseTrackingMonitors()
        }
        if appState.isCollapsedHistoryEntry {
            installHistoryClickMonitors()
        } else {
            removeHistoryClickMonitors()
        }

        let activePanel = panel(for: appState.phase)
        let activeHostingView = hostingView(for: appState.phase)
        let inactivePanel = inactivePanel(for: appState.phase)

        let isCollapsedRecording: Bool
        if case .recording = appState.phase {
            isCollapsedRecording = !appState.isRecordingIslandExpanded
        } else {
            isCollapsedRecording = false
        }
        let isCollapsedHistory: Bool
        if case .idle = appState.phase {
            isCollapsedHistory = appState.shouldShowIdleIsland && !appState.historyOpen
        } else {
            isCollapsedHistory = false
        }
        let isNotchAttachedExpansion: Bool
        if case .recording = appState.phase {
            isNotchAttachedExpansion = appState.isRecordingIslandExpanded
        } else if case .idle = appState.phase {
            isNotchAttachedExpansion = appState.historyOpen
        } else {
            isNotchAttachedExpansion = false
        }
        let screenGeometry = NSScreen.typenoNotchPreferred.map {
            ScreenGeometry(
                frame: $0.frame,
                visibleFrame: $0.visibleFrame,
                safeAreaTop: $0.safeAreaInsets.top,
                auxiliaryTopLeftArea: $0.auxiliaryTopLeftArea ?? .zero,
                auxiliaryTopRightArea: $0.auxiliaryTopRightArea ?? .zero
            )
        }
        let overlayPlan = screenGeometry.flatMap {
            appState.updateIslandLayout(for: $0)
        }
        let layoutWidth = appState.islandWidth
        let collapsedLayoutWidth = appState.collapsedRecordingRailWidth
        let activeLayoutWidth: CGFloat
        if isCollapsedRecording || isCollapsedHistory {
            activeLayoutWidth = collapsedLayoutWidth
        } else if case .idle = appState.phase, appState.historyOpen {
            activeLayoutWidth = appState.historyPanelWidth
        } else if case .recording = appState.phase, appState.isRecordingIslandExpanded {
            activeLayoutWidth = appState.previewPanelWidth
        } else {
            activeLayoutWidth = layoutWidth
        }
        let usesIslandLayout: Bool
        if case .permissions = appState.phase {
            usesIslandLayout = false
        } else if case .missingColi = appState.phase {
            usesIslandLayout = false
        } else if case .installingColi = appState.phase {
            usesIslandLayout = false
        } else {
            usesIslandLayout = true
        }
        if !usesIslandLayout {
            appState.updateTopOverlayHost(active: false)
        }

        let measuringView = usesIslandLayout ? measuringHostingView : activeHostingView
        measuringView.invalidateIntrinsicContentSize()
        let idealSize = measuringView.fittingSize
        let minimumWidth: CGFloat
        if isCollapsedHistory {
            minimumWidth = usesIslandLayout ? activeLayoutWidth : CompactIslandMetrics.collapsedRecordingSideSlotWidth
        } else if isCollapsedRecording {
            minimumWidth = usesIslandLayout ? activeLayoutWidth : CompactIslandMetrics.collapsedRecordingWidth
        } else {
            minimumWidth = usesIslandLayout ? activeLayoutWidth : 240
        }
        let minimumHeight: CGFloat
        if isCollapsedRecording || isCollapsedHistory {
            minimumHeight = CompactIslandMetrics.collapsedRecordingHeight
        } else if isNotchAttachedExpansion {
            minimumHeight = minimumNotchAttachedExpansionHeight()
        } else {
            minimumHeight = CompactIslandMetrics.minimumHeight
        }
        let width: CGFloat
        if usesIslandLayout, let overlayPlan {
            width = overlayPlan.panelFrame.width
        } else if isCollapsedHistory {
            width = minimumWidth
        } else {
            width = max(idealSize.width, minimumWidth)
        }

        let height: CGFloat
        if usesIslandLayout, let overlayPlan {
            height = overlayPlan.panelFrame.height
        } else if isCollapsedRecording || isCollapsedHistory {
            height = CompactIslandMetrics.collapsedRecordingHeight
        } else {
            height = max(idealSize.height, minimumHeight)
        }

        if let screen = NSScreen.typenoNotchPreferred {
            let frame = screen.visibleFrame
            let panelFrame: NSRect
            let x: CGFloat
            let y: CGFloat

            if case .permissions = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .missingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .installingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if usesIslandLayout, let overlayPlan {
                x = overlayPlan.panelFrame.minX
                y = overlayPlan.panelFrame.minY
            } else if let screenGeometry {
                // Collapsed states hug the hardware notch; expanded panels grow from the top edge.
                let islandFrame: CGRect
                if isCollapsedRecording {
                    islandFrame = OverlayGeometry.collapsedRecordingFrame(
                        panelSize: NSSize(width: width, height: height),
                        screen: screenGeometry
                    )
                } else if isCollapsedHistory {
                    islandFrame = OverlayGeometry.collapsedRecordingFrame(
                        panelSize: NSSize(width: width, height: height),
                        screen: screenGeometry
                    )
                } else if isNotchAttachedExpansion {
                    islandFrame = OverlayGeometry.notchAttachedIslandFrame(
                        panelSize: NSSize(width: width, height: height),
                        screen: screenGeometry
                    )
                } else {
                    islandFrame = OverlayGeometry.compactIslandFrame(
                        panelSize: NSSize(width: width, height: height),
                        screen: screenGeometry
                    )
                }
                x = islandFrame.minX
                y = islandFrame.minY
            } else {
                x = frame.midX - width / 2
                y = frame.maxY - height - 8
            }

            if usesIslandLayout {
                let hostFrame = overlayPlan?.hostFrame ?? CGRect(
                    x: screen.frame.minX,
                    y: screen.frame.maxY - max(CGFloat(420), height + (screen.frame.maxY - (y + height))),
                    width: screen.frame.width,
                    height: max(CGFloat(420), height + (screen.frame.maxY - (y + height)))
                )
                let contentFrame = overlayPlan?.contentFrame ?? CGRect(
                    x: x - screen.frame.minX,
                    y: screen.frame.maxY - (y + height),
                    width: width,
                    height: height
                )
                appState.updateTopOverlayHost(
                    active: true,
                    hostWidth: hostFrame.width,
                    hostHeight: hostFrame.height,
                    contentFrame: contentFrame
                )
                activeHostingView.invalidateIntrinsicContentSize()
                panelFrame = hostFrame
            } else {
                panelFrame = NSRect(x: x, y: y, width: width, height: height)
            }

            let shouldBridgePanels = usesIslandLayout
                && !activePanel.isVisible
                && inactivePanel.isVisible
            if shouldBridgePanels {
                activePanel.setFrame(inactivePanel.frame, display: false)
                present(panel: activePanel)
                inactivePanel.orderOut(nil)
            }
            setFrame(panelFrame, for: activePanel, animated: usesIslandLayout)
        } else {
            activePanel.setContentSize(NSSize(width: width, height: height))
        }

        if !activePanel.isVisible {
            present(panel: activePanel)
        }
        inactivePanel.orderOut(nil)
    }

    func hide() {
        removeMouseTrackingMonitors()
        removeHistoryClickMonitors()
        appState.updateTopOverlayHost(active: false)
        hudPanel.orderOut(nil)
        capturePanel.orderOut(nil)
    }

    private func setFrame(_ frame: NSRect, for panel: NSPanel, animated: Bool) {
        guard animated,
              panel.isVisible,
              panel.frame != frame else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = islandFrameAnimationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.0, 0.16, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func present(panel: NSPanel) {
        if panel === capturePanel {
            NSApp.activate(ignoringOtherApps: true)
            capturePanel.makeKeyAndOrderFront(nil)
            capturePanel.makeFirstResponder(capturePanel.contentView)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func isMouseInsideRecordingIslandRegion() -> Bool {
        guard let screen = NSScreen.typenoNotchPreferred else { return false }

        let screenGeometry = ScreenGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero
        )
        let measurements = OverlayMeasurements(
            previewTextSize: appState.overlayLayoutPlan?.viewportHeight.map {
                CGSize(width: 0, height: $0)
            }
        )
        let collapsedPlan = OverlayLayoutPlanner.makePlan(
            OverlayLayoutRequest(
                screen: screenGeometry,
                scene: .recording(
                    RecordingOverlayScene(
                        isExpanded: false,
                        previewText: appState.previewTranscript,
                        elapsedText: appState.recordingElapsedStr
                    )
                ),
                measurements: measurements
            )
        )
        let expandedFrame = appState.overlayLayoutPlan?.panelFrame ?? collapsedPlan.panelFrame
        return OverlayGeometry.recordingHoverRegionContains(
            NSEvent.mouseLocation,
            collapsedFrame: collapsedPlan.panelFrame,
            expandedFrame: expandedFrame
        )
    }

    private func isMouseInsideCollapsedHistoryEntry() -> Bool {
        if let frame = appState.overlayLayoutPlan?.panelFrame {
            return frame.insetBy(dx: -18, dy: -10).contains(NSEvent.mouseLocation)
        }

        guard let screen = NSScreen.typenoNotchPreferred else { return false }
        let screenGeometry = ScreenGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero
        )
        let frame = OverlayGeometry.collapsedRecordingFrame(
            panelSize: NSSize(
                width: CompactIslandMetrics.collapsedRecordingWidth(for: screenGeometry),
                height: CompactIslandMetrics.collapsedRecordingHeight
            ),
            screen: screenGeometry
        )
        return frame.insetBy(dx: -18, dy: -10).contains(NSEvent.mouseLocation)
    }

    private func minimumNotchAttachedExpansionHeight() -> CGFloat {
        let attachmentHeight = appState.notchAttachmentHeight

        if case .idle = appState.phase, appState.historyOpen {
            let textLengths = appState.transcriptHistory.items.map { $0.text.count }
            let estimatedRowsHeight = CompactIslandMetrics.historyRowsViewportHeight(
                forTextLengths: textLengths,
                panelWidth: appState.historyPanelWidth
            )
            if textLengths.count == 1 {
                return attachmentHeight + 16 + max(30, estimatedRowsHeight)
            }

            let headerHeight: CGFloat = 18
            let panelVerticalPadding: CGFloat = 20
            let contentSpacing: CGFloat = 6

            return attachmentHeight
                + headerHeight
                + panelVerticalPadding
                + contentSpacing
                + estimatedRowsHeight
        }

        if case .recording = appState.phase {
            let previewText = appState.previewTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !previewText.isEmpty else {
                return attachmentHeight + CompactIslandMetrics.minimumHeight
            }

            let estimatedCharactersPerLine = max(18, Int((appState.previewPanelWidth - 112) / 7))
            let estimatedLineCount = max(
                1,
                Int(ceil(Double(previewText.count) / Double(estimatedCharactersPerLine)))
            )
            let estimatedTextHeight = min(
                CompactIslandMetrics.maximumTextViewportHeight,
                CGFloat(estimatedLineCount) * 17
            )

            return attachmentHeight
                + 20
                + max(18, estimatedTextHeight)
        }

        return attachmentHeight + CompactIslandMetrics.minimumHeight
    }

    private func shouldCaptureKeyboard(for phase: AppPhase) -> Bool {
        switch phase {
        case .recording, .transcribing:
            true
        case .idle:
            false
        default:
            false
        }
    }

    private func configure(panel: NSPanel, contentView: NSView) {
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = contentView
    }

    private func panel(for phase: AppPhase) -> NSPanel {
        shouldCaptureKeyboard(for: phase) ? capturePanel : hudPanel
    }

    private func hostingView(for phase: AppPhase) -> NSHostingView<OverlayView> {
        shouldCaptureKeyboard(for: phase) ? captureHostingView : hudHostingView
    }

    private func inactivePanel(for phase: AppPhase) -> NSPanel {
        shouldCaptureKeyboard(for: phase) ? hudPanel : capturePanel
    }
}

// MARK: - Overlay View

struct BreathingDot: View {
    var color: Color = .white

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.2)) { context in
            let pulseIndex = Int(context.date.timeIntervalSinceReferenceDate / 1.2)
            let isLit = pulseIndex.isMultiple(of: 2)

            Circle()
                .fill(color.opacity(isLit ? 0.86 : 0.42))
                .frame(width: 6, height: 6)
                .animation(.easeInOut(duration: 0.18), value: isLit)
        }
    }
}

struct NotchSurfaceShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topRadius = min(topCornerRadius, rect.width / 2, rect.height / 2)
        let bottomRadius = min(bottomCornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

private struct CompactTextSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = CGSize(width: 0, height: 18)

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

private struct HistoryRowSizePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGSize] = [:]

    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue()) { current, next in
            CGSize(width: max(current.width, next.width), height: max(current.height, next.height))
        }
    }
}

struct OverlayView: View {
    @ObservedObject var appState: AppState
    var forceContentOnly = false
    @State private var copiedHistoryID: UUID?
    @State private var compactTextContentHeight: CGFloat = 18

    private var notchMorphAnimation: Animation {
        .smooth(duration: 0.28)
    }

    private var notchMicroAnimation: Animation {
        .easeOut(duration: 0.16)
    }

    private func contentFadeInAnimation(active: Bool) -> Animation {
        active ? .easeOut(duration: 0.16).delay(0.08) : .easeOut(duration: 0.08)
    }

    private func contentFadeOutAnimation(active: Bool) -> Animation {
        active ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16).delay(0.08)
    }

    var body: some View {
        if appState.usesTopOverlayHost && !forceContentOnly {
            ZStack(alignment: .topLeading) {
                overlayContent
                    .fixedSize()
                    .offset(x: appState.overlayContentX, y: appState.overlayContentY)
                    .animation(
                        notchMorphAnimation,
                        value: appState.overlayContentX
                    )
                    .animation(
                        notchMorphAnimation,
                        value: appState.overlayContentY
                    )
            }
            .frame(
                width: appState.overlayHostWidth,
                height: appState.overlayHostHeight,
                alignment: .topLeading
            )
        } else {
            overlayContent
                .fixedSize()
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        Group {
            switch appState.phase {
            case .recording:
                recordingIslandView
            case .idle:
                idleIslandView
            case .permissions(let missing):
                permissionView(missing: missing)
            case .missingColi:
                missingColiView
            case .installingColi(let message):
                installingColiView(message: message)
            default:
                compactView
            }
        }
    }

    @ViewBuilder
    private var recordingIslandView: some View {
        let expanded = appState.isRecordingIslandExpanded
        morphingNotchSurface(
            width: expanded ? appState.previewPanelWidth : appState.collapsedRecordingRailWidth,
            height: expanded ? max(appState.overlayContentHeight, CompactIslandMetrics.minimumHeight) : CompactIslandMetrics.collapsedRecordingHeight,
            topCornerRadius: expanded ? 16 : 6,
            bottomCornerRadius: expanded ? 20 : 14
        ) {
            ZStack(alignment: .top) {
                recordingCollapsedContent
                    .frame(
                        width: appState.collapsedRecordingRailWidth,
                        height: CompactIslandMetrics.collapsedRecordingHeight
                    )
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
                    .animation(contentFadeOutAnimation(active: expanded), value: expanded)

                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: appState.notchAttachmentHeight)

                    compactEmbeddedView
                }
                .frame(width: appState.previewPanelWidth, alignment: .top)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .animation(contentFadeInAnimation(active: expanded), value: expanded)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            appState.setIslandHovering(hovering)
        }
        .onTapGesture {
            appState.toggleRecordingIsland()
        }
        .animation(
            notchMorphAnimation,
            value: appState.isRecordingIslandExpanded
        )
    }

    private var recordingExpandedView: some View {
        Group {
            if appState.notchAttachmentHeight > 0 {
                notchAttachedSurface(width: appState.previewPanelWidth) {
                    compactEmbeddedView
                }
            } else {
                compactView
            }
        }
        .animation(
            notchMorphAnimation,
            value: appState.collapsedRecordingSpacerWidth
        )
    }

    @ViewBuilder
    private var idleIslandView: some View {
        if appState.shouldShowIdleIsland {
            let expanded = appState.historyOpen
            morphingNotchSurface(
                width: expanded ? appState.historyPanelWidth : appState.collapsedRecordingRailWidth,
                height: expanded ? max(appState.overlayContentHeight, CompactIslandMetrics.minimumHeight) : CompactIslandMetrics.collapsedRecordingHeight,
                topCornerRadius: expanded ? 16 : 6,
                bottomCornerRadius: expanded ? 20 : 14
            ) {
                ZStack(alignment: .top) {
                    historyCollapsedButtonContent
                        .opacity(expanded ? 0 : 1)
                        .allowsHitTesting(!expanded)
                        .animation(contentFadeOutAnimation(active: expanded), value: expanded)

                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: appState.notchAttachmentHeight)

                        historyPanelEmbeddedView
                    }
                    .frame(width: appState.historyPanelWidth, alignment: .top)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
                    .animation(contentFadeInAnimation(active: expanded), value: expanded)
                }
            }
            .contentShape(Rectangle())
            .animation(notchMorphAnimation, value: appState.historyOpen)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var notchAttachedHistoryPanelView: some View {
        if appState.notchAttachmentHeight > 0 {
            notchAttachedSurface(width: appState.historyPanelWidth) {
                historyPanelEmbeddedView
            }
        } else {
            historyPanelView
        }
    }

    private func notchAttachedSurface<Content: View>(
        width: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = NotchSurfaceShape(topCornerRadius: 16, bottomCornerRadius: 20)
        let surfaceWidth = width ?? appState.islandWidth

        return ZStack(alignment: .top) {
            shape
                .fill(notchSurfaceFill)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: appState.notchAttachmentHeight)

                content()
            }
        }
        .frame(width: surfaceWidth)
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.26), radius: 14, y: 5)
    }

    private var recordingCollapsedView: some View {
        morphingNotchSurface(
            width: appState.collapsedRecordingRailWidth,
            height: CompactIslandMetrics.collapsedRecordingHeight,
            topCornerRadius: 6,
            bottomCornerRadius: 14
        ) {
            recordingCollapsedContent
        }
    }

    private var recordingCollapsedContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                BreathingDot(color: Color(red: 1.0, green: 0.24, blue: 0.18))
                Text("REC")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .frame(
                width: CompactIslandMetrics.collapsedRecordingSideSlotWidth,
                height: CompactIslandMetrics.collapsedRecordingHeight,
                alignment: .trailing
            )

            Spacer(minLength: appState.collapsedRecordingSpacerWidth)

            Text(appState.recordingElapsedStr)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 12)
                .frame(
                    width: CompactIslandMetrics.collapsedRecordingSideSlotWidth,
                    height: CompactIslandMetrics.collapsedRecordingHeight,
                    alignment: .leading
                )
        }
        .frame(
            width: appState.collapsedRecordingRailWidth,
            height: CompactIslandMetrics.collapsedRecordingHeight
        )
        .animation(
            notchMicroAnimation,
            value: appState.collapsedRecordingSpacerWidth
        )
    }

    private func morphingNotchSurface<Content: View>(
        width: CGFloat,
        height: CGFloat,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = NotchSurfaceShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )

        return ZStack(alignment: .top) {
            shape
                .fill(notchSurfaceFill)

            content()
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(height > CompactIslandMetrics.collapsedRecordingHeight ? 0.26 : 0),
            radius: 14,
            y: 5
        )
        .animation(notchMorphAnimation, value: width)
        .animation(notchMorphAnimation, value: height)
        .animation(notchMorphAnimation, value: topCornerRadius)
        .animation(notchMorphAnimation, value: bottomCornerRadius)
    }

    private func compactNotchSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = NotchSurfaceShape(topCornerRadius: 6, bottomCornerRadius: 14)

        return ZStack {
            shape
                .fill(notchSurfaceFill)

            content()
        }
        .frame(
            width: appState.collapsedRecordingRailWidth,
            height: CompactIslandMetrics.collapsedRecordingHeight,
            alignment: .center
        )
        .clipShape(shape)
        .contentShape(shape)
        .compositingGroup()
    }

    private var notchSurfaceFill: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0.98),
                Color(red: 0.035, green: 0.035, blue: 0.04).opacity(0.98)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var historyCollapsedView: some View {
        Button {
            appState.openHistory()
        } label: {
            morphingNotchSurface(
                width: appState.collapsedRecordingRailWidth,
                height: CompactIslandMetrics.collapsedRecordingHeight,
                topCornerRadius: 6,
                bottomCornerRadius: 14
            ) {
                historyCollapsedContent
            }
        }
        .buttonStyle(.plain)
        .frame(
            width: appState.collapsedRecordingRailWidth,
            height: CompactIslandMetrics.collapsedRecordingHeight,
            alignment: .center
        )
        .contentShape(
            NotchSurfaceShape(topCornerRadius: 6, bottomCornerRadius: 14)
        )
        .animation(
            notchMicroAnimation,
            value: appState.transcriptHistory.items.count
        )
    }

    private var historyCollapsedButtonContent: some View {
        Button {
            appState.openHistory()
        } label: {
            historyCollapsedContent
        }
        .buttonStyle(.plain)
        .frame(
            width: appState.collapsedRecordingRailWidth,
            height: CompactIslandMetrics.collapsedRecordingHeight,
            alignment: .center
        )
        .contentShape(Rectangle())
    }

    private var historyCollapsedContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                Text("\(appState.transcriptHistory.items.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(
                width: CompactIslandMetrics.collapsedRecordingSideSlotWidth,
                height: CompactIslandMetrics.collapsedRecordingHeight,
                alignment: .trailing
            )

            Spacer(minLength: appState.collapsedRecordingSpacerWidth)

            Color.clear
                .frame(
                    width: CompactIslandMetrics.collapsedRecordingSideSlotWidth,
                    height: CompactIslandMetrics.collapsedRecordingHeight
                )
        }
        .frame(
            width: appState.collapsedRecordingRailWidth,
            height: CompactIslandMetrics.collapsedRecordingHeight
        )
    }

    private var historyPanelView: some View {
        historyPanelContent
            .padding(.horizontal, historyHorizontalPadding)
            .padding(.vertical, 10)
            .frame(width: appState.historyPanelWidth)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.13))
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var historyPanelEmbeddedView: some View {
        historyPanelContent
            .padding(.horizontal, historyHorizontalPadding)
            .padding(.vertical, 10)
            .frame(width: appState.historyPanelWidth)
    }

    private var historyHorizontalPadding: CGFloat {
        22
    }

    private var historyPanelContent: some View {
        Group {
            if appState.transcriptHistory.items.count == 1,
               let item = appState.transcriptHistory.items.first {
                singleHistoryRow(item)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))

                        Text(L("History", "历史"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))

                        Spacer()

                        Button {
                            appState.closeHistory()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                    }

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(appState.transcriptHistory.items) { item in
                                historyRow(item)
                            }
                        }
                    }
                    .frame(height: historyRowsViewportHeight)
                }
            }
        }
        .onPreferenceChange(HistoryRowSizePreferenceKey.self) { sizes in
            appState.updateMeasuredHistoryRowSizes(sizes)
        }
    }

    private func singleHistoryRow(_ item: TranscriptHistoryItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(item.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                appState.copyHistoryItem(item)
                copiedHistoryID = item.id
            } label: {
                Image(systemName: copiedHistoryID == item.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(copiedHistoryID == item.id ? 0.86 : 0.56))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L("Copy", "复制"))

            Button {
                appState.closeHistory()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 30)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HistoryRowSizePreferenceKey.self,
                    value: [item.id: proxy.size]
                )
            }
        )
    }

    private func historyRow(_ item: TranscriptHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                appState.copyHistoryItem(item)
                copiedHistoryID = item.id
            } label: {
                Image(systemName: copiedHistoryID == item.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(copiedHistoryID == item.id ? 0.86 : 0.52))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(L("Copy", "复制"))
        }
        .padding(.vertical, 6)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HistoryRowSizePreferenceKey.self,
                    value: [item.id: proxy.size]
                )
            }
        )
    }

    private var historyRowsViewportHeight: CGFloat {
        max(26, appState.overlayHistoryRowsViewportHeight)
    }

    var compactView: some View {
        compactContentView
            .padding(.horizontal, compactHorizontalPadding)
            .padding(.vertical, 10)
            .frame(width: currentCompactPanelWidth)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.15))
            )
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var compactEmbeddedView: some View {
        compactContentView
            .padding(.horizontal, compactHorizontalPadding)
            .padding(.vertical, 10)
            .frame(width: currentCompactPanelWidth)
    }

    private var compactHorizontalPadding: CGFloat {
        if case .recording = appState.phase {
            return 24
        }

        return 14
    }

    private var currentCompactPanelWidth: CGFloat {
        if case .recording = appState.phase, appState.isRecordingIslandExpanded {
            return appState.previewPanelWidth
        }

        return appState.islandWidth
    }

    private var compactContentView: some View {
        HStack(alignment: .top, spacing: 8) {
            // Left indicator
            if case .recording = appState.phase {
                BreathingDot()
                    .padding(.top, 6)
            } else if case .transcribing = appState.phase {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 2)
            } else if case .updating = appState.phase {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 2)
            }

            compactTextView

            Spacer(minLength: 0)

            // Right side: timer or error dismiss
            if case .recording = appState.phase {
                Text(appState.recordingElapsedStr)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
                    .padding(.top, 1)
            }

            if case .error = appState.phase {
                Button {
                    appState.onCancel?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var compactTextView: some View {
        if shouldScrollCompactText {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        compactTextContent
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: compactTextColumnWidth, alignment: .leading)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: CompactTextSizePreferenceKey.self,
                                        value: proxy.size
                                    )
                                }
                            )

                        Color.clear
                            .frame(height: 1)
                            .id(compactTextBottomID)
                    }
                }
                .frame(height: compactTextViewportHeight)
                .onAppear {
                    proxy.scrollTo(compactTextBottomID, anchor: .bottom)
                }
                .onChange(of: compactTextScrollKey) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(compactTextBottomID, anchor: .bottom)
                    }
                }
                .onPreferenceChange(CompactTextSizePreferenceKey.self) { size in
                    compactTextContentHeight = max(18, size.height)
                    appState.updateMeasuredPreviewTextSize(size)
                }
            }
            .font(.system(size: 14))
            .multilineTextAlignment(.leading)
            .truncationMode(.tail)
            .frame(width: compactTextColumnWidth, alignment: .leading)
        } else {
            compactTextContent
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: compactTextColumnWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var compactTextContent: some View {
        if case .done(let text) = appState.phase {
            Text(text)
                .foregroundStyle(.white)
        } else if case .recording = appState.phase {
            if appState.previewTranscript.isEmpty {
                Text(L("Listening...", "聆听中..."))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                Text(appState.previewTranscript)
                    .foregroundStyle(.white.opacity(0.9))
            }
        } else if case .error = appState.phase {
            Text(appState.phase.subtitle)
                .foregroundStyle(.red.opacity(0.9))
        } else {
            Text(appState.phase.subtitle)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var shouldScrollCompactText: Bool {
        switch appState.phase {
        case .recording where !appState.previewTranscript.isEmpty:
            return true
        case .done, .error:
            return true
        default:
            return false
        }
    }

    private var compactTextColumnWidth: CGFloat {
        let leadingIndicatorWidth: CGFloat
        switch appState.phase {
        case .recording, .transcribing, .updating:
            leadingIndicatorWidth = 14
        default:
            leadingIndicatorWidth = 0
        }

        let trailingControlWidth: CGFloat
        switch appState.phase {
        case .recording:
            trailingControlWidth = 56
        case .error:
            trailingControlWidth = 20
        default:
            trailingControlWidth = 0
        }

        return max(
            160,
            currentCompactPanelWidth - compactHorizontalPadding * 2 - leadingIndicatorWidth - trailingControlWidth - 16
        )
    }

    private var compactTextViewportHeight: CGFloat {
        if case .recording = appState.phase {
            return max(18, appState.overlayPreviewTextViewportHeight)
        }

        return max(
            18,
            CompactIslandMetrics.textViewportHeight(forContentHeight: compactTextContentHeight)
        )
    }

    private var compactTextScrollKey: String {
        switch appState.phase {
        case .recording:
            return appState.previewTranscript
        default:
            return appState.phase.subtitle
        }
    }

    private var compactTextBottomID: String {
        "compactTextBottom"
    }

    func permissionView(missing: Set<PermissionKind>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(missing.sorted { $0.title < $1.title }), id: \.self) { kind in
                HStack(spacing: 12) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(kind.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(L("Open Settings", "打开设置")) {
                        appState.onPermissionOpen?(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack {
                Text(L("Checking automatically...", "自动检测中..."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("Cancel", "取消")) {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    var missingColiView: some View {
        let status = appState.dependencyStatus
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Finish setup", "完成依赖配置"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("TypeNo checks Node.js, ffmpeg, and coli before recording.", "TypeNo 会在录制前检查 Node.js、ffmpeg 和 coli。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(DependencyID.allCases) { dependency in
                    dependencyRow(dependency, status: status)
                }
            }
            .padding(.leading, 2)

            if let errorMessage = appState.dependencyErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }

            HStack(spacing: 8) {
                if status.npmPath == nil {
                    Button(L("Open Node.js", "打开 Node.js")) {
                        if let url = URL(string: "https://nodejs.org") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }

                if status.canAutoInstallFFmpeg && !appState.autoInstallBlocked(for: .ffmpeg) {
                    Button(L("Install ffmpeg", "安装 ffmpeg")) {
                        appState.autoInstallFFmpeg()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }

                if status.canAutoInstallColi && !appState.autoInstallBlocked(for: .coli) {
                    Button(L("Install coli", "安装 coli")) {
                        appState.autoInstallColi()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }

                Button(L("Copy commands", "复制命令")) {
                    appState.copyDependencySetupCommands()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .disabled(status.setupCommands.isEmpty)

                Spacer()

                Button(L("Cancel", "取消")) {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func dependencyRow(_ dependency: DependencyID, status: DependencyStatus) -> some View {
        let ready = status.isReady(dependency)

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : dependency.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ready ? .green : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))

                Text(status.detail(for: dependency))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func installingColiView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Setting up speech engine", "配置语音引擎"))
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Update Service

final class UpdateService: @unchecked Sendable {
    static let repoOwner = "musterkill007"
    static let repoName = "TypeNo-new"
    static let assetName = "TypeNo.app.zip"

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
    }

    enum CheckResult {
        case updateAvailable(ReleaseInfo)
        case upToDate
        case rateLimited
        case failed
    }

    func checkForUpdate() async -> ReleaseInfo? {
        switch await checkForUpdateDetailed() {
        case .updateAvailable(let info): return info
        default: return nil
        }
    }

    func checkForUpdateDetailed() async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest") else {
            return .failed
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TypeNo/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed
            }

            // GitHub rate limit error
            if json["message"] as? String != nil && json["tag_name"] == nil {
                return .rateLimited
            }

            guard let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return .failed
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard Self.isNewer(remote: remoteVersion, current: currentVersion) else {
                return .upToDate
            }

            guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                return .failed
            }

            return .updateAvailable(ReleaseInfo(version: remoteVersion, downloadURL: downloadURL))
        } catch {
            return .failed
        }
    }

    func downloadAndInstall(from downloadURL: URL, onProgress: @MainActor @Sendable (String) -> Void) async throws {
        await onProgress(L("Downloading update...", "下载更新..."))

        // Download zip to temp
        let (zipURL, _) = try await URLSession.shared.download(from: downloadURL)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipDest = tempDir.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zipDest.path) {
            try FileManager.default.removeItem(at: zipDest)
        }
        try FileManager.default.moveItem(at: zipURL, to: zipDest)

        await onProgress(L("Installing update...", "安装更新..."))

        // Use ditto --noqtn to unzip the app bundle — ditto is the macOS-native tool
        // for copying app bundles and --noqtn prevents quarantine from being propagated
        // to the extracted app (unlike /usr/bin/unzip which inherits quarantine).
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", "--noqtn", zipDest.path, tempDir.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()

        guard ditto.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let newAppURL = tempDir.appendingPathComponent("TypeNo.app")
        guard FileManager.default.fileExists(atPath: newAppURL.path) else {
            throw UpdateError.appNotFound
        }

        // Belt-and-suspenders: also remove quarantine recursively from the extracted app
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", newAppURL.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        // Replace current app
        let currentAppURL = Bundle.main.bundleURL
        let appParent = currentAppURL.deletingLastPathComponent()
        let backupURL = appParent.appendingPathComponent("TypeNo.app.bak")

        // Remove old backup if exists
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }

        // Move current → backup
        try FileManager.default.moveItem(at: currentAppURL, to: backupURL)

        // Move new → current
        do {
            try FileManager.default.moveItem(at: newAppURL, to: currentAppURL)
        } catch {
            // Rollback if move fails
            try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
            throw UpdateError.replaceFailed
        }

        // Remove quarantine from the final location AFTER the move.
        // Some macOS versions re-add quarantine during FileManager.moveItem;
        // cleaning here ensures the relocated app is trusted when opened.
        let xattrFinal = Process()
        xattrFinal.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrFinal.arguments = ["-cr", currentAppURL.path]   // -c clears all xattrs, -r recursive
        xattrFinal.standardOutput = FileHandle.nullDevice
        xattrFinal.standardError = FileHandle.nullDevice
        try? xattrFinal.run()
        xattrFinal.waitUntilExit()

        // Clean up backup and temp
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: tempDir)

        await onProgress("Restarting...")

        // Relaunch: strip quarantine one final time right before open so
        // any attribute reapplied between here and the actual launch is cleared.
        let appPath = currentAppURL.path
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1 && xattr -cr \"\(appPath)\" && open \"\(appPath)\""]
        try script.run()

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private static func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case unzipFailed
    case appNotFound
    case replaceFailed

    var errorDescription: String? {
        switch self {
        case .unzipFailed: "Failed to unzip update"
        case .appNotFound: "Update package is invalid"
        case .replaceFailed: "Failed to replace app"
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
