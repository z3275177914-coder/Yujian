# 参与玉鉴开发

感谢参与玉鉴。玉鉴是面向 macOS 的开源图片查看器。提交改动前，请先确认它与现有用户界面、文件格式边界和隐私承诺保持一致。

## 开发环境

- macOS 14 或更高版本
- Swift 6 工具链
- SwiftUI + AppKit

本项目当前不依赖第三方 Swift Package。图像处理优先使用 macOS 原生 ImageIO、Core Image、Core Graphics、AVFoundation、Vision 和 AppKit 能力。

## 开始前

```sh
swift build -c debug
swift test
```

如果修改了代码、路径或打包逻辑，提交前运行：

```sh
swift build -c release
swift test
git diff --check
```

如果修改了打包或应用身份，还应执行 `Scripts/package-release.sh` 和 `Scripts/verify-release-app.sh`。

## 架构边界

- `ImageViewerCore` 不引入 SwiftUI；领域模型、缓存、解码、编辑、导出和协调逻辑放在 Core。
- AppKit 画布和高频输入路径放在 `Sources/ImageViewer/Platform/macOS/Canvas`。
- UI 功能按 `Features` 和 `UI` 归类，不把业务逻辑重新塞回 View。
- 图片浏览流畅度优先；异步工作必须有取消、session/revision 或 latest-wins 保护。
- 普通图片路径不能因为 GIF 或动态照片而创建不必要的播放器或解码任务。

新增文件先按职责放入既有目录，不改变 target 名称、可执行文件名、Bundle Identifier、URL Scheme、缓存键或用户数据键；涉及兼容性变化时，请在 Pull Request 中说明迁移影响。

## 隐私与测试素材

不得提交 API Key、钥匙串导出、证书密码、私钥、用户图片、动态照片、个人绝对路径或含 EXIF/GPS 的真实样本。测试素材应使用合成数据，或在提交前清除敏感元数据；Issue 和 Pull Request 中也不要直接附带敏感图片。

涉及 AI、ChatGPT 交接、本地工具桥接、剪贴板、文件移动或删除时，应同步检查 `Docs/PRIVACY_NOTICE.md` 和 `Docs/LOCAL_TOOL_BRIDGE.md`，并覆盖用户确认、拒绝和失败路径。

## 提交与 Pull Request

提交信息使用清晰的前缀，例如 `feat:`、`fix:`、`perf:`、`refactor:`、`test:`、`docs:` 或 `chore:`。一个提交尽量只解决一个可说明的主题。

Pull Request 至少说明：

- 变更目标和影响范围；
- 是否触碰画布、GIF、动态照片、缓存或 AI 数据边界；
- 已运行的构建、测试和质量门；
- 是否需要目标 Mac 完成人工 UI、输入设备、VoiceOver 或 Instruments 验收；
- 若有行为变化，相关用户文档和变更记录是否同步。

不要直接复制 GPL 项目的源代码、注释或资源。参考成熟项目时只记录行为、架构思路和公开出处；新增依赖必须先确认许可证、版本和用途。
