import Foundation
import CryptoKit

/// FastCDC content-defined chunking.
/// Produces stable chunk boundaries so editing a file only invalidates ~1-2 chunks.
/// Parameters: min=16KB, avg=64KB, max=256KB
public struct FastCDC {

    public static let minSize = 16_384    // 16 KB
    public static let avgSize = 65_536    // 64 KB
    public static let maxSize = 262_144   // 256 KB

    // Gear hash table — deterministic random values per byte value
    private static let gear: [UInt64] = {
        // Standard FastCDC gear table (first 256 values)
        var table = [UInt64](repeating: 0, count: 256)
        var seed: UInt64 = 0xbaadf00d_deadbeef
        for i in 0..<256 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            table[i] = seed
        }
        return table
    }()

    public struct Chunk {
        public let offset: Int
        public let length: Int
        public let hash: String   // SHA-256 hex of plaintext chunk
    }

    /// Split data into content-defined chunks.
    /// Returns array of Chunk descriptors. Caller encrypts each chunk separately.
    public static func split(_ data: Data) -> [Chunk] {
        var chunks: [Chunk] = []
        var offset = 0
        let total = data.count

        while offset < total {
            let remaining = total - offset

            if remaining <= minSize {
                // Last small chunk
                let hash = computeHash(data, offset: offset, length: remaining)
                chunks.append(Chunk(offset: offset, length: remaining, hash: hash))
                break
            }

            let length = findBoundary(data, offset: offset, remaining: remaining)
            let hash = computeHash(data, offset: offset, length: length)
            chunks.append(Chunk(offset: offset, length: length, hash: hash))
            offset += length
        }

        return chunks
    }

    private static func findBoundary(_ data: Data, offset: Int, remaining: Int) -> Int {
        let maskS: UInt64 = 0x0003590703530000  // avg size mask
        let maskL: UInt64 = 0x0000d90303530000  // large size mask

        var fp: UInt64 = 0
        var i = minSize
        let limit = min(remaining, maxSize)

        data.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

            // Small region: use stricter mask
            let normalEnd = min(remaining, avgSize)
            while i < normalEnd {
                fp = (fp >> 1) &+ gear[Int(ptr[offset + i])]
                if (fp & maskS) == 0 { return }
                i += 1
            }

            // Large region: use looser mask
            while i < limit {
                fp = (fp >> 1) &+ gear[Int(ptr[offset + i])]
                if (fp & maskL) == 0 { return }
                i += 1
            }
        }

        return i
    }

    private static func computeHash(_ data: Data, offset: Int, length: Int) -> String {
        let slice = data[offset..<(offset + length)]
        let digest = SHA256.hash(data: slice)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
