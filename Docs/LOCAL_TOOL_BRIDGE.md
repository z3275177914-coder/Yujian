# 本地工具桥接

玉鉴提供一个受权限控制的本地工具入口，可供外部桌面自动化或适配器调用。所有权限默认关闭，用户可以在“设置 → 本地工具 / MCP”中分别开启。本说明只描述应用侧支持的协议；第三方进程适配器不随应用提供。

## 工具

```text
yujian://tool/get_current_image
yujian://tool/get_image_metadata
yujian://tool/list_folder_images
yujian://tool/open_image?path=%2Fabsolute%2Fpath%2Fto%2Fimage.png
```

公开版本的主 URL Scheme 是 `yujian://`。为兼容已有外部调用，当前版本仍同时接受旧的 `imageviewer://tool/...` Scheme；新集成应使用 `yujian://`。

其中 `open_image` 的 `path` 必须是绝对路径；图片查看器会再次检查文件是否存在以及格式是否受支持。即使用户已经开启“请求打开图片”权限，每次 `open_image` 仍会在应用内显示确认框，确认后才执行。`list_folder_images` 只返回当前已经打开文件夹中的图片，不接受任意目录遍历参数。

## 权限

| 权限 | 允许的工具 |
| --- | --- |
| 读取当前图片和元数据 | `get_current_image`、`get_image_metadata` |
| 列出当前文件夹图片 | `list_folder_images` |
| 请求打开图片 | `open_image` |

应用侧会把请求转换为 `LocalToolResponse`，并通过本地通知返回结构化结果。请求、权限和响应类型由 `ImageViewerCore` 统一定义。

## 安全边界

- 所有权限默认关闭。
- 读取权限和打开权限分开控制。
- 外部打开请求采用逐次确认，拒绝请求也会返回结构化失败响应。
- 当前桥接只接受本地文件路径，不提供任意目录遍历或写入工具。
