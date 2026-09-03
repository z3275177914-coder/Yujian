#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="debug"
if [[ $# -gt 0 ]]; then
    configuration="$1"
fi
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    printf 'Unsupported configuration: %s\n' "$configuration" >&2
    exit 2
fi

version_file="$project_root/VERSION"
if [[ ! -f "$version_file" ]]; then
    printf 'Missing version file: %s\n' "$version_file" >&2
    exit 2
fi
version="$(<"$version_file")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION must use major.minor.patch: %s\n' "$version" >&2
    exit 2
fi

git_commit="$(git -C "$project_root" rev-parse --short=12 HEAD 2>/dev/null || true)"
git_build="$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || true)"
git_branch="$(git -C "$project_root" symbolic-ref --short -q HEAD 2>/dev/null || printf 'detached')"
if [[ -z "$git_commit" ]]; then
    git_commit="unknown"
fi
if [[ -z "$git_build" ]]; then
    git_build="0"
fi
if [[ -n "$(git -C "$project_root" status --porcelain 2>/dev/null)" ]]; then
    dirty=true
else
    dirty=false
fi
build_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
module_cache_dir="/private/tmp/image-viewer-module-cache"
app_path="$project_root/.build/玉鉴.app"
icon_path="$project_root/Resources/AppIcon.icns"
license_path="$project_root/LICENSE"

if [[ ! -f "$icon_path" ]]; then
    printf 'Missing application icon: %s\n' "$icon_path" >&2
    exit 2
fi
if [[ ! -f "$license_path" ]]; then
    printf 'Missing project license: %s\n' "$license_path" >&2
    exit 2
fi
if ! /usr/bin/grep -Fq 'MIT License' "$license_path" || ! /usr/bin/grep -Fq 'Permission is hereby granted' "$license_path"; then
    printf 'Project license is not a complete MIT License: %s\n' "$license_path" >&2
    exit 2
fi

mkdir -p "$module_cache_dir"

cd "$project_root"
env \
    CLANG_MODULE_CACHE_PATH="$module_cache_dir" \
    SWIFT_MODULECACHE_PATH="$module_cache_dir" \
    swift build -c "$configuration"

bin_path="$(
    env \
        CLANG_MODULE_CACHE_PATH="$module_cache_dir" \
        SWIFT_MODULECACHE_PATH="$module_cache_dir" \
        swift build -c "$configuration" --show-bin-path
)"

if [[ -d "$app_path" ]]; then
    rm -rf "$app_path"
fi

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ ! -x "$bin_path/ImageViewer" ]]; then
    printf 'Build output is missing or not executable: %s\n' "$bin_path/ImageViewer" >&2
    exit 1
fi
cp "$bin_path/ImageViewer" "$app_path/Contents/MacOS/ImageViewer"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$icon_path" "$app_path/Contents/Resources/AppIcon.icns"
cp "$license_path" "$app_path/Contents/Resources/LICENSE.txt"

plist_path="$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$plist_path"
/usr/bin/plutil -replace CFBundleVersion -string "$git_build" "$plist_path"
/usr/bin/plutil -replace ImageViewerGitCommit -string "$git_commit" "$plist_path"
/usr/bin/plutil -replace ImageViewerGitBranch -string "$git_branch" "$plist_path"
/usr/bin/plutil -replace ImageViewerBuildDate -string "$build_date" "$plist_path"
/usr/bin/plutil -replace ImageViewerBuildConfiguration -string "$configuration" "$plist_path"
/usr/bin/plutil -replace ImageViewerDirty -bool "$dirty" "$plist_path"

packaged_commit="$(/usr/bin/plutil -extract ImageViewerGitCommit raw -o - "$plist_path")"
if [[ "$packaged_commit" != "$git_commit" ]]; then
    printf 'Packaged commit mismatch: expected %s, got %s\n' "$git_commit" "$packaged_commit" >&2
    exit 1
fi

codesign --force --deep --sign - "$app_path" >/dev/null
codesign --verify --deep --strict "$app_path"

printf 'Created %s\n' "$app_path"
printf 'Version %s (%s), commit %s, configuration %s\n' "$version" "$git_build" "$git_commit" "$configuration"
