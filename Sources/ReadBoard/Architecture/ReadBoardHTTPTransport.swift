import Foundation
import Network
import ReadBoardContract

public enum ReadBoardAPI {
    public static let version = "1"
    public static let versionHeader = "x-readboard-api-version"
    public static let maximumRequestBytes = 2 * 1_024 * 1_024
}

public struct ReadBoardHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public struct ReadBoardHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

private struct APIErrorBody: Codable { let error: String; let message: String }
private struct ContentStateRequest: Codable { let contentID: Int64; let value: Bool }
private struct ContentIDRequest: Codable { let contentID: Int64 }
private struct RuntimeSnapshotRequest: Codable { let refreshCounts: Bool }

/// 与 socket 无关的可测试路由器。所有错误都被转换为稳定 JSON，不把数据库或平台异常堆栈暴露给客户端。
public struct ReadBoardHTTPRouter: Sendable {
    private let services: ReadBoardServices
    private let bearerToken: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(services: ReadBoardServices, bearerToken: String) {
        self.services = services; self.bearerToken = bearerToken
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func handle(_ request: ReadBoardHTTPRequest) async -> ReadBoardHTTPResponse {
        if request.path == "/health" {
            return json(["status": "ok", "apiVersion": ReadBoardAPI.version])
        }
        guard request.path.hasPrefix("/api/v1/") else { return failure(404, "not_found", "接口不存在") }
        guard request.headers[ReadBoardAPI.versionHeader] == ReadBoardAPI.version else {
            return failure(426, "version_mismatch", "客户端与服务端 API 版本不兼容")
        }
        guard request.headers["authorization"] == "Bearer \(bearerToken)", !bearerToken.isEmpty else {
            return failure(401, "unauthorized", "设备令牌无效")
        }
        guard request.body.count <= ReadBoardAPI.maximumRequestBytes else {
            return failure(413, "request_too_large", "请求体超过限制")
        }

        do {
            switch (request.method.uppercased(), request.path) {
            case ("POST", "/api/v1/library/page"):
                return json(try await services.library.page(try decode(ContentQuery.self, request.body)))
            case ("GET", "/api/v1/library/snapshot"):
                return json(try await services.library.snapshot())
            case ("POST", "/api/v1/library/read"):
                let value = try decode(ContentStateRequest.self, request.body)
                return json(try await services.library.setRead(contentID: value.contentID, isRead: value.value))
            case ("POST", "/api/v1/library/star"):
                let value = try decode(ContentStateRequest.self, request.body)
                return json(try await services.library.setStarred(contentID: value.contentID, isStarred: value.value))
            case ("POST", "/api/v1/library/mark-read"):
                return json(try await services.library.markRead(filter: try decode(ContentFilter.self, request.body)))
            case ("POST", "/api/v1/content/detail"):
                let value = try decode(ContentIDRequest.self, request.body)
                return json(try await services.contentDetail.detail(contentID: value.contentID))
            case ("GET", "/api/v1/sources/catalog"):
                return json(try await services.sourceCatalog.snapshot())
            case ("POST", "/api/v1/runtime/snapshot"):
                let value = try decode(RuntimeSnapshotRequest.self, request.body)
                return json(await services.runtimeStatus.snapshot(refreshCounts: value.refreshCounts))
            case ("POST", "/api/v1/processing/submit"):
                return json(try await services.processing.submit(try decode(ProcessingCommand.self, request.body)))
            case ("GET", "/api/v1/admin/dashboard"):
                return json(await services.administration.dashboardStatistics())
            case ("GET", "/api/v1/admin/problems"):
                return json(await services.administration.operationalProblemCounts())
            case ("GET", "/api/v1/auth/status"):
                return json(await services.authentication.statuses())
            case ("GET", "/api/v1/configuration"):
                return json(await services.configuration.snapshot())
            case ("GET", "/api/v1/maintenance"):
                return json(await services.maintenance.snapshot())
            default:
                return failure(404, "not_found", "接口不存在")
            }
        } catch let error as DecodingError {
            return failure(400, "invalid_request", String(describing: error))
        } catch {
            return failure(500, "operation_failed", error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    private func json<T: Encodable>(_ value: T, status: Int = 200) -> ReadBoardHTTPResponse {
        do {
            return ReadBoardHTTPResponse(status: status,
                headers: ["content-type": "application/json; charset=utf-8",
                          ReadBoardAPI.versionHeader: ReadBoardAPI.version],
                body: try encoder.encode(value))
        } catch { return failure(500, "encoding_failed", "服务响应编码失败") }
    }

    private func failure(_ status: Int, _ code: String, _ message: String) -> ReadBoardHTTPResponse {
        let body = (try? encoder.encode(APIErrorBody(error: code, message: message))) ?? Data()
        return ReadBoardHTTPResponse(status: status,
            headers: ["content-type": "application/json; charset=utf-8",
                      ReadBoardAPI.versionHeader: ReadBoardAPI.version], body: body)
    }
}

/// 小型 HTTP/1.1 服务。默认只绑定回环地址；LAN 暴露必须显式开启。
public final class ReadBoardHTTPServer: @unchecked Sendable {
    private let router: ReadBoardHTTPRouter
    private let port: NWEndpoint.Port
    private let allowLAN: Bool
    private let queue = DispatchQueue(label: "readboard.http.server", qos: .utility)
    private var listener: NWListener?
    private let lock = NSLock()

    public init(services: ReadBoardServices, token: String, port: UInt16 = 7331, allowLAN: Bool = true) {
        self.router = ReadBoardHTTPRouter(services: services, bearerToken: token)
        self.port = NWEndpoint.Port(rawValue: port) ?? 7331
        self.allowLAN = allowLAN
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        let host: NWEndpoint.Host = allowLAN ? "0.0.0.0" : "127.0.0.1"
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let value = try NWListener(using: parameters)
        value.newConnectionHandler = { [weak self] in self?.accept($0) }
        value.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("[http] listener failed: \(error)\n", stderr)
            }
        }
        value.start(queue: queue)
        listener = value
    }

    public func stop() {
        lock.lock(); let value = listener; listener = nil; lock.unlock()
        value?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > ReadBoardAPI.maximumRequestBytes + 16 * 1_024 {
                self.send(.init(status: 413), on: connection); return
            }
            if let request = self.parse(buffer) {
                Task { self.send(await self.router.handle(request), on: connection) }
            } else if complete || error != nil {
                self.send(.init(status: 400), on: connection)
            } else {
                self.receive(connection, accumulated: buffer)
            }
        }
    }

    private func parse(_ data: Data) -> ReadBoardHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestLine = first.split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return ReadBoardHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
            headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func send(_ response: ReadBoardHTTPResponse, on connection: NWConnection) {
        let reason: String = switch response.status {
        case 200: "OK"; case 400: "Bad Request"; case 401: "Unauthorized"
        case 404: "Not Found"; case 413: "Payload Too Large"; case 426: "Upgrade Required"
        default: "Internal Server Error"
        }
        var headers = response.headers
        headers["content-length"] = String(response.body.count)
        headers["connection"] = "close"
        let text = "HTTP/1.1 \(response.status) \(reason)\r\n"
            + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        var bytes = Data(text.utf8); bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
