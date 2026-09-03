#!/bin/zsh

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_root/.." && pwd)"
app_path="$project_root/.build/玉鉴.app"

"$script_root/package-app.sh" release
"$script_root/verify-packaged-app.sh" release

if (( $# > 0 )); then
    open -na "$app_path" --args "$@"
else
    open -na "$app_path"
fi
