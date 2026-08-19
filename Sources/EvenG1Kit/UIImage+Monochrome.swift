

#if canImport(UIKit)
import UIKit

extension UIImage {
    /// Converts the image to a 1-bit monochrome buffer (MSB first, top-down, no
    /// row padding). Returns width * height / 8 bytes.
    public func to1BitRaw(width: Int, height: Int, threshold: UInt8 = 128) -> Data? {
        // Render to 8-bit grayscale first.
        UIGraphicsBeginImageContext(CGSize(width: width, height: height))
        self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()
        guard let cg = rendered.cgImage else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var gray = Data(count: width * height)
        let ok = gray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: 0
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        let gbytes = [UInt8](gray)

        var out = Data()
        out.reserveCapacity((width * height + 7) / 8)
        var byte: UInt8 = 0
        var bitIndex = 0
        for y in 0..<height {
            for x in 0..<width {
                let v = gbytes[y*width + x]
                let bit: UInt8 = (v < threshold) ? 1 : 0 // 1 = lit pixel
                byte |= (bit << (7 - bitIndex))
                bitIndex += 1
                if bitIndex == 8 {
                    out.append(byte)
                    byte = 0
                    bitIndex = 0
                }
            }
        }
        if bitIndex != 0 { out.append(byte) }
        return out
    }
}
#endif
