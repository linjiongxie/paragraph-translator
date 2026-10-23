import AppKit
import ApplicationServices

/// Native Terminal uses text areas rather than web text markers. This adapter
/// exposes only container metadata and explicit selections to the traversal.
/// It never requests AXValue, terminal scrollback, or the clipboard.
@MainActor
final class AccessibilityTerminalSelectionSource: TerminalSelectionSource {
    typealias Element = Int

    let bundleIdentifier: String?
    let focusedElement = 0
    private(set) var focusedWindow: Int?

    private let processID: pid_t
    private let application: AXUIElement
    private let deadline: TimeInterval
    private let record: (String) -> Void
    private var elements: [AXUIElement]

    init(focused: AXUIElement, processID: pid_t, record: @escaping (String) -> Void = { _ in }) throws {
        self.record = record
        self.processID = processID
        application = AXUIElementCreateApplication(processID)
        bundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        deadline = ProcessInfo.processInfo.systemUptime + 1
        elements = [focused]
        if let window = try elementAttribute(kAXFocusedWindowAttribute as CFString, of: application) {
            focusedWindow = identifier(for: window)
        }
    }

    func element(for identifier: Int) -> AXUIElement { elements[identifier] }

    func role(of element: Int) throws -> String? {
        let role = try attribute(kAXRoleAttribute as CFString, of: elements[element]) as? String
        record("node=\(element) role=\(role ?? "nil")")
        return role
    }

    func parent(of element: Int) throws -> Int? {
        guard let parent = try elementAttribute(kAXParentAttribute as CFString, of: elements[element]) else { return nil }
        return identifier(for: parent)
    }

    func children(of element: Int, limit: Int) throws -> [Int] {
        let target = elements[element]
        try prepare(target)
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(target, kAXChildrenAttribute as CFString, &count)
        record("node=\(element) childrenStatus=\(countError.rawValue) count=\(count)")
        try check(countError)
        guard countError == .success, count > 0 else { return [] }
        guard count <= limit else { throw TerminalSelectionFailure.limitExceeded }

        try prepare(target)
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(target, kAXChildrenAttribute as CFString, 0, count, &values)
        try check(error)
        guard error == .success, let values, CFArrayGetCount(values) == count else {
            throw TerminalSelectionFailure.invalidHierarchy
        }
        var children: [Int] = []
        for index in 0..<count {
            let child = unsafeBitCast(CFArrayGetValueAtIndex(values, index), to: CFTypeRef.self)
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else {
                throw TerminalSelectionFailure.invalidHierarchy
            }
            children.append(identifier(for: child as! AXUIElement))
        }
        return children
    }

    func selectedText(of element: Int) throws -> String? {
        let text = try attribute(kAXSelectedTextAttribute as CFString, of: elements[element]) as? String
        record("node=\(element) selectedUTF16=\(text?.utf16.count ?? -1) whitespace=\(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false)")
        return text
    }

    func selectedRange(of element: Int) throws -> NSRange? {
        guard let value = try attribute(kAXSelectedTextRangeAttribute as CFString, of: elements[element]) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cfRange else {
            throw TerminalSelectionFailure.invalidRange
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            throw TerminalSelectionFailure.invalidRange
        }
        record("node=\(element) range=\(range.location),\(range.length)")
        return NSRange(location: range.location, length: range.length)
    }

    func string(for range: NSRange, of element: Int) throws -> String? {
        var characters = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &characters) else { throw TerminalSelectionFailure.invalidRange }
        let target = elements[element]
        try prepare(target)
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            target, kAXStringForRangeParameterizedAttribute as CFString, value, &result
        )
        record("node=\(element) stringForRangeStatus=\(error.rawValue) requestedUTF16=\(range.length) returnedUTF16=\((result as? String)?.utf16.count ?? -1)")
        try check(error)
        return error == .success ? result as? String : nil
    }

    func sourceIsCurrent() throws -> Bool {
        let frontmostMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        record("frontmostMatches=\(frontmostMatches)")
        guard frontmostMatches else { return false }
        let focused = try elementAttribute(kAXFocusedUIElementAttribute as CFString, of: application)
        let focusMatches = focused.map { CFEqual($0, elements[focusedElement]) } ?? false
        record("focusMatches=\(focusMatches)")
        guard focusMatches else { return false }
        let currentWindow = try elementAttribute(kAXFocusedWindowAttribute as CFString, of: application)
        if let focusedWindow {
            let matches = currentWindow.map { CFEqual($0, elements[focusedWindow]) } ?? false
            record("windowMatches=\(matches)")
            return matches
        }
        return currentWindow == nil
    }

    private func identifier(for element: AXUIElement) -> Int {
        if let index = elements.firstIndex(where: { CFEqual($0, element) }) { return index }
        elements.append(element)
        return elements.count - 1
    }

    private func prepare(_ element: AXUIElement) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw TerminalSelectionFailure.timedOut }
        AXUIElementSetMessagingTimeout(element, Float(min(0.1, remaining)))
    }

    private func attribute(_ name: CFString, of element: AXUIElement) throws -> CFTypeRef? {
        try prepare(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        record("node=\(identifier(for: element)) attribute=\(name) status=\(error.rawValue) type=\(value.map { CFGetTypeID($0) } ?? 0)")
        try check(error)
        return error == .success ? value : nil
    }

    private func elementAttribute(_ name: CFString, of element: AXUIElement) throws -> AXUIElement? {
        guard let value = try attribute(name, of: element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw TerminalSelectionFailure.invalidHierarchy }
        return (value as! AXUIElement)
    }

    private func check(_ error: AXError) throws {
        switch error {
        case .success, .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported:
            return
        case .apiDisabled:
            throw SelectionError.accessibilityNotAuthorized
        default:
            throw SelectionError.applicationUnavailable
        }
    }
}
