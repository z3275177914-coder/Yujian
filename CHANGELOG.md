# 变更记录

本文件记录玉鉴公开版本的重要变化。

## [0.4.7] - 2026-09-04

### 新增

- 本地图片目录浏览、缩放、平移、缩略图和 minimap 视口联动。
- GIF/WebP 动画、Apple Live Photo、Android/Samsung Motion Photo 识别与播放入口。
- 基础非破坏式调整、裁剪、旋转、翻转、撤销/重做和导出副本。
- 图片信息、EXIF、直方图、像素取样、本机 OCR 和可选云端 AI Provider。
- ChatGPT 桌面端交接、本地工具桥接、权限确认和文件安全操作。
- Universal 2 开源 Release、MIT License、SHA-256 校验和安装安全说明。

### 变更

- 应用名称固定为“玉鉴”，公开 Bundle Identifier 为 `io.github.z3275177914-coder.yujian`。
- 保留 `imageviewer://` 作为旧集成兼容 Scheme，同时使用 `yujian://` 作为主 Scheme。
- 普通浏览、缓存、动画和动态照片路径维持本地处理；云端 AI 和 ChatGPT 交接由用户主动触发。

### 已知限制

- 开源 Release 使用 ad-hoc 签名，不包含 Developer ID、公证或 Gatekeeper 放行。
- 格式能否成功解码取决于 macOS 版本、系统编解码器、硬件和原文件参数；详见格式支持说明。
- 导出动态照片、GIF 或多帧 WebP 时生成静态图片，不保留动画视频组件。

[0.4.7]: https://github.com/z3275177914-coder/Yujian/releases/tag/v0.4.7
