import Foundation
import ModelBarCore
import Network

/// 只监听本机的 HTTP 服务：接收 Codex 的 Responses 请求，转给上游的 Chat 接口。
/// 日志只记录路径、状态和耗时，不记录密钥和对话内容。
final class BridgeServer: @unchecked Sendable {
    private let configFile: URL
    private let port: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "modelbar.bridge")
    private let session: URLSession

    init(configFile: URL, port: Int) throws {
        self.configFile = configFile
        self.port = port

        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ConfigError("端口无效：\(port)")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                BridgeLog.write("listening on 127.0.0.1:\(self.port)")
            case .failed(let error):
                BridgeLog.write("listener failed: \(error)")
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let client = BridgeClient(connection: connection, server: self)
            client.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    // MARK: 路由

    func handle(_ request: HTTPRequest, client: BridgeClient) async {
        let started = Date()
        let status = await route(request, client: client)
        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        BridgeLog.write("\(request.method) \(request.path) \(status) \(elapsed)")
    }

    private func route(_ request: HTTPRequest, client: BridgeClient) async -> Int {
        guard isAllowedHost(request.headers["host"]) else {
            await client.respondJSON(status: 403, error: "只接受来自本机的请求")
            return 403
        }
        if request.method == "GET", request.path == "/health" {
            await client.respondJSON(status: 200, object: ["ok": true, "version": BridgeInfo.version])
            return 200
        }

        let config: BridgeConfig
        do {
            config = try BridgeConfig.load(from: configFile)
        } catch {
            await client.respondJSON(status: 500, error: "无法读取转换服务配置")
            return 500
        }
        guard isAuthorized(request.headers["authorization"], tokenFile: config.tokenFile) else {
            await client.respondJSON(status: 401, error: "本机访问令牌不正确")
            return 401
        }

        switch (request.method, request.path) {
        case ("POST", "/v1/responses"):
            return await handleResponses(request, config: config, client: client)
        case ("GET", "/v1/models"):
            return await forwardModels(config: config, client: client)
        default:
            await client.respondJSON(status: 404, error: "转换服务不支持这个路径")
            return 404
        }
    }

    /// 校验 Host，防止网页通过 DNS 重绑定访问本机服务。
    private func isAllowedHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    private func isAuthorized(_ header: String?, tokenFile: String) -> Bool {
        guard let expected = try? String(contentsOfFile: tokenFile, encoding: .utf8), !expected.isEmpty, let header else {
            return false
        }
        let actual = Array(header.utf8)
        let wanted = Array("Bearer \(expected)".utf8)
        guard actual.count == wanted.count else { return false }
        var difference: UInt8 = 0
        for index in actual.indices { difference |= actual[index] ^ wanted[index] }
        return difference == 0
    }

    private func upstreamRequest(path: String, config: BridgeConfig) throws -> URLRequest {
        guard let url = URL(string: config.upstreamBaseURL + path) else { throw ConfigError("上游地址无效") }
        var request = URLRequest(url: url)
        if let keyFile = config.upstreamKeyFile {
            let key = try String(contentsOfFile: keyFile, encoding: .utf8)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: /v1/models

    private func forwardModels(config: BridgeConfig, client: BridgeClient) async -> Int {
        do {
            let request = try upstreamRequest(path: "/models", config: config)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            await client.respond(status: status, contentType: "application/json", body: data)
            return status
        } catch {
            await client.respondJSON(status: 502, error: "无法连接上游接口：\(error.localizedDescription)")
            return 502
        }
    }

    // MARK: /v1/responses

    private func handleResponses(_ request: HTTPRequest, config: BridgeConfig, client: BridgeClient) async -> Int {
        guard request.headers["content-encoding"].map({ $0 == "identity" }) ?? true else {
            await client.respondJSON(status: 415, error: "转换服务不支持压缩的请求")
            return 415
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            await client.respondJSON(status: 400, error: "请求不是有效的 JSON")
            return 400
        }
        let translated = ResponsesBridge.translate(object)

        let bytes: URLSession.AsyncBytes
        let httpResponse: HTTPURLResponse
        do {
            var upstream = try upstreamRequest(path: "/chat/completions", config: config)
            upstream.httpMethod = "POST"
            upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
            upstream.setValue(translated.isStreaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
            upstream.httpBody = try JSONSerialization.data(withJSONObject: translated.body, options: [.withoutEscapingSlashes])
            let (stream, response) = try await session.bytes(for: upstream)
            guard let http = response as? HTTPURLResponse else { throw ConfigError("上游返回了无效的响应") }
            bytes = stream
            httpResponse = http
        } catch {
            await client.respondJSON(status: 502, error: "无法连接上游接口：\(error.localizedDescription)")
            return 502
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            await forwardUpstreamError(status: httpResponse.statusCode, bytes: bytes, client: client)
            return httpResponse.statusCode
        }

        let writer = ResponsesStreamWriter(model: translated.model, routes: translated.routes)
        let isEventStream = httpResponse.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") ?? false
        if translated.isStreaming {
            await client.startEventStream()
            await client.send(writer.start())
        }
        let events = await readUpstream(bytes, isEventStream: isEventStream, writer: writer) { events in
            if translated.isStreaming { await client.send(events) }
        }
        if translated.isStreaming {
            await client.send(events)
            await client.close()
        } else {
            let status = (writer.response["status"] as? String) == "failed" ? 502 : 200
            await client.respondJSON(status: status, object: writer.response)
            return status
        }
        return 200
    }

    /// 按字节切行，不用系统的按行读取：它会把正文里的 U+2028 当成换行，切坏 JSON。
    private func readUpstream(
        _ bytes: URLSession.AsyncBytes,
        isEventStream: Bool,
        writer: ResponsesStreamWriter,
        deliver: ([BridgeEvent]) async -> Void
    ) async -> [BridgeEvent] {
        do {
            if !isEventStream {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                guard let completion = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return writer.fail(message: "上游返回的内容无法解析", code: "invalid_upstream_response")
                }
                await deliver(writer.consumeCompletion(completion))
                return writer.finish()
            }

            var line = [UInt8]()
            lineLoop: for try await byte in bytes {
                guard byte == 0x0A else {
                    line.append(byte)
                    continue
                }
                defer { line.removeAll(keepingCapacity: true) }
                switch Self.parseSSELine(line) {
                case .ignore:
                    continue
                case .done:
                    break lineLoop
                case .chunk(let chunk):
                    if let error = chunk["error"] {
                        return writer.fail(message: Self.errorMessage(error), code: "upstream_error")
                    }
                    await deliver(writer.consume(chunk))
                }
            }
            return writer.finish()
        } catch is CancellationError {
            return []
        } catch {
            return writer.fail(message: "上游连接中断：\(error.localizedDescription)", code: "upstream_disconnected")
        }
    }

    private enum SSELine {
        case ignore
        case done
        case chunk([String: Any])
    }

    private static func parseSSELine(_ raw: [UInt8]) -> SSELine {
        var bytes = raw[...]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        guard bytes.starts(with: Array("data:".utf8)) else { return .ignore }
        bytes = bytes.dropFirst(5)
        while bytes.first == 0x20 { bytes = bytes.dropFirst() }
        if bytes.elementsEqual(Array("[DONE]".utf8)) { return .done }
        guard let chunk = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return .ignore }
        return .chunk(chunk)
    }

    private static func errorMessage(_ error: Any) -> String {
        if let error = error as? [String: Any], let message = error["message"] as? String { return message }
        if let error = error as? String { return error }
        return "上游接口返回了错误"
    }

    private func forwardUpstreamError(status: Int, bytes: URLSession.AsyncBytes, client: BridgeClient) async {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 64 * 1024 { break }
            }
        } catch {}
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] != nil {
            await client.respond(status: status, contentType: "application/json", body: data)
            return
        }
        let text = String(data: data.prefix(500), encoding: .utf8) ?? ""
        await client.respondJSON(status: status, error: "上游接口返回 HTTP \(status)" + (text.isEmpty ? "" : "：\(text)"))
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

/// 一个请求对应一条连接，回复后关闭。
final class BridgeClient: @unchecked Sendable {
    private static let maxRequestSize = 256 * 1024 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let server: BridgeServer
    private var buffer = Data()
    private var task: Task<Void, Never>?

    init(connection: NWConnection, server: BridgeServer) {
        self.connection = connection
        self.server = server
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled:
                task?.cancel()
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let request = parseRequest() {
                task = Task { await server.handle(request, client: self) }
                return
            }
            if error != nil || isComplete || buffer.count > Self.maxRequestSize {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func parseRequest() -> HTTPRequest? {
        guard let headerRange = buffer.range(of: Self.headerEnd),
              let head = String(data: buffer[buffer.startIndex..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]

        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: Data(body))
    }

    // MARK: 回复

    func respond(status: Int, contentType: String, body: Data) async {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        await write(data)
        await close()
    }

    func respondJSON(status: Int, object: [String: Any]) async {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        await respond(status: status, contentType: "application/json", body: body)
    }

    func respondJSON(status: Int, error: String) async {
        await respondJSON(status: status, object: ["error": ["message": error, "type": "modelbar_bridge"]])
    }

    func startEventStream() async {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        await write(Data(head.utf8))
    }

    func send(_ events: [BridgeEvent]) async {
        guard !events.isEmpty else { return }
        var data = Data()
        for event in events { data.append(event.sseData) }
        await write(data)
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }

    private func write(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private static func reason(_ status: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }
}

enum BridgeLog {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        fputs("\(stamp) \(message)\n", stderr)
    }
}
