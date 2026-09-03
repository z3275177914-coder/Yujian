import Foundation

struct AppBuildInfo: Equatable {
    let version: String
    let build: String
    let commit: String
    let branch: String
    let buildDate: String
    let configuration: String
    let isDirty: Bool

    static var current: AppBuildInfo {
        AppBuildInfo(bundle: .main)
    }

    init(bundle: Bundle) {
        version = bundle.stringValue(forInfoKey: "CFBundleShortVersionString") ?? "0.4.7"
        build = bundle.stringValue(forInfoKey: "CFBundleVersion") ?? "dev"
        commit = bundle.stringValue(forInfoKey: "ImageViewerGitCommit") ?? "development"
        branch = bundle.stringValue(forInfoKey: "ImageViewerGitBranch") ?? "local"
        buildDate = bundle.stringValue(forInfoKey: "ImageViewerBuildDate") ?? "未打包"
        configuration = bundle.stringValue(forInfoKey: "ImageViewerBuildConfiguration") ?? "debug"
        isDirty = bundle.boolValue(forInfoKey: "ImageViewerDirty")
    }

    var versionLabel: String {
        "\(version) (\(build))"
    }

    var commitLabel: String {
        if isDirty {
            return "(commit) · 未提交修改"
        }
        return commit
    }
}

private extension Bundle {
    func stringValue(forInfoKey key: String) -> String? {
        object(forInfoDictionaryKey: key) as? String
    }

    func boolValue(forInfoKey key: String) -> Bool {
        object(forInfoDictionaryKey: key) as? Bool ?? false
    }
}
