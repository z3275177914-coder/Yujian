import Foundation
import Vision

public enum LocalOCRService {
    public static func recognizeText(
        in url: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            let image = try ImageEncodingService.image(
                for: url,
                selection: selection,
                maxPixelSize: 4096
            )
            return try recognizeText(in: image)
        }.value
    }

    private static func recognizeText(in image: CGImage) throws -> String {
        var recognizedText: [String] = []
        var requestError: Error?
        let request = VNRecognizeTextRequest { request, error in
            requestError = error
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            recognizedText = observations.compactMap {
                $0.topCandidates(1).first?.string
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        if let requestError {
            throw requestError
        }
        return recognizedText.joined(separator: "\n")
    }
}
