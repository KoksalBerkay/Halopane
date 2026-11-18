#!/bin/bash
# 2D-to-3D on the Mac: model, depth filter, mesh and Metal warp.
# Usage: ./Verification/depth-3d-smoke.sh [image]   (no image: a drawn test scene)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
build_path="$(swift build --show-bin-path)"
harness_dir="$(mktemp -d)"
trap 'rm -rf "$harness_dir"' EXIT
if [ -f "$build_path/libSpatialMath.a" ]; then
  module=(-I "$build_path" -L "$build_path" -lSpatialMath)
else
  module=(-I "$build_path/Modules" "$build_path/SpatialMath.build/"*.swift.o)
fi
swiftc "${module[@]}" \
  Sources/Depth/{DepthEstimator,StereoConversion,StereoWarpRenderer}.swift \
  Sources/Media/ImageTexture.swift \
  Verification/Depth3DSmoke.swift -o "$harness_dir/depth-3d-smoke"
mkdir -p artifacts
"$harness_dir/depth-3d-smoke" Resources/DepthAnythingV2SmallF16P6.mlpackage artifacts/depth-3d-mac-smoke.png "$@"
