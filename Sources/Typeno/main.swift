import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers



@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: StatusItemController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var overlayController: OverlayPanelController?
    private var permissionsGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = OverlayPanelController(appState: appState)
        statusItemController = StatusItemController(appState: appState)
        hotkeyMonitor = HotkeyMonitor(onToggle: { [weak self] in
            self?.handleToggle()
        })

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

        appState.onPermissionOpen = { [weak self] kind in
            self?.openPermissionSettings(for: kind)
        }

        appState.onPermissionRetryRequest = { [weak self] in
            self?.refreshPermissionGuidance()
        }

        appState.onCancel = { [weak self] in
            self?.cancelFlow()
        }

        appState.onConfirm = { [weak self] in
            self?.appState.confirmInsert()
        }

        hotkeyMonitor?.start()
    }

    private func handleToggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .done:
            appState.confirmInsert()
        case .transcribing, .error, .permissions:
            break
        }
    }

    private func startRecording() {
        // Only check permissions if not previously granted this session
        if !permissionsGranted {
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: true)
            if !missing.isEmpty {
                appState.showPermissions(missing)
                return
            }
            permissionsGranted = true
        }

        do {
            try appState.startRecording()
        } catch {
            appState.showError(error.localizedDescription)
        }
    }

    private func stopRecording() {
        do {
            try appState.stopRecording()
            Task { @MainActor in
                await appState.transcribeAndInsert()
            }
        } catch {
            appState.showError(error.localizedDescription)
        }
    }

    private func cancelFlow() {
        appState.cancel()
    }

    private func openPermissionSettings(for kind: PermissionKind) {
        PermissionManager.openPrivacySettings(for: [kind])
    }

    private func refreshPermissionGuidance() {
        let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: false)
        if missing.isEmpty {
            appState.hidePermissions()
        } else {
            appState.showPermissions(missing)
        }
    }
}

// MARK: - Model

enum PermissionKind: CaseIterable, Hashable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: "Required to capture your voice"
        case .accessibility: "Required to type text into apps"
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
    case transcribing
    case done(String)        // transcription result, waiting for user confirm
    case permissions(Set<PermissionKind>)
    case error(String)

    var subtitle: String {
        switch self {
        case .idle: "Press Fn to start"
        case .recording: "Listening..."
        case .transcribing: "Transcribing..."
        case .done(let text): text
        case .permissions: ""
        case .error(let message): message
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var transcript = ""

    var onOverlayRequest: ((Bool) -> Void)?
    var onPermissionOpen: ((PermissionKind) -> Void)?
    var onPermissionRetryRequest: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onToggleRequest: (() -> Void)?

    private let recorder = AudioRecorder()
    private let asrService = ColiASRService()
    private var currentRecordingURL: URL?
    private var previousApp: NSRunningApplication?

    func startRecording() throws {
        transcript = ""
        previousApp = NSWorkspace.shared.frontmostApplication
        currentRecordingURL = try recorder.start()
        phase = .recording
        onOverlayRequest?(true)
    }

    func stopRecording() throws {
        guard let url = recorder.stop() else {
            throw TypeNoError.noRecording
        }

        currentRecordingURL = url
        phase = .transcribing
        onOverlayRequest?(true)
    }

    func cancel() {
        recorder.cancel()
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        transcript = ""
        phase = .idle
        onOverlayRequest?(false)
    }

    func showPermissions(_ missing: Set<PermissionKind>) {
        phase = .permissions(missing)
        onOverlayRequest?(true)
    }

    func hidePermissions() {
        phase = .idle
        onOverlayRequest?(false)
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

        phase = .transcribing

        do {
            let text = try await asrService.transcribe(fileURL: url)
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            // Show result briefly, then auto-insert
            phase = .done(transcript)
            onOverlayRequest?(true)
            confirmInsert()
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
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        previousApp = nil
        transcript = ""
        phase = .idle
        onOverlayRequest?(false)
    }

    func transcribeFile(_ url: URL) async {
        previousApp = NSWorkspace.shared.frontmostApplication
        phase = .transcribing
        onOverlayRequest?(true)

        do {
            let text = try await asrService.transcribe(fileURL: url)
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            phase = .done(transcript)
            onOverlayRequest?(true)
            confirmInsert()
        } catch {
            showError(error.localizedDescription)
        }
    }
}

// MARK: - Errors

enum TypeNoError: LocalizedError {
    case noRecording
    case emptyTranscript
    case coliNotInstalled
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecording: "No recording"
        case .emptyTranscript: "No speech detected"
        case .coliNotInstalled: "coli not found. Install: npm i -g @coli.codes/coli"
        case .transcriptionFailed(let message): message
        }
    }
}

// MARK: - Permission Manager

enum PermissionManager {
    static func missingPermissions(requestMicrophoneIfNeeded: Bool) -> Set<PermissionKind> {
        var missing = Set<PermissionKind>()

        switch microphoneStatus(requestIfNeeded: requestMicrophoneIfNeeded) {
        case .authorized:
            break
        default:
            missing.insert(.microphone)
        }

        if !AXIsProcessTrusted() {
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

// MARK: - Audio Recorder

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func start() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.record()

        self.recorder = recorder
        self.recordingURL = url
        return url
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        defer { recordingURL = nil }
        return recordingURL
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }
}

// MARK: - ASR Service

struct ColiASRService {
    func transcribe(fileURL: URL) async throws -> String {
        guard let coliPath = Self.findColiPath() else {
            throw TypeNoError.coliNotInstalled
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: coliPath)
                    process.arguments = ["asr", fileURL.path]

                    // Inherit a proper PATH so node/bun can be found
                    var env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/versions/node/",  // nvm
                        home + "/.bun/bin",
                        home + "/.npm-global/bin",
                        "/opt/homebrew/opt/node/bin"
                    ]
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                    process.environment = env

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()
                    process.waitUntilExit()

                    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TypeNoError.transcriptionFailed(msg.isEmpty ? "coli failed" : msg)
                    }

                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func findColiPath() -> String? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = [
            "/opt/homebrew/bin/coli",
            "/usr/local/bin/coli",
            home + "/.npm-global/bin/coli",
            home + "/.bun/bin/coli"
        ]

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

// MARK: - Hotkey Monitor (short-press Control only)

@MainActor
final class HotkeyMonitor {
    private let onToggle: () -> Void
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var controlDownAt: Date?
    private var otherKeyPressed = false

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func start() {
        // Track key presses while Control is held (both global and local)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.otherKeyPressed = true
            return event
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
            return event
        }
    }

    private func handle(event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)
        // If any other modifier is also held, it's a combo — ignore
        let otherModifiers: NSEvent.ModifierFlags = [.shift, .option, .command, .function]
        let hasOtherModifier = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if controlPressed && !hasOtherModifier {
            // Pure Control just went down
            if controlDownAt == nil {
                controlDownAt = Date()
                otherKeyPressed = false
            }
        } else {
            // Control released or another modifier involved
            if let downAt = controlDownAt {
                let elapsed = Date().timeIntervalSince(downAt)
                if elapsed < 0.3 && !otherKeyPressed && !hasOtherModifier {
                    onToggle()
                }
            }
            controlDownAt = nil
            otherKeyPressed = false
        }
    }
}

// MARK: - Status Item

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

        let recordItem = NSMenuItem(title: "Record  ⌃", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.tag = 100
        menu.addItem(recordItem)

        let transcribeItem = NSMenuItem(title: "Transcribe File...", action: #selector(transcribeFile), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Privacy Settings", action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TypeNo", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateRecordMenuItem(for phase: AppPhase) {
        guard let item = statusItem.menu?.item(withTag: 100) else { return }
        switch phase {
        case .recording:
            item.title = "Stop Recording"
        default:
            item.title = "Record"
        }
    }

    private func updateTitle(for phase: AppPhase) {
        statusItem.button?.title = switch phase {
        case .idle: "⌃"
        case .recording: "Rec"
        case .transcribing: "..."
        case .done: "✓"
        case .permissions: "!"
        case .error: "!"
        }
    }

    @objc private func openPrivacySettings() {
        PermissionManager.openPrivacySettings(for: [])
    }

    @objc private func toggleRecording() {
        appState?.onToggleRequest?()
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
        panel.message = "Choose an audio file to transcribe"

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

extension StatusItemController: NSWindowDelegate {
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
final class OverlayPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<OverlayView>
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let overlayView = OverlayView(appState: appState)
        hostingView = NSHostingView(rootView: overlayView)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
    }

    func show() {
        hostingView.invalidateIntrinsicContentSize()
        let idealSize = hostingView.fittingSize
        let width = max(idealSize.width, 240)
        let height = max(idealSize.height, 44)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - width / 2
            let y: CGFloat

            if case .permissions = appState.phase {
                // Onboarding: center of screen
                y = frame.midY - height / 2
            } else {
                // Recording/transcription bar: near bottom
                y = frame.minY + 48
            }

            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else {
            panel.setContentSize(NSSize(width: width, height: height))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            switch appState.phase {
            case .permissions(let missing):
                permissionView(missing: missing)
            case .idle:
                EmptyView()
            default:
                compactView
            }
        }
        .fixedSize()
    }

    var compactView: some View {
        HStack(spacing: 10) {
            if case .recording = appState.phase {
                Circle()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            if case .transcribing = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .done(let text) = appState.phase {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            } else {
                Text(appState.phase.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }

            if case .error = appState.phase {
                Button("OK") {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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

                    Button("Open Settings") {
                        appState.onPermissionOpen?(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Try Again") {
                    appState.onPermissionRetryRequest?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))

                Button("Cancel") {
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
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
