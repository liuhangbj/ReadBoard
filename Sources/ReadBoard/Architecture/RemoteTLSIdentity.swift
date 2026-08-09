import CryptoKit
import Foundation
import Security

struct RemoteTLSIdentity: @unchecked Sendable {
    let identity: sec_identity_t
    let certificateFingerprint: String
}

private final class RemoteTLSEphemeralKeychain: @unchecked Sendable {
    let reference: SecKeychain
    let fileURL: URL

    init(reference: SecKeychain, fileURL: URL) {
        self.reference = reference
        self.fileURL = fileURL
    }

    deinit {
        SecKeychainDelete(reference)
        try? FileManager.default.removeItem(at: fileURL)
    }
}

actor RemoteTLSIdentityStore {
    private static let containerPassphrase = "ReadBoard-Local-TLS-Identity-v1"
    private let fileURL: URL
    private var cached: RemoteTLSIdentity?
    private var importedKeychain: RemoteTLSEphemeralKeychain?

    init(fileURL: URL = URL(fileURLWithPath: Database.dataDirectory)
        .appendingPathComponent("remote-identity.p12")) {
        self.fileURL = fileURL
    }

    func loadOrCreate() throws -> RemoteTLSIdentity {
        if let cached { return cached }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try createIdentity()
        }
        let value = try loadIdentity()
        cached = value
        return value
    }

    private func createIdentity() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        let temporary = manager.temporaryDirectory
            .appendingPathComponent("readboard-tls-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }

        let key = temporary.appendingPathComponent("key.pem")
        let certificate = temporary.appendingPathComponent("certificate.pem")
        try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                        "-keyout", key.path, "-out", certificate.path,
                        "-days", "3650", "-subj", "/CN=ReadBoard Local Service"])
        try runOpenSSL(["pkcs12", "-export", "-out", fileURL.path,
                        "-inkey", key.path, "-in", certificate.path,
                        "-passout", "pass:\(Self.containerPassphrase)"])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self)
            throw RemoteTLSIdentityError.generationFailed(message)
        }
    }

    private func loadIdentity() throws -> RemoteTLSIdentity {
        let data = try Data(contentsOf: fileURL)
        let keychain = try makeEphemeralImportKeychain()
        var access: SecAccess?
        let accessStatus = SecAccessCreate("ReadBoard Remote TLS" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw RemoteTLSIdentityError.ephemeralKeychainAccessFailed(accessStatus)
        }
        try allowNonInteractiveSigning(access)
        var imported: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: Self.containerPassphrase,
            kSecImportExportKeychain as String: keychain.reference,
            kSecImportExportAccess as String: access,
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess,
              let values = imported as? [[String: Any]],
              let first = values.first,
              let rawIdentity = first[kSecImportItemIdentity as String] else {
            throw RemoteTLSIdentityError.importFailed(status)
        }
        let identityRef = rawIdentity as! SecIdentity
        try verifyPrivateKey(identityRef)
        guard let identity = sec_identity_create(identityRef) else {
            throw RemoteTLSIdentityError.importFailed(status)
        }
        var certificateRef: SecCertificate?
        guard SecIdentityCopyCertificate(identityRef, &certificateRef) == errSecSuccess,
              let certificateRef else {
            throw RemoteTLSIdentityError.certificateMissing
        }
        let certificateData = SecCertificateCopyData(certificateRef) as Data
        let fingerprint = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }.joined()
        return RemoteTLSIdentity(identity: identity, certificateFingerprint: fingerprint)
    }

    private func verifyPrivateKey(_ identity: SecIdentity) throws {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else {
            throw RemoteTLSIdentityError.privateKeyUnavailable
        }
        let digest = Data(repeating: 0x52, count: SHA256.byteCount)
        var error: Unmanaged<CFError>?
        guard SecKeyCreateSignature(
            key,
            .rsaSignatureDigestPKCS1v15SHA256,
            digest as CFData,
            &error) != nil else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw RemoteTLSIdentityError.privateKeySigningFailed(message)
        }
    }

    /// The packaged development app is ad-hoc signed, so the legacy keychain
    /// default ACL may classify the Network.framework signing request as an
    /// unsigned/changed client and display a password dialog.  This keychain is
    /// private to the current process, contains only the self-signed local TLS
    /// key and is deleted at shutdown; signing it without UI is both narrower
    /// and safer than asking the user for an unknown temporary-keychain password.
    private func allowNonInteractiveSigning(_ access: SecAccess) throws {
        guard let rawACLs = SecAccessCopyMatchingACLList(
            access,
            kSecACLAuthorizationSign) else {
            throw RemoteTLSIdentityError.ephemeralKeychainACLFailed(errSecItemNotFound)
        }
        for case let acl as SecACL in rawACLs as NSArray {
            let status = SecACLSetContents(
                acl,
                nil,
                "ReadBoard Remote TLS" as CFString,
                SecKeychainPromptSelector(rawValue: 0))
            guard status == errSecSuccess else {
                throw RemoteTLSIdentityError.ephemeralKeychainACLFailed(status)
            }
        }
    }

    /// PKCS#12 直接导入登录钥匙串时，私钥 ACL 会绑定当次调试包的代码签名。
    /// App 重编译后证书仍可读取，但 TLS 首次签名会以 CSSMERR_CSP_INVALID_KEYATTR_MASK
    /// 卡住。把同一份 P12 导入当前进程专用的临时钥匙串，可保持证书指纹不变，
    /// 同时让每次启动都获得属于当前二进制的可用私钥。
    private func makeEphemeralImportKeychain() throws -> RemoteTLSEphemeralKeychain {
        let manager = FileManager.default
        let url = manager.temporaryDirectory.appendingPathComponent(
            "readboard-remote-tls-\(UUID().uuidString).keychain-db")
        let password = Data(Self.containerPassphrase.utf8)
        var value: SecKeychain?
        let status = password.withUnsafeBytes { bytes in
            SecKeychainCreate(
                url.path,
                UInt32(password.count),
                bytes.baseAddress,
                false,
                nil,
                &value)
        }
        guard status == errSecSuccess, let value else {
            throw RemoteTLSIdentityError.ephemeralKeychainFailed(status)
        }
        let unlockStatus = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(
                value,
                UInt32(password.count),
                bytes.baseAddress,
                true)
        }
        guard unlockStatus == errSecSuccess else {
            SecKeychainDelete(value)
            throw RemoteTLSIdentityError.ephemeralKeychainUnlockFailed(unlockStatus)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let container = RemoteTLSEphemeralKeychain(reference: value, fileURL: url)
        importedKeychain = container
        return container
    }
}

enum RemoteTLSIdentityError: LocalizedError {
    case generationFailed(String)
    case importFailed(OSStatus)
    case certificateMissing
    case ephemeralKeychainFailed(OSStatus)
    case ephemeralKeychainUnlockFailed(OSStatus)
    case ephemeralKeychainAccessFailed(OSStatus)
    case ephemeralKeychainACLFailed(OSStatus)
    case privateKeyUnavailable
    case privateKeySigningFailed(String)

    var errorDescription: String? {
        switch self {
        case .generationFailed(let message):
            "无法生成远程访问证书：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .importFailed(let status): "无法载入远程访问证书（\(status)）"
        case .certificateMissing: "远程访问证书不完整"
        case .ephemeralKeychainFailed(let status): "无法准备远程访问私钥（\(status)）"
        case .ephemeralKeychainUnlockFailed(let status): "无法解锁远程访问私钥（\(status)）"
        case .ephemeralKeychainAccessFailed(let status): "无法配置远程访问私钥权限（\(status)）"
        case .ephemeralKeychainACLFailed(let status): "无法关闭远程访问私钥交互授权（\(status)）"
        case .privateKeyUnavailable: "远程访问证书缺少私钥"
        case .privateKeySigningFailed(let message): "远程访问私钥不可用：\(message)"
        }
    }
}
