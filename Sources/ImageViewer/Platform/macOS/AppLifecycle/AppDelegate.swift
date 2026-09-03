import AppKit
import Foundation
import ImageViewerCore

extension Notification.Name {
    static let imageViewerOpenURLs = Notification.Name("ImageViewerOpenURLs")
    static let imageViewerLocalToolURLs = Notification.Name("ImageViewerLocalToolURLs")
    static let imageViewerLocalToolResponse = Notification.Name("ImageViewerLocalToolResponse")
    static let imageViewerToggleSidebar = Notification.Name("ImageViewerToggleSidebar")
    static let imageViewerToggleInspector = Notification.Name("ImageViewerToggleInspector")
    static let imageViewerShowAI = Notification.Name("ImageViewerShowAI")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var pendingOpenURLs: [URL] = []
    private(set) var pendingLocalToolURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        PerformanceLog.event("AppReady")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let toolURLs = urls.filter {
            ImageViewerAppIdentity.acceptsURLScheme($0.scheme)
        }
        let imageURLs = urls.filter { $0.isFileURL }

        if !imageURLs.isEmpty {
            pendingOpenURLs.append(contentsOf: imageURLs)
            NotificationCenter.default.post(
                name: .imageViewerOpenURLs,
                object: imageURLs
            )
        }

        if !toolURLs.isEmpty {
            pendingLocalToolURLs.append(contentsOf: toolURLs)
            NotificationCenter.default.post(
                name: .imageViewerLocalToolURLs,
                object: toolURLs
            )
        }
    }

    func consumePendingOpenURL() -> URL? {
        guard let url = pendingOpenURLs.first else {
            return nil
        }
        pendingOpenURLs.removeAll()
        return url
    }

    func consumePendingLocalToolURLs() -> [URL] {
        let urls = pendingLocalToolURLs
        pendingLocalToolURLs.removeAll()
        return urls
    }
}
