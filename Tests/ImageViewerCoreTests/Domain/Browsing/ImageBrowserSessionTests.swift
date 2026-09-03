import Foundation
import Testing
@testable import ImageViewerCore

@Test("Browser session returns the asset at the current index")
func browserSessionReturnsCurrentAsset() {
    let firstURL = URL(fileURLWithPath: "/tmp/first.png")
    let secondURL = URL(fileURLWithPath: "/tmp/second.png")
    let first = ImageAsset(url: firstURL)
    let second = ImageAsset(url: secondURL)
    var session = ImageBrowserSession(
        directoryURL: URL(fileURLWithPath: "/tmp"),
        assets: [first, second],
        currentIndex: 1
    )

    #expect(session.currentAsset?.id == second.id)

    session.currentIndex = 0
    #expect(session.currentAsset?.id == first.id)
}
