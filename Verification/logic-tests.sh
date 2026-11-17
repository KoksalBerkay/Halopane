#!/bin/bash
# Plain logic checks for app code without UI. Builds a small Mac program from the
# app's source files and runs it.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
swiftc -parse-as-library \
  "$project_dir/Verification/LogicTests.swift" \
  "$project_dir/Sources/Browser/Web/BrowserDestination.swift" \
  "$project_dir/Sources/Browser/Web/HomeFavicon.swift" \
  -o "$build_dir/logic-tests"
"$build_dir/logic-tests"
