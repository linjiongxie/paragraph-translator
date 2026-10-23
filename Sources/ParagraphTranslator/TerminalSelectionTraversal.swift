import Foundation

struct TerminalSelectedText<Element: Hashable> {
    let element: Element
    let text: String
    let range: NSRange?
}

enum TerminalSelectionFailure: Error, Equatable {
    case unsupportedApplication
    case noSelection
    case selectionChanged
    case invalidRange
    case invalidContent
    case limitExceeded
    case timedOut
    case ambiguousSelection
    case invalidHierarchy
}

/// Only selection text and bounded structural metadata are available here.
/// Implementations must reject oversized child collections, not truncate them.
@MainActor
protocol TerminalSelectionSource {
    associatedtype Element: Hashable
    var bundleIdentifier: String? { get }
    var focusedElement: Element { get }
    var focusedWindow: Element? { get }
    func role(of element: Element) throws -> String?
    func parent(of element: Element) throws -> Element?
    func children(of element: Element, limit: Int) throws -> [Element]
    func selectedText(of element: Element) throws -> String?
    func selectedRange(of element: Element) throws -> NSRange?
    func string(for range: NSRange, of element: Element) throws -> String?
    func sourceIsCurrent() throws -> Bool
}

@MainActor
enum TerminalSelectionTraversal {
    static func capture<Source: TerminalSelectionSource>(source: Source) throws -> TerminalSelectedText<Source.Element> {
        guard source.bundleIdentifier == "com.apple.Terminal" else {
            throw TerminalSelectionFailure.unsupportedApplication
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let maximumNodes = 32
        let maximumDepth = 5
        let maximumCharacters = 20_000
        let containerRoles: Set<String> = ["AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea"]
        var accounted: Set<Source.Element> = []

        func checkTime() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TerminalSelectionFailure.timedOut
            }
        }

        func read<Value>(_ operation: () throws -> Value) throws -> Value {
            try checkTime()
            let value = try operation()
            try checkTime()
            return value
        }

        func checkSource() throws {
            guard try read({ try source.sourceIsCurrent() }) else {
                throw TerminalSelectionFailure.selectionChanged
            }
        }

        func account(_ element: Source.Element) throws {
            if !accounted.contains(element) {
                guard accounted.count < maximumNodes else { throw TerminalSelectionFailure.limitExceeded }
                accounted.insert(element)
            }
        }

        func validate(_ range: NSRange) throws {
            guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
                  !range.location.addingReportingOverflow(range.length).overflow else {
                throw TerminalSelectionFailure.invalidRange
            }
            guard range.length <= maximumCharacters else { throw TerminalSelectionFailure.limitExceeded }
        }

        func selectedText(in element: Source.Element) throws -> TerminalSelectedText<Source.Element>? {
            let before = try read { try source.selectedRange(of: element) }
            if let before { try validate(before) }
            let direct = try read { try source.selectedText(of: element) }
            var text = direct
            if direct?.isEmpty != false,
               let before, before.length > 0 {
                text = try read { try source.string(for: before, of: element) }
                guard let text, text.utf16.count == before.length else {
                    throw TerminalSelectionFailure.invalidContent
                }
            }
            let after = try read { try source.selectedRange(of: element) }
            guard before == after else { throw TerminalSelectionFailure.selectionChanged }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let length = text.utf16.count
            guard length <= maximumCharacters else { throw TerminalSelectionFailure.limitExceeded }
            if let before {
                guard before.length > 0, before.length == length else { throw TerminalSelectionFailure.invalidContent }
            }
            return TerminalSelectedText(element: element, text: text, range: before)
        }

        func finish(_ candidate: TerminalSelectedText<Source.Element>) throws -> TerminalSelectedText<Source.Element> {
            try checkSource()
            guard let confirmed = try selectedText(in: candidate.element),
                  confirmed.text == candidate.text, confirmed.range == candidate.range else {
                throw TerminalSelectionFailure.selectionChanged
            }
            try checkSource()
            return confirmed
        }

        try checkSource()

        // A focused text area (or a focused child inside it) unambiguously
        // identifies the active pane, even when another pane retains a selection.
        var element = source.focusedElement
        var parentsSeen: Set<Source.Element> = []
        var searchRoot: (element: Source.Element, role: String)?
        for distance in 0...8 {
            guard parentsSeen.insert(element).inserted else { throw TerminalSelectionFailure.invalidHierarchy }
            try account(element)
            let role = try read { try source.role(of: element) }
            if searchRoot == nil, let role, containerRoles.contains(role) {
                searchRoot = (element, role)
            }
            if role == "AXTextArea" {
                if let selection = try selectedText(in: element) {
                    return try finish(selection)
                }
                // Once the active text pane is known, another pane's retained
                // selection is not a substitute for the user's current selection.
                try checkSource()
                throw TerminalSelectionFailure.noSelection
            }
            guard distance < 8, let parent = try read({ try source.parent(of: element) }) else { break }
            element = parent
        }

        guard let searchRoot else {
            try checkSource()
            throw TerminalSelectionFailure.noSelection
        }
        if searchRoot.role == "AXWindow", searchRoot.element != source.focusedWindow {
            throw TerminalSelectionFailure.invalidHierarchy
        }

        // Terminal can expose focus on a container rather than its text area.
        // Stay inside the nearest focused container: a sibling pane's retained
        // selection is not a substitute when the focused container is empty.
        // Only window-level focus permits a window-wide scan, and that window
        // must be the source's focused window. Finish the full bounded subtree
        // before choosing a candidate, so incomplete scans cannot select a pane.
        var queue: [(element: Source.Element, depth: Int)] = [(searchRoot.element, 0)]
        var treeSeen: Set<Source.Element> = [searchRoot.element]
        var cursor = 0
        var candidate: TerminalSelectedText<Source.Element>?
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            guard let role = try read({ try source.role(of: current.element) }) else {
                throw TerminalSelectionFailure.invalidHierarchy
            }
            if role == "AXTextArea" {
                if let selection = try selectedText(in: current.element) {
                    guard candidate == nil else { throw TerminalSelectionFailure.ambiguousSelection }
                    candidate = selection
                }
                continue
            }
            guard containerRoles.contains(role) else { continue }
            let children = try read { try source.children(of: current.element, limit: maximumNodes) }
            guard children.count <= maximumNodes else { throw TerminalSelectionFailure.limitExceeded }
            guard children.isEmpty || current.depth < maximumDepth else { throw TerminalSelectionFailure.limitExceeded }
            for child in children {
                guard treeSeen.insert(child).inserted else { throw TerminalSelectionFailure.invalidHierarchy }
                try account(child)
                queue.append((child, current.depth + 1))
            }
        }
        try checkSource()
        guard let candidate else { throw TerminalSelectionFailure.noSelection }
        return try finish(candidate)
    }
}
