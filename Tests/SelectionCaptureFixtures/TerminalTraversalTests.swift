import Foundation

@MainActor
private final class TerminalFixture: TerminalSelectionSource {
    struct Node {
        var role: String
        var parent: Int?
        var children: [Int] = []
        var selected: String?
        var range: NSRange?
        var rangeText: String?
    }

    var bundleIdentifier: String? = "com.apple.Terminal"
    var focusedElement = 1
    var focusedWindow: Int? = 0
    var nodes: [Int: Node] = [:]
    var reads: [String] = []
    var exactRanges: [(Int, NSRange)] = []
    var changedRangeFor: Int?
    var rangeReads: [Int: Int] = [:]
    var currentChecks = 0
    var changesSourceAfterCheck: Int?
    var delayedRoleFor: Int?
    var ignoreChildLimit = false
    var changesSelectionWhenReadingRole: Int?
    var changedTextOnReadFor: Int?
    var textReads: [Int: Int] = [:]

    func role(of element: Int) throws -> String? {
        reads.append("role:\(element)")
        if delayedRoleFor == element { Thread.sleep(forTimeInterval: 1.02) }
        if changesSelectionWhenReadingRole == element {
            nodes[3]?.selected = "World"
            nodes[3]?.range = NSRange(location: 50, length: 5)
        }
        return nodes[element]?.role
    }
    func parent(of element: Int) throws -> Int? {
        reads.append("parent:\(element)")
        return nodes[element]?.parent
    }
    func children(of element: Int, limit: Int) throws -> [Int] {
        reads.append("children:\(element)")
        let children = nodes[element]?.children ?? []
        if !ignoreChildLimit && children.count > limit { throw TerminalSelectionFailure.limitExceeded }
        return children
    }
    func selectedText(of element: Int) throws -> String? {
        reads.append("text:\(element)")
        textReads[element, default: 0] += 1
        if changedTextOnReadFor == element, textReads[element, default: 0] > 1 { return "World" }
        return nodes[element]?.selected
    }
    func selectedRange(of element: Int) throws -> NSRange? {
        reads.append("range:\(element)")
        rangeReads[element, default: 0] += 1
        if changedRangeFor == element, rangeReads[element, default: 0] > 1 {
            return NSRange(location: 91, length: 6)
        }
        return nodes[element]?.range
    }
    func string(for range: NSRange, of element: Int) throws -> String? {
        reads.append("string:\(element)")
        exactRanges.append((element, range))
        guard range == nodes[element]?.range else { throw TerminalSelectionFailure.invalidRange }
        return nodes[element]?.rangeText
    }
    func sourceIsCurrent() throws -> Bool {
        reads.append("current")
        currentChecks += 1
        return changesSourceAfterCheck.map { currentChecks <= $0 } ?? true
    }

    static func container() -> TerminalFixture {
        let fixture = TerminalFixture()
        fixture.nodes = [
            0: Node(role: "AXWindow", children: [1]),
            1: Node(role: "AXGroup", parent: 0, children: [2]),
            2: Node(role: "AXScrollArea", parent: 1, children: [3]),
            3: Node(role: "AXTextArea", parent: 2, selected: "Hello", range: NSRange(location: 40, length: 5))
        ]
        return fixture
    }
}

@main
struct TerminalTraversalTests {
    @MainActor static func main() {
        do { try run() }
        catch {
            fputs("Terminal selection traversal FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "TerminalSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
        }
        func expect(_ expected: TerminalSelectionFailure, from fixture: TerminalFixture, _ label: String) throws {
            do {
                _ = try TerminalSelectionTraversal.capture(source: fixture)
                try check(false, label)
            } catch let failure as TerminalSelectionFailure {
                try check(failure == expected, "\(label): got \(failure), expected \(expected)")
            }
        }

        let container = TerminalFixture.container()
        let result = try TerminalSelectionTraversal.capture(source: container)
        try check(result.text == "Hello" && result.element == 3 && result.range == NSRange(location: 40, length: 5), "A selected text area under the focused container must be discovered")
        try check(!container.reads.contains("text:0") && !container.reads.contains("text:1") && !container.reads.contains("text:2"), "Only text-area leaves may supply selected text")
        try check(container.currentChecks >= 2, "Check source identity before and after capture")

        let focused = TerminalFixture.container()
        focused.focusedElement = 3
        focused.nodes[4] = .init(role: "AXTextArea", parent: 1, selected: "Other")
        focused.nodes[1]?.children.append(4)
        let focusedResult = try TerminalSelectionTraversal.capture(source: focused)
        try check(focusedResult.element == 3, "A focused text area's selection takes precedence over other panes")
        try check(!focused.reads.contains(where: { $0.hasPrefix("children:") }), "Focused selection must not trigger window traversal")

        let emptyFocusedPane = TerminalFixture.container()
        emptyFocusedPane.focusedElement = 3
        emptyFocusedPane.nodes[3]?.selected = nil
        emptyFocusedPane.nodes[3]?.range = NSRange(location: 4, length: 0)
        emptyFocusedPane.nodes[4] = .init(role: "AXTextArea", parent: 1, selected: "Retained selection in another pane")
        emptyFocusedPane.nodes[1]?.children.append(4)
        try expect(.noSelection, from: emptyFocusedPane, "An active empty text pane must not borrow a sibling pane's retained selection")
        try check(!emptyFocusedPane.reads.contains(where: { $0.hasPrefix("children:") }), "Do not scan the window after identifying an active text pane without selection")

        let emptyFocusedScrollArea = TerminalFixture.container()
        emptyFocusedScrollArea.focusedElement = 2
        emptyFocusedScrollArea.nodes[3]?.selected = nil
        emptyFocusedScrollArea.nodes[3]?.range = NSRange(location: 4, length: 0)
        emptyFocusedScrollArea.nodes[4] = .init(role: "AXTextArea", parent: 1, selected: "Retained selection in a sibling pane")
        emptyFocusedScrollArea.nodes[1]?.children.append(4)
        try expect(.noSelection, from: emptyFocusedScrollArea, "An empty focused scroll area must not borrow a sibling pane's selection")
        try check(!emptyFocusedScrollArea.reads.contains("children:1") && !emptyFocusedScrollArea.reads.contains("role:4"), "Only scan the nearest focused container's subtree")

        let focusedContainerWithSibling = TerminalFixture.container()
        focusedContainerWithSibling.nodes[4] = .init(role: "AXTextArea", parent: 0, selected: "Another pane's retained selection")
        focusedContainerWithSibling.nodes[0]?.children.append(4)
        try check(try TerminalSelectionTraversal.capture(source: focusedContainerWithSibling).element == 3, "Choose the selected text in the focused container without considering sibling containers")
        try check(!focusedContainerWithSibling.reads.contains("children:0") && !focusedContainerWithSibling.reads.contains("role:4"), "Do not read a sibling pane outside the focused container")

        let focusedWindowWithTwoSelections = TerminalFixture.container()
        focusedWindowWithTwoSelections.focusedElement = 0
        focusedWindowWithTwoSelections.nodes[4] = .init(role: "AXTextArea", parent: 0, selected: "Another selected pane")
        focusedWindowWithTwoSelections.nodes[0]?.children.append(4)
        try expect(.ambiguousSelection, from: focusedWindowWithTwoSelections, "Window-level focus cannot disambiguate two selected panes")

        let mismatchedWindow = TerminalFixture.container()
        mismatchedWindow.focusedElement = 0
        mismatchedWindow.focusedWindow = 99
        try expect(.invalidHierarchy, from: mismatchedWindow, "A window search root must match the source's focused window")
        try check(!mismatchedWindow.reads.contains(where: { $0.hasPrefix("children:") }), "Do not scan a mismatched window")

        let ancestor = TerminalFixture.container()
        ancestor.focusedElement = 4
        ancestor.nodes[4] = .init(role: "AXUnknown", parent: 3)
        try check(try TerminalSelectionTraversal.capture(source: ancestor).element == 3, "A text area on the focused parent chain is preferred")

        let rangeOnly = TerminalFixture.container()
        rangeOnly.nodes[3]?.selected = nil
        rangeOnly.nodes[3]?.range = NSRange(location: 7, length: 4)
        rangeOnly.nodes[3]?.rangeText = "A😀中"
        let rangeResult = try TerminalSelectionTraversal.capture(source: rangeOnly)
        try check(rangeResult.text == "A😀中", "A nonempty exact selected range can supply text without AXSelectedText")
        try check(rangeOnly.exactRanges.count == 2 && rangeOnly.exactRanges.allSatisfy { $0.1 == NSRange(location: 7, length: 4) }, "Read and revalidate only the exact selected UTF-16 range")

        let noRange = TerminalFixture.container()
        noRange.nodes[3]?.range = nil
        try check(try TerminalSelectionTraversal.capture(source: noRange).text == "Hello", "Direct selected text is usable when range is unsupported")

        let empty = TerminalFixture.container()
        empty.nodes[3]?.selected = nil
        empty.nodes[3]?.range = NSRange(location: 10, length: 0)
        try expect(.noSelection, from: empty, "An insertion point is not a selection")
        try check(empty.exactRanges.isEmpty, "Never read a zero-length range")

        let inconsistentCaret = TerminalFixture.container()
        inconsistentCaret.nodes[3]?.range = NSRange(location: 10, length: 0)
        try expect(.invalidContent, from: inconsistentCaret, "Nonempty direct text with an insertion-point range must fail closed")

        let whitespace = TerminalFixture.container()
        whitespace.nodes[3]?.selected = " \n "
        whitespace.nodes[3]?.range = NSRange(location: 9, length: 3)
        try expect(.noSelection, from: whitespace, "Whitespace-only selected text does not become a translation request")
        try check(whitespace.exactRanges.isEmpty, "Whitespace selected text does not trigger additional range reads")

        let whitespaceRange = TerminalFixture.container()
        whitespaceRange.nodes[3]?.selected = nil
        whitespaceRange.nodes[3]?.range = NSRange(location: 9, length: 3)
        whitespaceRange.nodes[3]?.rangeText = " \n "
        try expect(.noSelection, from: whitespaceRange, "Whitespace-only exact-range results do not become translation requests")
        try check(whitespaceRange.exactRanges.count == 1 && whitespaceRange.exactRanges[0].1 == NSRange(location: 9, length: 3), "Whitespace fallback reads only the requested selection")

        let changed = TerminalFixture.container()
        changed.changedRangeFor = 3
        try expect(.selectionChanged, from: changed, "Changing direct selected ranges must fail closed")

        let changedExact = TerminalFixture.container()
        changedExact.nodes[3]?.selected = nil
        changedExact.nodes[3]?.rangeText = "Hello"
        changedExact.changedRangeFor = 3
        try expect(.selectionChanged, from: changedExact, "Changing ranges during StringForRange must fail closed")

        let changesDuringScan = TerminalFixture.container()
        changesDuringScan.nodes[4] = .init(role: "AXTextArea", parent: 2)
        changesDuringScan.nodes[2]?.children.append(4)
        changesDuringScan.changesSelectionWhenReadingRole = 4
        try expect(.selectionChanged, from: changesDuringScan, "Revalidate an earlier candidate after scanning the remaining panes")

        let changesWithoutRange = TerminalFixture.container()
        changesWithoutRange.focusedElement = 3
        changesWithoutRange.nodes[3]?.range = nil
        changesWithoutRange.changedTextOnReadFor = 3
        try expect(.selectionChanged, from: changesWithoutRange, "Revalidate direct selected text even when the source has no range API")

        let invalidLength = TerminalFixture.container()
        invalidLength.nodes[3]?.selected = nil
        invalidLength.nodes[3]?.rangeText = "Hi"
        try expect(.invalidContent, from: invalidLength, "Exact-range text must match the requested UTF-16 length")

        let ambiguous = TerminalFixture.container()
        ambiguous.nodes[4] = .init(role: "AXTextArea", parent: 1, selected: "Other")
        ambiguous.nodes[1]?.children.append(4)
        try expect(.ambiguousSelection, from: ambiguous, "Two selected nonfocused panes cannot be disambiguated")

        let unsupported = TerminalFixture.container()
        unsupported.bundleIdentifier = "com.example.Other"
        try expect(.unsupportedApplication, from: unsupported, "The traversal only supports Apple Terminal")
        try check(unsupported.reads.isEmpty, "Other apps must not be probed")

        let nilBundle = TerminalFixture.container()
        nilBundle.bundleIdentifier = nil
        try expect(.unsupportedApplication, from: nilBundle, "Unknown application identity must not be probed")
        try check(nilBundle.reads.isEmpty, "Unknown apps have no AX reads")

        let switched = TerminalFixture.container()
        switched.changesSourceAfterCheck = 1
        try expect(.selectionChanged, from: switched, "Changing foreground source during capture must discard the result")

        let initiallyStale = TerminalFixture.container()
        initiallyStale.changesSourceAfterCheck = 0
        try expect(.selectionChanged, from: initiallyStale, "A stale source must fail before capture")
        try check(initiallyStale.reads == ["current"], "No source content reads after initial identity mismatch")

        let parentCycle = TerminalFixture.container()
        parentCycle.nodes[1]?.parent = 1
        try expect(.invalidHierarchy, from: parentCycle, "Cyclic focused parent chains must terminate")

        let childCycle = TerminalFixture.container()
        childCycle.nodes[2]?.children = [1]
        try expect(.invalidHierarchy, from: childCycle, "Cyclic child metadata must fail closed")

        let tooWide = TerminalFixture.container()
        tooWide.nodes[1]?.children = Array(10..<43)
        for node in 10..<43 { tooWide.nodes[node] = .init(role: "AXTextArea", parent: 1) }
        tooWide.nodes[10]?.selected = "Selected"
        try expect(.limitExceeded, from: tooWide, "An incomplete window scan must not return its first selected pane")

        let badChildAdapter = TerminalFixture.container()
        badChildAdapter.nodes[1]?.children = Array(10..<43)
        badChildAdapter.ignoreChildLimit = true
        try expect(.limitExceeded, from: badChildAdapter, "Defend against an adapter returning more children than requested")

        let missingMetadata = TerminalFixture.container()
        missingMetadata.nodes[1]?.children.append(50)
        try expect(.invalidHierarchy, from: missingMetadata, "A selected pane cannot be returned when another node's structural metadata is unavailable")

        let tooDeep = TerminalFixture.container()
        tooDeep.nodes[1]?.children = [3, 10]
        tooDeep.nodes[10] = .init(role: "AXGroup", parent: 1, children: [11])
        tooDeep.nodes[11] = .init(role: "AXGroup", parent: 10, children: [12])
        tooDeep.nodes[12] = .init(role: "AXGroup", parent: 11, children: [13])
        tooDeep.nodes[13] = .init(role: "AXGroup", parent: 12, children: [14])
        tooDeep.nodes[14] = .init(role: "AXGroup", parent: 13, children: [15])
        tooDeep.nodes[15] = .init(role: "AXTextArea", parent: 14)
        try expect(.limitExceeded, from: tooDeep, "A selected pane cannot be returned if another container exceeds depth budget")

        let timedOut = TerminalFixture.container()
        timedOut.delayedRoleFor = 3
        try expect(.timedOut, from: timedOut, "A slow metadata lookup must not yield a result after the deadline")

        let oversized = TerminalFixture.container()
        oversized.nodes[3]?.selected = String(repeating: "a", count: 20_001)
        oversized.nodes[3]?.range = nil
        try expect(.limitExceeded, from: oversized, "Direct selected text is capped before translation")

        let oversizedRange = TerminalFixture.container()
        oversizedRange.nodes[3]?.selected = nil
        oversizedRange.nodes[3]?.range = NSRange(location: 0, length: 20_001)
        try expect(.limitExceeded, from: oversizedRange, "Range fallback is capped before reading")
        try check(oversizedRange.exactRanges.isEmpty, "Do not request oversized text ranges")

        for invalidRange in [NSRange(location: -1, length: 5), NSRange(location: Int.max, length: 1), NSRange(location: Int.max - 1, length: 5), NSRange(location: 1, length: -1)] {
            let invalid = TerminalFixture.container()
            invalid.nodes[3]?.selected = nil
            invalid.nodes[3]?.range = invalidRange
            try expect(.invalidRange, from: invalid, "Invalid or overflowing range must fail before StringForRange")
            try check(invalid.exactRanges.isEmpty, "Invalid range cannot reach the text API")
        }

        let outsideContainer = TerminalFixture.container()
        outsideContainer.nodes[1]?.role = "AXButton"
        outsideContainer.nodes[1]?.parent = nil
        try expect(.noSelection, from: outsideContainer, "Do not traverse arbitrary roles into other content")
        try check(!outsideContainer.reads.contains("children:1"), "Only allowlisted container roles can be expanded")
        try check(!outsideContainer.reads.contains("children:0"), "No eligible focused container means no fallback to a broader window")

        let noWindow = TerminalFixture.container()
        noWindow.focusedWindow = nil
        noWindow.focusedElement = 0
        try expect(.invalidHierarchy, from: noWindow, "Window-level focus requires a matching known focused window")

        print("Terminal selection traversal: \(checks) checks passed")
    }
}
