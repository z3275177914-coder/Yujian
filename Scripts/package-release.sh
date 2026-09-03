#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/.build/玉鉴.app"
release_root="$project_root/.build/release"
license_path="$project_root/LICENSE"
archive_name="玉鉴-$(<"$project_root/VERSION")-macOS-universal.zip"
archive_path="$release_root/$archive_name"
distribution_mode="${IMAGEVIEWER_DISTRIBUTION_MODE:-open-source}"
signing_identity="${IMAGEVIEWER_SIGNING_IDENTITY:-}"
notary_profile="${IMAGEVIEWER_NOTARY_PROFILE:-}"
archive_staging="$release_root/.archive-staging"

if [[ ! -f "$license_path" ]]; then
    printf 'Missing project license: %s\n' "$license_path" >&2
    exit 2
fi
if ! /usr/bin/grep -Fq 'MIT License' "$license_path" || ! /usr/bin/grep -Fq 'Permission is hereby granted' "$license_path"; then
    printf 'Project license is not a complete MIT License: %s\n' "$license_path" >&2
    exit 2
fi

if [[ "$distribution_mode" != "open-source" && "$distribution_mode" != "formal" ]]; then
    printf 'Unsupported IMAGEVIEWER_DISTRIBUTION_MODE: %s (use open-source or formal).\n' "$distribution_mode" >&2
    exit 2
fi

if [[ "$distribution_mode" == "formal" && ( -z "$signing_identity" || "$signing_identity" == "-" ) ]]; then
    printf 'Formal distribution requires IMAGEVIEWER_SIGNING_IDENTITY.\n' >&2
    exit 2
fi

if [[ -n "$(git -C "$project_root" status --porcelain 2>/dev/null)" ]]; then
    printf 'Release packaging requires a clean Git worktree.\n' >&2
    exit 2
fi

mkdir -p "$release_root"

printf 'Building release metadata bundle…\n'
"$project_root/Scripts/package-app.sh" release

arm_scratch="$release_root/spm-arm64"
x86_scratch="$release_root/spm-x86_64"

printf 'Building arm64 binary…\n'
swift build \
    -c release \
    --triple arm64-apple-macosx14.0 \
    --scratch-path "$arm_scratch"
arm_bin_path="$(swift build \
    -c release \
    --triple arm64-apple-macosx14.0 \
    --scratch-path "$arm_scratch" \
    --show-bin-path)"

printf 'Building x86_64 binary…\n'
swift build \
    -c release \
    --triple x86_64-apple-macosx14.0 \
    --scratch-path "$x86_scratch"
x86_bin_path="$(swift build \
    -c release \
    --triple x86_64-apple-macosx14.0 \
    --scratch-path "$x86_scratch" \
    --show-bin-path)"

universal_binary="$release_root/ImageViewer-universal"
lipo -create \
    "$arm_bin_path/ImageViewer" \
    "$x86_bin_path/ImageViewer" \
    -output "$universal_binary"
cp "$universal_binary" "$app_path/Contents/MacOS/ImageViewer"

if [[ "$distribution_mode" == "formal" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app_path"
else
    # An ad-hoc signature makes the locally built app verifiable without
    # requiring an Apple Developer account. It is not a trust/notarization
    # claim and is intentionally the default for the open-source project.
    codesign --force --deep --sign - "$app_path"
fi
codesign --verify --deep --strict "$app_path"

create_archive() {
    rm -rf "$archive_staging"
    mkdir -p "$archive_staging"
    ditto "$app_path" "$archive_staging/玉鉴.app"
    cp "$license_path" "$archive_staging/LICENSE"
    (
        cd "$archive_staging"
        /usr/bin/zip -q -r "$archive_path" "玉鉴.app" "LICENSE"
    )
    rm -rf "$archive_staging"
}

mkdir -p "$release_root"
rm -f "$archive_path" "$archive_path.sha256"
create_archive

if ! /usr/bin/unzip -Z1 "$archive_path" | /usr/bin/grep -Fxq 'LICENSE'; then
    printf 'Release archive is missing top-level LICENSE: %s\n' "$archive_path" >&2
    exit 1
fi
if ! /usr/bin/unzip -p "$archive_path" LICENSE | /usr/bin/grep -Fq 'MIT License'; then
    printf 'Release archive contains an invalid LICENSE: %s\n' "$archive_path" >&2
    exit 1
fi
if ! /usr/bin/unzip -p "$archive_path" '*/Contents/Resources/LICENSE.txt' | cmp -s - "$license_path"; then
    printf 'Release archive contains an invalid embedded LICENSE.txt: %s\n' "$archive_path" >&2
    exit 1
fi

if [[ "$distribution_mode" == "formal" && -n "$notary_profile" ]]; then
    printf 'Submitting archive for notarization…\n'
    xcrun notarytool submit "$archive_path" \
        --keychain-profile "$notary_profile" \
        --wait
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"

    rm -f "$archive_path"
    create_archive
    spctl --assess --type execute --verbose=2 "$app_path"
elif [[ "$distribution_mode" == "formal" ]]; then
    printf 'Notarization skipped: set IMAGEVIEWER_NOTARY_PROFILE to submit and staple the formal release.\n'
else
    printf 'Open-source distribution: Developer ID signing, notarization, stapling and Gatekeeper checks are not required.\n'
fi

(
    cd "$release_root"
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

printf 'Created %s\n' "$archive_path"
printf 'SHA-256: %s\n' "$(cut -d ' ' -f 1 "$archive_path.sha256")"
printf 'Distribution mode: %s\n' "$distribution_mode"
