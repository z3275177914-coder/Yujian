import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageMetadataReader {
    public static func read(asset: ImageAsset) -> ImageMetadata {
        let imageProperties = properties(for: asset.url)
        let information = makeInformation(for: asset, properties: imageProperties)
        let exif = makeEXIF(properties: imageProperties)
        let advanced = makeAdvanced(properties: imageProperties, url: asset.url)
        return ImageMetadata(information: information, exif: exif, advanced: advanced)
    }

    private static func properties(for url: URL) -> NSDictionary? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
    }

    private static func makeInformation(
        for asset: ImageAsset,
        properties: NSDictionary?
    ) -> [MetadataField] {
        var fields: [MetadataField] = [
            MetadataField(label: "文件名", value: asset.filename),
            MetadataField(label: "文件夹", value: asset.url.deletingLastPathComponent().path),
            MetadataField(label: "尺寸", value: asset.dimensionsLabel),
            MetadataField(label: "文件大小", value: ByteCountFormatter.string(
                fromByteCount: asset.fileSize,
                countStyle: .file
            )),
            MetadataField(label: "格式", value: asset.fileExtension.uppercased())
        ]

        if let colorModel = stringValue(properties?.object(forKey: kCGImagePropertyColorModel)) {
            fields.append(MetadataField(label: "色彩模型", value: colorModel))
        }

        if let profileName = stringValue(properties?.object(forKey: kCGImagePropertyProfileName)) {
            fields.append(MetadataField(label: "色彩配置文件", value: profileName))
        }

        let dpiWidth = numberValue(properties?.object(forKey: kCGImagePropertyDPIWidth))
        let dpiHeight = numberValue(properties?.object(forKey: kCGImagePropertyDPIHeight))
        if let dpiWidth, let dpiHeight {
            fields.append(MetadataField(
                label: "分辨率 DPI",
                value: "\(formattedNumber(dpiWidth)) × \(formattedNumber(dpiHeight))"
            ))
        }

        if let createdAt = asset.createdAt {
            fields.append(MetadataField(label: "创建时间", value: dateString(createdAt)))
        }
        if let modifiedAt = asset.modifiedAt {
            fields.append(MetadataField(label: "修改时间", value: dateString(modifiedAt)))
        }

        return fields
    }

    private static func makeEXIF(properties: NSDictionary?) -> [MetadataField] {
        guard let properties else {
            return []
        }

        let exif = nestedDictionary(properties, key: kCGImagePropertyExifDictionary)
        let tiff = nestedDictionary(properties, key: kCGImagePropertyTIFFDictionary)
        let gps = nestedDictionary(properties, key: kCGImagePropertyGPSDictionary)
        var fields: [MetadataField] = []

        append(stringValue(tiff?.object(forKey: kCGImagePropertyTIFFMake)), label: "相机品牌", to: &fields)
        append(stringValue(tiff?.object(forKey: kCGImagePropertyTIFFModel)), label: "相机型号", to: &fields)
        append(stringValue(exif?.object(forKey: kCGImagePropertyExifLensModel)), label: "镜头", to: &fields)
        append(stringValue(exif?.object(forKey: kCGImagePropertyExifDateTimeOriginal)), label: "拍摄时间", to: &fields)

        if let iso = firstNumber(exif?.object(forKey: kCGImagePropertyExifISOSpeedRatings)) {
            append(String(Int(iso)), label: "ISO 感光度", to: &fields)
        }
        if let exposure = numberValue(exif?.object(forKey: kCGImagePropertyExifExposureTime)) {
            append("\(formattedNumber(exposure)) 秒", label: "快门", to: &fields)
        }
        if let aperture = numberValue(exif?.object(forKey: kCGImagePropertyExifFNumber)) {
            append("ƒ/\(formattedNumber(aperture))", label: "光圈", to: &fields)
        }
        if let focalLength = numberValue(exif?.object(forKey: kCGImagePropertyExifFocalLength)) {
            append("\(formattedNumber(focalLength)) mm", label: "焦距", to: &fields)
        }

        if let latitude = stringValue(gps?.object(forKey: kCGImagePropertyGPSLatitude)),
           let longitude = stringValue(gps?.object(forKey: kCGImagePropertyGPSLongitude)) {
            append("\(latitude), \(longitude)", label: "GPS 位置", to: &fields)
        }

        return fields
    }

    private static func makeAdvanced(
        properties: NSDictionary?,
        url: URL
    ) -> [MetadataField] {
        var fields: [MetadataField] = []

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let typeIdentifier = CGImageSourceGetType(source) as String? {
            let typeName = UTType(typeIdentifier)?.localizedDescription ?? typeIdentifier
            fields.append(MetadataField(label: "统一类型标识符", value: typeIdentifier))
            fields.append(MetadataField(label: "类型", value: typeName))
        }

        append(
            stringValue(properties?.object(forKey: kCGImagePropertyOrientation)).map(orientationName),
            label: "图像方向",
            to: &fields
        )
        if let bits = numberValue(properties?.object(forKey: kCGImagePropertyDepth)) {
            append("\(formattedNumber(bits)) 位", label: "每通道位深", to: &fields)
        }
        if let hasAlpha = properties?.object(forKey: kCGImagePropertyHasAlpha) as? Bool {
            append(hasAlpha ? "是" : "否", label: "透明通道", to: &fields)
        }

        let tiff = properties.flatMap { nestedDictionary($0, key: kCGImagePropertyTIFFDictionary) }
        append(stringValue(tiff?.object(forKey: kCGImagePropertyTIFFSoftware)), label: "软件", to: &fields)
        append(stringValue(tiff?.object(forKey: kCGImagePropertyTIFFArtist)), label: "作者", to: &fields)
        append(stringValue(tiff?.object(forKey: kCGImagePropertyTIFFCopyright)), label: "版权", to: &fields)
        append(stringValue(tiff?.object(forKey: kCGImagePropertyTIFFImageDescription)), label: "图像描述", to: &fields)

        let iptc = properties.flatMap { nestedDictionary($0, key: kCGImagePropertyIPTCDictionary) }
        append(stringValue(iptc?.object(forKey: kCGImagePropertyIPTCByline)), label: "署名", to: &fields)
        append(stringValue(iptc?.object(forKey: kCGImagePropertyIPTCCaptionAbstract)), label: "说明", to: &fields)
        append(stringValue(iptc?.object(forKey: kCGImagePropertyIPTCKeywords)), label: "关键词", to: &fields)
        append(stringValue(iptc?.object(forKey: kCGImagePropertyIPTCCity)), label: "城市", to: &fields)
        append(stringValue(iptc?.object(forKey: kCGImagePropertyIPTCCountryPrimaryLocationName)), label: "国家/地区", to: &fields)

        return fields
    }

    private static func nestedDictionary(_ dictionary: NSDictionary, key: CFString) -> NSDictionary? {
        dictionary.object(forKey: key) as? NSDictionary
    }

    private static func append(
        _ value: String?,
        label: String,
        to fields: inout [MetadataField]
    ) {
        guard let value, !value.isEmpty else {
            return
        }
        fields.append(MetadataField(label: label, value: value))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return formattedNumber(number.doubleValue)
        }
        if let array = value as? NSArray {
            let values = array.compactMap { stringValue($0) }
            return values.isEmpty ? nil : values.joined(separator: ", ")
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func firstNumber(_ value: Any?) -> Double? {
        if let array = value as? NSArray {
            return numberValue(array.firstObject)
        }
        return numberValue(value)
    }

    private static func formattedNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }

    private static func orientationName(_ value: String) -> String {
        switch value {
        case "1":
            return "正常"
        case "2":
            return "水平翻转"
        case "3":
            return "旋转 180°"
        case "4":
            return "垂直翻转"
        case "5":
            return "水平翻转后旋转 270°"
        case "6":
            return "旋转 90°"
        case "7":
            return "水平翻转后旋转 90°"
        case "8":
            return "旋转 270°"
        default:
            return value
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
