#!/usr/bin/env bash
set -euo pipefail

# Compile the production traversal with neutral fixtures, without interacting
# with another app or rebuilding/re-signing the installed translator.
terminal_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
terminal_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/paragraph-terminal-test.XXXXXX")"
trap 'rm -rf -- "$terminal_test_dir"' EXIT

xcrun swiftc -swift-version 5 \
  "$terminal_repo_root/Sources/ParagraphTranslator/TerminalSelectionTraversal.swift" \
  "$terminal_repo_root/Tests/SelectionCaptureFixtures/TerminalTraversalTests.swift" \
  -o "$terminal_test_dir/tests"
"$terminal_test_dir/tests"
