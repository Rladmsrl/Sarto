import Foundation

/// Encoding helpers shared across Sarto's Noise, Relay, and Push protocols.
public enum BaseEncoding {
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Encodes raw bytes as RFC 4648 base64url without padding.
    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes an unpadded RFC 4648 base64url string, or returns nil if malformed.
    public static func base64URLDecode(_ text: String) -> Data? {
        guard text.count % 4 != 1 else { return nil }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let valid = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                || (v >= 48 && v <= 57) || v == 45 || v == 95
            if !valid { return nil }
        }
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: standard)
    }

    /// Encodes raw bytes as RFC 4648 lowercase base32 without padding.
    public static func base32Encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var out: [UInt8] = []
        out.reserveCapacity((data.count * 8 + 4) / 5)

        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                let index = (value >> (bits - 5)) & 31
                out.append(base32Alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = (value << (5 - bits)) & 31
            out.append(base32Alphabet[index])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes a lowercase RFC 4648 base32 string (without padding) into raw bytes.
    public static func base32Decode(_ text: String) -> Data? {
        var bits = 0
        var value = 0
        var out: [UInt8] = []
        out.reserveCapacity((text.count * 5) / 8)

        for scalar in text.unicodeScalars {
            let digit: Int
            switch scalar.value {
            case 97...122: digit = Int(scalar.value - 97) // a-z
            case 50...55: digit = Int(scalar.value - 50 + 26) // 2-7
            default: return nil
            }
            value = (value << 5) | digit
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        if bits > 0 && (value & ((1 << bits) - 1)) != 0 {
            return nil
        }
        return Data(out)
    }

    /// Encodes raw bytes as lowercase hex.
    public static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes a hex string into bytes, or returns nil if malformed.
    public static func hexDecode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }
}
