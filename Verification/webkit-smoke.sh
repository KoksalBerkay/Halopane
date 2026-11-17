#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"' EXIT
output="${1:-$project_dir/artifacts/webkit-mac-smoke.png}"
mkdir -p "$(dirname "$output")"
swiftc -parse-as-library "$project_dir/Verification/WebKitSmoke.swift" "$project_dir/Sources/Diagnostics/WebFixtureLocator.swift" "$project_dir/Sources/Browser/Web/BrowserDestination.swift" "$project_dir/Sources/Browser/Web/HomeFavicon.swift" -o "$verify_dir/webkit-smoke"
"$verify_dir/webkit-smoke" "$project_dir/Resources/web-probe.html" "$output"
