import Foundation
import ReadBoardContract

enum RemoteAccessSettings {
    private static let legacyTokenKey = "service.http.deviceToken"

    static var configuration: RemoteAccessConfiguration {
        RemoteAccessConfiguration(
            enabled: UserDefaults.standard.object(forKey: "service.http.enabled") as? Bool ?? true,
            allowLAN: UserDefaults.standard.object(forKey: "service.http.allowLAN") as? Bool ?? true,
            port: {
                let value = UserDefaults.standard.integer(forKey: "service.http.port")
                return UInt16(exactly: value > 0 ? value : 7331) ?? 7331
            }())
    }

    static func save(_ value: RemoteAccessConfiguration) {
        UserDefaults.standard.set(value.enabled, forKey: "service.http.enabled")
        UserDefaults.standard.set(value.allowLAN, forKey: "service.http.allowLAN")
        UserDefaults.standard.set(Int(value.port), forKey: "service.http.port")
    }

    static var legacyToken: String? { SecretStore.load(forKey: legacyTokenKey) }
    static func clearLegacyToken() { _ = SecretStore.delete(forKey: legacyTokenKey) }
}

@MainActor
final class RemoteAccessController {
    static let shared = RemoteAccessController()

    private let deviceStore = RemoteDeviceStore()
    private lazy var pairingService = RemotePairingService(deviceStore: deviceStore)
    private var services: ReadBoardServices?
    private var server: ReadBoardHTTPServer?
    private(set) var state: RemoteServiceState = .stopped
    private(set) var lastError: String?
    private var generation = 0

    private init() {}

    func start(services: ReadBoardServices) {
        generation += 1
        let startupGeneration = generation
        self.services = services
        state = .starting
        let legacyToken = RemoteAccessSettings.legacyToken
        Task {
            do {
                try await deviceStore.migrateLegacyToken(legacyToken)
                if legacyToken != nil { RemoteAccessSettings.clearLegacyToken() }
                guard generation == startupGeneration else { return }
                restartServer()
            } catch {
                guard generation == startupGeneration else { return }
                state = .failed
                lastError = "旧版访问令牌迁移失败：\(error.localizedDescription)"
            }
        }
    }

    func stop() {
        generation += 1
        server?.stop()
        server = nil
        state = .stopped
    }

    func snapshot() async -> RemoteAccessSnapshot {
        let config = RemoteAccessSettings.configuration
        return RemoteAccessSnapshot(configuration: config, state: state,
            serviceURLs: state == .running ? serviceURLs(configuration: config) : [],
            devices: await deviceStore.devices(), lastError: lastError)
    }

    func updateConfiguration(_ configuration: RemoteAccessConfiguration) {
        RemoteAccessSettings.save(configuration)
        restartServer()
    }

    func beginPairing() async throws -> RemotePairingChallenge {
        let snapshot = await snapshot()
        guard snapshot.state == .running, !snapshot.serviceURLs.isEmpty else {
            throw RemotePairingError.serviceUnavailable
        }
        return await pairingService.begin(serviceURLs: snapshot.serviceURLs)
    }

    func cancelPairing(challengeID: String) async {
        await pairingService.cancel(id: challengeID)
    }

    func revokeDevice(id: String) async throws {
        try await deviceStore.revoke(id: id)
    }

    private func restartServer() {
        generation += 1
        let currentGeneration = generation
        server?.stop()
        server = nil
        lastError = nil

        let config = RemoteAccessSettings.configuration
        guard config.enabled else {
            state = .stopped
            return
        }
        guard let services else {
            state = .failed
            lastError = "应用服务尚未完成初始化"
            return
        }

        state = .starting
        let value = ReadBoardHTTPServer(services: services, deviceStore: deviceStore,
            pairingService: pairingService, port: config.port, allowLAN: config.allowLAN) {
                [weak self] serverState in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    switch serverState {
                    case .starting:
                        self.state = .starting
                    case .ready:
                        self.state = .running; self.lastError = nil
                    case .waiting(let message):
                        self.state = .starting; self.lastError = message
                    case .failed(let message):
                        self.state = .failed; self.lastError = message
                    case .stopped:
                        if RemoteAccessSettings.configuration.enabled { self.state = .stopped }
                    }
                }
            }
        do {
            try value.start()
            server = value
        } catch {
            state = .failed
            lastError = error.localizedDescription
        }
    }

    private func serviceURLs(configuration: RemoteAccessConfiguration) -> [String] {
        guard configuration.enabled else { return [] }
        let hosts = configuration.allowLAN
            ? RemoteAccessNetwork.localIPv4Addresses()
            : ["127.0.0.1"]
        return hosts.map { "http://\($0):\(configuration.port)" }
    }
}

public final class LocalRemoteAccessGateway: RemoteAccessGateway, @unchecked Sendable {
    public init() {}

    public func snapshot() async -> RemoteAccessSnapshot {
        await RemoteAccessController.shared.snapshot()
    }

    public func updateConfiguration(_ configuration: RemoteAccessConfiguration) async {
        await RemoteAccessController.shared.updateConfiguration(configuration)
    }

    public func beginPairing() async throws -> RemotePairingChallenge {
        try await RemoteAccessController.shared.beginPairing()
    }

    public func cancelPairing(challengeID: String) async {
        await RemoteAccessController.shared.cancelPairing(challengeID: challengeID)
    }

    public func revokeDevice(id: String) async throws {
        try await RemoteAccessController.shared.revokeDevice(id: id)
    }
}
