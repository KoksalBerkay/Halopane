#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 easylist.txt easyprivacy.txt [output-directory]" >&2
    exit 2
fi
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
xcrun swiftc -O -module-cache-path "$temp/Modules" \
    "$project/Sources/SpatialMath/ContentRuleConversion.swift" "$project/Verification/ContentRulesCLI.swift" \
    -o "$temp/convert"
"$temp/convert" "$1" "$2" "${3:-$project/Resources}"
