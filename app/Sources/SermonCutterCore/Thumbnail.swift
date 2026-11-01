import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The stream's YouTube thumbnail, which is the Sunday's banner.
public enum YouTubeThumbnail {
    /// Where YouTube keeps a video's thumbnail, best first. The first two are
    /// 1280x720 when the video has them; the last two are 4:3 with black bars
    /// above and below, which `banner(from:)` crops off.
    public static func candidates(_ id: String) -> [URL] {
        ["maxresdefault", "hq720", "sddefault", "hqdefault"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg")
        }
    }

    /// The 16:9 middle of a picture `width` by `height`; the whole picture
    /// when it's 16:9 already (to within a pixel).
    public static func crop16x9(width w: Int, height h: Int) -> CGRect {
        if w * 9 > h * 16 {
            let cw = Int((Double(h) * 16 / 9).rounded())
            if cw >= w - 1 { return CGRect(x: 0, y: 0, width: w, height: h) }
            return CGRect(x: (w - cw) / 2, y: 0, width: cw, height: h)
        }
        let ch = Int((Double(w) * 9 / 16).rounded())
        if ch >= h - 1 { return CGRect(x: 0, y: 0, width: w, height: h) }
        return CGRect(x: 0, y: (h - ch) / 2, width: w, height: ch)
    }

    /// The thumbnail as a 16:9 JPEG for the banner: as YouTube sent it when
    /// it's 16:9 already, otherwise its middle. Nil when it isn't a picture
    /// or is only YouTube's tiny placeholder.
    public static func banner(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= 320
        else { return nil }
        let rect = crop16x9(width: image.width, height: image.height)
        let whole = Int(rect.width) == image.width && Int(rect.height) == image.height
        if whole, let type = CGImageSourceGetType(source), type as String == UTType.jpeg.identifier {
            return data
        }
        guard let picture = whole ? .some(image) : image.cropping(to: rect) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, picture, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
