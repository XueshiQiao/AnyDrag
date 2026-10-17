#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library AnyDrag/Sources/DragStrategy.swift tests/DragWindowFocus.swift -o "$test_dir/drag-window-focus-test"
"$test_dir/drag-window-focus-test"
