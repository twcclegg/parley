import CryptoKit
import Foundation

/// Helpers for OpenSSH public key lines such as `ssh-ed25519 AAAA… comment`.
public enum OpenSSHKey {
    /// The key's type and its SHA-256 fingerprint as `ssh-keygen -l` prints it, `SHA256:…`.
    public static func fingerprint(of line: String) -> (type: String, fingerprint: String)? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        let trimmed = digest.replacingOccurrences(of: "=", with: "")
        return (String(fields[0]), "SHA256:" + trimmed)
    }
}
