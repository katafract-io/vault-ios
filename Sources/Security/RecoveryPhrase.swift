import Foundation
import CryptoKit

/// BIP39-compatible round-trip between a 256-bit master key and a 24-word
/// recovery phrase.
///
/// Standard BIP39 construction:
///   1. Take 32 bytes of entropy.
///   2. Compute SHA256(entropy); take first 8 bits as checksum.
///   3. Concatenate entropy (256 bits) + checksum (8 bits) = 264 bits.
///   4. Split into 24 groups of 11 bits each. Each group indexes a word.
///
/// Verification on restore walks the same path in reverse and asserts the
/// recomputed checksum matches — catches typos in ~99.6% of single-word
/// substitutions. (Not a substitute for "please save this somewhere safe,"
/// but it catches the "I think I wrote 'abundance' but you wrote
/// 'abandoned'" class of errors.)
enum RecoveryPhrase {

    enum Error: Swift.Error, LocalizedError {
        case wrongWordCount(got: Int)
        case unknownWord(String)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .wrongWordCount(let got):
                return "Expected 24 words, got \(got)."
            case .unknownWord(let w):
                return "\"\(w)\" is not a valid BIP39 word."
            case .checksumMismatch:
                return "Recovery phrase checksum doesn't match. Check for typos."
            }
        }
    }

    /// Encode 32 bytes → 24 words.
    static func encode(entropy: Data) -> [String] {
        precondition(entropy.count == 32, "RecoveryPhrase expects exactly 32 bytes")
        let checksum = Data(SHA256.hash(data: entropy)).prefix(1)  // 1 byte = 8 bits of checksum
        var bitString = ""
        for byte in entropy {
            bitString += String(byte, radix: 2).leftPadded(to: 8, with: "0")
        }
        bitString += String(checksum[0], radix: 2).leftPadded(to: 8, with: "0")

        var words: [String] = []
        words.reserveCapacity(24)
        for i in stride(from: 0, to: bitString.count, by: 11) {
            let start = bitString.index(bitString.startIndex, offsetBy: i)
            let end = bitString.index(start, offsetBy: 11)
            let slice = bitString[start..<end]
            let idx = Int(slice, radix: 2)!
            words.append(BIP39WordList.words[idx])
        }
        return words
    }

    /// Decode 24 words → 32 bytes. Throws on wrong count, unknown word, or
    /// checksum mismatch.
    static func decode(words: [String]) throws -> Data {
        guard words.count == 24 else {
            throw Error.wrongWordCount(got: words.count)
        }
        var bitString = ""
        for word in words {
            let normalized = word.lowercased().trimmingCharacters(in: .whitespaces)
            guard let idx = BIP39WordList.words.firstIndex(of: normalized) else {
                throw Error.unknownWord(word)
            }
            bitString += String(idx, radix: 2).leftPadded(to: 11, with: "0")
        }

        // 264 bits = 33 bytes, split into 32 bytes entropy + 1 byte checksum (high 8 bits of byte 33).
        var entropy = Data(capacity: 32)
        for i in stride(from: 0, to: 32 * 8, by: 8) {
            let start = bitString.index(bitString.startIndex, offsetBy: i)
            let end = bitString.index(start, offsetBy: 8)
            entropy.append(UInt8(bitString[start..<end], radix: 2)!)
        }
        let checksumBits = String(
            bitString[bitString.index(bitString.startIndex, offsetBy: 256)...])
        guard let providedChecksum = UInt8(checksumBits, radix: 2) else {
            throw Error.checksumMismatch
        }
        let expectedChecksum = Data(SHA256.hash(data: entropy)).first!
        guard providedChecksum == expectedChecksum else {
            throw Error.checksumMismatch
        }
        return entropy
    }

    /// Convenience: current master key → 24 words.
    static func phrase(for key: SymmetricKey) -> [String] {
        let bytes = key.withUnsafeBytes { Data($0) }
        return encode(entropy: bytes)
    }

    /// Convenience: 24 words → SymmetricKey.
    static func key(from words: [String]) throws -> SymmetricKey {
        let data = try decode(words: words)
        return SymmetricKey(data: data)
    }
}

private extension String {
    func leftPadded(to length: Int, with char: Character) -> String {
        guard count < length else { return self }
        return String(repeating: char, count: length - count) + self
    }
}
