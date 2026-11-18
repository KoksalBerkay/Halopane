#!/bin/bash
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
  Sources/Media/{MediaFormat,SpatialPhotoFrames,StereoVideoOutput,MediaLuma,LiveStereoImages}.swift \
  Sources/Media/NativeMediaSession.swift Sources/Media/MediaLoading.swift Sources/Media/NativeMediaRenderer.swift \
  Sources/Media/NativeMediaDiagnostics.swift Sources/Media/StereoTrackReader.swift Sources/Media/LocalPanelFile.swift \
  Sources/App/WorldRenderer.swift \
  Sources/Depth/{DepthEstimator,StereoConversion,StereoWarpRenderer,NativeMediaConversion}.swift \
  Sources/Media/ImageTexture.swift \
  Verification/NativeMediaSmoke.swift -o "$harness_dir/native-media-smoke"
"$harness_dir/native-media-smoke" "$@"
