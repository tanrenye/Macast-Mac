import Foundation
import Network
import OSLog

/// DLNA 请求及其来源地址。事件回调必须发回订阅方。
struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    let peer: IPv4Address?
}

struct HTTPResponse {
    var status = 200
    var type = "text/plain; charset=utf-8"
    var headers: [String: String] = [:]
    var body = ""
    var afterSend: (() -> Void)?

    func encode(headOnly: Bool) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 404: "Not Found",
                       405: "Method Not Allowed", 412: "Precondition Failed",
                       413: "Content Too Large", 500: "Internal Server Error"]
        let payload = Data(body.utf8)
        var prefix = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        prefix += "Connection: close\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
        prefix += headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        return headOnly ? Data(prefix.utf8) : Data(prefix.utf8) + payload
    }
}

/// HTTP/1.1 接收端。每个连接处理一个请求，限制请求大小和空闲时间。
final class HTTPServer {
    private let listener: NWListener
    private let logger = Logger(subsystem: "local.mycast.receiver", category: "DLNA")
    private var clients: [UUID: NWConnection] = [:]
    var handle: ((HTTPRequest) -> HTTPResponse)?
    var ready: ((UInt16) -> Void)?
    var failed: ((NWError) -> Void)?

    init(port: UInt16) throws {
        listener = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port { ready?(port.rawValue) }
            case .failed(let error): failed?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, clients.count < 64 else { connection.cancel(); return }
            let id = UUID()
            clients[id] = connection
            connection.start(queue: .main)
            read(id, connection, buffer: Data())
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.close(id)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        for connection in clients.values { connection.cancel() }
        clients.removeAll()
    }

    private func close(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
    }

    private func read(_ id: UUID, _ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, ended, error in
            guard let self, clients[id] != nil else { return }
            guard error == nil else { close(id); return }
            let bytes = buffer + (data ?? Data())
            let limit = 512 * 1024
            guard bytes.count <= limit + 16384 else {
                send(HTTPResponse(status: 413), to: id, headOnly: false)
                return
            }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)), end.lowerBound <= 16384 else {
                if ended || bytes.count > 16384 { send(HTTPResponse(status: 400), to: id, headOnly: false) }
                else { read(id, connection, buffer: bytes) }
                return
            }
            let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let start = lines[0].split(separator: " ")
            guard start.count == 3, start[1].hasPrefix("/"), ["HTTP/1.0", "HTTP/1.1"].contains(start[2]) else {
                send(HTTPResponse(status: 400), to: id, headOnly: false)
                return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else {
                    send(HTTPResponse(status: 400), to: id, headOnly: false)
                    return
                }
                let key = line[..<colon].lowercased()
                guard !key.isEmpty, headers[key] == nil else {
                    send(HTTPResponse(status: 400), to: id, headOnly: false)
                    return
                }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
                send(HTTPResponse(status: 400), to: id, headOnly: false)
                return
            }
            guard length <= limit else { send(HTTPResponse(status: 413), to: id, headOnly: false); return }
            if headers["expect"]?.lowercased() == "100-continue", buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
            let bodyStart = end.upperBound
            guard bytes.count - bodyStart >= length else {
                if ended { send(HTTPResponse(status: 400), to: id, headOnly: false) }
                else { read(id, connection, buffer: bytes) }
                return
            }
            let peer: IPv4Address?
            if case let .hostPort(.ipv4(ip), _) = connection.endpoint { peer = ip }
            else if case let .hostPort(.ipv6(ip), _) = connection.endpoint, ip.isIPv4Mapped {
                peer = IPv4Address(ip.rawValue.suffix(4))
            } else { peer = nil }
            let request = HTTPRequest(method: String(start[0]), target: String(start[1]), headers: headers,
                                      body: bytes.subdata(in: bodyStart..<bodyStart + length), peer: peer)
            let response = handle?(request) ?? HTTPResponse(status: 404)
            let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            logger.info("\(request.method, privacy: .public) \(path, privacy: .private) → HTTP \(response.status)")
            send(response, to: id, headOnly: request.method == "HEAD")
        }
    }

    private func send(_ response: HTTPResponse, to id: UUID, headOnly: Bool) {
        clients[id]?.send(content: response.encode(headOnly: headOnly), contentContext: .finalMessage,
                          isComplete: true, completion: .contentProcessed { [weak self] error in
            guard error == nil, let connection = self?.clients[id] else { self?.close(id); return }
            response.afterSend?()
            // finalMessage 会先发送 FIN。等对端关闭，避免 cancel 提前终止大 XML 响应。
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                self?.close(id)
            }
        })
    }
}
