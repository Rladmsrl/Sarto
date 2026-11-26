import CryptoKit
import Foundation

/// Sarto's update keys, raw Ed25519 public keys in standard base64. They must match
/// tools/sarto/update-keys.json, which the release signs against; a test holds them together.
/// A signature under either key of a purpose is accepted, so a key can be replaced without
/// stranding anyone.
public enum SartoUpdateKeys {
    public static let release: [String] = [
        "Z7cDyHho3VK4aOcQcEJ66AeIZJn0ufVY9JHOiqSFEE8=",
        "S5mF3JjChaxEZMKsW2rPHvY/1TvlOEfHnZxNS5Ih6pg=",
    ]
    public static let sources: [String] = [
        "7BXNxnBBR1l4MuBqHnYFFQS9CuUEjnuiQwsfYz3uIQE=",
        "W7RZAHJ/JOJVkdE/OkEuixl/+nh9C4YLlbjmvSfsJis=",
    ]
}

public enum UpdateSignature {
    /// Whether `signature` is an Ed25519 signature of `message` under one of `keys`.
    public static func verify(message: Data, signature: Data, keys: [String]) -> Bool {
        guard signature.count == 64 else { return false }
        return keys.contains { raw in
            guard let bytes = Data(base64Encoded: raw),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
            else { return false }
            return key.isValidSignature(signature, for: message)
        }
    }

    /// What the release key signs for an update file: its name, a newline and its bytes, so one
    /// channel's signed file cannot pass as another's.
    public static func updateFileMessage(name: String, file: Data) -> Data {
        Data("\(name)\n".utf8) + file
    }

    /// Whether `signatureFile`, the `<name>.sig` a release uploads, signs update file `name`: the
    /// standard base64 of 64 bytes, then at most the one newline readers ignore.
    public static func verifyUpdateFile(
        name: String,
        file: Data,
        signatureFile: Data,
        keys: [String] = SartoUpdateKeys.release
    ) -> Bool {
        guard signatureFile.count <= 90,
              let text = String(data: signatureFile, encoding: .ascii)
        else { return false }
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard body.count == 88, body.hasSuffix("=="),
              body.dropLast(2).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }),
              let signature = Data(base64Encoded: body)
        else { return false }
        return verify(message: updateFileMessage(name: name, file: file), signature: signature, keys: keys)
    }
}

public enum Base64URL {
    /// Decodes unpadded base64url; nil for anything outside its alphabet.
    public static func decode(_ text: String) -> Data? {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}

public enum FileDigest {
    /// The SHA-512 of a file, read in pieces so a large download never sits in memory whole.
    public static func sha512(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
