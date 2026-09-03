#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
app_path="$project_root/.build/玉鉴.app"
plist_path="$app_path/Contents/Info.plist"
binary_path="$app_path/Contents/MacOS/ImageViewer"
icon_path="$app_path/Contents/Resources/AppIcon.icns"
license_path="$app_path/Contents/Resources/LICENSE.txt"

if [[ ! -x "$binary_path" || ! -f "$plist_path" || ! -f "$icon_path" || ! -f "$license_path" ]]; then
    printf 'Packaged app is incomplete: %s\n' "$app_path" >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'MIT License' "$license_path" || ! /usr/bin/grep -Fq 'Permission is hereby granted' "$license_path"; then
    printf 'Packaged app does not contain a complete MIT License: %s\n' "$license_path" >&2
    exit 1
fi

expected_version="$(<"$project_root/VERSION")"
expected_commit="$(git -C "$project_root" rev-parse --short=12 HEAD)"
expected_dirty=false
if [[ -n "$(git -C "$project_root" status --porcelain 2>/dev/null)" ]]; then
    expected_dirty=true
fi

actual_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist_path")"
actual_bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist_path")"
url_schemes="$(/usr/bin/plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes xml1 -o - "$plist_path")"
actual_display_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$plist_path")"
actual_icon_file="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$plist_path")"
actual_commit="$(/usr/bin/plutil -extract ImageViewerGitCommit raw -o - "$plist_path")"
actual_configuration="$(/usr/bin/plutil -extract ImageViewerBuildConfiguration raw -o - "$plist_path")"
actual_dirty="$(/usr/bin/plutil -extract ImageViewerDirty raw -o - "$plist_path")"

if [[ "$actual_bundle_identifier" != "io.github.z3275177914-coder.yujian" ]]; then
    printf 'Bundle Identifier mismatch: expected io.github.z3275177914-coder.yujian, got %s\n' "$actual_bundle_identifier" >&2
    exit 1
fi
if [[ "$url_schemes" != *"<string>yujian</string>"* || "$url_schemes" != *"<string>imageviewer</string>"* ]]; then
    printf 'URL Scheme compatibility mismatch: expected yujian and imageviewer.\n' >&2
    exit 1
fi
if [[ "$actual_display_name" != "玉鉴" ]]; then
    printf 'Display name mismatch: expected 玉鉴, got %s\n' "$actual_display_name" >&2
    exit 1
fi
if [[ "$actual_icon_file" != "AppIcon.icns" ]]; then
    printf 'Icon declaration mismatch: expected AppIcon.icns, got %s\n' "$actual_icon_file" >&2
    exit 1
fi
if [[ "$actual_version" != "$expected_version" ]]; then
    printf 'Version mismatch: expected %s, got %s\n' "$expected_version" "$actual_version" >&2
    exit 1
fi
if [[ "$actual_commit" != "$expected_commit" ]]; then
    printf 'Commit mismatch: expected %s, got %s\n' "$expected_commit" "$actual_commit" >&2
    exit 1
fi
if [[ "$actual_configuration" != "$configuration" ]]; then
    printf 'Configuration mismatch: expected %s, got %s\n' "$configuration" "$actual_configuration" >&2
    exit 1
fi
if [[ "$actual_dirty" != "$expected_dirty" ]]; then
    printf 'Dirty-state mismatch: expected %s, got %s\n' "$expected_dirty" "$actual_dirty" >&2
    exit 1
fi

codesign --verify --deep --strict "$app_path"
printf 'Verified %s: version %s, commit %s, configuration %s\n' "$app_path" "$actual_version" "$actual_commit" "$actual_configuration"
