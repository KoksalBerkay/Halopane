#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build
build_path="$(swift build --show-bin-path)"
verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"' EXIT
if [ -f "$build_path/libSpatialMath.a" ]; then
    swiftc -I "$build_path" -L "$build_path" -lSpatialMath Sources/App/WorldRenderer.swift Sources/Browser/Rendering/WebSnapshotRenderer.swift Verification/WebTextureSmoke.swift -o "$verify_dir/web-texture-smoke"
else
    swiftc -I "$build_path/Modules" Sources/App/WorldRenderer.swift Sources/Browser/Rendering/WebSnapshotRenderer.swift Verification/WebTextureSmoke.swift "$build_path/SpatialMath.build/"*.swift.o -o "$verify_dir/web-texture-smoke"
fi
"$verify_dir/web-texture-smoke" "$project_dir/artifacts/webkit-mac-smoke.png" "$project_dir/artifacts/web-texture-mac-smoke.png"
