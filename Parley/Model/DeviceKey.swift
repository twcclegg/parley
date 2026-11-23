import CryptoKit
import Foundation
import NIOSSH
import Observation
import ParleyCore
import Security
import UIKit

/// This device's SSH key. It's made in the Secure Enclave where there is one, so the private
/// key never leaves the device; elsewhere (the simulator) it's a P-256 key kept in the Keychain.
@MainActor @Observable
final class DeviceKeyStore {
    struct DeviceKey {
        let privateKey: NIOSSHPrivateKey
        /// The line for `~/.ssh/authorized_keys`.
        let publicKeyLine: String
        let fingerprint: String
        let isSecureEnclave: Bool
    }

    private(set) var key: DeviceKey?
    private(set) var error: String?

    private static let service = "parley.device-key"
    private static let account = "default"
    private static let secureEnclaveTag: UInt8 = 1
    private static let softwareTag: UInt8 = 2

    init() {
        do {
            key = try Self.load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The key, made the first time it's needed.
    func deviceKey() throws -> DeviceKey {
        if let key { return key }
        let made = try Self.create()
        key = made
        error = nil
        return made
    }

    /// Replaces the key with a new one. Servers that trusted the old key must be given the new one.
    func regenerate() throws {
        Self.delete()
        key = nil
        _ = try deviceKey()
    }

    // MARK: - Keychain

    private static func load() throws -> DeviceKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let tag = data.first else {
            throw KeyError.keychain(status)
        }
        let body = data.dropFirst()
        switch tag {
        case secureEnclaveTag:
            return make(.init(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)), secureEnclave: true)
        case softwareTag:
            return make(.init(p256Key: try P256.Signing.PrivateKey(rawRepresentation: body)), secureEnclave: false)
        default:
            throw KeyError.unreadable
        }
    }

    private static func create() throws -> DeviceKey {
        let stored: Data
        let key: DeviceKey
        if SecureEnclave.isAvailable {
            let enclaveKey = try SecureEnclave.P256.Signing.PrivateKey()
            stored = Data([secureEnclaveTag]) + enclaveKey.dataRepresentation
            key = make(.init(secureEnclaveP256Key: enclaveKey), secureEnclave: true)
        } else {
            let softwareKey = P256.Signing.PrivateKey()
            stored = Data([softwareTag]) + softwareKey.rawRepresentation
            key = make(.init(p256Key: softwareKey), secureEnclave: false)
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: stored,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
        return key
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func make(_ privateKey: NIOSSHPrivateKey, secureEnclave: Bool) -> DeviceKey {
        let comment = "parley@" + UIDevice.current.model.lowercased().replacingOccurrences(of: " ", with: "-")
        let line = String(openSSHPublicKey: privateKey.publicKey) + " " + comment
        return DeviceKey(
            privateKey: privateKey,
            publicKeyLine: line,
            fingerprint: OpenSSHKey.fingerprint(of: line)?.fingerprint ?? "",
            isSecureEnclave: secureEnclave
        )
    }

    enum KeyError: LocalizedError {
        case keychain(OSStatus)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                "The Keychain couldn't store or read this device's key (\(status))."
            case .unreadable:
                "This device's saved key couldn't be read. Make a new one in Settings."
            }
        }
    }
}
