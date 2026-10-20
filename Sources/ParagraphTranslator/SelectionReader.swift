import AppKit
import ApplicationServices

struct SelectedPassage {
    let text: String
    /// AppKit screen coordinates (points, with an upward-pointing y axis).
    let bounds: CGRect?
    let plainFallback: Bool
    let fallbackReason: String?

    init(text: String, bounds: CGRect?, plainFallback: Bool = false, fallbackReason: String? = nil) {
        self.text = text
        self.bounds = bounds
        self.plainFallback = plainFallback
        self.fallbackReason = fallbackReason
    }
}

enum SelectionError: LocalizedError {
    case accessibilityNotAuthorized
    case noSelection
    case unsupportedApplication
    case applicationUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityNotAuthorized:
            return "请先在系统设置的“隐私与安全性 → 辅助功能”中允许段落翻译读取选中文字。"
        case .noSelection:
            return "没有读到选中文字。请先在来源应用中选中一段文字，再按 ⌥⌘T。"
        case .unsupportedApplication:
            return "当前应用没有通过辅助功能提供选中文字，暂时无法读取这处选区。"
        case .applicationUnavailable:
            return "暂时无法读取来源应用。请回到来源应用，重新选中文字后再试。"
        }
    }
}

@MainActor
final class SelectionReader {
    var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Call before activating our application or showing a panel: both the text
    /// and its position belong to the currently focused source application.
    func readSelection() throws -> SelectedPassage {
        guard hasAccessibilityAccess else {
            throw SelectionError.accessibilityNotAuthorized
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        let focused = try attribute(kAXFocusedUIElementAttribute as CFString, of: system)
        guard let focusedValue = focused.value,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw focused.error == .attributeUnsupported
                ? SelectionError.unsupportedApplication
                : SelectionError.applicationUnavailable
        }

        var element = focusedValue as! AXUIElement
        var visited: [AXUIElement] = []
        var supportsSelection = false
        let webReader = WebSelectionReader()
        var fallback: SelectedPassage?
        var formatFailure = WebSelectionFailure.unsupported

        // Some applications focus a child inside the actual text element.
        // Inspect only that element, its bounded parent chain, and explicit
        // selected marker intervals. Never read the document value, traverse
        // document children, or copy to the clipboard.
        for _ in 0..<8 {
            guard !visited.contains(where: { CFEqual($0, element) }) else { break }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.1)

            // Snapshot the original selection before the optional formatter
            // can spend its deadline or reduce this element's AX timeout.
            let selected: (error: AXError, value: CFTypeRef?)
            do {
                selected = try attribute(kAXSelectedTextAttribute as CFString, of: element)
            } catch {
                if fallback != nil { break }
                throw error
            }
            let range = try? attribute(kAXSelectedTextRangeAttribute as CFString, of: element)
            supportsSelection = supportsSelection
                || selected.error == .success || selected.error == .noValue
                || range?.error == .success || range?.error == .noValue

            if fallback == nil, let text = selected.value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Read the bounds now, while the source still owns focus.
                // Position is optional: a slow/unsupported geometry lookup
                // must not discard text we have already captured.
                let bounds = try? selectionBounds(range?.value, in: element)
                fallback = SelectedPassage(text: text, bounds: bounds)
            }

            do {
                let markdown = try webReader.read(from: element, expectedText: fallback?.text)
                return SelectedPassage(text: markdown, bounds: fallback?.bounds)
            } catch let failure as WebSelectionFailure {
                if failure != .unsupported {
                    supportsSelection = true
                    formatFailure = failure
                }
            }

            guard webReader.hasTimeRemaining else { break }
            AXUIElementSetMessagingTimeout(element, 0.1)
            let parent: (error: AXError, value: CFTypeRef?)
            do {
                parent = try attribute(kAXParentAttribute as CFString, of: element)
            } catch {
                if fallback != nil { break }
                throw error
            }
            guard let parentValue = parent.value,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            element = parentValue as! AXUIElement
        }

        if let fallback {
            return SelectedPassage(
                text: fallback.text,
                bounds: fallback.bounds,
                plainFallback: true,
                fallbackReason: formatFailure.fallbackReason
            )
        }

        throw supportsSelection
            ? SelectionError.noSelection
            : SelectionError.unsupportedApplication
    }

    private func attribute(
        _ name: CFString,
        of element: AXUIElement
    ) throws -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        try checkAvailability(error)
        return (error, value)
    }

    private func selectionBounds(_ range: CFTypeRef?, in element: AXUIElement) throws -> CGRect? {
        guard let range,
              CFGetTypeID(range) == AXValueGetTypeID(),
              AXValueGetType(range as! AXValue) == .cfRange else { return nil }

        var characters = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &characters),
              characters.location >= 0, characters.length > 0 else { return nil }

        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value
        )
        try checkAvailability(error)
        guard error == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgRect else { return nil }

        var rectangle = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rectangle),
              rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite,
              !rectangle.isEmpty,
              let primaryScreen = NSScreen.screens.first else { return nil }

        // AX starts at the top-left of the menu-bar display. AppKit starts at
        // its bottom-left. Use the primary screen, not NSScreen.main (which can
        // change with focus), and preserve global x so secondary screens above,
        // below, or to the left of the primary display retain their position.
        return CGRect(
            x: rectangle.minX,
            y: primaryScreen.frame.maxY - rectangle.maxY,
            width: rectangle.width,
            height: rectangle.height
        )
    }

    private func checkAvailability(_ error: AXError) throws {
        switch error {
        case .apiDisabled:
            throw SelectionError.accessibilityNotAuthorized
        case .cannotComplete, .invalidUIElement:
            throw SelectionError.applicationUnavailable
        default:
            break
        }
    }
}
