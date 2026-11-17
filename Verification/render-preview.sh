#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build
build_path="$(swift build --show-bin-path)"
preview_dir="${1:-$project_dir/artifacts/preview}"
harness_dir="$(mktemp -d)"
trap 'rm -rf "$harness_dir"' EXIT
if [ -f "$build_path/libSpatialMath.a" ]; then
    swiftc -I "$build_path" -L "$build_path" -lSpatialMath \
        Sources/App/WorldRenderer.swift Verification/RenderPreview.swift -o "$harness_dir/render-preview"
else
    swiftc -I "$build_path/Modules" Sources/App/WorldRenderer.swift Verification/RenderPreview.swift \
        "$build_path/SpatialMath.build/"*.swift.o \
        -o "$harness_dir/render-preview"
fi
"$harness_dir/render-preview" "$preview_dir"
