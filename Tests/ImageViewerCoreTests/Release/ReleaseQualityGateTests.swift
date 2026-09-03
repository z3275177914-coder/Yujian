import Foundation
import Testing
@testable import ImageViewerCore

@Test("Release quality gate contracts cover viewer, edit, export and AI boundaries")
func releaseQualityGateContracts() {
    #expect(CanvasInputReducer.clampedSensitivity(1.0) == 1.0)
    #expect(EditHistory().current == .empty)
    #expect(ImageExportOptions(metadataPolicy: .stripPrivateLocation).metadataPolicy == .stripPrivateLocation)
    #expect(AIProviderKind.allCases.allSatisfy { $0.capabilities.maxPixelSize >= 256 })
    #expect(KeychainStore.openAIService == "io.github.z3275177914-coder.yujian.openai")
    #expect(PerformanceLog.subsystem == ImageViewerAppIdentity.bundleIdentifier)
}
