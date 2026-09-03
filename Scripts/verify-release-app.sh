#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$project_root/.build/玉鉴.app}"
release_root="$project_root/.build/release"
archive_name="玉鉴-$(<"$project_root/VERSION")-macOS-universal.zip"
archive_path="$release_root/$archive_name"
checksum_path="$archive_path.sha256"
binary_path="$app_path/Contents/MacOS/ImageViewer"
plist_path="$app_path/Contents/Info.plist"
license_path="$app_path/Contents/Resources/LICENSE.txt"
distribution_mode="${IMAGEVIEWER_DISTRIBUTION_MODE:-open-source}"
expected_version="$(<"$project_root/VERSION")"
expected_commit="$(git -C "$project_root" rev-parse --short=12 HEAD)"

if [[ "$distribution_mode" != "open-source" && "$distribution_mode" != "formal" ]]; then
    printf 'Unsupported IMAGEVIEWER_DISTRIBUTION_MODE: %s (use open-source or formal).\n' "$distribution_mode" >&2
    exit 2
fi

if [[ ! -x "$binary_path" || ! -f "$plist_path" || ! -f "$license_path" ]]; then
    printf 'Release app is incomplete: %s\n' "$app_path" >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'MIT License' "$license_path" || ! /usr/bin/grep -Fq 'Permission is hereby granted' "$license_path"; then
    printf 'Release app does not contain a complete MIT License: %s\n' "$license_path" >&2
    exit 1
fi

configuration="$(/usr/bin/plutil -extract ImageViewerBuildConfiguration raw -o - "$plist_path")"
dirty="$(/usr/bin/plutil -extract ImageViewerDirty raw -o - "$plist_path")"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist_path")"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist_path")"
commit="$(/usr/bin/plutil -extract ImageViewerGitCommit raw -o - "$plist_path")"
url_schemes="$(/usr/bin/plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes xml1 -o - "$plist_path")"
if [[ "$configuration" != "release" || "$dirty" != "false" ]]; then
    printf 'Release metadata is invalid: configuration=%s dirty=%s\n' "$configuration" "$dirty" >&2
    exit 1
fi
if [[ "$version" != "$expected_version" ]]; then
    printf 'Release app version mismatch: expected %s, got %s\n' "$expected_version" "$version" >&2
    exit 1
fi
if [[ "$commit" != "$expected_commit" ]]; then
    printf 'Release app commit mismatch: expected %s, got %s\n' "$expected_commit" "$commit" >&2
    exit 1
fi
if [[ "$bundle_identifier" != "io.github.z3275177914-coder.yujian" ]]; then
    printf 'Bundle Identifier mismatch: expected io.github.z3275177914-coder.yujian, got %s\n' "$bundle_identifier" >&2
    exit 1
fi
if [[ "$url_schemes" != *"<string>yujian</string>"* || "$url_schemes" != *"<string>imageviewer</string>"* ]]; then
    printf 'URL Scheme compatibility mismatch: expected yujian and imageviewer.\n' >&2
    exit 1
fi

if [[ ! -f "$archive_path" || ! -f "$checksum_path" ]]; then
    printf 'Release archive or checksum is missing: %s\n' "$archive_path" >&2
    exit 1
fi
checksum_entry="$(/usr/bin/sed -n '1p' "$checksum_path")"
expected_checksum="$(printf '%s\n' "$checksum_entry" | /usr/bin/awk '{ print $1 }')"
checksum_file="$(printf '%s\n' "$checksum_entry" | /usr/bin/awk '{ print $2 }')"
actual_checksum="$(shasum -a 256 "$archive_path" | /usr/bin/awk '{ print $1 }')"
if [[ "$checksum_file" != "$archive_name" || -z "$expected_checksum" || "$expected_checksum" != "$actual_checksum" ]]; then
    printf 'Release checksum is invalid or not portable: %s\n' "$checksum_path" >&2
    exit 1
fi

archive_plist="$(mktemp /private/tmp/yujian-release-plist.XXXXXX)"
trap 'rm -f "$archive_plist"' EXIT
if ! /usr/bin/unzip -p "$archive_path" '*/Contents/Info.plist' > "$archive_plist" || [[ ! -s "$archive_plist" ]]; then
    printf 'Release archive does not contain an application Info.plist: %s\n' "$archive_path" >&2
    exit 1
fi
archive_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$archive_plist")"
archive_commit="$(/usr/bin/plutil -extract ImageViewerGitCommit raw -o - "$archive_plist")"
if [[ "$archive_version" != "$expected_version" || "$archive_commit" != "$expected_commit" ]]; then
    printf 'Release archive metadata mismatch: version=%s commit=%s\n' "$archive_version" "$archive_commit" >&2
    exit 1
fi
if ! LC_ALL=C /usr/bin/unzip -Z1 "$archive_path" | LC_ALL=C /usr/bin/grep -F 'Contents/Resources/LICENSE.txt' > /dev/null; then
    printf 'Release archive is missing embedded LICENSE.txt: %s\n' "$archive_path" >&2
    exit 1
fi
if ! LC_ALL=C /usr/bin/unzip -Z1 "$archive_path" | LC_ALL=C /usr/bin/grep -Fx 'LICENSE' > /dev/null; then
    printf 'Release archive is missing top-level LICENSE: %s\n' "$archive_path" >&2
    exit 1
fi

architectures="$(lipo -archs "$binary_path")"
if [[ "$architectures" != *arm64* ]]; then
    printf 'Release binary must contain arm64; got %s\n' "$architectures" >&2
    exit 1
fi

codesign --verify --deep --strict "$app_path"

if [[ "$distribution_mode" == "formal" ]]; then
    if [[ "$architectures" != *x86_64* ]]; then
        printf 'Formal release binary must contain arm64 and x86_64; got %s\n' "$architectures" >&2
        exit 1
    fi

    signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
    if [[ "$signature_details" != *"flags=0x10000(runtime)"* && "$signature_details" != *"flags=0x10000(runtime,"* ]]; then
        printf 'Hardened Runtime is missing.\n' >&2
        exit 1
    fi
    if [[ "$signature_details" == *"Signature=adhoc"* || "$signature_details" == *"TeamIdentifier=not set"* ]]; then
        printf 'A Developer ID signature is required.\n' >&2
        exit 1
    fi

    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
    printf 'Verified formal universal release app: %s\n' "$app_path"
elif [[ "$architectures" != *x86_64* ]]; then
    printf 'Verified open-source arm64 release app (Universal 2 not present): %s\n' "$app_path"
else
    printf 'Verified open-source universal release app: %s\n' "$app_path"
fi
