import SwiftUI

struct ViewerCommands: Commands {
    @ObservedObject var model: ImageViewerModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            SettingsLink {
                Text("设置…")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("打开图片…") {
                model.openPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("视图") {
            Button("上一张图片") {
                model.previousImage()
            }
            .keyboardShortcut(.leftArrow)

            Button("下一张图片") {
                model.nextImage()
            }
            .keyboardShortcut(.rightArrow)

            Divider()

            Button("适应窗口") {
                model.fitImage()
            }
            .keyboardShortcut("0", modifiers: [])

            Button("实际大小") {
                model.actualSize()
            }
            .keyboardShortcut("1", modifiers: [])

            Button("无限画布") {
                model.infiniteCanvas()
            }
            .keyboardShortcut("2", modifiers: [])

            Button("放大") {
                model.zoomIn()
            }
            .keyboardShortcut("+", modifiers: [])

            Button("缩小") {
                model.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [])

            Button("适应窗口 / 实际大小") {
                if model.canvasMode == .fit {
                    model.actualSize()
                } else {
                    model.fitImage()
                }
            }
            .keyboardShortcut(.space, modifiers: [])

            Divider()

            Button("撤销编辑") {
                model.undoEdits()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndoEdits)

            Button("重做编辑") {
                model.redoEdits()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedoEdits)

            Button("查看原图") {
                model.toggleOriginalPreview()
            }
            .keyboardShortcut("\\", modifiers: [])
            .disabled(!model.hasPreviewEdits)

            Divider()

            Button("显示或隐藏侧栏") {
                NotificationCenter.default.post(
                    name: .imageViewerToggleSidebar,
                    object: nil
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button("显示或隐藏检查器") {
                NotificationCenter.default.post(
                    name: .imageViewerToggleInspector,
                    object: nil
                )
            }
            .keyboardShortcut("i", modifiers: [])

            Button("全屏") {
                model.toggleFullScreen()
            }
            .keyboardShortcut("f", modifiers: [])
        }

        CommandMenu("图片") {
            Button("向右旋转") {
                model.rotateRight()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("在访达中显示") {
                model.revealInFinder()
            }
            .disabled(model.currentAsset == nil)

            Button("另存为…") {
                model.saveAs()
            }
            .disabled(model.currentAsset == nil)

            Button("移到废纸篓") {
                model.moveCurrentToTrash()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.currentAsset == nil)

            Divider()

            Button("询问 AI") {
                NotificationCenter.default.post(
                    name: .imageViewerShowAI,
                    object: nil
                )
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model.currentAsset == nil)
        }
    }
}
