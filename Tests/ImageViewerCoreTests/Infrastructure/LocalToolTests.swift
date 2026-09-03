import Foundation
import Testing
@testable import ImageViewerCore

@Test("本地工具 URL 可以解析工具名和图片路径")
func localToolURLParsesRequest() {
    let url = URL(string: "yujian://tool/open_image?path=%2Ftmp%2Fdemo.png")
    let request = url.flatMap(LocalToolRequest.init(url:))

    #expect(request?.tool == .openImage)
    #expect(request?.path == "/tmp/demo.png")
}

@Test("旧本地工具 URL Scheme 保持兼容")
func legacyLocalToolURLRemainsSupported() {
    let url = URL(string: "imageviewer://tool/get_current_image")
    let request = url.flatMap(LocalToolRequest.init(url:))

    #expect(request?.tool == .getCurrentImage)
}

@Test("本地工具权限按工具范围隔离")
func localToolPermissionsAreScoped() {
    var permissions = LocalToolPermissions()
    permissions.set(true, for: .readCurrentImage)

    #expect(permissions.allows(.getCurrentImage))
    #expect(permissions.allows(.getImageMetadata))
    #expect(!permissions.allows(LocalToolName.listFolderImages))
    #expect(!permissions.allows(LocalToolName.openImage))
}

@Test("本地工具响应可以编码为稳定 JSON")
func localToolResponseRoundTrips() throws {
    let response = LocalToolResponse.success(
        for: .listFolderImages,
        message: "完成",
        images: []
    )
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(LocalToolResponse.self, from: data)

    #expect(decoded == response)
}
