import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import SwiftUI



@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: StatusItemController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var overlayController: OverlayPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = OverlayPanelController(appState: appState)
        statusItemController = StatusItemController(appState: appState)
        hotkeyMonitor = HotkeyMonitor(onToggle: { [weak self] in
            self?.handleToggle()
        })

        appState.onOverlayRequest = { [weak self] visible in
            if visible {
                self?.overlayController?.show()
            } else {
                self?.overlayController?.hide()
            }
        }

        appState.onPermissionHelpRequest = { [weak self] in
            self?.openPermissionSettings()
        }

        appState.onPermissionRetryRequest = { [weak self] in
            self?.refreshPermissionGuidance()
        }

        appState.onCancel = { [weak self] in
            self?.cancelFlow()
        }

        appState.onCommit = { [weak self] in
            self?.commitFlow()
        }

        hotkeyMonitor?.start()
    }

    private func handleToggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .ready, .transcribing, .error, .permissions:
            break
        }
    }

    private func startRecording() {
        let missingPermissions = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: true)
        guard missingPermissions.isEmpty else {
            appState.showPermissions(missingPermissions)
            return
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
        } catch {
            appState.showError(error.localizedDescription)
        }
    }

    private func cancelFlow() {
        appState.cancel()
    }

    private func commitFlow() {
        Task { @MainActor [weak self] in
            await self?.appState.transcribeAndInsert()
        }
    }

    private func openPermissionSettings() {
        guard case .permissions(let missingPermissions) = appState.phase else {
            PermissionManager.openPrivacySettings(for: [])
            return
        }

        PermissionManager.openPrivacySettings(for: missingPermissions)
    }

    private func refreshPermissionGuidance() {
        let missingPermissions = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: false)
        if missingPermissions.isEmpty {
            appState.hidePermissions()
        } else {
            appState.showPermissions(missingPermissions)
        }
    }
}

enum PermissionKind: CaseIterable, Hashable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }
}

enum AppPhase: Equatable {
    case idle
    case recording
    case ready
    case transcribing
    case permissions(Set<PermissionKind>)
    case error(String)

    var title: String {
        switch self {
        case .idle: "Idle"
        case .recording: "Listening"
        case .ready: "Ready"
        case .transcribing: "Transcribing"
        case .permissions(let missingPermissions):
            missingPermissions.count > 1 ? "Permissions needed" : "Permission needed"
        case .error: "Something went wrong"
        }
    }

    var subtitle: String {
        switch self {
        case .idle: "Press Fn"
        case .recording: "Press Fn again to stop"
        case .ready: "Cancel or Complete"
        case .transcribing: "Running coli"
        case .permissions(let missingPermissions):
            switch missingPermissions {
            case [.microphone]:
                "Enable microphone access in System Settings"
            case [.accessibility]:
                "Enable accessibility access in System Settings"
            default:
                "Enable microphone and accessibility in System Settings"
            }
        case .error(let message): message
        }
    }

    var detail: String? {
        switch self {
        case .permissions(let missingPermissions):
            let names = missingPermissions
                .sorted { $0.title < $1.title }
                .map(\.title)
                .joined(separator: " + ")
            return "Turn on \(names), then come back and tap Try Again."
        default:
            return nil
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var transcript = ""

    var onOverlayRequest: ((Bool) -> Void)?
    var onPermissionHelpRequest: (() -> Void)?
    var onPermissionRetryRequest: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?

    private let recorder = AudioRecorder()
    private let asrService = ColiASRService()
    private let textInserter = TextInsertionService()
    private var currentRecordingURL: URL?

    func startRecording() throws {
        transcript = ""
        currentRecordingURL = try recorder.start()
        phase = .recording
        onOverlayRequest?(true)
    }

    func stopRecording() throws {
        guard let url = recorder.stop() else {
            throw TypeNoError.noRecording
        }

        currentRecordingURL = url
        phase = .ready
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

    func showPermissions(_ missingPermissions: Set<PermissionKind>) {
        phase = .permissions(missingPermissions)
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

            try textInserter.insert(transcript)
            cancel()
        } catch {
            showError(error.localizedDescription)
        }
    }
}

enum TypeNoError: LocalizedError {
    case noRecording
    case emptyTranscript
    case coliNotInstalled
    case transcriptionFailed(String)
    case textInsertionFailed

    var errorDescription: String? {
        switch self {
        case .noRecording: "No recording"
        case .emptyTranscript: "No speech detected"
        case .coliNotInstalled: "Install coli first"
        case .transcriptionFailed(let message): message
        case .textInsertionFailed: "Unable to insert text"
        }
    }
}

enum PermissionManager {
    static func missingPermissions(requestMicrophoneIfNeeded: Bool) -> Set<PermissionKind> {
        var missingPermissions = Set<PermissionKind>()

        switch microphoneStatus(requestIfNeeded: requestMicrophoneIfNeeded) {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            missingPermissions.insert(.microphone)
        @unknown default:
            missingPermissions.insert(.microphone)
        }

        if hasAccessibilityTrust() == false {
            missingPermissions.insert(.accessibility)
        }

        return missingPermissions
    }

    static func microphoneStatus(requestIfNeeded: Bool) -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined, requestIfNeeded {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        return status
    }

    static func hasAccessibilityTrust() -> Bool {
        AXIsProcessTrusted()
    }

    static func openPrivacySettings(for missingPermissions: Set<PermissionKind>) {
        let urls = missingPermissions
            .sorted { $0.title < $1.title }
            .compactMap(privacySettingsURL(for:))

        if let url = urls.first {
            NSWorkspace.shared.open(url)
            return
        }

        openPrivacySettings()
    }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func privacySettingsURL(for permission: PermissionKind) -> URL? {
        let rawValue = switch permission {
        case .microphone:
            "Privacy_Microphone"
        case .accessibility:
            "Privacy_Accessibility"
        }

        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}

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

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()
                    process.waitUntilExit()

                    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        throw TypeNoError.transcriptionFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "coli failed" : errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
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
            home + "/.bun/bin/coli",
            home + "/.volta/bin/coli"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // GUI apps don't inherit terminal PATH, so spawn a login shell to resolve coli
        return resolveViaShell("coli")
    }

    private static func resolveViaShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "which \(command)"]

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
}

struct TextInsertionService {
    func insert(_ text: String) throws {
        if try insertViaAccessibility(text) {
            return
        }

        try insertViaPasteboard(text)
    }

    private func insertViaAccessibility(_ text: String) throws -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard result == .success, let focusedObject else {
            return false
        }

        let focusedElement = unsafeDowncast(focusedObject, to: AXUIElement.self)
        let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, text as CFTypeRef)
        return setResult == .success
    }

    private func insertViaPasteboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TypeNoError.textInsertionFailed
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        commandDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        commandDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)

        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}

@MainActor
final class HotkeyMonitor {
    private let onToggle: () -> Void
    private var eventMonitor: Any?
    private var lastToggleAt = Date.distantPast

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func start() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    func hasAccessibilityTrust() -> Bool {
        AXIsProcessTrusted()
    }

    private func handle(event: NSEvent) {
        guard event.keyCode == 63, event.modifierFlags.contains(.function) else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.35 else {
            return
        }

        lastToggleAt = now
        onToggle()
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellable: AnyCancellable?

    init(appState: AppState) {
        super.init()
        configureMenu()
        updateTitle(for: appState.phase)
        cancellable = appState.$phase.sink { [weak self] phase in
            self?.updateTitle(for: phase)
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Privacy Settings", action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TypeNo", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateTitle(for phase: AppPhase) {
        statusItem.button?.title = switch phase {
        case .idle: "Fn"
        case .recording: "Rec"
        case .ready: "Done"
        case .transcribing: "..."
        case .permissions: "Fix"
        case .error: "!"
        }
    }

    @objc private func openPrivacySettings() {
        PermissionManager.openPrivacySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel

    init(appState: AppState) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(appState: appState))
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 32)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct OverlayView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.phase.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(appState.phase.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let detail = appState.phase.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            switch appState.phase {
            case .recording:
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
            case .ready:
                Button("Cancel") {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)

                Button("Complete") {
                    appState.onCommit?()
                }
                .buttonStyle(.borderedProminent)
            case .permissions:
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Open Settings") {
                        appState.onPermissionHelpRequest?()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Try Again") {
                        appState.onPermissionRetryRequest?()
                    }
                    .buttonStyle(.borderless)
                }
            case .error:
                Button("Dismiss") {
                    appState.onCancel?()
                }
                .buttonStyle(.borderedProminent)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
