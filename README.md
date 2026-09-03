# 玉鉴

玉鉴是一款面向 macOS 的本地图片查看器，提供目录浏览、缩放/平移、GIF/WebP、动态照片、缩略图、基础非破坏式编辑和可选 AI 工作流入口。

## 应用身份

- Bundle Identifier：`io.github.z3275177914-coder.yujian`
- 主 URL Scheme：`yujian://`
- 旧版兼容 URL Scheme：`imageviewer://`

首次启动新身份版本时，应用会自动迁移旧 Bundle ID 下的 UserDefaults、AI API Key 和动态照片缓存；旧数据源不会被立即删除，便于回滚。

## 环境

- macOS 14 或更高版本
- Swift 6 工具链
- SwiftUI + AppKit

## 构建与运行

从 GitHub Release 下载的安装步骤、SHA-256 校验、macOS 安全提示处理方式和风险边界见 [`Docs/INSTALLATION.md`](Docs/INSTALLATION.md)。

```sh
swift build -c release
swift test
Scripts/package-app.sh release
Scripts/verify-packaged-app.sh release
Scripts/run-packaged-app.sh
```

生成并校验开源分发包：

```sh
Scripts/package-release.sh
Scripts/verify-release-app.sh
```

默认分发流程使用 ad-hoc 签名，仅用于本地包完整性校验；不代表 Developer ID 信任、公证或 Gatekeeper 放行。商业上架相关流程不属于本项目的开源交付范围。

## 隐私边界

普通图片浏览、元数据读取、基础编辑和导出默认在本机完成。云端 AI、ChatGPT 交接和本地工具桥接都需要用户主动操作或确认，具体技术边界见 [`Docs/PRIVACY_NOTICE.md`](Docs/PRIVACY_NOTICE.md) 与 [`Docs/LOCAL_TOOL_BRIDGE.md`](Docs/LOCAL_TOOL_BRIDGE.md)。

## 格式与媒体支持

当前格式识别、动画、Apple Live Photo、Android/Samsung Motion Photo、导出和系统解码限制见 [`Docs/IMAGE_FORMAT_SUPPORT.md`](Docs/IMAGE_FORMAT_SUPPORT.md)。玉鉴使用 macOS 原生 ImageIO 等能力；格式扩展名被识别不等于所有文件参数都能成功解码。

## 许可证

本项目采用 MIT License，完整文本见根目录 [`LICENSE`](LICENSE)。

## 开源协作

- 贡献流程和架构边界见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
- 安全漏洞请先阅读 [`SECURITY.md`](SECURITY.md)，不要在公开 Issue 中上传图片、API Key 或复现机密。
- 版本变化见 [`CHANGELOG.md`](CHANGELOG.md)。
