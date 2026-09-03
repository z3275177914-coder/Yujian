# 玉鉴开源版安装与安全提示

适用版本：`0.4.7` 及之后遵循同一开源交付方式的版本。

本文面向从 GitHub Release 下载玉鉴，或从源码自行构建玉鉴的开发者和用户。开源版默认使用 ad-hoc 签名，不包含 Developer ID 信任和 Apple 公证，因此首次运行时可能看到 macOS 的“无法验证开发者”或类似安全提示。这是当前分发方式的正常结果，不代表应用已经被 Apple 认证。

## 安装前先确认来源和完整性

优先从项目的 [GitHub 仓库](https://github.com/z3275177914-coder/Yujian)及其 Release 获取以下两个文件：

- `玉鉴-<VERSION>-macOS-universal.zip`
- 对应的 `.sha256` 校验文件

校验文件必须来自同一个 Release。下载后，在两个文件所在目录执行以下检查，并将结果中的两个 SHA-256 值进行比较：

```sh
archive='玉鉴-0.4.7-macOS-universal.zip'
expected="$(awk 'NR == 1 { print $1 }' "$archive.sha256")"
actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"

if [[ -n "$expected" && "$expected" == "$actual" ]]; then
    echo 'SHA-256 校验通过'
else
    echo 'SHA-256 校验失败：不要打开此文件' >&2
    exit 1
fi
```

校验失败、Release 来源不明，或压缩包内容不是预期的 `玉鉴.app` 和 `LICENSE` 时，应删除该文件并重新获取；不要通过移除隔离属性来掩盖校验失败。

## 方式一：Finder 安装（推荐）

1. 双击已通过校验的 ZIP，将 `玉鉴.app` 拖到“应用程序”文件夹。
2. 第一次打开时，在 Finder 中按住 Control 点击 `玉鉴.app`，选择“打开”，再在确认窗口选择“打开”。这是 macOS 针对单个应用的一次性例外。
3. 如果仍被拦截，先尝试打开一次，然后进入“系统设置 → 隐私与安全性”，在安全性区域选择“仍要打开”并确认。

菜单名称会随 macOS 版本和系统语言略有不同。只对已核验、来源可信的 `玉鉴.app` 进行确认。

## 方式二：开发者从源码构建

源码构建不需要使用 Release 二进制。完成 Git 来源检查后，在项目根目录执行：

```sh
swift build -c release
Scripts/package-app.sh release
Scripts/verify-packaged-app.sh release
open '.build/玉鉴.app'
```

如果要生成可公开分发的 Universal ZIP，请执行以下命令完成打包和校验，而不是直接分发未验证的 `.build` 目录：

```sh
Scripts/package-release.sh
Scripts/verify-release-app.sh
```

## 方式三：仅对已核验应用移除隔离提示（开发者自助方案）

只有在以下条件全部满足时才使用本方案：

- 应用来自可信的项目仓库或自己检查过的源码构建；
- Release ZIP 已完成 SHA-256 校验，或源码构建过程和提交来源已确认；
- `app_path` 是你准备运行的那一个具体 `玉鉴.app` 的绝对路径。

将下面的路径替换为实际路径。该操作只处理这个应用包，不需要 `sudo`：

```sh
app_path='/Applications/玉鉴.app'

if /usr/bin/xattr -lr "$app_path" 2>/dev/null | /usr/bin/grep -q 'com.apple.quarantine'; then
    /usr/bin/xattr -dr com.apple.quarantine "$app_path"
fi

open "$app_path"
```

`com.apple.quarantine` 是 macOS 下载隔离标记。移除它可以让这个已核验的应用不再重复触发相应的首次启动提示，但不会给应用增加 Apple 信任、公证或安全认证，也不会修复被篡改的程序。

## 风险和处理边界

| 情况 | 风险 | 正确处理 |
| --- | --- | --- |
| 开源包为 ad-hoc 签名 | macOS 无法据此确认开发者身份，首次启动可能报警 | 先核验来源和 SHA-256，再按本页的单应用方式确认 |
| 移除 `com.apple.quarantine` | 该应用少了一层首次启动隔离提醒；若应用本身不可信，恶意代码可能直接运行 | 只对已核验的具体路径使用；不对整个用户目录或所有应用批量处理 |
| 提示“应用已损坏”或“将损害你的电脑” | 可能是下载损坏、内容被修改，或系统检测到更严重的风险 | 停止运行，重新下载并重新校验；校验不一致时不得绕过 |
| 应用访问图片和系统服务 | 浏览时会读取用户选择的文件，并使用缓存、钥匙串或系统剪贴板等能力 | 阅读 [`PRIVACY_NOTICE.md`](PRIVACY_NOTICE.md)，只授予必要权限 |
| 使用云端 AI 或 ChatGPT 交接 | 用户主动选择的图片、选区或提示词可能离开本机 | 首次使用前阅读隐私提示和 Provider 政策，不处理不适合上传的内容 |

不要为了运行玉鉴而全局关闭 Gatekeeper、全局关闭下载隔离、给应用授予不必要的管理员权限，或跳过 SHA-256 校验。这些做法会扩大风险范围，也不是玉鉴开源版的安装要求。

如果无法确认 Release 来源、校验值或应用行为，应优先从源码自行构建，或者暂不安装。
