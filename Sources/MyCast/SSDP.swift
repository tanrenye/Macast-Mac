import Darwin
import Foundation
import OSLog

/// SSDP 可用的 IPv4 网卡及其子网。
struct CastInterface: Hashable {
    let name: String
    let address: String
    let ip: in_addr_t
    let mask: in_addr_t

    static func available() -> [CastInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [CastInterface] = []
        var node = first
        while let current = node {
            let entry = current.pointee
            node = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard flags & (IFF_UP | IFF_MULTICAST) == (IFF_UP | IFF_MULTICAST),
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  address.pointee.sa_family == AF_INET, netmask.pointee.sa_family == AF_INET else { continue }
            var ip = UnsafeRawPointer(address).load(as: sockaddr_in.self).sin_addr
            let mask = UnsafeRawPointer(netmask).load(as: sockaddr_in.self).sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            result.append(CastInterface(name: String(cString: entry.ifa_name), address: String(cString: text),
                                        ip: ip.s_addr, mask: mask.s_addr))
        }
        return result
    }
}

/// 多网卡 SSDP 广播和搜索响应。网卡变化时重新加入组播。
final class SSDP {
    static let device = "urn:schemas-upnp-org:device:MediaRenderer:1"
    private let group = inet_addr("239.255.255.250")
    private let usn: String
    private let port: UInt16
    private let blocked: Set<String>
    private let targets: [String]
    private var senders: [CastInterface: Int32] = [:]
    var interfaces: [CastInterface] { senders.keys.sorted { $0.name < $1.name } }
    private(set) var lastSearch: AppMessage?
    private(set) var lastSearchTime: Date?
    private(set) var lastError: AppMessage? {
        didSet {
            if let lastError, lastError != oldValue { logger.error("\(lastError.english, privacy: .public)") }
        }
    }
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var descriptor: Int32 = -1
    private var ticks = 0
    private var retryAnnouncement = false
    private var pendingSearches = 0
    private let logger = Logger(subsystem: "local.mycast.receiver", category: "SSDP")
    private let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    init(uuid: String, port: UInt16, blocked: Set<String>) {
        usn = "uuid:\(uuid)"
        self.port = port
        self.blocked = blocked
        targets = ["upnp:rootdevice", usn, Self.device] + DLNAService.allCases.map(\.urn)
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try option(fd, SOL_SOCKET, SO_REUSEPORT, Int32(1))
            var address = socketAddress(ip: INADDR_ANY, port: 1900)
            guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(fd)
            throw error
        }
        descriptor = fd
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        read.setEventHandler { [weak self] in self?.receive() }
        read.setCancelHandler { close(fd) }
        source = read
        read.resume()
        refresh()
        let clock = DispatchSource.makeTimerSource(queue: .main)
        clock.schedule(deadline: .now() + 5, repeating: .seconds(5))
        clock.setEventHandler { [weak self] in self?.refresh() }
        timer = clock
        clock.resume()
    }

    func stop() {
        _ = announce("ssdp:byebye", on: interfaces)
        timer?.cancel()
        source?.cancel()
        timer = nil
        source = nil
        descriptor = -1
        senders.values.forEach { close($0) }
        senders.removeAll()
    }

    private func refresh() {
        let candidates = CastInterface.available().filter { !blocked.contains($0.name) }
        let removed = interfaces.filter { !candidates.contains($0) }
        _ = announce("ssdp:byebye", on: removed)
        for nic in removed {
            try? option(descriptor, IPPROTO_IP, IP_DROP_MEMBERSHIP,
                        ip_mreq(imr_multiaddr: in_addr(s_addr: group), imr_interface: in_addr(s_addr: nic.ip)))
            if let fd = senders.removeValue(forKey: nic) { close(fd) }
        }
        var added: [CastInterface] = []
        for nic in candidates where senders[nic] == nil {
            do {
                let fd = try sender(for: nic)
                do {
                    try option(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                               ip_mreq(imr_multiaddr: in_addr(s_addr: group), imr_interface: in_addr(s_addr: nic.ip)))
                } catch {
                    close(fd)
                    throw error
                }
                senders[nic] = fd
                added.append(nic)
            } catch {
                let detail = error.localizedDescription
                lastError = AppMessage("\(nic.name) could not join SSDP multicast (\(detail))",
                                       "\(nic.name) 加入 SSDP 组播失败（\(detail)）")
            }
        }
        ticks += 1
        // 首轮广播失败时，在下一次网卡刷新时重试。
        let announceAll = retryAnnouncement || ticks == 2 || ticks == 4 || ticks.isMultiple(of: 120)
        retryAnnouncement = !announce("ssdp:alive", on: announceAll ? interfaces : added)
    }

    private func receive() {
        // 单次限制处理数量，避免高流量组播阻塞播放器和菜单。
        for _ in 0..<32 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(descriptor, &bytes, bytes.count, 0, $0, &length)
            } }
            guard count > 0 else { return }
            let lines = String(decoding: bytes.prefix(count), as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            let command = lines[0].uppercased().split(whereSeparator: \.isWhitespace)
            guard command.count == 3, command[0] == "M-SEARCH", command[1] == "*",
                  ["HTTP/1.0", "HTTP/1.1"].contains(command[2]) else { continue }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    fields[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            guard let st = fields["st"], !st.isEmpty else { continue }
            let man = fields["man"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
            guard man == nil || man == "ssdp:discover" else { continue }
            let remote = !interfaces.contains { $0.ip == sender.sin_addr.s_addr }
            let senderIP = remote ? String(cString: inet_ntoa(sender.sin_addr)) : ""
            if remote { lastSearchTime = Date() }
            guard let nic = interfaces.filter({ (sender.sin_addr.s_addr & $0.mask) == ($0.ip & $0.mask) })
                    .max(by: { $0.mask.nonzeroBitCount < $1.mask.nonzeroBitCount }) else {
                if remote {
                    lastSearch = AppMessage("Search from \(senderIP) has no SSDP interface on its subnet",
                                            "收到 \(senderIP) 的搜索，但没有对应网段的 SSDP 网卡")
                }
                continue
            }
            let matches = st.lowercased() == "ssdp:all" ? targets : targets.filter { $0.lowercased() == st.lowercased() }
            guard !matches.isEmpty else {
                if remote {
                    let target = st.prefix(80)
                    lastSearch = AppMessage("Search from \(senderIP) did not match any target (\(target))",
                                            "收到 \(senderIP) 的搜索，目标不匹配（\(target)）")
                }
                continue
            }
            guard pendingSearches < 128 else { continue }
            // 部分投屏端只等待很短时间。单目标立即应答，全量搜索在窗口内错开应答。
            let delay = matches.count == 1 || fields["mx"] == "0" ? 0 : Double.random(in: 0...0.25)
            let destination = sender
            pendingSearches += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                pendingSearches -= 1
                guard senders[nic] != nil else { return }
                var sent = false
                for target in matches {
                    let success = send(["HTTP/1.1 200 OK", "CACHE-CONTROL: max-age=1800", "EXT:",
                          "DATE: \(httpDate.string(from: Date()))",
                          "LOCATION: \(location(nic))", "SERVER: macOS UPnP/1.0 MyCast/1.0",
                          "ST: \(target)", "USN: \(identity(target))"], to: destination, using: descriptor)
                    sent = sent || success
                }
                if remote {
                    lastSearch = AppMessage("\(senderIP) · \(sent ? "Search answered" : "Search reply failed")",
                                            "\(senderIP) · \(sent ? "已回复搜索" : "回复搜索失败")")
                }
            }
        }
    }

    private func announce(_ kind: String, on nics: [CastInterface]) -> Bool {
        guard descriptor >= 0 else { return false }
        var success = true
        for nic in nics {
            guard let fd = senders[nic] else { continue }
            for target in targets {
                var fields = ["NOTIFY * HTTP/1.1", "HOST: 239.255.255.250:1900", "NT: \(target)",
                              "NTS: \(kind)", "USN: \(identity(target))"]
                if kind == "ssdp:alive" {
                    fields += ["LOCATION: \(location(nic))", "CACHE-CONTROL: max-age=1800",
                               "SERVER: macOS UPnP/1.0 MyCast/1.0"]
                }
                if !send(fields, to: socketAddress(ip: group, port: 1900), using: fd) {
                    success = false
                    break
                }
            }
        }
        return success
    }

    private func location(_ nic: CastInterface) -> String { "http://\(nic.address):\(port)/description.xml" }
    private func identity(_ target: String) -> String { target == usn ? usn : "\(usn)::\(target)" }

    private func socketAddress(ip: in_addr_t, port: UInt16) -> sockaddr_in {
        sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                    sin_port: port.bigEndian, sin_addr: in_addr(s_addr: ip), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    }

    private func sender(for nic: CastInterface) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try option(fd, IPPROTO_IP, IP_MULTICAST_IF, in_addr(s_addr: nic.ip))
            try option(fd, IPPROTO_IP, IP_MULTICAST_TTL, UInt8(2))
            var address = socketAddress(ip: nic.ip, port: 0)
            guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func send(_ lines: [String], to address: sockaddr_in, using fd: Int32) -> Bool {
        let bytes = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        var address = address
        let sent = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        if sent == bytes.count { return true }
        let detail = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
        lastError = AppMessage("Could not send SSDP packet (\(detail))", "SSDP 发包失败（\(detail)）")
        return false
    }

    private func option<T>(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: T) throws {
        let result = withUnsafeBytes(of: value) { buffer in
            setsockopt(fd, level, name, buffer.baseAddress, socklen_t(buffer.count))
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
