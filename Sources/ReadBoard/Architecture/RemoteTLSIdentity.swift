import CryptoKit
import Foundation
import Security

struct RemoteTLSIdentity: @unchecked Sendable {
    let identity: sec_identity_t
    let certificateFingerprint: String
}

actor RemoteTLSIdentityStore {
    private static let containerPassphrase = "ReadBoard-Local-TLS-Identity-v1"
    private let fileURL: URL
    private var cached: RemoteTLSIdentity?

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
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: Self.containerPassphrase]
            as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &imported)
        guard status == errSecSuccess,
              let values = imported as? [[String: Any]],
              let first = values.first,
              let rawIdentity = first[kSecImportItemIdentity as String] else {
            throw RemoteTLSIdentityError.importFailed(status)
        }
        let identityRef = rawIdentity as! SecIdentity
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
}

enum RemoteTLSIdentityError: LocalizedError {
    case generationFailed(String)
    case importFailed(OSStatus)
    case certificateMissing

    var errorDescription: String? {
        switch self {
        case .generationFailed(let message):
            "无法生成远程访问证书：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .importFailed(let status): "无法载入远程访问证书（\(status)）"
        case .certificateMissing: "远程访问证书不完整"
        }
    }
}
