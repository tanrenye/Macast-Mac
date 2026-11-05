import Foundation
import Network

/// GENA 订阅按 SID 顺序发送。同一订阅在回调进行时只保留最新状态。
final class GENA {
    private final class Subscription {
        let service: DLNAService
        let callback: URL
        let peer: IPv4Address
        var expires: Date
        var sequence: UInt32 = 0
        var started = false
        var task: URLSessionDataTask?
        var pending: String?

        init(service: DLNAService, callback: URL, peer: IPv4Address, expires: Date) {
            self.service = service
            self.callback = callback
            self.peer = peer
            self.expires = expires
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private var subscriptions: [String: Subscription] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func reset() {
        subscriptions.values.forEach { $0.task?.cancel() }
        subscriptions.removeAll()
    }

    func handle(_ request: HTTPRequest, service: DLNAService, initial: @escaping () -> String) -> HTTPResponse {
        prune()
        guard let peer = request.peer else { return HTTPResponse(status: 412) }
        let headers = request.headers
        let sid = headers["sid"]
        if request.method == "UNSUBSCRIBE" {
            guard let sid, let subscription = subscriptions[sid], subscription.service == service,
                  subscription.peer == peer, headers["callback"] == nil, headers["nt"] == nil else {
                return HTTPResponse(status: 412)
            }
            subscriptions.removeValue(forKey: sid)?.task?.cancel()
            return HTTPResponse()
        }
        guard request.method == "SUBSCRIBE" else { return HTTPResponse(status: 405) }

        let requestedTimeout = headers["timeout"]?.lowercased() ?? "second-1800"
        let seconds = min(1800, max(30, Int(requestedTimeout.dropFirst(7)) ?? 1800))
        let expiration = Date().addingTimeInterval(Double(seconds))
        if let sid {
            guard let subscription = subscriptions[sid], subscription.service == service, subscription.peer == peer,
                  headers["callback"] == nil, headers["nt"] == nil else { return HTTPResponse(status: 412) }
            subscription.expires = expiration
            return HTTPResponse(headers: ["SID": sid, "TIMEOUT": "Second-\(seconds)"])
        }

        // 要求回调使用订阅端的 IPv4 字面地址，禁止借接收器向其他主机发送请求。
        guard headers["nt"]?.lowercased() == "upnp:event", subscriptions.count < 64,
              let value = headers["callback"], value.first == "<", let end = value.firstIndex(of: ">"),
              let callback = URL(string: String(value[value.index(after: value.startIndex)..<end])),
              callback.scheme?.lowercased() == "http", let host = callback.host,
              IPv4Address(host) == peer, callback.user == nil, callback.password == nil,
              callback.fragment == nil else { return HTTPResponse(status: 412) }
        let id = "uuid:\(UUID().uuidString.lowercased())"
        let subscription = Subscription(service: service, callback: callback, peer: peer, expires: expiration)
        subscriptions[id] = subscription
        return HTTPResponse(headers: ["SID": id, "TIMEOUT": "Second-\(seconds)"], afterSend: { [weak self, weak subscription] in
            guard let self, let subscription, subscriptions[id] === subscription else { return }
            subscription.started = true
            notify(initial(), id: id, subscription: subscription)
        })
    }

    func publish(_ body: String, service: DLNAService) {
        prune()
        for (id, subscription) in subscriptions where subscription.service == service && subscription.started {
            if subscription.task != nil { subscription.pending = body }
            else { notify(body, id: id, subscription: subscription) }
        }
    }

    private func prune() {
        let now = Date()
        let expired = subscriptions.filter { $0.value.expires <= now }.keys
        for id in expired { subscriptions.removeValue(forKey: id)?.task?.cancel() }
    }

    private func notify(_ body: String, id: String, subscription: Subscription) {
        var request = URLRequest(url: subscription.callback)
        request.httpMethod = "NOTIFY"
        request.httpBody = Data(body.utf8)
        for (key, value) in ["CONTENT-TYPE": DLNA.xmlType, "NT": "upnp:event", "NTS": "upnp:propchange",
                             "SID": id, "SEQ": String(subscription.sequence)] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        subscription.sequence = subscription.sequence == .max ? 1 : subscription.sequence + 1
        let task = session.dataTask(with: request) { [weak self, weak subscription] _, _, _ in
            DispatchQueue.main.async { [weak self, weak subscription] in
                guard let self, let subscription, subscriptions[id] === subscription else { return }
                subscription.task = nil
                if let pending = subscription.pending, subscription.expires > Date() {
                    subscription.pending = nil
                    notify(pending, id: id, subscription: subscription)
                }
            }
        }
        subscription.task = task
        task.resume()
    }
}
