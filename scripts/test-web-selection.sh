#!/usr/bin/env bash
set -euo pipefail

# Compile the real capture boundary and its fixture without launching the app,
# inspecting another application's selection, or rebuilding/re-signing dist.
capture_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
capture_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/paragraph-selection-test.XXXXXX")"
trap 'rm -rf -- "$capture_test_dir"' EXIT

xcrun swiftc -swift-version 5 \
  "$capture_repo_root/Sources/ParagraphTranslator/SelectionReader.swift" \
  "$capture_repo_root/Sources/ParagraphTranslator/TerminalSelectionTraversal.swift" \
  "$capture_repo_root/Sources/ParagraphTranslator/TerminalSelectionReader.swift" \
  "$capture_repo_root/Sources/ParagraphTranslator/WebSelectionReader.swift" \
  "$capture_repo_root/Tests/SelectionCaptureFixtures/TraversalTests.swift" \
  -o "$capture_test_dir/tests"
"$capture_test_dir/tests"
