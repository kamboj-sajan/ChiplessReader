import Foundation

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) — a common choice for embedded
/// serial protocols, used here by `ReferenceCodec`. If your Altra Waves module's
/// real checksum differs (many R2000-class readers use a simple additive checksum
/// instead), swap this out inside your real `PacketCodec` implementation; nothing
/// above the codec layer depends on which algorithm is used.
public enum CRC16 {
    public static func ccitt(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}
