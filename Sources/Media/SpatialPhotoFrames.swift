import Foundation
import ImageIO

/// Reads the left and right images of a spatial photo.
enum NativePhotoFrames {
    static func eyeIndices(_ source: CGImageSource) -> (Int, Int)? {
        let count = CGImageSourceGetCount(source)
        var left: Int?
        var right: Int?
        func check(_ properties: [CFString: Any]?, index: Int?) {
            let value = properties?[kCGImagePropertyGroups]
            let list = value as? [[CFString: Any]] ?? (value as? [CFString: Any]).map { [$0] } ?? []
            for group in list {
                if let item = group[kCGImagePropertyGroupImageIndexLeft] as? Int {
                    left = item
                }
                if let item = group[kCGImagePropertyGroupImageIndexRight] as? Int {
                    right = item
                }
                if group[kCGImagePropertyGroupImageIsLeftImage] as? Bool == true, let index {
                    left = index
                }
                if group[kCGImagePropertyGroupImageIsRightImage] as? Bool == true, let index {
                    right = index
                }
            }
        }
        if count > 1 {
            check(CGImageSourceCopyProperties(source, nil) as? [CFString: Any], index: nil)
            for index in 0..<min(count, 32) {
                check(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any], index: index)
            }
        }
        guard let left, let right, left != right, (0..<count).contains(left), (0..<count).contains(right) else {
            return nil
        }
        return (left, right)
    }

    static func projection(_ source: CGImageSource) -> MediaProjection? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            let shape = CGImageMetadataCopyStringValueWithPath(metadata, nil, "GPano:ProjectionType" as CFString),
            (shape as String).lowercased() == "equirectangular"
        else {
            return nil
        }
        func number(_ name: String) -> Int? {
            guard let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, ("GPano:" + name) as CFString)
            else {
                return nil
            }
            return Int(value as String)
        }
        // The renderer expects a whole equirectangular sphere. A cropped
        // Photo Sphere needs its own projection before it can auto-open in VR.
        guard let width = number("FullPanoWidthPixels"), let height = number("FullPanoHeightPixels"),
            width > 0, height > 0, number("CroppedAreaImageWidthPixels") == width,
            number("CroppedAreaImageHeightPixels") == height,
            (number("CroppedAreaLeftPixels") ?? 0) == 0, (number("CroppedAreaTopPixels") ?? 0) == 0
        else {
            return nil
        }
        return .sphere
    }

    static func read(_ url: URL, maxSide: Int = 4096) -> (CGImage, CGImage?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return read(source, maxSide: maxSide)
    }

    static func read(_ source: CGImageSource, maxSide: Int) -> (CGImage, CGImage?)? {
        let count = CGImageSourceGetCount(source)
        let eyes = eyeIndices(source)
        // Decode the pixels now, on this background task, so a large photo is not
        // decoded later on the display loop when it is first drawn.
        let options =
            [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: (eyes == nil ? maxSide : min(maxSide, 3072))
            ] as CFDictionary
        func decode(_ index: Int) -> CGImage? {
            guard (0..<count).contains(index) else {
                return nil
            }
            return CGImageSourceCreateThumbnailAtIndex(source, index, options)
        }
        if let (left, right) = eyes, let leftImage = decode(left), let rightImage = decode(right) {
            return (leftImage, rightImage)
        }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        return (decode(primary) ?? decode(0)).map { ($0, nil) }
    }
}
