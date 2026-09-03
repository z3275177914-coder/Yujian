import AppKit
import Foundation

public enum FileOperations {
    @MainActor
    public static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "打开图片"
        panel.message = "选择要查看的图片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "另存为"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "选择目标文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    public static func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    public static func saveCopy(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}
