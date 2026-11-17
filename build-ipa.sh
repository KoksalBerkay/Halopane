#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
mode=public
if [[ "${1:-}" == "--personal" ]]; then
    mode=personal
    shift
fi
if [[ "${1:-}" == -* || $# -gt 2 ]]; then
    echo "Usage: ./build-ipa.sh [--personal] [output.ipa] [Halopane]" >&2
    exit 2
fi
target="${2:-Halopane}"
case "$target" in Halopane) ;; *) printf 'Unknown target: %s\n' "$target" >&2; exit 2;; esac
bundle_id="${HALOPANE_BUNDLE_ID:-}"
default_name=Halopane.ipa
if [[ "$mode" == personal || -n "$bundle_id" ]]; then default_name=Halopane-local.ipa; fi
identity_args=()
if [[ -n "$bundle_id" ]]; then
    if [[ ! "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
        echo "HALOPANE_BUNDLE_ID must be a dot-separated bundle identifier." >&2
        exit 2
    fi
    identity_args=("PRODUCT_BUNDLE_IDENTIFIER=$bundle_id")
fi
output="${1:-$project_dir/artifacts/$default_name}"
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "The iPhoneOS SDK is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
    exit 1
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
xcodebuild -project "$project_dir/Halopane.xcodeproj" \
    -scheme "$target" -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath "$build_dir/Build" \
    CODE_SIGNING_ALLOWED=NO ${identity_args[@]+"${identity_args[@]}"} build
mkdir -p "$build_dir/Payload"
ditto "$build_dir/Build/Build/Products/Release-iphoneos/$target.app" \
    "$build_dir/Payload/$target.app"
app="$build_dir/Payload/$target.app"
# Keep optional rules outside the Xcode build and package them only on request.
local_name=halopane-local-site-rules.json
included=no
if [[ "$mode" == personal ]]; then
    private_rules="${HALOPANE_PRIVATE_RULES:-}"
    if [[ -f "$private_rules" ]]; then
        /usr/bin/install -m 644 "$private_rules" "$app/$local_name"
        included=yes
    else
        echo "Set HALOPANE_PRIVATE_RULES to the path of your rules JSON for a personal build." >&2
        exit 2
    fi
fi
if [[ "$mode" == public && -e "$app/$local_name" ]]; then
    echo "Public packaging check failed." >&2
    exit 1
fi
printf 'Bundle identifier: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
printf 'Build mode: %s; local rules included: %s\n' "$mode" "$included"
/usr/bin/file "$app/$target"
(cd "$build_dir" && /usr/bin/zip -q -r Halopane.ipa Payload)
/usr/bin/unzip -tq "$build_dir/Halopane.ipa"
mv "$build_dir/Halopane.ipa" "$output"
echo "$output"
