
import Foundation

/// CRC-32/XZ (reflected polynomial 0xEDB88320, init and final XOR 0xFFFFFFFF).
/// Returns host endian; serialize it big-endian.
public func crc32xz(of data: Data, withPrefix prefix: [UInt8] = []) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    func step(_ b: UInt8) {
        var c = crc ^ UInt32(b)
        for _ in 0..<8 {
            if (c & 1) != 0 {
                c = (c >> 1) ^ 0xEDB88320
            } else {
                c = c >> 1
            }
        }
        crc = c
    }
    prefix.forEach(step)
    data.forEach(step)
    crc ^= 0xFFFFFFFF
    return crc
}
