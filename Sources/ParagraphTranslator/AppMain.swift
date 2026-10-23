import AppKit
import SwiftUI
import TranslatorCore

@main
enum ParagraphTranslatorMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--inspect-selection") {
            _ = NSApplication.shared
            do {
                let passage = try SelectionReader().readSelection()
                let record: [String: Any] = ["text": passage.text, "plainFallback": passage.plainFallback,
                                             "fallbackReason": passage.fallbackReason ?? ""]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(2)
            }
        }
        let streamIndex = arguments.firstIndex(of: "--stream-translate")
        if let index = streamIndex ?? arguments.firstIndex(of: "--translate"), index + 1 < arguments.count {
            let text = arguments[index + 1]
            let started = ProcessInfo.processInfo.systemUptime
            let onUpdate: (@Sendable (String) -> Void)?
            if streamIndex != nil {
                onUpdate = { text in printStreamRecord(type: "partial", text: text, started: started) }
            } else { onUpdate = nil }
            Task {
                do {
                    let result = try await CodexTranslator().translate(text, onUpdate: onUpdate)
                    if streamIndex == nil { print(result) }
                    else { printStreamRecord(type: "completed", text: result, started: started) }
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = TranslatorAppDelegate(demo: arguments.contains("--demo"))
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }

    nonisolated private static func printStreamRecord(type: String, text: String, started: TimeInterval) {
        let record: [String: Any] = ["type": type, "text": text,
                                     "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }
}

@MainActor
final class TranslationModel: ObservableObject {
    enum Phase { case ready, translating, translated, failed }
    @Published var source = ""
    @Published var translation = ""
    @Published var message = ""
    @Published var phase: Phase = .ready
    @Published var elapsed: TimeInterval = 0
    @Published var accessibilityGranted = false
    @Published var copied = false
    @Published var shortcutMessage = "⌥⌘T 翻译选中内容"
    @Published var captureWarning = ""
    @Published var captureDiagnostics = ""

    private let translator = CodexTranslator()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()

    func translate(_ text: String, captureWarning: String = "") {
        cancel()
        let passage = text
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard passage.count <= 20_000 else {
            showError("选中文字超过 20,000 字符，请分段翻译。")
            return
        }
        source = passage
        self.captureWarning = captureWarning
        captureDiagnostics = ""
        translation = ""
        message = ""
        copied = false
        elapsed = 0
        phase = .translating
        let request = UUID()
        generation = request
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.generation == request else { return }
                self?.elapsed = Date().timeIntervalSince(started)
            }
        }
        task = Task { [weak self, translator] in
            let (updates, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let resultTask = Task {
                defer { continuation.finish() }
                return try await translator.translate(passage, onUpdate: { continuation.yield($0) })
            }
            do {
                let result = try await withTaskCancellationHandler {
                    for await partial in updates {
                        try Task.checkCancellation()
                        guard let self, self.generation == request else { continue }
                        self.translation = partial
                    }
                    return try await resultTask.value
                } onCancel: {
                    resultTask.cancel()
                    continuation.finish()
                }
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.timer?.invalidate()
                self.elapsed = Date().timeIntervalSince(started)
                self.translation = result
                self.phase = .translated
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.timer?.invalidate()
                self.translation = ""
                self.message = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        if phase == .translating { phase = .ready }
    }

    func reset() {
        cancel()
        source = ""
        translation = ""
        message = ""
        phase = .ready
        captureWarning = ""
        captureDiagnostics = ""
    }

    func showError(_ error: String, captureDiagnostics: String = "") {
        cancel()
        source = ""
        translation = ""
        copied = false
        captureWarning = ""
        message = error
        self.captureDiagnostics = captureDiagnostics
        phase = .failed
    }

    func copyTranslation() {
        guard !translation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translation, forType: .string)
        copied = true
    }
}

@MainActor
final class TranslatorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TranslationModel()
    private let selection = SelectionReader()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var panel: TranslationPanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private let demo: Bool

    init(demo: Bool) { self.demo = demo }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditingMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "段落翻译")
        let menu = NSMenu()
        menu.addItem(withTitle: "翻译选中内容  ⌥⌘T", action: #selector(translateSelection), keyEquivalent: "")
        menu.addItem(withTitle: "输入或粘贴英文…", action: #selector(openEditor), keyEquivalent: "")
        menu.addItem(withTitle: "翻译剪贴板中的英文", action: #selector(translateClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "授权辅助功能…", action: #selector(requestAccess), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出段落翻译", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
        NSApp.servicesProvider = self
        do {
            hotKey = try GlobalHotKey { [weak self] in self?.translateSelection() }
        } catch {
            model.shortcutMessage = "快捷键不可用，可从菜单栏打开"
            model.message = error.localizedDescription
        }
        model.accessibilityGranted = selection.hasAccessibilityAccess
        if demo {
            model.source = "Select a paragraph in any app, then press the keyboard shortcut. A small window will appear beside the selected text with the Chinese translation."
            model.translation = "在应用中选中一段英文，然后按下快捷键。选中文字旁会弹出一个小窗口，显示整段中文译文。"
            model.phase = .translated
        }
        showPanel(near: nil)
        if !demo { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(near: nil)
        return true
    }

    private func installEditingMenu() {
        // An AppKit lifecycle needs an explicit Edit menu for NSTextView's
        // standard keyboard equivalents, including the SwiftUI TextEditor.
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出段落翻译", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
        hotKey?.unregister()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    @objc private func translateSelection() {
        // Capture the source selection before showing our own window.
        do {
            let passage = try selection.readSelection()
            model.accessibilityGranted = true
            showPanel(near: passage.bounds)
            model.translate(passage.text, captureWarning: passage.plainFallback ? "未能读取原文排版，本次仅翻译纯文本。" : "")
        } catch {
            model.accessibilityGranted = selection.hasAccessibilityAccess
            model.showError(error.localizedDescription, captureDiagnostics: selection.diagnostics)
            showPanel(near: nil)
        }
    }

    @objc private func openEditor() {
        model.reset()
        showPanel(near: nil)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc private func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.showError("剪贴板中没有文字。请先复制英文，或在这里直接输入。")
            showPanel(near: nil)
            return
        }
        showPanel(near: nil)
        model.translate(text)
    }

    @objc private func requestAccess() {
        selection.requestAccessibilityAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc func translatePassage(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "没有收到选中的文字。" as NSString
            return
        }
        showPanel(near: nil)
        model.translate(text)
    }

    private func showPanel(near bounds: CGRect?) {
        model.accessibilityGranted = selection.hasAccessibilityAccess
        if panel == nil {
            let window = TranslationPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 530),
                styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            window.title = "段落翻译"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 480, height: 530)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.onDismiss = { [weak self] in self?.dismiss() }
            let content = NSHostingView(rootView: TranslationCard(
                model: model,
                onClose: { [weak self] in self?.dismiss() },
                onAccess: { [weak self] in self?.requestAccess() },
                onEdit: { [weak self] in self?.openEditor() }
            ))
            // The panel owns its dimensions; flexible SwiftUI content must
            // not replace them with an unbounded preferred size.
            content.sizingOptions = []
            window.contentView = content
            panel = window
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.model.phase == .translating || self.model.phase == .translated else { return }
                    self.dismiss()
                }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel?.isVisible == true,
                      event.window === self.panel, event.keyCode == 53 else { return event }
                self.dismiss()
                return nil
            }
        }
        guard let panel else { return }
        let anchor = bounds.map { NSPoint(x: $0.midX, y: $0.minY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Reopening on a smaller display must keep a previously enlarged
        // panel inside that display's usable bounds.
        panel.maxSize = NSSize(width: max(panel.minSize.width, visible.width - 24),
                               height: max(panel.minSize.height, visible.height - 24))
        let size = NSSize(width: min(panel.frame.width, panel.maxSize.width),
                          height: min(panel.frame.height, panel.maxSize.height))
        var x = anchor.x - size.width / 2
        var y = anchor.y - size.height - 12
        if y < visible.minY + 12 {
            y = (bounds?.maxY ?? anchor.y) + 12
        }
        x = min(max(x, visible.minX + 12), visible.maxX - size.width - 12)
        y = min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
        // A nonactivating panel can receive Escape/copy without switching the source app.
        panel.makeKey()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        model.cancel()
    }
}

final class TranslationPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }
}
