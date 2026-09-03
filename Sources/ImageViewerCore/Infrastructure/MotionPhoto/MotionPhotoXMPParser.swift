import Foundation

struct MotionPhotoEmbeddedMetadata: Equatable, Sendable {
    let offset: UInt64
    let length: UInt64
    let presentationTimestamp: Int64?
}

/// Small, allocation-bounded helpers shared by the format-specific detectors.
/// The detectors only pass the XMP probe here; the image and embedded movie
/// are never loaded as one in-memory buffer.
enum MotionPhotoXMPParser {
    static func androidMetadata(
        in xmpData: Data,
        fileSize: UInt64
    ) -> MotionPhotoEmbeddedMetadata? {
        let xmp = String(decoding: xmpData, as: UTF8.self)
        guard truthy(attributeValue("MotionPhoto", in: xmp)) else {
            return nil
        }

        let length: UInt64?
        if let offset = positiveInteger(
            attributeValue("MotionPhotoOffset", in: xmp)
                ?? attributeValue("MicroVideoOffset", in: xmp)
        ) {
            length = offset
        } else {
            length = containerVideoLength(in: xmp)
        }

        guard let length,
              let offset = tailOffset(length: length, fileSize: fileSize) else {
            return nil
        }
        return MotionPhotoEmbeddedMetadata(
            offset: offset,
            length: length,
            presentationTimestamp: presentationTimestamp(
                in: xmp,
                names: [
                    "MotionPhotoPresentationTimestampUs",
                    "MicroVideoPresentationTimestampUs",
                    "PresentationTimestampUs"
                ]
            )
        )
    }

    static func legacyGoogleMetadata(
        in xmpData: Data,
        fileSize: UInt64
    ) -> MotionPhotoEmbeddedMetadata? {
        let xmp = String(decoding: xmpData, as: UTF8.self)
        guard truthy(attributeValue("MicroVideo", in: xmp))
            || attributeValue("MicroVideoVersion", in: xmp) != nil
            || attributeValue("MicroVideoOffset", in: xmp) != nil else {
            return nil
        }
        guard let length = positiveInteger(
            attributeValue("MicroVideoOffset", in: xmp)
        ),
        let offset = tailOffset(length: length, fileSize: fileSize) else {
            return nil
        }

        return MotionPhotoEmbeddedMetadata(
            offset: offset,
            length: length,
            presentationTimestamp: presentationTimestamp(
                in: xmp,
                names: [
                    "MicroVideoPresentationTimestampUs",
                    "MotionPhotoPresentationTimestampUs"
                ]
            )
        )
    }

    static func samsungMetadata(
        in xmpData: Data,
        fileSize: UInt64
    ) -> MotionPhotoEmbeddedMetadata? {
        let xmp = String(decoding: xmpData, as: UTF8.self)
        guard hasSamsungMarker(in: xmp) else {
            return nil
        }

        let offset = nonNegativeUInt64(
            attributeValue("MotionPhotoVideoOffset", in: xmp)
                ?? attributeValue("VideoOffset", in: xmp)
        )
        let length = positiveInteger(
            attributeValue("MotionPhotoVideoLength", in: xmp)
                ?? attributeValue("VideoLength", in: xmp)
        )

        if let offset,
           let length,
           isValidRange(offset: offset, length: length, fileSize: fileSize) {
            return MotionPhotoEmbeddedMetadata(
                offset: offset,
                length: length,
                presentationTimestamp: samsungTimestamp(in: xmp)
            )
        }
        return nil
    }

    static func hasSamsungMarker(in data: Data) -> Bool {
        hasSamsungMarker(in: String(decoding: data, as: UTF8.self))
    }

    static func isValidRange(
        offset: UInt64,
        length: UInt64,
        fileSize: UInt64
    ) -> Bool {
        length > 0 && offset <= fileSize && length <= fileSize - offset
    }

    private static func hasSamsungMarker(in text: String) -> Bool {
        text.range(of: "MotionPhoto_Data", options: .caseInsensitive) != nil
            || text.range(of: "SamsungMotionPhoto", options: .caseInsensitive) != nil
    }

    private static func samsungTimestamp(in xmp: String) -> Int64? {
        presentationTimestamp(
            in: xmp,
            names: [
                "MotionPhotoPresentationTimestampUs",
                "MicroVideoPresentationTimestampUs",
                "PresentationTimestampUs"
            ]
        )
    }

    private static func tailOffset(
        length: UInt64,
        fileSize: UInt64
    ) -> UInt64? {
        guard length > 0, length < fileSize else {
            return nil
        }
        return fileSize - length
    }

    private static func containerVideoLength(in xmp: String) -> UInt64? {
        for tag in tags(in: xmp) {
            let mime = attributeValue("Item:Mime", in: tag)
                ?? attributeValue("Mime", in: tag)
            guard mime?.caseInsensitiveCompare("video/mp4") == .orderedSame else {
                continue
            }
            let semantic = attributeValue("Item:Semantic", in: tag)
                ?? attributeValue("Semantic", in: tag)
            guard semantic == nil
                || semantic?.caseInsensitiveCompare("MotionPhoto") == .orderedSame
                || semantic?.caseInsensitiveCompare("Motion Photo") == .orderedSame else {
                continue
            }
            if let length = positiveInteger(
                attributeValue("Item:Length", in: tag)
                    ?? attributeValue("Length", in: tag)
            ) {
                return length
            }
        }
        return nil
    }

    private static func tags(in text: String) -> [String] {
        var result: [String] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let start = text[searchStart...].firstIndex(of: "<"),
              let end = text[start...].firstIndex(of: ">") {
            result.append(String(text[start...end]))
            searchStart = text.index(after: end)
        }
        return result
    }

    private static func presentationTimestamp(
        in xmp: String,
        names: [String]
    ) -> Int64? {
        names.lazy
            .compactMap { nonNegativeInteger(attributeValue($0, in: xmp)) }
            .first
    }

    private static func attributeValue(
        _ name: String,
        in text: String
    ) -> String? {
        let names = [
            "GCamera:\(name)",
            "Camera:\(name)",
            "GContainer:\(name)",
            "Container:\(name)",
            "Samsung:\(name)",
            name
        ]

        for candidate in names {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                      of: candidate,
                      range: searchStart..<text.endIndex
                  ) {
                var index = range.upperBound
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                guard index < text.endIndex, text[index] == "=" else {
                    searchStart = range.upperBound
                    continue
                }
                index = text.index(after: index)
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                guard index < text.endIndex else {
                    break
                }

                let quote = text[index]
                if quote == "\"" || quote == "'" {
                    index = text.index(after: index)
                    guard let end = text[index...].firstIndex(of: quote) else {
                        break
                    }
                    return String(text[index..<end])
                }

                let end = text[index...].firstIndex {
                    $0.isWhitespace || $0 == ">" || $0 == "/"
                } ?? text.endIndex
                return String(text[index..<end])
            }
        }
        return nil
    }

    private static func positiveInteger(_ value: String?) -> UInt64? {
        guard let value,
              let number = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              number > 0 else {
            return nil
        }
        return number
    }

    private static func nonNegativeUInt64(_ value: String?) -> UInt64? {
        guard let value,
              let number = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return number
    }

    private static func nonNegativeInteger(_ value: String?) -> Int64? {
        guard let value,
              let number = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              number >= 0 else {
            return nil
        }
        return number
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
    }
}
