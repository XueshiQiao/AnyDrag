#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library AnyDrag/Sources/KeyboardShortcuts.swift tests/KeyboardShortcutsTest.swift -o "$test_dir/keyboard-shortcuts-test"
"$test_dir/keyboard-shortcuts-test"
